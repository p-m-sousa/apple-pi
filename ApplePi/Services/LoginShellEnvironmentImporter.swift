import Foundation

public enum LoginShellEnvironmentError: LocalizedError, Sendable {
    case shellNotExecutable(String)
    case commandFailed(status: Int32)
    case sentinelMissing

    public var errorDescription: String? {
        switch self {
        case let .shellNotExecutable(path):
            "The configured login shell is not executable: \(path)"
        case let .commandFailed(status):
            "The login shell environment command exited with status \(status)."
        case .sentinelMissing:
            "The login shell did not produce a recognizable environment payload."
        }
    }
}

public actor LoginShellEnvironmentImporter {
    public struct Configuration: Sendable {
        public let timeout: TimeInterval
        public let maximumOutputBytes: Int

        public init(timeout: TimeInterval = 3, maximumOutputBytes: Int = 2 * 1_024 * 1_024) {
            self.timeout = timeout
            self.maximumOutputBytes = maximumOutputBytes
        }
    }

    private static let sentinel = Data("\0__APPLE_PI_ENV_V1__\0".utf8)
    private let configuration: Configuration
    private var cachedEnvironment: [String: String]?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Imports a login-shell environment once per app process.
    ///
    /// The result is meant only for child processes. Callers must not persist or log it.
    public func environment(forceRefresh: Bool = false) async throws -> [String: String] {
        if !forceRefresh, let cachedEnvironment { return cachedEnvironment }

        let base = ProcessInfo.processInfo.environment
        let shellPath = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shellPath) else {
            throw LoginShellEnvironmentError.shellNotExecutable(shellPath)
        }

        // The command is fixed application code; no user-controlled values are
        // interpolated into the shell source.
        let command = #"printf '\0__APPLE_PI_ENV_V1__\0'; /usr/bin/env -0"#
        let result = try await ProcessCapture.run(
            executable: URL(filePath: shellPath),
            arguments: ["-lic", command],
            environment: base,
            timeout: configuration.timeout,
            maximumOutputBytes: configuration.maximumOutputBytes
        )
        guard result.status == 0 else {
            throw LoginShellEnvironmentError.commandFailed(status: result.status)
        }
        guard let sentinelRange = result.standardOutput.range(of: Self.sentinel) else {
            throw LoginShellEnvironmentError.sentinelMissing
        }

        let payload = result.standardOutput[sentinelRange.upperBound...]
        var imported = base
        for record in payload.split(separator: 0, omittingEmptySubsequences: true) {
            guard let separator = record.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let keyData = record[..<separator]
            let valueData = record[record.index(after: separator)...]
            guard let key = String(data: keyData, encoding: .utf8),
                  !key.isEmpty,
                  !key.contains("\0"),
                  let value = String(data: valueData, encoding: .utf8) else {
                continue
            }
            imported[key] = value
        }

        cachedEnvironment = imported
        return imported
    }

    public func clearCache() {
        cachedEnvironment = nil
    }
}
