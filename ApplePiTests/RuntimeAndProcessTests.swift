import Darwin
import Foundation
import Testing
@testable import ApplePi

@Suite("Git permanent worktrees")
struct GitWorktreeServiceTests {
    @Test("A permanent worktree creates the requested branch and checkout")
    func createsWorktree() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appending(path: "repository", directoryHint: .isDirectory)
        let destination = directory.appending(path: "feature-worktree", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        try await runGit(["init", "-b", "main"], in: repository)
        try await runGit(["config", "user.name", "ApplePi Tests"], in: repository)
        try await runGit(["config", "user.email", "apple-pi@example.invalid"], in: repository)
        try TestSupport.write("seed", to: repository.appending(path: "seed.txt"))
        try await runGit(["add", "seed.txt"], in: repository)
        try await runGit(["commit", "-m", "seed"], in: repository)

        try await GitWorktreeService.create(
            from: repository,
            branchName: "feature/sidebar-projects",
            destination: destination
        )

        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "seed.txt").path))
        let branch = try await ProcessCapture.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-C", destination.path, "branch", "--show-current"]
        )
        #expect(branch.status == 0)
        #expect(branch.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            == "feature/sidebar-projects")
    }

    private func runGit(_ arguments: [String], in directory: URL) async throws {
        let result = try await ProcessCapture.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectory: directory
        )
        guard result.status == 0 else {
            throw GitTestError.failed(result.stderrString)
        }
    }
}

@Suite("Managed task worktrees")
struct ManagedWorktreeServiceTests {
    @Test("A Git project gets an isolated detached checkout")
    func createsDetachedWorktree() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appending(path: "repository", directoryHint: .isDirectory)
        let managedRoot = directory.appending(path: "managed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try await runGit(["init", "-b", "main"], in: repository)
        try await runGit(["config", "user.name", "ApplePi Tests"], in: repository)
        try await runGit(["config", "user.email", "apple-pi@example.invalid"], in: repository)
        try TestSupport.write("seed", to: repository.appending(path: "seed.txt"))
        try await runGit(["add", "seed.txt"], in: repository)
        try await runGit(["commit", "-m", "seed"], in: repository)

        let service = ManagedWorktreeService(root: managedRoot)
        let candidate = try await service.createIfSupported(
            from: repository,
            taskID: "draft-task-1"
        )
        let created = try #require(candidate)

        #expect(created == managedRoot.appending(path: "draft-task-1", directoryHint: .isDirectory))
        #expect(FileManager.default.fileExists(atPath: created.appending(path: "seed.txt").path))
        #expect(ManagedWorktreeService.isManagedDirectory(created, root: managedRoot))

        let branch = try await ProcessCapture.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-C", created.path, "branch", "--show-current"]
        )
        #expect(branch.status == 0)
        #expect(branch.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        try await service.removeUntouched(at: created, from: repository)
        #expect(!FileManager.default.fileExists(atPath: created.path))
    }

    @Test("A non-Git project remains local")
    func skipsNonGitDirectory() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ManagedWorktreeService(
            root: directory.appending(path: "managed", directoryHint: .isDirectory)
        )

        let created = try await service.createIfSupported(from: directory, taskID: "draft-task-2")

        #expect(created == nil)
    }

    @Test("A project subfolder remains the working directory in its checkout")
    func preservesProjectSubfolder() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appending(path: "repository", directoryHint: .isDirectory)
        let project = repository.appending(path: "Packages/App", directoryHint: .isDirectory)
        let managedRoot = directory.appending(path: "managed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try await runGit(["init", "-b", "main"], in: repository)
        try await runGit(["config", "user.name", "ApplePi Tests"], in: repository)
        try await runGit(["config", "user.email", "apple-pi@example.invalid"], in: repository)
        try TestSupport.write("seed", to: project.appending(path: "seed.txt"))
        try await runGit(["add", "Packages/App/seed.txt"], in: repository)
        try await runGit(["commit", "-m", "seed"], in: repository)

        let service = ManagedWorktreeService(root: managedRoot)
        let candidate = try await service.createIfSupported(from: project, taskID: "draft-nested")
        let created = try #require(candidate)

        #expect(created == managedRoot.appending(path: "draft-nested/Packages/App", directoryHint: .isDirectory))
        #expect(FileManager.default.fileExists(atPath: created.appending(path: "seed.txt").path))

        try await service.removeUntouched(at: created, from: project)
        #expect(!FileManager.default.fileExists(atPath: managedRoot.appending(path: "draft-nested").path))
    }

    @Test("Concurrent worktree mutations are serialized")
    func serializesMutations() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appending(path: "repository", directoryHint: .isDirectory)
        let managedRoot = directory.appending(path: "managed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let probe = WorktreeMutationProbe(repository: repository)
        let service = ManagedWorktreeService(root: managedRoot) { arguments, _ in
            await probe.run(arguments: arguments)
        }

        try await withThrowingTaskGroup(of: URL?.self) { group in
            for index in 0..<6 {
                group.addTask {
                    try await service.createIfSupported(from: repository, taskID: "draft-\(index)")
                }
            }
            for try await result in group { #expect(result != nil) }
        }

        #expect(await probe.mutationCount == 6)
        #expect(await probe.maximumConcurrentMutations == 1)
    }

    @Test("Different repositories mutate concurrently while each repository remains serialized")
    func repositoryKeyedMutationConcurrency() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstRepository = directory.appending(path: "repository-a", directoryHint: .isDirectory)
        let secondRepository = directory.appending(path: "repository-b", directoryHint: .isDirectory)
        let managedRoot = directory.appending(path: "managed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstRepository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRepository, withIntermediateDirectories: true)
        let probe = MultiRepositoryWorktreeMutationProbe(repositories: [firstRepository, secondRepository])
        let service = ManagedWorktreeService(root: managedRoot) { arguments, _ in
            await probe.run(arguments: arguments)
        }

        try await withThrowingTaskGroup(of: URL?.self) { group in
            for index in 0..<4 {
                group.addTask {
                    try await service.createIfSupported(from: firstRepository, taskID: "a-\(index)")
                }
                group.addTask {
                    try await service.createIfSupported(from: secondRepository, taskID: "b-\(index)")
                }
            }
            for try await result in group { #expect(result != nil) }
        }

        #expect(await probe.mutationCount == 8)
        #expect(await probe.maximumConcurrentMutations >= 2)
        #expect(await probe.maximumConcurrentMutations(for: firstRepository) == 1)
        #expect(await probe.maximumConcurrentMutations(for: secondRepository) == 1)
    }

    private func runGit(_ arguments: [String], in directory: URL) async throws {
        let result = try await ProcessCapture.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectory: directory
        )
        guard result.status == 0 else {
            throw GitTestError.failed(result.stderrString)
        }
    }
}

private enum GitTestError: Error {
    case failed(String)
}

private actor WorktreeMutationProbe {
    let repository: URL
    private(set) var mutationCount = 0
    private(set) var maximumConcurrentMutations = 0
    private var activeMutations = 0

    init(repository: URL) {
        self.repository = repository
    }

    func run(arguments: [String]) async -> CapturedProcessResult {
        if arguments.contains("rev-parse") {
            return CapturedProcessResult(
                status: 0,
                standardOutput: Data("\(repository.path)\n".utf8),
                standardError: Data()
            )
        }
        mutationCount += 1
        activeMutations += 1
        maximumConcurrentMutations = max(maximumConcurrentMutations, activeMutations)
        try? await Task.sleep(for: .milliseconds(40))
        activeMutations -= 1
        return CapturedProcessResult(status: 0, standardOutput: Data(), standardError: Data())
    }
}

private actor MultiRepositoryWorktreeMutationProbe {
    let repositories: [URL]
    private(set) var mutationCount = 0
    private(set) var maximumConcurrentMutations = 0
    private var activeMutations = 0
    private var activeMutationsByRepository: [String: Int] = [:]
    private var maximumConcurrentMutationsByRepository: [String: Int] = [:]

    init(repositories: [URL]) {
        self.repositories = repositories
    }

    func run(arguments: [String]) async -> CapturedProcessResult {
        let repository = repository(for: arguments)
        if arguments.contains("rev-parse") {
            let output = arguments.contains("--git-common-dir")
                ? repository.appending(path: ".git", directoryHint: .isDirectory).path
                : repository.path
            return CapturedProcessResult(
                status: 0,
                standardOutput: Data("\(output)\n".utf8),
                standardError: Data()
            )
        }

        let key = repository.standardizedFileURL.path
        mutationCount += 1
        activeMutations += 1
        activeMutationsByRepository[key, default: 0] += 1
        maximumConcurrentMutations = max(maximumConcurrentMutations, activeMutations)
        maximumConcurrentMutationsByRepository[key] = max(
            maximumConcurrentMutationsByRepository[key] ?? 0,
            activeMutationsByRepository[key] ?? 0
        )
        try? await Task.sleep(for: .milliseconds(40))
        activeMutations -= 1
        activeMutationsByRepository[key, default: 1] -= 1
        return CapturedProcessResult(status: 0, standardOutput: Data(), standardError: Data())
    }

    func maximumConcurrentMutations(for repository: URL) -> Int {
        maximumConcurrentMutationsByRepository[repository.standardizedFileURL.path] ?? 0
    }

    private func repository(for arguments: [String]) -> URL {
        guard let index = arguments.firstIndex(of: "-C"), arguments.indices.contains(index + 1) else {
            return repositories[0]
        }
        let directory = URL(filePath: arguments[index + 1], directoryHint: .isDirectory).standardizedFileURL
        return repositories.first { repository in
            directory.path == repository.standardizedFileURL.path
                || directory.path.hasPrefix(repository.standardizedFileURL.path + "/")
        } ?? repositories[0]
    }
}

@Suite("Runtime discovery and child-process safety", .serialized)
struct RuntimeAndProcessTests {
    @Test("Ordered pipe writes cap pending bytes and remove cancelled producers")
    func orderedPipeWriterBackpressure() async {
        let pipe = Pipe()
        let limit = 16 * 1_024 * 1_024
        let payload = Data(repeating: UInt8(ascii: "x"), count: 12 * 1_024 * 1_024)
        let writer = OrderedPipeWriter(
            handle: pipe.fileHandleForWriting,
            maximumPendingBytes: limit,
            chunkBytes: 64 * 1_024
        )
        defer {
            writer.close()
            try? pipe.fileHandleForReading.close()
        }

        let first = Task { try await writer.write(payload) }
        let clock = ContinuousClock()
        let activeDeadline = clock.now.advanced(by: .seconds(1))
        while !writer.hasActiveWrite, clock.now < activeDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(writer.hasActiveWrite)

        let second = Task { try await writer.write(payload) }
        let pendingDeadline = clock.now.advanced(by: .seconds(1))
        while writer.pendingByteCount == 0, clock.now < pendingDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let third = Task { try await writer.write(payload) }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(writer.pendingByteCount == payload.count)
        #expect(writer.pendingByteCount <= limit)

        second.cancel()
        do {
            try await second.value
            Issue.record("Expected the pending writer to observe cancellation")
        } catch is CancellationError {
            // Expected: cancellation removes and resumes this producer once.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
        let promotedDeadline = clock.now.advanced(by: .seconds(1))
        while writer.pendingByteCount == 0, clock.now < promotedDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(writer.pendingByteCount == payload.count)
        #expect(writer.pendingByteCount <= limit)

        writer.close()
        _ = try? await first.value
        _ = try? await third.value
    }

    @Test("Runtime probes use bounded concurrency and preserve discovery priority")
    func runtimeProbeConcurrencyAndOrder() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counterDirectory = directory.appending(path: "counter", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: counterDirectory, withIntermediateDirectories: true)
        let executables = try (0..<4).map { index in
            let executable = directory.appending(path: "pi-\(index)")
            try TestSupport.writeExecutableShellScript(
                """
                lock='\(counterDirectory.path)/lock'
                while ! /bin/mkdir "$lock" 2>/dev/null; do /bin/sleep 0.005; done
                active=$(/bin/cat '\(counterDirectory.path)/active' 2>/dev/null || printf '0')
                active=$((active + 1))
                printf '%s' "$active" > '\(counterDirectory.path)/active'
                maximum=$(/bin/cat '\(counterDirectory.path)/maximum' 2>/dev/null || printf '0')
                if [ "$active" -gt "$maximum" ]; then printf '%s' "$active" > '\(counterDirectory.path)/maximum'; fi
                /bin/rmdir "$lock"
                /bin/sleep 0.08
                while ! /bin/mkdir "$lock" 2>/dev/null; do /bin/sleep 0.005; done
                active=$(/bin/cat '\(counterDirectory.path)/active')
                printf '%s' "$((active - 1))" > '\(counterDirectory.path)/active'
                /bin/rmdir "$lock"
                if [ "$1" = "--version" ]; then
                  printf '%s\n' '0.84.2'
                else
                  printf '%s\n' '--mode <mode> rpc --extension --approve --no-approve pi install pi remove'
                fi
                """,
                to: executable
            )
            return executable
        }
        let resolution = await PiRuntimeResolver(configuration: .init(
            commonExecutableURLs: executables,
            bridgeURL: nil
        )).resolve()

        let resolvedPaths = resolution.candidates
            .filter { executables.contains($0.executable) }
            .map(\.executable)
        #expect(resolvedPaths == executables)
        let maximum = try String(
            contentsOf: counterDirectory.appending(path: "maximum"),
            encoding: .utf8
        )
        #expect(maximum == "2")
    }

    @Test("A compatible saved runtime wins after version and capability probes")
    func compatibleSavedRuntimeWins() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "pi")
        try TestSupport.writeExecutableShellScript(
            """
            case "${1:-}" in
              --version)
                printf '%s\\n' 'pi 0.84.3'
                ;;
              --help)
                printf '%s\\n' 'usage: pi --mode <mode> rpc --extension --approve --no-approve pi install pi remove'
                ;;
              *)
                exit 0
                ;;
            esac
            """,
            to: executable
        )

        let resolver = PiRuntimeResolver(configuration: .init(
            savedExecutable: executable,
            commonExecutableURLs: []
        ))
        let resolution = await resolver.resolve()
        let saved = try #require(resolution.candidates.first { $0.source == .savedExecutable })
        #expect(saved.executable.standardizedFileURL == executable.standardizedFileURL)
        #expect(saved.version == SemanticVersion(major: 0, minor: 84, patch: 3))
        #expect(saved.compatibility == .native)
        #expect(saved.capabilities.isSuperset(of: .nativeV1Required))
        #expect(resolution.selected?.id == saved.id)
    }

    @Test("Out-of-range runtimes require an explicit override and a nonce-bound bridge probe")
    func advancedOverrideRequiresBridgeProbe() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "pi")
        try TestSupport.writeExecutableShellScript(
            """
            case "${1:-}" in
              --version) printf '%s\\n' 'pi 0.86.0' ;;
              --help) printf '%s\\n' 'usage: pi --mode <mode> rpc --extension --approve --no-approve pi install pi remove' ;;
              *) exit 0 ;;
            esac
            """,
            to: executable
        )

        let normal = await PiRuntimeResolver(configuration: .init(
            savedExecutable: executable,
            allowAdvancedOverride: false,
            commonExecutableURLs: []
        )).resolve()
        let normalCandidate = try #require(normal.candidates.first { $0.executable.path == executable.path })
        #expect(normalCandidate.compatibility == .terminalOnly)
        #expect(!normalCandidate.supportsNativeTasks)

        let helpOnlyOverride = await PiRuntimeResolver(configuration: .init(
            savedExecutable: executable,
            allowAdvancedOverride: true,
            commonExecutableURLs: [],
            bridgeURL: nil
        )).resolve()
        let helpOnlyCandidate = try #require(helpOnlyOverride.candidates.first { $0.executable.path == executable.path })
        #expect(helpOnlyCandidate.compatibility == .terminalOnly)
        #expect(!helpOnlyCandidate.supportsNativeTasks)

        let bridge = directory.appending(path: "apple-pi-bridge.ts")
        try TestSupport.write("// readable probe fixture", to: bridge)
        try TestSupport.writeExecutable(
            """
            #!/usr/bin/python3
            import base64, json, sys
            argument = sys.argv[1] if len(sys.argv) > 1 else ""
            if argument == "--version":
                print("pi 0.86.0")
                sys.exit(0)
            if argument == "--help":
                print("usage: pi --mode <mode> rpc --extension --approve --no-approve pi install pi remove")
                sys.exit(0)

            request = json.loads(sys.stdin.readline())
            encoded = request["message"].split(" ", 1)[1]
            encoded += "=" * ((4 - len(encoded) % 4) % 4)
            envelope = json.loads(base64.urlsafe_b64decode(encoded))
            response = {
                "version": 1,
                "requestID": envelope["requestID"],
                "nonce": envelope["nonce"],
                "success": True,
                "result": {"pong": True},
                "error": None,
            }
            notification = base64.urlsafe_b64encode(
                json.dumps(response, separators=(",", ":")).encode()
            ).decode().rstrip("=")
            print(json.dumps({
                "type": "response",
                "id": "apple-pi-compatibility-probe",
                "command": "prompt",
                "success": True,
            }, separators=(",", ":")))
            print(json.dumps({
                "type": "extension_ui_request",
                "id": "bridge-notification",
                "method": "notify",
                "message": "__APPLE_PI_BRIDGE_V1__:" + notification,
            }, separators=(",", ":")))
            """,
            to: executable
        )

        let advanced = await PiRuntimeResolver(configuration: .init(
            savedExecutable: executable,
            allowAdvancedOverride: true,
            commonExecutableURLs: [],
            bridgeURL: bridge
        )).resolve()
        let advancedCandidate = try #require(advanced.candidates.first { $0.executable.path == executable.path })
        #expect(advancedCandidate.compatibility == .advancedOverride)
        #expect(advancedCandidate.supportsNativeTasks)
        #expect(advancedCandidate.capabilities.contains(.bridgeV1))
    }

    @Test("The imported login-shell environment is cached and preserves the base environment")
    func loginEnvironmentIsCached() async throws {
        let importer = LoginShellEnvironmentImporter(configuration: .init(timeout: 5))
        let first = try await importer.environment()
        let second = try await importer.environment()

        #expect(first == second)
        #expect(first["PATH"]?.isEmpty == false)
        if let baseValue = ProcessInfo.processInfo.environment["TMPDIR"] {
            #expect(first["TMPDIR"] == baseValue)
        }
    }

    @Test("Process capture enforces its timeout without waiting for the child")
    func processTimeoutTerminatesChild() async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await ProcessCapture.run(
                executable: URL(filePath: "/bin/sleep"),
                arguments: ["10"],
                timeout: 0.05
            )
            Issue.record("Expected the process to time out")
        } catch let error as ProcessExecutionError {
            guard case .timedOut = error else {
                Issue.record("Unexpected process error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(started.duration(to: clock.now) < .seconds(2))
    }

    @Test("The child process group is established before exec")
    func nativeLaunchCreatesPrivateProcessGroup() async throws {
        let result = try await ProcessCapture.run(
            executable: URL(filePath: "/usr/bin/python3"),
            arguments: ["-c", "import os; print(os.getpid(), os.getpgrp())"],
            timeout: 2
        )
        let identifiers = result.stdoutString
            .split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t($0) }
        #expect(identifiers.count == 2)
        #expect(identifiers.first == identifiers.last)
    }

    @Test("Process output is capped independently for stdout and stderr")
    func processOutputCap() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "output")
        try TestSupport.writeExecutable(
            """
            #!/usr/bin/python3
            import sys
            sys.stdout.write("1" * (256 * 1024))
            sys.stderr.write("a" * (256 * 1024))
            """,
            to: executable
        )
        let result = try await ProcessCapture.run(
            executable: executable,
            arguments: [],
            timeout: 2,
            maximumOutputBytes: 4
        )
        #expect(result.status == 0)
        #expect(result.stdoutString == "1111")
        #expect(result.stderrString == "aaaa")
    }

    @Test("Process input and output are drained concurrently")
    func processInputDoesNotDeadlockOutput() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "duplex-io")
        try TestSupport.writeExecutable(
            """
            #!/usr/bin/python3
            import sys
            sys.stdout.buffer.write(b"o" * (512 * 1024))
            sys.stdout.buffer.flush()
            payload = sys.stdin.buffer.read()
            sys.exit(0 if len(payload) == 512 * 1024 else 7)
            """,
            to: executable
        )

        let result = try await ProcessCapture.run(
            executable: executable,
            arguments: [],
            input: Data(repeating: UInt8(ascii: "i"), count: 512 * 1_024),
            timeout: 2,
            maximumOutputBytes: 8
        )

        #expect(result.status == 0)
        #expect(result.stdoutString == "oooooooo")
    }

    @Test("A descendant holding inherited pipes cannot defeat the timeout")
    func inheritedPipeTimeout() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "inherited-pipe")
        try TestSupport.writeExecutableShellScript(
            """
            /bin/sleep 10 &
            printf '%s' "$!" > descendant.pid
            /bin/sleep 0.05
            exit 0
            """,
            to: executable
        )
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await ProcessCapture.run(
                executable: executable,
                arguments: [],
                currentDirectory: directory,
                timeout: 0.15
            )
            Issue.record("Expected inherited pipe ownership to time out")
        } catch let error as ProcessExecutionError {
            guard case .timedOut = error else {
                Issue.record("Unexpected process error: \(error)")
                return
            }
        }

        #expect(started.duration(to: clock.now) < .seconds(2))
        let descendantText = try String(
            contentsOf: directory.appending(path: "descendant.pid"),
            encoding: .utf8
        )
        let descendantPID = try #require(pid_t(descendantText))
        #expect(Darwin.kill(descendantPID, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("Cancellation interrupts process capture promptly")
    func processCancellation() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await ProcessCapture.run(
                executable: URL(filePath: "/bin/sleep"),
                arguments: ["10"],
                timeout: 30
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected process capture cancellation")
        } catch is CancellationError {
            // Expected.
        }
        #expect(started.duration(to: clock.now) < .seconds(2))
    }

    @Test("Timeout escalates from TERM to KILL for an uncooperative process group")
    func ignoredTermEscalatesToKill() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "ignore-term")
        try TestSupport.writeExecutableShellScript(
            """
            trap '' TERM
            printf '%s' "$$" > root.pid
            while :; do /bin/sleep 1; done
            """,
            to: executable
        )

        do {
            _ = try await ProcessCapture.run(
                executable: executable,
                arguments: [],
                currentDirectory: directory,
                timeout: 0.05
            )
            Issue.record("Expected the process to time out")
        } catch let error as ProcessExecutionError {
            guard case .timedOut = error else {
                Issue.record("Unexpected process error: \(error)")
                return
            }
        }

        let pidText = try String(contentsOf: directory.appending(path: "root.pid"), encoding: .utf8)
        let pid = try #require(pid_t(pidText))
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("Immediate exit preserves final unterminated stdout and stderr")
    func immediateExitPreservesBothFinalStreams() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "final-streams")
        try TestSupport.writeExecutableShellScript(
            """
            printf '%s' 'final-stdout'
            printf '%s' 'final-stderr' >&2
            """,
            to: executable
        )

        let result = try await ProcessCapture.run(
            executable: executable,
            arguments: [],
            timeout: 2
        )

        #expect(result.status == 0)
        #expect(result.stdoutString == "final-stdout")
        #expect(result.stderrString == "final-stderr")
    }

    @Test("One hundred native launch-stop cycles leave no child or descriptor growth")
    func repeatedNativeLaunchStopIsStable() async throws {
        let descriptorBaseline = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count

        for _ in 0..<100 {
            let process = try NativeSubprocess.launch(
                executable: URL(filePath: "/bin/cat"),
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"],
                providesStandardInput: true
            )
            process.closeInput()
            #expect(await process.wait() == 0)
            process.signalGroup(SIGKILL)
            process.closeOutput()
            #expect(Darwin.kill(process.processIdentifier, 0) == -1)
            #expect(errno == ESRCH)
        }

        let descriptorFinal = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        #expect(descriptorFinal <= descriptorBaseline + 2)
    }
}
