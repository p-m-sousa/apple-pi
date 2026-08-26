import Darwin
import Foundation

public enum PiPackageCLIError: LocalizedError, Sendable {
    case operationInProgress
    case invalidSource
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .operationInProgress: "Another Pi package operation is already running."
        case .invalidSource: "The package source is empty or contains invalid control characters."
        case let .launchFailed(message): "Pi package command could not launch: \(message)"
        }
    }
}

public actor PiPackageCLIService {
    public nonisolated let events: AsyncStream<PackageOperationEvent>

    private let runtime: PiRuntimeDescriptor
    private let environment: [String: String]
    private let workingDirectory: URL
    private let projectTrusted: Bool
    private let eventSource: ByteBoundedAsyncStream<PackageOperationEvent>
    private var process: NativeSubprocess?
    private var operation: PackageOperation?
    private var stdoutTail = ByteTailBuffer(capacity: 2 * 1_024 * 1_024)
    private var stderrTail = ByteTailBuffer(capacity: 2 * 1_024 * 1_024)
    private var cancellationEscalation: Task<Void, Never>?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    public init(
        runtime: PiRuntimeDescriptor,
        environment: [String: String],
        workingDirectory: URL,
        projectTrusted: Bool,
        maximumEventBufferedBytes: Int = 2 * 1_024 * 1_024
    ) {
        self.runtime = runtime
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.projectTrusted = projectTrusted
        let eventSource = ByteBoundedAsyncStream<PackageOperationEvent>(
            maximumBufferedBytes: maximumEventBufferedBytes,
            makeGap: { (.outputGap, 1) },
            isLossy: { event in
                if case .output = event { return true }
                return false
            }
        )
        events = eventSource.stream
        self.eventSource = eventSource
    }

    deinit {
        eventSource.finish()
        process?.signalGroup(SIGKILL)
        stdoutTask?.cancel()
        stderrTask?.cancel()
    }

    public func perform(_ requestedOperation: PackageOperation) async throws -> PackageOperationResult {
        guard process == nil else { throw PiPackageCLIError.operationInProgress }
        let arguments = try arguments(for: requestedOperation)
        operation = requestedOperation
        stdoutTail = ByteTailBuffer(capacity: 2 * 1_024 * 1_024)
        stderrTail = ByteTailBuffer(capacity: 2 * 1_024 * 1_024)
        let process: NativeSubprocess
        do {
            process = try NativeSubprocess.launch(
                executable: runtime.executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: workingDirectory,
                providesStandardInput: false
            )
        } catch {
            operation = nil
            throw PiPackageCLIError.launchFailed(error.localizedDescription)
        }
        self.process = process
        stdoutTask = Self.readerTask(
            handle: process.standardOutput,
            consume: { [weak self] data in await self?.consume(data, isError: false) }
        )
        stderrTask = Self.readerTask(
            handle: process.standardError,
            consume: { [weak self] data in await self?.consume(data, isError: true) }
        )
        emitEvent(.started(requestedOperation), byteCost: 128)

        let status = await withTaskCancellationHandler {
            await process.wait()
        } onCancel: {
            Task { await self.cancel() }
        }

        await drainReadersAfterTermination(process: process)
        let result = PackageOperationResult(
            operation: requestedOperation,
            status: status,
            output: DiagnosticsRedactor.redact(stdoutTail.string),
            errorOutput: DiagnosticsRedactor.redact(stderrTail.string)
        )
        emitEvent(.completed(requestedOperation, status: status), byteCost: 128)
        clearProcess()
        return result
    }

    public func cancel() {
        guard let process else { return }
        let pid = process.processIdentifier
        process.signalGroup(SIGTERM)
        cancellationEscalation?.cancel()
        cancellationEscalation = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            await self?.forceCancel(pid: pid)
        }
    }

    private func forceCancel(pid: pid_t) {
        guard process?.processIdentifier == pid else { return }
        process?.signalGroup(SIGKILL)
    }

    private func arguments(for operation: PackageOperation) throws -> [String] {
        let trust = projectTrusted ? "--approve" : "--no-approve"
        switch operation {
        case let .install(source, scope):
            try validate(source)
            return ["install", source] + (scope == .project ? ["--local"] : []) + [trust]
        case let .remove(source, scope):
            try validate(source)
            return ["remove", source] + (scope == .project ? ["--local"] : []) + [trust]
        case let .update(source):
            if let source {
                try validate(source)
                return ["update", source, trust]
            }
            return ["update", "--extensions", trust]
        case .updateAllPackages:
            return ["update", "--extensions", trust]
        case .refreshModels:
            return ["update", "--models", trust]
        }
    }

    private func validate(_ source: String) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.contains("\0"),
              !source.contains("\n"),
              !source.contains("\r") else {
            throw PiPackageCLIError.invalidSource
        }
    }

    private func consume(_ data: Data, isError: Bool) {
        if isError { stderrTail.append(data) }
        else { stdoutTail.append(data) }
        let text = String(decoding: data, as: UTF8.self)
        if !text.isEmpty {
            let redacted = DiagnosticsRedactor.redact(text)
            emitEvent(.output(redacted, isError: isError), byteCost: redacted.utf8.count + 32)
        }
    }

    private func emitEvent(_ event: PackageOperationEvent, byteCost: Int) {
        switch eventSource.yield(event, byteCost: byteCost) {
        case .delivered, .enqueued, .dropped, .terminated:
            break
        }
    }

    private static func readerTask(
        handle: FileHandle,
        consume: @escaping @Sendable (Data) async -> Void
    ) -> Task<Void, Never> {
        let box = PackageFileHandleBox(handle)
        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let data: Data
                do {
                    guard let chunk = try NativePipeIO.read(from: box.handle), !chunk.isEmpty else { return }
                    data = chunk
                } catch {
                    return
                }
                await consume(data)
            }
        }
    }

    private func drainReadersAfterTermination(process: NativeSubprocess) async {
        let stdout = stdoutTask
        let stderr = stderrTask
        // A completed command must not leave helper descendants holding the
        // inherited descriptors. Root output is already in the kernel pipes;
        // terminating the residual group lets both readers drain to true EOF.
        process.signalGroup(SIGKILL)
        await stdout?.value
        await stderr?.value
        process.closeOutput()
    }

    private func clearProcess() {
        cancellationEscalation?.cancel()
        cancellationEscalation = nil
        if let process {
            process.closeInput()
            process.closeOutput()
        }
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil
        process = nil
        operation = nil
    }
}

private final class PackageFileHandleBox: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
}
