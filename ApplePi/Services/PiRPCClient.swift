import Darwin
import Foundation

public enum PiRPCClientError: LocalizedError, Sendable {
    case incompatibleRuntime
    case alreadyStarted
    case notRunning
    case requestTimedOut(command: String)
    case requestFailed(command: String, message: String)
    case processExited(status: Int32)
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
        case .incompatibleRuntime: "The selected Pi runtime cannot run native RPC tasks."
        case .alreadyStarted: "The Pi RPC process is already running."
        case .notRunning: "The Pi RPC process is not running."
        case let .requestTimedOut(command): "Pi did not answer the \(command) request in time."
        case let .requestFailed(command, message): "Pi rejected \(command): \(message)"
        case let .processExited(status): "Pi exited with status \(status)."
        case let .protocolViolation(message): "Pi RPC protocol error: \(message)"
        }
    }
}

struct PiRPCClientDiagnostics: Sendable, CustomStringConvertible {
    let processIdentifier: pid_t?
    let processIsRunning: Bool
    let pendingRequests: [String]
    let pendingWrites: [String]
    let writerHasActiveWrite: Bool
    let writerPendingBytes: Int
    let stderr: String
    let lastTimeoutContext: String?
    let transcript: [String]

    var description: String {
        let pid = processIdentifier.map(String.init) ?? "none"
        let pending = pendingRequests.isEmpty ? "none" : pendingRequests.joined(separator: ",")
        let writes = pendingWrites.isEmpty ? "none" : pendingWrites.joined(separator: ",")
        let timeout = lastTimeoutContext ?? "none"
        let stderrValue = stderr.isEmpty ? "none" : stderr
        let transcriptValue = transcript.isEmpty ? "none" : transcript.joined(separator: " | ")
        return "pid=\(pid) running=\(processIsRunning) pending=[\(pending)] "
            + "writes=[\(writes)] writerActive=\(writerHasActiveWrite) "
            + "writerPendingBytes=\(writerPendingBytes) lastTimeout={\(timeout)} "
            + "stderr={\(stderrValue)} transcript={\(transcriptValue)}"
    }
}

/// Serializes potentially blocking pipe writes away from the RPC actor. Queued
/// writes are byte-bounded; producers beyond that bound remain suspended until
/// earlier writes advance. Closing the handle from another executor interrupts
/// an in-flight write during stop or transport failure.
final class OrderedPipeWriter: @unchecked Sendable {
    private final class Request: @unchecked Sendable {
        enum Location { case initial, waiting, pending, active, finished }

        let data: Data
        var location = Location.initial
        var cancellationRequested = false
        var continuation: CheckedContinuation<Void, any Error>?

        init(data: Data) { self.data = data }
    }

    private struct RequestQueue {
        private var storage: [Request?] = []
        private var head = 0

        mutating func append(_ request: Request) {
            storage.append(request)
        }

        mutating func first() -> Request? {
            discardEmptyPrefix()
            return head < storage.count ? storage[head] : nil
        }

        mutating func popFirst() -> Request? {
            discardEmptyPrefix()
            guard head < storage.count, let request = storage[head] else { return nil }
            storage[head] = nil
            head += 1
            compactIfNeeded()
            return request
        }

        mutating func remove(_ request: Request) -> Bool {
            guard head < storage.count else { return false }
            for index in head ..< storage.count where storage[index] === request {
                storage[index] = nil
                if index == head { discardEmptyPrefix() }
                compactIfNeeded()
                return true
            }
            return false
        }

        mutating func removeAll() -> [Request] {
            let requests = storage[head...].compactMap { $0 }
            storage.removeAll(keepingCapacity: false)
            head = 0
            return requests
        }

        private mutating func discardEmptyPrefix() {
            while head < storage.count, storage[head] == nil { head += 1 }
            compactIfNeeded()
        }

        private mutating func compactIfNeeded() {
            guard head > 1_024, head * 2 >= storage.count else { return }
            storage.removeFirst(head)
            head = 0
        }
    }

    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.paulsousa.ApplePi.rpc-writer", qos: .userInitiated)
    private let lock = NSLock()
    private let maximumPendingBytes: Int
    private let chunkBytes: Int
    private var isClosed = false
    private var active: Request?
    private var pending = RequestQueue()
    private var waiting = RequestQueue()
    private var pendingBytes = 0

    init(
        handle: FileHandle,
        maximumPendingBytes: Int = 16 * 1_024 * 1_024,
        chunkBytes: Int = 64 * 1_024
    ) {
        self.handle = handle
        self.maximumPendingBytes = max(1, maximumPendingBytes)
        self.chunkBytes = max(1, chunkBytes)
        // A child can close stdin while a queued chunk is in flight. Convert
        // that condition to EPIPE instead of allowing SIGPIPE to terminate the
        // entire app (or test host).
        _ = Darwin.fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func write(_ data: Data) async throws {
        let request = Request(data: data)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(request, continuation: continuation)
            }
        } onCancel: {
            cancel(request)
        }
    }

    func close() {
        var continuations: [CheckedContinuation<Void, any Error>] = []
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        if let continuation = active?.continuation {
            active?.continuation = nil
            continuations.append(continuation)
        }
        let queued = pending.removeAll() + waiting.removeAll()
        pendingBytes = 0
        for request in queued {
            request.location = .finished
            if let continuation = request.continuation {
                request.continuation = nil
                continuations.append(continuation)
            }
        }
        lock.unlock()
        try? handle.close()
        let error = CocoaError(.fileWriteUnknown)
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    var pendingByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingBytes
    }

    var hasActiveWrite: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active != nil
    }

    private func enqueue(
        _ request: Request,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        var immediateError: (any Error)?
        var next: Request?
        lock.lock()
        request.continuation = continuation
        if request.cancellationRequested {
            request.location = .finished
            request.continuation = nil
            immediateError = CancellationError()
        } else if isClosed {
            request.location = .finished
            request.continuation = nil
            immediateError = CocoaError(.fileWriteUnknown)
        } else {
            request.location = .waiting
            waiting.append(request)
            next = rebalanceLocked()
        }
        lock.unlock()

        if let immediateError { continuation.resume(throwing: immediateError) }
        if let next { schedule(next) }
    }

    private func cancel(_ request: Request) {
        var continuation: CheckedContinuation<Void, any Error>?
        var next: Request?
        lock.lock()
        switch request.location {
        case .initial:
            request.cancellationRequested = true
        case .waiting:
            if waiting.remove(request) {
                request.location = .finished
                continuation = request.continuation
                request.continuation = nil
                next = rebalanceLocked()
            }
        case .pending:
            if pending.remove(request) {
                pendingBytes -= request.data.count
                request.location = .finished
                continuation = request.continuation
                request.continuation = nil
                next = rebalanceLocked()
            }
        case .active:
            // A partially written JSONL record must remain ordered and complete,
            // but the suspended producer can stop waiting immediately.
            continuation = request.continuation
            request.continuation = nil
        case .finished:
            break
        }
        lock.unlock()

        continuation?.resume(throwing: CancellationError())
        if let next { schedule(next) }
    }

    /// Selects an active write and fills the admitted pending buffer. The first
    /// waiting producer is never bypassed, preserving command priority/order.
    private func rebalanceLocked() -> Request? {
        guard !isClosed else { return nil }
        var next: Request?
        if active == nil {
            if let request = pending.popFirst() {
                pendingBytes -= request.data.count
                request.location = .active
                active = request
                next = request
            } else if let request = waiting.popFirst() {
                request.location = .active
                active = request
                next = request
            }
        }

        while let request = waiting.first() {
            guard request.data.count <= maximumPendingBytes - pendingBytes else { break }
            _ = waiting.popFirst()
            request.location = .pending
            pending.append(request)
            pendingBytes += request.data.count
        }
        return next
    }

    private func schedule(_ request: Request) {
        queue.async { [self] in
            do {
                var start = 0
                while start < request.data.count {
                    lock.lock()
                    let closed = isClosed
                    lock.unlock()
                    guard !closed else { throw CocoaError(.fileWriteUnknown) }
                    let end = min(request.data.count, start + chunkBytes)
                    try handle.write(contentsOf: request.data.subdata(in: start ..< end))
                    start = end
                }
                finish(request, error: nil)
            } catch {
                finish(request, error: error)
            }
        }
    }

    private func finish(_ request: Request, error: (any Error)?) {
        var continuations: [CheckedContinuation<Void, any Error>] = []
        var next: Request?
        var shouldCloseHandle = false
        lock.lock()
        if active === request {
            active = nil
            request.location = .finished
            if let continuation = request.continuation { continuations.append(continuation) }
            request.continuation = nil
            if error != nil, !isClosed {
                isClosed = true
                shouldCloseHandle = true
                let queued = pending.removeAll() + waiting.removeAll()
                pendingBytes = 0
                for queuedRequest in queued {
                    queuedRequest.location = .finished
                    if let continuation = queuedRequest.continuation {
                        queuedRequest.continuation = nil
                        continuations.append(continuation)
                    }
                }
            } else {
                next = rebalanceLocked()
            }
        }
        lock.unlock()

        if shouldCloseHandle { try? handle.close() }
        for continuation in continuations {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: ()) }
        }
        if let next { schedule(next) }
    }
}

public actor PiRPCClient {
    public struct Configuration: Sendable, Hashable {
        public let runtime: PiRuntimeDescriptor
        public let workingDirectory: URL
        public let sessionPath: URL?
        public let projectTrusted: Bool
        public let bridgeURL: URL?
        public let environment: [String: String]
        public let offlineStartup: Bool
        public let noSession: Bool
        public let disableDiscoveredResources: Bool
        public let maximumLineBytes: Int
        public let maximumBufferedBytes: Int
        public let maximumEventBufferedBytes: Int
        public let stderrCapacity: Int

        public init(
            runtime: PiRuntimeDescriptor,
            workingDirectory: URL,
            sessionPath: URL? = nil,
            projectTrusted: Bool,
            bridgeURL: URL?,
            environment: [String: String],
            offlineStartup: Bool = true,
            noSession: Bool = false,
            disableDiscoveredResources: Bool = false,
            maximumLineBytes: Int = 8 * 1_024 * 1_024,
            maximumBufferedBytes: Int = 16 * 1_024 * 1_024,
            maximumEventBufferedBytes: Int = 8 * 1_024 * 1_024,
            stderrCapacity: Int = 256 * 1_024
        ) {
            self.runtime = runtime
            self.workingDirectory = workingDirectory
            self.sessionPath = sessionPath
            self.projectTrusted = projectTrusted
            self.bridgeURL = bridgeURL
            self.environment = environment
            self.offlineStartup = offlineStartup
            self.noSession = noSession
            self.disableDiscoveredResources = disableDiscoveredResources
            self.maximumLineBytes = maximumLineBytes
            self.maximumBufferedBytes = maximumBufferedBytes
            self.maximumEventBufferedBytes = maximumEventBufferedBytes
            self.stderrCapacity = stderrCapacity
        }
    }

    private struct PendingRequest {
        let command: String
        let timeout: TimeInterval
        let continuation: CheckedContinuation<PiRPCResponse, any Error>
    }

    public nonisolated let events: AsyncStream<PiRPCEvent>

    private let configuration: Configuration
    private let eventSource: ByteBoundedAsyncStream<PiRPCEvent>
    /// Pi assigns a canonical file after a session-less task first starts. Keep
    /// that file separately from the immutable launch configuration so an idle
    /// runtime can resume the same conversation on its next process launch.
    private var resumeSessionPath: URL?
    private var process: NativeSubprocess?
    private var inputWriter: OrderedPipeWriter?
    private var processWaitTask: Task<Void, Never>?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var stdoutFramer: BoundedLineBuffer
    private var stderrTail: ByteTailBuffer
    private var pendingRequests: [String: PendingRequest] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var writeTasks: [String: Task<Void, Never>] = [:]
    private var nextRequestNumber: UInt64 = 0
    private var lastTimeoutContext: String?
    private var transcript: [String] = []
    private static let maximumTranscriptEntries = 64

    public init(configuration: Configuration) {
        self.configuration = configuration
        resumeSessionPath = configuration.sessionPath
        stdoutFramer = BoundedLineBuffer(
            maximumLineBytes: configuration.maximumLineBytes,
            maximumBufferedBytes: configuration.maximumBufferedBytes
        )
        stderrTail = ByteTailBuffer(capacity: configuration.stderrCapacity)
        let eventSource = ByteBoundedAsyncStream<PiRPCEvent>(
            maximumBufferedBytes: configuration.maximumEventBufferedBytes,
            makeGap: { (.streamGap, 1) },
            isLossy: \.isLossyStreamDelta
        )
        events = eventSource.stream
        self.eventSource = eventSource
    }

    deinit {
        eventSource.finish()
        stdoutTask?.cancel()
        stderrTask?.cancel()
        processWaitTask?.cancel()
        inputWriter?.close()
        process?.signalGroup(SIGKILL)
    }

    public var isRunning: Bool { process?.isRunning == true }

    var bufferedEventByteCount: Int { eventSource.bufferedByteCount }
    var bufferedLossyEventByteCount: Int { eventSource.lossyBufferedByteCount }
    var hasActiveProcessResources: Bool { process != nil }

    public func start() async throws {
        guard configuration.runtime.supportsNativeTasks else {
            throw PiRPCClientError.incompatibleRuntime
        }
        if let previous = process {
            guard !previous.isRunning else { throw PiRPCClientError.alreadyStarted }
            await handleProcessTermination(
                status: await previous.wait(),
                pid: previous.processIdentifier
            )
        }
        guard !(configuration.noSession && resumeSessionPath != nil) else {
            throw PiRPCClientError.protocolViolation(
                "A session-free RPC process cannot also be launched with a session path."
            )
        }

        stdoutFramer = BoundedLineBuffer(
            maximumLineBytes: configuration.maximumLineBytes,
            maximumBufferedBytes: configuration.maximumBufferedBytes
        )
        stderrTail = ByteTailBuffer(capacity: configuration.stderrCapacity)

        let process: NativeSubprocess
        do {
            process = try NativeSubprocess.launch(
                executable: configuration.runtime.executable,
                arguments: launchArguments(),
                environment: configuration.environment,
                currentDirectory: configuration.workingDirectory,
                providesStandardInput: true
            )
        } catch {
            throw ProcessExecutionError.couldNotLaunch(error.localizedDescription)
        }

        self.process = process
        guard let standardInput = process.standardInput else {
            process.signalGroup(SIGKILL)
            throw ProcessExecutionError.couldNotLaunch("The RPC stdin pipe was not established.")
        }
        inputWriter = OrderedPipeWriter(handle: standardInput)
        stdoutTask = Self.readerTask(
            handle: process.standardOutput,
            consume: { [weak self] data in await self?.consumeStdout(data) },
            failure: { [weak self] error in
                await self?.recordPipeReadFailure(stream: "stdout", error: error)
            }
        )
        stderrTask = Self.readerTask(
            handle: process.standardError,
            consume: { [weak self] data in await self?.consumeStderr(data) },
            failure: { [weak self] error in
                await self?.recordPipeReadFailure(stream: "stderr", error: error)
            }
        )
        let pid = process.processIdentifier
        lastTimeoutContext = nil
        appendTranscript("process-start pid=\(pid)")
        processWaitTask = Task { [weak self] in
            let status = await process.wait()
            await self?.handleProcessTermination(status: status, pid: pid)
        }
    }

    public func send(
        _ command: PiRPCCommand,
        timeout: TimeInterval = 30
    ) async throws -> PiRPCResponse {
        guard isRunning else { throw PiRPCClientError.notRunning }
        guard case .extensionUIResponse = command else {
            return try await sendRequest(command, timeout: timeout)
        }
        try await write(command.jsonObject(id: nil))
        return PiRPCResponse(
            id: nil,
            command: command.commandName,
            success: true,
            data: nil,
            error: nil,
            raw: .object(command.jsonObject(id: nil))
        )
    }

    public func respond(to request: PiExtensionUIRequest, with response: PiExtensionUIResponse) async throws {
        guard isRunning else { throw PiRPCClientError.notRunning }
        try await write(PiRPCCommand.extensionUIResponse(response).jsonObject(id: nil))
    }

    public func invokeBridge(
        action: BridgeActionV1,
        payload: JSONValue = .object([:]),
        nonce: String = BridgeCodec.randomNonce()
    ) async throws -> BridgeEnvelopeV1 {
        let envelope = BridgeEnvelopeV1(nonce: nonce, action: action, payload: payload)
        let message = try BridgeCodec.commandMessage(for: envelope)
        _ = try await send(.prompt(message: message, images: [], behavior: nil))
        return envelope
    }

    public func stop(gracePeriod: TimeInterval = 1) async {
        guard let process else { return }
        let pid = process.processIdentifier
        inputWriter?.close()
        process.signalGroup(SIGTERM)
        if await process.wait(timeout: max(0, gracePeriod)) == nil {
            process.signalGroup(SIGKILL)
        }
        let status = await process.wait()
        // Kill residual descendants even after the root exits so inherited
        // descriptors cannot delay EOF publication indefinitely.
        process.signalGroup(SIGKILL)
        if self.process?.processIdentifier == pid {
            await handleProcessTermination(status: status, pid: pid)
        }
    }

    /// Updates only the path used by a future process launch. The active Pi
    /// process already owns its current session and is never switched implicitly.
    public func setResumeSessionPath(_ path: URL?) {
        resumeSessionPath = path?.standardizedFileURL
    }

    public func stderrSnapshot(redacted: Bool = true) -> String {
        let value = stderrTail.string
        return redacted ? DiagnosticsRedactor.redact(value) : value
    }

    func diagnosticsSnapshot() -> PiRPCClientDiagnostics {
        PiRPCClientDiagnostics(
            processIdentifier: process?.processIdentifier,
            processIsRunning: process?.isRunning == true,
            pendingRequests: pendingRequests
                .map { "\($0.key):\($0.value.command)" }
                .sorted(),
            pendingWrites: writeTasks.keys.sorted(),
            writerHasActiveWrite: inputWriter?.hasActiveWrite == true,
            writerPendingBytes: inputWriter?.pendingByteCount ?? 0,
            stderr: stderrSnapshot(),
            lastTimeoutContext: lastTimeoutContext,
            transcript: transcript
        )
    }

    private func launchArguments() -> [String] {
        var arguments = ["--mode", "rpc"]
        if configuration.offlineStartup { arguments.append("--offline") }
        if configuration.noSession { arguments.append("--no-session") }
        if configuration.disableDiscoveredResources {
            arguments.append(contentsOf: [
                "--no-extensions", "--no-skills", "--no-prompt-templates",
                "--no-themes", "--no-context-files",
            ])
        }
        if let session = resumeSessionPath {
            arguments.append(contentsOf: ["--session", session.path])
        }
        if let bridge = configuration.bridgeURL {
            arguments.append(contentsOf: ["--extension", bridge.path])
        }
        arguments.append(configuration.projectTrusted ? "--approve" : "--no-approve")
        return arguments
    }

    private func sendRequest(_ command: PiRPCCommand, timeout: TimeInterval) async throws -> PiRPCResponse {
        nextRequestNumber &+= 1
        let id = "apple-pi-\(nextRequestNumber)-\(UUID().uuidString)"
        let object = command.jsonObject(id: id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[id] = PendingRequest(
                    command: command.commandName,
                    timeout: timeout,
                    continuation: continuation
                )
                appendTranscript(
                    "request-pending id=\(id) command=\(command.commandName) timeout=\(timeout)"
                )
                timeoutTasks[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) }
                    catch { return }
                    guard let self else { return }
                    await self.timeoutRequest(id: id)
                }
                writeTasks[id] = Task { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    do {
                        try await self.write(object)
                        await self.finishWrite(id: id)
                    } catch {
                        await self.failRequestWrite(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    private func write(_ object: [String: JSONValue]) async throws {
        guard let inputWriter, isRunning else {
            throw PiRPCClientError.notRunning
        }
        var data = try JSONValue.object(object).encodedData()
        data.append(0x0A)
        do {
            try await inputWriter.write(data)
        } catch {
            throw PiRPCClientError.protocolViolation(error.localizedDescription)
        }
    }

    private func finishWrite(id: String) {
        writeTasks.removeValue(forKey: id)
        appendTranscript("request-written id=\(id)")
    }

    private func failRequestWrite(id: String, error: any Error) {
        writeTasks.removeValue(forKey: id)
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        appendTranscript(
            "request-write-failed id=\(id) command=\(pending.command) error=\(error.localizedDescription)"
        )
        pending.continuation.resume(throwing: error)
    }

    private func cancelRequest(id: String) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        writeTasks.removeValue(forKey: id)?.cancel()
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        appendTranscript("request-cancelled id=\(id) command=\(pending.command)")
        pending.continuation.resume(throwing: CancellationError())
    }

    private func timeoutRequest(id: String) {
        timeoutTasks.removeValue(forKey: id)
        writeTasks.removeValue(forKey: id)?.cancel()
        guard let pending = pendingRequests[id] else { return }
        let pid = (process?.processIdentifier).map(String.init) ?? "none"
        let pendingIDs = pendingRequests.keys.sorted().joined(separator: ",")
        let context = "id=\(id) command=\(pending.command) configuredTimeout=\(pending.timeout) "
            + "pid=\(pid) running=\(process?.isRunning == true) pendingIDs=[\(pendingIDs)] "
            + "writerActive=\(inputWriter?.hasActiveWrite == true) "
            + "writerPendingBytes=\(inputWriter?.pendingByteCount ?? 0)"
        lastTimeoutContext = context
        appendTranscript("request-timeout \(context)")
        _ = pendingRequests.removeValue(forKey: id)
        pending.continuation.resume(throwing: PiRPCClientError.requestTimedOut(command: pending.command))
    }

    private func consumeStdout(_ data: Data) {
        do {
            for line in try stdoutFramer.append(data) where !line.isEmpty {
                decodeLine(line)
            }
        } catch {
            emitEvent(.malformedLine(error.localizedDescription))
            failAllPending(with: error)
            process?.signalGroup(SIGTERM)
        }
    }

    private func consumeStderr(_ data: Data) {
        stderrTail.append(data)
    }

    private func decodeLine(_ data: Data) {
        let raw: JSONValue
        do {
            raw = try JSONValue.decode(data: data)
        } catch {
            let preview = String(decoding: data.prefix(2_048), as: UTF8.self)
            emitEvent(.malformedLine(DiagnosticsRedactor.redact(preview)), byteCost: data.count)
            return
        }
        guard let object = raw.objectValue else {
            emitEvent(.unknown(type: nil, raw: raw), byteCost: data.count)
            return
        }

        let type = object["type"]?.stringValue
        if type == "response" {
            handleResponse(object: object, raw: raw, byteCost: data.count)
            return
        }
        emitEvent(projectEvent(type: type, object: object, raw: raw), byteCost: data.count)
    }

    private func handleResponse(object: [String: JSONValue], raw: JSONValue, byteCost: Int) {
        let response = PiRPCResponse(
            id: object["id"]?.stringValue,
            command: object["command"]?.stringValue ?? "unknown",
            success: object["success"]?.boolValue ?? false,
            data: object["data"],
            error: object["error"]?.stringValue,
            raw: raw
        )
        appendTranscript(
            "response id=\(response.id ?? "none") command=\(response.command) success=\(response.success)"
        )
        emitEvent(.response(response), byteCost: byteCost)
        guard let id = response.id, let pending = pendingRequests.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        writeTasks.removeValue(forKey: id)?.cancel()
        if response.success {
            pending.continuation.resume(returning: response)
        } else {
            pending.continuation.resume(throwing: PiRPCClientError.requestFailed(
                command: response.command,
                message: response.error ?? "Unknown error"
            ))
        }
    }

    private func projectEvent(type: String?, object: [String: JSONValue], raw: JSONValue) -> PiRPCEvent {
        switch type {
        case "agent_start": return .agentStarted(raw: raw)
        case "agent_end": return .agentEnded(willRetry: object["willRetry"]?.boolValue ?? false, raw: raw)
        case "agent_settled": return .agentSettled(raw: raw)
        case "turn_start": return .turnStarted(raw: raw)
        case "turn_end": return .turnEnded(raw: raw)
        case "message_start": return .messageStarted(raw: raw)
        case "message_update":
            let update = object["assistantMessageEvent"]?.objectValue
            return .messageUpdated(kind: update?["type"]?.stringValue, delta: update?["delta"]?.stringValue, raw: raw)
        case "message_end": return .messageEnded(raw: raw)
        case "tool_execution_start":
            return .toolStarted(id: object["toolCallId"]?.stringValue, name: object["toolName"]?.stringValue, raw: raw)
        case "tool_execution_update":
            return .toolUpdated(id: object["toolCallId"]?.stringValue, name: object["toolName"]?.stringValue, raw: raw)
        case "tool_execution_end":
            return .toolEnded(
                id: object["toolCallId"]?.stringValue,
                name: object["toolName"]?.stringValue,
                isError: object["isError"]?.boolValue ?? false,
                raw: raw
            )
        case "queue_update":
            return .queueUpdated(
                steering: object["steering"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                followUp: object["followUp"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                raw: raw
            )
        case "compaction_start": return .compactionStarted(raw: raw)
        case "compaction_end":
            return .compactionEnded(
                aborted: object["aborted"]?.boolValue ?? false,
                error: object["errorMessage"]?.stringValue,
                raw: raw
            )
        case "auto_retry_start", "auto_retry_end", "summarization_retry_scheduled",
             "summarization_retry_attempt_start", "summarization_retry_finished":
            return .retry(raw: raw)
        case "bash_execution_update":
            return .bashUpdated(
                id: object["id"]?.stringValue,
                delta: object["delta"]?.stringValue ?? "",
                raw: raw
            )
        case "entry_appended": return .entryAppended(raw: raw)
        case "session_info_changed": return .sessionInfoChanged(name: object["name"]?.stringValue, raw: raw)
        case "thinking_level_changed":
            return .thinkingLevelChanged(level: object["level"]?.stringValue, raw: raw)
        case "extension_error":
            return .extensionError(
                path: object["extensionPath"]?.stringValue,
                event: object["event"]?.stringValue,
                message: object["error"]?.stringValue ?? "Unknown extension error",
                raw: raw
            )
        case "extension_ui_request":
            let request = extensionUIRequest(object: object, raw: raw)
            if request.method == .notify, let message = request.message {
                do {
                    if let bridge = try BridgeCodec.decodeNotification(message) { return .bridge(bridge) }
                } catch {
                    return .malformedLine(error.localizedDescription)
                }
            }
            return .extensionUI(request)
        default:
            return .unknown(type: type, raw: raw)
        }
    }

    private func extensionUIRequest(object: [String: JSONValue], raw: JSONValue) -> PiExtensionUIRequest {
        let methodName = object["method"]?.stringValue ?? "unknown"
        let method = PiExtensionUIMethod(rawValue: methodName) ?? .unknown
        return PiExtensionUIRequest(
            id: object["id"]?.stringValue ?? UUID().uuidString,
            method: method,
            title: object["title"]?.stringValue,
            message: object["message"]?.stringValue,
            options: object["options"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            placeholder: object["placeholder"]?.stringValue,
            prefill: object["prefill"]?.stringValue,
            timeoutMilliseconds: object["timeout"]?.numberValue.map(Int.init),
            notificationType: object["notifyType"]?.stringValue,
            statusKey: object["statusKey"]?.stringValue,
            statusText: object["statusText"]?.stringValue,
            widgetKey: object["widgetKey"]?.stringValue,
            widgetLines: object["widgetLines"]?.arrayValue?.compactMap(\.stringValue),
            widgetPlacement: object["widgetPlacement"]?.stringValue,
            text: object["text"]?.stringValue,
            raw: raw
        )
    }

    private func handleProcessTermination(status: Int32, pid: pid_t) async {
        // A delayed Foundation termination callback from an earlier launch must
        // never tear down a newly restarted process.
        guard process?.processIdentifier == pid else { return }
        await drainReadersAfterTermination(process: process)
        guard process?.processIdentifier == pid else { return }
        if let finalLine = try? stdoutFramer.finish(), !finalLine.isEmpty {
            decodeLine(finalLine)
        }
        let diagnostic = stderrSnapshot()
        appendTranscript("process-terminated pid=\(pid) status=\(status) stderrBytes=\(diagnostic.utf8.count)")
        emitEvent(
            .processTerminated(status: status, stderr: diagnostic),
            byteCost: diagnostic.utf8.count + 64
        )
        failAllPending(with: PiRPCClientError.processExited(status: status))
        clearProcessResources()
    }

    private func failAllPending(with error: any Error) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        for task in writeTasks.values { task.cancel() }
        writeTasks.removeAll()
        for request in pending.values { request.continuation.resume(throwing: error) }
    }

    private func drainReadersAfterTermination(process: NativeSubprocess?) async {
        let stdout = stdoutTask
        let stderr = stderrTask
        process?.signalGroup(SIGKILL)
        await stdout?.value
        await stderr?.value
        process?.closeOutput()
    }

    private func emitEvent(_ event: PiRPCEvent, byteCost: Int? = nil) {
        let result = eventSource.yield(
            event,
            byteCost: byteCost ?? event.estimatedBufferedByteCount
        )
        switch result {
        case .delivered, .enqueued, .dropped, .terminated:
            break
        }
    }

    private func appendTranscript(_ entry: String) {
        transcript.append(DiagnosticsRedactor.redact(entry))
        let excess = transcript.count - Self.maximumTranscriptEntries
        if excess > 0 { transcript.removeFirst(excess) }
    }

    private func recordPipeReadFailure(stream: String, error: String) {
        let message = "\(stream) pipe read failed: \(error)"
        appendTranscript("pipe-read-failed stream=\(stream) error=\(error)")
        inputWriter?.close()
        failAllPending(with: PiRPCClientError.protocolViolation(message))
        process?.signalGroup(SIGKILL)
    }

    private func clearProcessResources() {
        inputWriter?.close()
        process?.closeInput()
        process?.closeOutput()
        stdoutTask?.cancel()
        stderrTask?.cancel()
        processWaitTask?.cancel()
        process = nil
        inputWriter = nil
        processWaitTask = nil
    }

    private static func readerTask(
        handle: FileHandle,
        consume: @escaping @Sendable (Data) async -> Void,
        failure: @escaping @Sendable (String) async -> Void
    ) -> Task<Void, Never> {
        let reader = AsyncNativePipeReader(handle: handle)
        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                switch await reader.read() {
                case let .data(data):
                    guard !data.isEmpty else { continue }
                    await consume(data)
                case .endOfFile:
                    return
                case let .failure(error):
                    await failure(error)
                    return
                }
            }
        }
    }
}
