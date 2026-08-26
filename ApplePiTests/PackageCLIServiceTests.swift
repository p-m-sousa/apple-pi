import Foundation
import Testing
@testable import ApplePi

@Suite("Official Pi package CLI boundary", .serialized)
struct PackageCLIServiceTests {
    @Test("Package sources and trust flags are passed as literal argv")
    func literalArguments() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "pi")
        try TestSupport.writeExecutableShellScript(
            """
            : > package-argv.txt
            for argument in "$@"; do
              printf '%s\\n' "$argument" >> package-argv.txt
            done
            printf '%s' 'installed'
            printf '%s' 'api_key=should-not-escape' >&2
            """,
            to: executable
        )

        let service = PiPackageCLIService(
            runtime: TestSupport.nativeRuntime(executable: executable),
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: directory,
            projectTrusted: false
        )
        let source = "creator/package; touch package-pwned"
        let result = try await service.perform(.install(source: source, scope: .project))
        let arguments = try String(
            contentsOf: directory.appending(path: "package-argv.txt"),
            encoding: .utf8
        ).split(separator: "\n").map(String.init)

        #expect(result.succeeded)
        #expect(arguments == ["install", source, "--local", "--no-approve"])
        #expect(result.output == "installed")
        #expect(result.errorOutput.contains("<redacted>"))
        #expect(!result.errorOutput.contains("should-not-escape"))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "package-pwned").path))
    }

    @Test("Empty and control-character package sources are rejected before launch")
    func invalidSources() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "pi")
        try TestSupport.writeExecutableShellScript("exit 99", to: executable)
        let service = PiPackageCLIService(
            runtime: TestSupport.nativeRuntime(executable: executable),
            environment: [:],
            workingDirectory: directory,
            projectTrusted: true
        )

        for source in ["", "   ", "creator/package\nmalicious", "creator/package\0malicious"] {
            do {
                _ = try await service.perform(.install(source: source, scope: .user))
                Issue.record("Expected source to be rejected: \(source.debugDescription)")
            } catch let error as PiPackageCLIError {
                guard case .invalidSource = error else {
                    Issue.record("Unexpected package error: \(error)")
                    continue
                }
            }
        }
    }

    @Test("Refresh operations use Pi update subcommands and never a shell")
    func refreshModelArguments() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "pi")
        try TestSupport.writeExecutableShellScript(
            """
            for argument in "$@"; do printf '%s\\n' "$argument"; done
            """,
            to: executable
        )
        let service = PiPackageCLIService(
            runtime: TestSupport.nativeRuntime(executable: executable),
            environment: [:],
            workingDirectory: directory,
            projectTrusted: true
        )

        let models = try await service.perform(.refreshModels)
        #expect(models.output.split(separator: "\n").map(String.init) == ["update", "--models", "--approve"])
        let packages = try await service.perform(.updateAllPackages)
        #expect(packages.output.split(separator: "\n").map(String.init) == ["update", "--extensions", "--approve"])
    }

    @Test("Immediate process exit drains ordered stdout and stderr")
    func immediateExitDrainsOutput() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "pi")
        try TestSupport.writeExecutable(
            """
            #!/usr/bin/python3
            import os
            for value in (b"alpha", b"-", b"omega"):
                os.write(1, value)
            for value in (b"warning", b"-", b"tail"):
                os.write(2, value)
            """,
            to: executable
        )
        let service = PiPackageCLIService(
            runtime: TestSupport.nativeRuntime(executable: executable),
            environment: [:],
            workingDirectory: directory,
            projectTrusted: true
        )

        let result = try await service.perform(.refreshModels)

        #expect(result.output == "alpha-omega")
        #expect(result.errorOutput == "warning-tail")
    }

    @Test("Output overflow preserves started and completed lifecycle events")
    func outputOverflowPreservesLifecycleEvents() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "pi")
        try TestSupport.writeExecutable(
            """
            #!/usr/bin/python3
            import os
            os.write(1, b"x" * (256 * 1024))
            """,
            to: executable
        )
        let service = PiPackageCLIService(
            runtime: TestSupport.nativeRuntime(executable: executable),
            environment: [:],
            workingDirectory: directory,
            projectTrusted: true,
            maximumEventBufferedBytes: 128
        )

        let result = try await service.perform(.refreshModels)
        #expect(result.succeeded)

        let events = try await withThrowingTaskGroup(of: [PackageOperationEvent].self) { group in
            group.addTask {
                var retained: [PackageOperationEvent] = []
                for await event in service.events {
                    retained.append(event)
                    if case .completed = event { return retained }
                }
                throw EventStreamEndedError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw TestTimeoutError()
            }
            let retained = try await group.next() ?? []
            group.cancelAll()
            return retained
        }

        let lifecycle = events.compactMap { event -> String? in
            switch event {
            case .started: "started"
            case .outputGap: "gap"
            case .completed: "completed"
            case .output: nil
            }
        }
        #expect(lifecycle == ["started", "gap", "completed"])
    }
}
