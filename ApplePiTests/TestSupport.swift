import Foundation
@testable import ApplePi

enum TestSupport {
    static func temporaryDirectory(named name: String = #function) throws -> URL {
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ApplePiTests-\(sanitized)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url, options: .atomic)
    }

    static func writeExecutableShellScript(_ body: String, to url: URL) throws {
        try write("#!/bin/sh\nset -eu\n\(body)\n", to: url)
        try makeExecutable(url)
    }

    static func writeExecutable(_ source: String, to url: URL) throws {
        try write(source, to: url)
        try makeExecutable(url)
    }

    private static func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    static func nativeRuntime(executable: URL) -> PiRuntimeDescriptor {
        PiRuntimeDescriptor(
            source: .savedExecutable,
            version: SemanticVersion(major: 0, minor: 84, patch: 3),
            executable: executable,
            compatibility: .native,
            capabilities: [.nativeV1Required, .bridgeV1]
        )
    }

    static func waitUntil(
        timeout: Duration = .seconds(3),
        interval: Duration = .milliseconds(20),
        _ predicate: @escaping @Sendable () -> Bool
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !predicate() {
                    try Task.checkCancellation()
                    try await Task.sleep(for: interval)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestTimeoutError()
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    static func nextEvent(
        in stream: AsyncStream<PiRPCEvent>,
        timeout: Duration = .seconds(3),
        matching predicate: @escaping @Sendable (PiRPCEvent) -> Bool
    ) async throws -> PiRPCEvent {
        try await withThrowingTaskGroup(of: PiRPCEvent.self) { group in
            group.addTask {
                for await event in stream where predicate(event) {
                    return event
                }
                throw EventStreamEndedError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestTimeoutError()
            }
            guard let event = try await group.next() else {
                throw EventStreamEndedError()
            }
            group.cancelAll()
            return event
        }
    }
}

struct TestTimeoutError: Error {}
struct EventStreamEndedError: Error {}
