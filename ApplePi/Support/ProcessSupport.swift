import Darwin
import Foundation
import os

public struct CapturedProcessResult: Sendable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data

    public var stdoutString: String { String(decoding: standardOutput, as: UTF8.self) }
    public var stderrString: String { String(decoding: standardError, as: UTF8.self) }
}

public enum ProcessExecutionError: LocalizedError, Sendable {
    case timedOut(seconds: TimeInterval)
    case couldNotLaunch(String)

    public var errorDescription: String? {
        switch self {
        case let .timedOut(seconds):
            "The subprocess did not finish within \(seconds.formatted()) seconds."
        case let .couldNotLaunch(message):
            "The subprocess could not be launched: \(message)"
        }
    }
}

/// A native subprocess with a private process group and explicitly owned pipe
/// endpoints. All launch sites use this transport so process-group setup cannot
/// race a short-lived child or a child which immediately creates descendants.
final class NativeSubprocess: @unchecked Sendable {
    let processIdentifier: pid_t
    let standardInput: FileHandle?
    let standardOutput: FileHandle
    let standardError: FileHandle

    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.paulsousa.ApplePi",
        category: .pointsOfInterest
    )
    private let exitSignal: NativeProcessExitSignal
    private let lock = NSLock()
    private var inputClosed = false
    private var outputClosed = false

    private init(
        processIdentifier: pid_t,
        standardInput: FileHandle?,
        standardOutput: FileHandle,
        standardError: FileHandle,
        exitSignal: NativeProcessExitSignal
    ) {
        self.processIdentifier = processIdentifier
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitSignal = exitSignal
    }

    var isRunning: Bool { exitSignal.status == nil }

    func wait() async -> Int32 {
        await exitSignal.wait()
    }

    func wait(timeout: TimeInterval) async -> Int32? {
        await exitSignal.wait(timeout: timeout)
    }

    /// The group remains signalable after its root exits while descendants are
    /// still alive, so this intentionally does not check `isRunning`.
    func signalGroup(_ signal: Int32) {
        guard processIdentifier > 0 else { return }
        _ = Darwin.kill(-processIdentifier, signal)
    }

    func terminate(escalatingAfter delay: TimeInterval = 1) {
        signalGroup(SIGTERM)
        let pid = processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, delay)) {
            _ = Darwin.kill(-pid, SIGKILL)
        }
    }

    func closeInput() {
        lock.lock()
        guard !inputClosed else {
            lock.unlock()
            return
        }
        inputClosed = true
        lock.unlock()
        try? standardInput?.close()
    }

    func closeOutput() {
        lock.lock()
        guard !outputClosed else {
            lock.unlock()
            return
        }
        outputClosed = true
        lock.unlock()
        try? standardOutput.close()
        try? standardError.close()
    }

    deinit {
        closeInput()
        closeOutput()
    }

    static func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        providesStandardInput: Bool
    ) throws -> NativeSubprocess {
        let executablePath = executable.path
        guard !executablePath.isEmpty,
              !executablePath.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              currentDirectory.map({ !$0.path.contains("\0") }) ?? true else {
            throw ProcessExecutionError.couldNotLaunch("Executable paths and arguments cannot contain NUL bytes.")
        }

        let effectiveEnvironment = environment ?? ProcessInfo.processInfo.environment
        guard effectiveEnvironment.allSatisfy({ key, value in
            !key.isEmpty && !key.contains("\0") && !key.contains("=") && !value.contains("\0")
        }) else {
            throw ProcessExecutionError.couldNotLaunch("Environment keys and values are not valid for exec.")
        }

        var inputDescriptors: (read: Int32, write: Int32)?
        let outputDescriptors = try makePipe()
        let errorDescriptors: (read: Int32, write: Int32)
        do {
            errorDescriptors = try makePipe()
        } catch {
            _ = Darwin.close(outputDescriptors.read)
            _ = Darwin.close(outputDescriptors.write)
            throw error
        }
        var ownedDescriptors = [
            outputDescriptors.read, outputDescriptors.write,
            errorDescriptors.read, errorDescriptors.write,
        ]
        do {
            if providesStandardInput {
                let descriptors = try makePipe()
                inputDescriptors = descriptors
                ownedDescriptors.append(contentsOf: [descriptors.read, descriptors.write])
            }
        } catch {
            ownedDescriptors.forEach { _ = Darwin.close($0) }
            throw error
        }
        var descriptorsTransferred = false
        defer {
            if !descriptorsTransferred {
                ownedDescriptors.forEach { _ = Darwin.close($0) }
            }
        }

        for descriptor in ownedDescriptors {
            _ = Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try checkSpawnCall(posix_spawn_file_actions_init(&fileActions), operation: "initialize file actions")
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try checkSpawnCall(posix_spawnattr_init(&attributes), operation: "initialize spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }

        if let inputDescriptors {
            try checkSpawnCall(
                posix_spawn_file_actions_adddup2(&fileActions, inputDescriptors.read, STDIN_FILENO),
                operation: "connect stdin"
            )
        } else {
            let result = "/dev/null".withCString { path in
                posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, path, O_RDONLY, 0)
            }
            try checkSpawnCall(result, operation: "open null stdin")
        }
        try checkSpawnCall(
            posix_spawn_file_actions_adddup2(&fileActions, outputDescriptors.write, STDOUT_FILENO),
            operation: "connect stdout"
        )
        try checkSpawnCall(
            posix_spawn_file_actions_adddup2(&fileActions, errorDescriptors.write, STDERR_FILENO),
            operation: "connect stderr"
        )
        for descriptor in ownedDescriptors {
            try checkSpawnCall(
                posix_spawn_file_actions_addclose(&fileActions, descriptor),
                operation: "close unused child descriptor"
            )
        }
        if let currentDirectory {
            let result = currentDirectory.path.withCString { path in
                posix_spawn_file_actions_addchdir(&fileActions, path)
            }
            try checkSpawnCall(result, operation: "set working directory")
        }

        try checkSpawnCall(
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
            operation: "enable process group"
        )
        try checkSpawnCall(
            posix_spawnattr_setpgroup(&attributes, 0),
            operation: "set process group"
        )

        let argv = [executablePath] + arguments
        let env = effectiveEnvironment.keys.sorted().map { "\($0)=\(effectiveEnvironment[$0]!)" }
        var pid: pid_t = 0
        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("ProcessLaunch", id: signpostID)
        defer { Self.signposter.endInterval("ProcessLaunch", interval) }
        let spawnResult = try withMutableCStringArray(argv) { argvPointer in
            try withMutableCStringArray(env) { envPointer in
                posix_spawn(
                    &pid,
                    executablePath,
                    &fileActions,
                    &attributes,
                    argvPointer,
                    envPointer
                )
            }
        }
        try checkSpawnCall(spawnResult, operation: "spawn \(executable.lastPathComponent)")

        // Close every child-side endpoint in the parent immediately. The only
        // surviving descriptors are wrapped by close-on-deallocation handles.
        if let inputDescriptors { _ = Darwin.close(inputDescriptors.read) }
        _ = Darwin.close(outputDescriptors.write)
        _ = Darwin.close(errorDescriptors.write)

        let inputHandle = inputDescriptors.map {
            FileHandle(fileDescriptor: $0.write, closeOnDealloc: true)
        }
        if let inputHandle {
            _ = Darwin.fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        }
        let outputHandle = FileHandle(fileDescriptor: outputDescriptors.read, closeOnDealloc: true)
        let errorHandle = FileHandle(fileDescriptor: errorDescriptors.read, closeOnDealloc: true)
        descriptorsTransferred = true

        let exitSignal = NativeProcessExitSignal()
        let spawnedPID = pid
        let lifetimeID = Self.signposter.makeSignpostID()
        let lifetimeInterval = Self.signposter.beginInterval("ProcessLifetime", id: lifetimeID)
        DispatchQueue.global(qos: .utility).async {
            var rawStatus: Int32 = 0
            var result: pid_t
            repeat {
                result = Darwin.waitpid(spawnedPID, &rawStatus, 0)
            } while result == -1 && errno == EINTR
            let status = result == spawnedPID ? decodedWaitStatus(rawStatus) : Int32(ECHILD)
            exitSignal.finish(status: status)
            Self.signposter.endInterval("ProcessLifetime", lifetimeInterval)
        }
        return NativeSubprocess(
            processIdentifier: pid,
            standardInput: inputHandle,
            standardOutput: outputHandle,
            standardError: errorHandle,
            exitSignal: exitSignal
        )
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard result == 0 else {
            throw ProcessExecutionError.couldNotLaunch(String(cString: strerror(errno)))
        }
        // File actions target descriptors 0...2. Normalize pipe descriptors
        // above that range even if the embedding process happened to launch
        // with one of its standard descriptors closed.
        for index in descriptors.indices where descriptors[index] <= STDERR_FILENO {
            let original = descriptors[index]
            let duplicate = Darwin.fcntl(original, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard duplicate >= 0 else {
                let savedError = errno
                descriptors.forEach { descriptor in
                    if descriptor >= 0 { _ = Darwin.close(descriptor) }
                }
                throw ProcessExecutionError.couldNotLaunch(String(cString: strerror(savedError)))
            }
            _ = Darwin.close(original)
            descriptors[index] = duplicate
        }
        return (descriptors[0], descriptors[1])
    }

    private static func checkSpawnCall(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw ProcessExecutionError.couldNotLaunch(
                "Could not \(operation): \(String(cString: strerror(result)))"
            )
        }
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        let allocated: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        guard allocated.allSatisfy({ $0 != nil }) else {
            throw ProcessExecutionError.couldNotLaunch("Could not allocate the exec argument vector.")
        }
        var pointers = allocated
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

private final class NativeProcessExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: Int32?
    private var continuations: [CheckedContinuation<Int32, Never>] = []
    private var observers: [@Sendable (Int32) -> Void] = []

    func finish(status: Int32) {
        lock.lock()
        guard storedStatus == nil else {
            lock.unlock()
            return
        }
        storedStatus = status
        let continuations = continuations
        self.continuations.removeAll()
        let observers = observers
        self.observers.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume(returning: status) }
        observers.forEach { $0(status) }
    }

    var status: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status = storedStatus {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func wait(timeout: TimeInterval) async -> Int32? {
        let latch = NativeWaitLatch()
        return await withCheckedContinuation { continuation in
            observe { status in
                guard latch.claim() else { return }
                continuation.resume(returning: status)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
                guard latch.claim() else { return }
                continuation.resume(returning: nil)
            }
        }
    }

    private func observe(_ observer: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        if let status = storedStatus {
            lock.unlock()
            observer(status)
        } else {
            observers.append(observer)
            lock.unlock()
        }
    }
}

private final class NativeWaitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private func decodedWaitStatus(_ rawStatus: Int32) -> Int32 {
    let signal = rawStatus & 0x7F
    if signal == 0 { return (rawStatus >> 8) & 0xFF }
    return signal
}

enum NativePipeIO {
    /// A direct POSIX read returns as soon as any pipe bytes are available.
    /// Foundation's `read(upToCount:)` may wait for EOF/full length on some
    /// FileHandle implementations, which would defeat live RPC delivery.
    static func read(from handle: FileHandle, maximumBytes: Int = 64 * 1_024) throws -> Data? {
        var storage = [UInt8](repeating: 0, count: max(1, maximumBytes))
        var count = -1
        repeat {
            count = storage.withUnsafeMutableBytes { buffer in
                Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
            }
        } while count < 0 && errno == EINTR
        if count > 0 { return Data(storage.prefix(count)) }
        if count == 0 { return nil }
        throw CocoaError(.fileReadUnknown)
    }
}

private final class FileHandleBox: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }

    /// Drain the pipe completely so the child cannot block, while retaining only
    /// the caller's bounded diagnostic prefix in memory.
    func readToEnd(retaining maximumBytes: Int) -> Data {
        let limit = max(0, maximumBytes)
        var retained = Data()
        retained.reserveCapacity(min(limit, 64 * 1_024))
        while true {
            let chunk: Data
            do {
                guard let value = try NativePipeIO.read(from: handle), !value.isEmpty else { break }
                chunk = value
            } catch {
                break
            }
            let remaining = limit - retained.count
            if remaining > 0 { retained.append(chunk.prefix(remaining)) }
        }
        return retained
    }
}

private enum ProcessCaptureRace: Sendable {
    case completed(CapturedProcessResult)
    case timedOut
}

public enum ProcessCapture {
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        input: Data? = nil,
        timeout: TimeInterval = 10,
        maximumOutputBytes: Int = 4 * 1_024 * 1_024
    ) async throws -> CapturedProcessResult {
        let process = try NativeSubprocess.launch(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            providesStandardInput: input != nil
        )

        let stdoutBox = FileHandleBox(process.standardOutput)
        let stderrBox = FileHandleBox(process.standardError)
        let stdoutTask = Task.detached(priority: .utility) {
            stdoutBox.readToEnd(retaining: maximumOutputBytes)
        }
        let stderrTask = Task.detached(priority: .utility) {
            stderrBox.readToEnd(retaining: maximumOutputBytes)
        }
        let inputTask: Task<Void, any Error>?
        if let input, let inputHandle = process.standardInput {
            let inputBox = FileHandleBox(inputHandle)
            inputTask = Task.detached(priority: .utility) {
                defer { try? inputBox.handle.close() }
                try inputBox.handle.write(contentsOf: input)
            }
        } else {
            inputTask = nil
        }

        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: ProcessCaptureRace.self) { group in
                    group.addTask {
                        let status = await process.wait()
                        if let inputTask { try await inputTask.value }
                        let outputData = await stdoutTask.value
                        let errorData = await stderrTask.value
                        return .completed(CapturedProcessResult(
                            status: status,
                            standardOutput: outputData,
                            standardError: errorData
                        ))
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeout))
                        return .timedOut
                    }
                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    switch first {
                    case let .completed(result):
                        try Task.checkCancellation()
                        process.closeInput()
                        process.closeOutput()
                        return result
                    case .timedOut:
                        await terminateAndDrain(
                            process: process,
                            inputTask: inputTask,
                            stdoutTask: stdoutTask,
                            stderrTask: stderrTask
                        )
                        throw ProcessExecutionError.timedOut(seconds: timeout)
                    }
                }
            } catch {
                await terminateAndDrain(
                    process: process,
                    inputTask: inputTask,
                    stdoutTask: stdoutTask,
                    stderrTask: stderrTask
                )
                throw error
            }
        } onCancel: {
            process.terminate()
            process.closeInput()
            inputTask?.cancel()
        }
    }

    private static func terminateAndDrain(
        process: NativeSubprocess,
        inputTask: Task<Void, any Error>?,
        stdoutTask: Task<Data, Never>,
        stderrTask: Task<Data, Never>
    ) async {
        process.closeInput()
        inputTask?.cancel()
        process.signalGroup(SIGTERM)
        if await process.wait(timeout: 1) == nil {
            process.signalGroup(SIGKILL)
            _ = await process.wait()
        }
        // The root may have exited while descendants still own inherited pipe
        // descriptors. KILL the group once more before waiting for true EOF.
        process.signalGroup(SIGKILL)
        _ = await stdoutTask.value
        _ = await stderrTask.value
        process.closeOutput()
    }
}
