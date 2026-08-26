import Foundation

public enum PiTaskRuntimeCoordinatorError: LocalizedError, Sendable {
    case taskNotFound

    public var errorDescription: String? {
        switch self {
        case .taskNotFound: "The Pi task runtime is no longer available."
        }
    }
}

public actor PiTaskRuntimeCoordinator {
    private struct PendingTurn: Sendable {
        let message: String
        let images: [PiImageAttachment]
        let behavior: PiStreamingBehavior
    }

    private struct Record {
        let configuration: PiTaskLaunchConfiguration
        let client: PiRPCClient
        var resumeSessionPath: URL?
        var state: TaskRuntimeState
        var isGenerating: Bool
        var pending: [PendingTurn]
        var listener: Task<Void, Never>?
        var idleEviction: Task<Void, Never>?
        var manuallyStopping: Bool
        var preservesRuntime: Bool
        var lifecycleGeneration: UInt64
    }

    private struct Startup {
        let generation: UInt64
        let task: Task<Void, any Error>
    }

    public nonisolated let events: AsyncStream<PiTaskCoordinatorEvent>

    private let eventSource: ByteBoundedAsyncStream<PiTaskCoordinatorEvent>
    private var records: [PiTaskID: Record] = [:]
    private var lastEmittedSnapshots: [PiTaskID: PiTaskSnapshot] = [:]
    private var startupTasks: [PiTaskID: Startup] = [:]
    private var maximumConcurrentTurns: Int?
    private let idleGracePeriod: TimeInterval

    public init(
        maximumConcurrentTurns: Int? = 2,
        idleGracePeriod: TimeInterval = 30,
        maximumEventBufferedBytes: Int = 32 * 1_024 * 1_024
    ) {
        if let maximumConcurrentTurns {
            self.maximumConcurrentTurns = max(1, min(8, maximumConcurrentTurns))
        } else {
            self.maximumConcurrentTurns = nil
        }
        self.idleGracePeriod = max(0, idleGracePeriod)
        let eventSource = ByteBoundedAsyncStream<PiTaskCoordinatorEvent>(
            maximumBufferedBytes: maximumEventBufferedBytes,
            makeGap: { (.streamGap, 1) },
            isLossy: { event in
                if case let .rpc(_, rpcEvent) = event {
                    return rpcEvent.isLossyStreamDelta
                }
                return false
            }
        )
        events = eventSource.stream
        self.eventSource = eventSource
    }

    deinit {
        eventSource.finish()
        for record in records.values {
            record.listener?.cancel()
            record.idleEviction?.cancel()
        }
        for startup in startupTasks.values { startup.task.cancel() }
    }

    @discardableResult
    public func open(_ configuration: PiTaskLaunchConfiguration) async throws -> PiTaskSnapshot {
        if records[configuration.id] != nil { return try await ensureRunning(configuration.id) }
        let client = PiRPCClient(configuration: .init(
            runtime: configuration.runtime,
            workingDirectory: configuration.workingDirectory,
            sessionPath: configuration.sessionPath,
            projectTrusted: configuration.projectTrusted,
            bridgeURL: configuration.bridgeURL,
            environment: configuration.environment
        ))
        var record = Record(
            configuration: configuration,
            client: client,
            resumeSessionPath: configuration.sessionPath,
            state: .starting,
            isGenerating: false,
            pending: [],
            listener: nil,
            idleEviction: nil,
            manuallyStopping: false,
            preservesRuntime: configuration.hasUserExtensions,
            lifecycleGeneration: 0
        )
        records[configuration.id] = record
        emit(configuration.id)

        let listener = Task { [weak self] in
            for await event in client.events {
                guard let self else { return }
                await self.handle(event, for: configuration.id)
            }
        }
        record.listener = listener
        records[configuration.id] = record

        return try await ensureRunning(configuration.id)
    }

    public func submit(
        to id: PiTaskID,
        message: String,
        images: [PiImageAttachment] = [],
        behavior: PiStreamingBehavior = .followUp
    ) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty,
              var record = records[id] else { return }
        record.idleEviction?.cancel()
        record.idleEviction = nil

        if record.isGenerating {
            records[id] = record
            let command: PiRPCCommand = behavior == .steer
                ? .steer(message: message, images: images)
                : .followUp(message: message, images: images)
            _ = try await record.client.send(command)
            return
        }

        if hasCapacity {
            records[id] = record
            try await beginTurn(id: id, turn: PendingTurn(message: message, images: images, behavior: behavior))
        } else {
            record.pending.append(PendingTurn(message: message, images: images, behavior: behavior))
            record.state = .queued
            records[id] = record
            emit(id)
        }
    }

    public func abort(_ id: PiTaskID) async throws {
        guard let record = records[id] else { return }
        _ = try await record.client.send(.abort, timeout: 10)
    }

    public func respond(_ response: PiExtensionUIResponse, to request: PiExtensionUIRequest, task id: PiTaskID) async throws {
        guard var record = records[id] else { return }
        try await record.client.respond(to: request, with: response)
        record.state = record.isGenerating ? .generating : .ready
        records[id] = record
        emit(id)
    }

    public func stop(_ id: PiTaskID) async {
        guard var record = records[id] else { return }
        record.lifecycleGeneration &+= 1
        let generation = record.lifecycleGeneration
        record.manuallyStopping = true
        record.pending.removeAll()
        record.idleEviction?.cancel()
        record.idleEviction = nil
        records[id] = record
        startupTasks.removeValue(forKey: id)?.task.cancel()
        await record.client.stop()
        if var current = records[id], current.lifecycleGeneration == generation {
            current.state = .stopped
            current.isGenerating = false
            records[id] = current
            emit(id)
        }
        await drainQueue()
    }

    public func close(_ id: PiTaskID) async {
        guard let record = records.removeValue(forKey: id) else { return }
        lastEmittedSnapshots.removeValue(forKey: id)
        record.idleEviction?.cancel()
        record.listener?.cancel()
        startupTasks.removeValue(forKey: id)?.task.cancel()
        emitEvent(.removed(id), byteCost: 64)
        // Remove the record before awaiting process termination. That makes
        // close terminal: a concurrent control action cannot resurrect a task
        // that is being archived, deleted, or explicitly discarded.
        await record.client.stop()
        await drainQueue()
    }

    public func stopAll() async {
        for id in Array(records.keys) { await stop(id) }
    }

    public func snapshots() -> [PiTaskSnapshot] {
        records.values.map(snapshot).sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    public func snapshot(for id: PiTaskID) -> PiTaskSnapshot? {
        records[id].map(snapshot)
    }

    public func client(for id: PiTaskID) -> PiRPCClient? { records[id]?.client }

    /// Starts a retained task process when an idle eviction or manual stop has
    /// reclaimed it. The existing client is reused so its canonical resume
    /// session path and event stream remain authoritative across launches.
    @discardableResult
    public func ensureRunning(_ id: PiTaskID) async throws -> PiTaskSnapshot {
        let running = try await ensureProcessRunning(id)
        scheduleIdleEviction(for: id)
        return records[id].map(snapshot) ?? running
    }

    /// Records the canonical Pi JSONL file assigned after a new task starts so
    /// an evicted process resumes that file instead of creating a new session.
    public func setResumeSessionPath(_ path: URL, for id: PiTaskID) async {
        guard var record = records[id] else { return }
        let standardized = path.standardizedFileURL
        record.resumeSessionPath = standardized
        records[id] = record
        await record.client.setResumeSessionPath(standardized)
        emit(id)
    }

    public func setMaximumConcurrentTurns(_ value: Int?) async {
        maximumConcurrentTurns = value.map { max(1, min(8, $0)) }
        await drainQueue()
    }

    /// Updates preservation after the bridge has resolved active extension resources.
    public func setPreservesRuntime(_ preservesRuntime: Bool, for id: PiTaskID) {
        guard var record = records[id] else { return }
        record.preservesRuntime = preservesRuntime
        records[id] = record
        if preservesRuntime {
            record.idleEviction?.cancel()
        } else if !record.isGenerating {
            scheduleIdleEviction(for: id)
        }
        emit(id)
    }

    private var hasCapacity: Bool {
        guard let maximumConcurrentTurns else { return true }
        return records.values.lazy.filter(\.isGenerating).count < maximumConcurrentTurns
    }

    private func beginTurn(id: PiTaskID, turn: PendingTurn) async throws {
        guard records[id] != nil else { return }
        _ = try await ensureProcessRunning(id)
        guard var record = records[id] else { return }
        record.isGenerating = true
        record.state = .generating
        record.manuallyStopping = false
        records[id] = record
        emit(id)
        do {
            _ = try await record.client.send(.prompt(message: turn.message, images: turn.images, behavior: nil))
        } catch {
            if var current = records[id] {
                current.isGenerating = false
                current.state = .failed(error.localizedDescription)
                records[id] = current
                emit(id)
            }
            await drainQueue()
            throw error
        }
    }

    private func handle(_ event: PiRPCEvent, for id: PiTaskID) async {
        emitEvent(.rpc(id, event), byteCost: event.estimatedBufferedByteCount + 64)
        guard var record = records[id] else { return }
        var snapshotChanged = false
        switch event {
        case .agentStarted:
            if !record.isGenerating || record.state != .generating {
                record.isGenerating = true
                record.state = .generating
                snapshotChanged = true
            }
        case let .agentEnded(willRetry, raw):
            if !willRetry, let message = terminalAgentError(in: raw) {
                let failed = TaskRuntimeState.failed(message)
                if record.isGenerating || record.state != failed {
                    record.isGenerating = false
                    record.state = failed
                    snapshotChanged = true
                }
            }
        case .agentSettled:
            let previous = snapshot(record)
            record.isGenerating = false
            if record.state.phase != .failed {
                record.state = .ready
            }
            records[id] = record
            if snapshot(record) != previous { emit(id) }
            scheduleIdleEviction(for: id)
            await drainQueue()
            return
        case let .extensionUI(request):
            if [.select, .confirm, .input, .editor].contains(request.method),
               record.state != .awaitingInput {
                record.state = .awaitingInput
                snapshotChanged = true
            }
        case let .processTerminated(status, stderr):
            // A termination event queued by an earlier, deliberately stopped
            // launch must not overwrite the state of a process already resumed.
            let observedGeneration = record.lifecycleGeneration
            let processIsRunning = await record.client.isRunning
            guard let refreshed = records[id],
                  refreshed.lifecycleGeneration == observedGeneration,
                  !processIsRunning else { return }
            record = refreshed
            let nextState: TaskRuntimeState = record.manuallyStopping || status == 0
                ? .stopped
                : .failed(stderr.isEmpty ? "Pi exited with status \(status)." : stderr)
            if record.isGenerating || record.state != nextState {
                record.isGenerating = false
                record.state = nextState
                snapshotChanged = true
            }
        default:
            break
        }
        records[id] = record
        if snapshotChanged { emit(id) }
        if case .processTerminated = event { await drainQueue() }
    }

    private func terminalAgentError(in raw: JSONValue) -> String? {
        guard let messages = raw.objectValue?["messages"]?.arrayValue else { return nil }
        for value in messages.reversed() {
            guard let message = value.objectValue,
                  message["role"]?.stringValue == "assistant" else { continue }
            guard message["stopReason"]?.stringValue == "error" else { return nil }
            let detail = message["errorMessage"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return detail?.isEmpty == false ? detail : "Pi stopped unexpectedly."
        }
        return nil
    }

    private func ensureProcessRunning(_ id: PiTaskID) async throws -> PiTaskSnapshot {
        guard var record = records[id] else {
            throw PiTaskRuntimeCoordinatorError.taskNotFound
        }
        record.idleEviction?.cancel()
        record.idleEviction = nil
        records[id] = record

        if let startup = startupTasks[id] {
            try await startup.task.value
            guard let current = records[id] else {
                throw PiTaskRuntimeCoordinatorError.taskNotFound
            }
            return snapshot(current)
        }

        var current = record
        let startupGeneration: UInt64
        if current.manuallyStopping || current.state.phase == .stopped {
            // Supersede the older stop before awaiting it. Its continuation may
            // resume later, but its generation can no longer publish `.stopped`.
            current.lifecycleGeneration &+= 1
            startupGeneration = current.lifecycleGeneration
            current.state = .starting
            current.manuallyStopping = false
            records[id] = current
            emit(id)
            await current.client.stop(gracePeriod: 0.25)
            guard let refreshed = records[id] else {
                throw PiTaskRuntimeCoordinatorError.taskNotFound
            }
            guard refreshed.lifecycleGeneration == startupGeneration else {
                return try await ensureProcessRunning(id)
            }
            current = refreshed
        } else {
            let observedGeneration = current.lifecycleGeneration
            let processIsRunning = await current.client.isRunning
            guard let refreshed = records[id] else {
                throw PiTaskRuntimeCoordinatorError.taskNotFound
            }
            if refreshed.lifecycleGeneration != observedGeneration {
                return try await ensureProcessRunning(id)
            }
            if let startup = startupTasks[id] {
                try await startup.task.value
                guard let running = records[id] else {
                    throw PiTaskRuntimeCoordinatorError.taskNotFound
                }
                return snapshot(running)
            }
            if processIsRunning { return snapshot(refreshed) }

            current = refreshed
            current.lifecycleGeneration &+= 1
            startupGeneration = current.lifecycleGeneration
            current.state = .starting
            current.manuallyStopping = false
            records[id] = current
            emit(id)
        }

        let client = current.client
        let startup = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await client.start()
                try Task.checkCancellation()
                _ = try await client.send(.getState, timeout: 10)
                try Task.checkCancellation()
                await self?.finishStartup(id, generation: startupGeneration, failure: nil)
            } catch {
                await client.stop(gracePeriod: 0.25)
                await self?.finishStartup(
                    id,
                    generation: startupGeneration,
                    failure: error.localizedDescription
                )
                throw error
            }
        }
        startupTasks[id] = Startup(generation: startupGeneration, task: startup)
        do {
            try await startup.value
        } catch {
            if startupTasks[id]?.generation == startupGeneration {
                startupTasks.removeValue(forKey: id)
            }
            throw error
        }
        if startupTasks[id]?.generation == startupGeneration {
            startupTasks.removeValue(forKey: id)
        }

        guard let current = records[id] else {
            throw PiTaskRuntimeCoordinatorError.taskNotFound
        }
        return snapshot(current)
    }

    private func finishStartup(_ id: PiTaskID, generation: UInt64, failure: String?) {
        if startupTasks[id]?.generation == generation {
            startupTasks.removeValue(forKey: id)
        }
        guard var record = records[id], record.lifecycleGeneration == generation else { return }
        record.isGenerating = false
        if record.manuallyStopping {
            record.state = .stopped
        } else if let failure {
            record.state = .failed(failure)
        } else {
            record.state = .ready
        }
        records[id] = record
        emit(id)
    }

    private func drainQueue() async {
        while hasCapacity {
            guard let id = records.first(where: { !$0.value.isGenerating && !$0.value.pending.isEmpty })?.key,
                  var record = records[id] else { return }
            let turn = record.pending.removeFirst()
            records[id] = record
            do { try await beginTurn(id: id, turn: turn) }
            catch { continue }
        }
    }

    private func scheduleIdleEviction(for id: PiTaskID) {
        guard var record = records[id], !record.preservesRuntime, !record.manuallyStopping,
              ![.stopped, .failed].contains(record.state.phase) else { return }
        record.idleEviction?.cancel()
        let delay = idleGracePeriod
        record.idleEviction = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self else { return }
            await self.evictIfIdle(id)
        }
        records[id] = record
    }

    private func evictIfIdle(_ id: PiTaskID) async {
        guard var record = records[id], !record.isGenerating, record.pending.isEmpty,
              !record.preservesRuntime else { return }
        record.lifecycleGeneration &+= 1
        let generation = record.lifecycleGeneration
        record.manuallyStopping = true
        record.state = .stopped
        record.idleEviction = nil
        records[id] = record
        emit(id)
        await record.client.stop()
        guard records[id]?.lifecycleGeneration == generation else { return }
    }

    private func emit(_ id: PiTaskID) {
        guard let record = records[id] else { return }
        let snapshot = snapshot(record)
        guard lastEmittedSnapshots[id] != snapshot else { return }
        lastEmittedSnapshots[id] = snapshot
        emitEvent(
            .changed(snapshot),
            byteCost: snapshot.workingDirectory.path.utf8.count
                + (snapshot.sessionPath?.path.utf8.count ?? 0)
                + snapshot.pendingTurnCount * 8
                + 256
        )
    }

    private func emitEvent(_ event: PiTaskCoordinatorEvent, byteCost: Int) {
        switch eventSource.yield(event, byteCost: byteCost) {
        case .delivered, .enqueued, .dropped, .terminated:
            break
        }
    }

    private func snapshot(_ record: Record) -> PiTaskSnapshot {
        PiTaskSnapshot(
            id: record.configuration.id,
            workingDirectory: record.configuration.workingDirectory,
            sessionPath: record.resumeSessionPath,
            state: record.state,
            pendingTurnCount: record.pending.count,
            hasUserExtensions: record.preservesRuntime
        )
    }
}
