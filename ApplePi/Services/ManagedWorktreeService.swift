import Foundation

public enum ManagedWorktreeError: LocalizedError, Sendable {
    case creationFailed(String)
    case removalFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .creationFailed(message):
            "ApplePi could not create an isolated task worktree. \(message)"
        case let .removalFailed(message):
            "ApplePi could not remove the unused task worktree. \(message)"
        }
    }
}

/// Serializes mutations to a repository's shared Git worktree metadata.
public actor ManagedWorktreeService {
    typealias GitRunner = @Sendable ([String], TimeInterval) async throws -> CapturedProcessResult

    private let root: URL
    private let fileManager: FileManager
    private let gitRunner: GitRunner
    private var lockedRepositoryKeys = Set<String>()
    private var mutationWaitersByRepository: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(root: URL = AppPaths().managedWorktrees, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        gitRunner = { arguments, timeout in
            try await ProcessCapture.run(
                executable: URL(filePath: "/usr/bin/git"),
                arguments: arguments,
                timeout: timeout,
                maximumOutputBytes: 64 * 1_024
            )
        }
    }

    init(root: URL, fileManager: FileManager = .default, gitRunner: @escaping GitRunner) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        self.gitRunner = gitRunner
    }

    /// Returns nil when the source directory is not part of a Git repository.
    public func createIfSupported(from sourceDirectory: URL, taskID: String) async throws -> URL? {
        let source = sourceDirectory.standardizedFileURL
        let repositoryCheck = try await runGit(
            ["-C", source.path, "rev-parse", "--show-toplevel"],
            timeout: 10
        )
        guard repositoryCheck.status == 0 else { return nil }

        let repositoryPath = repositoryCheck.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryPath.isEmpty else {
            throw ManagedWorktreeError.creationFailed("Git did not return a repository root.")
        }
        let repository = URL(filePath: repositoryPath, directoryHint: .isDirectory).standardizedFileURL
        let safeTaskID = taskID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let checkout = root.appending(path: safeTaskID, directoryHint: .isDirectory).standardizedFileURL
        guard Self.contains(checkout, in: root), !fileManager.fileExists(atPath: checkout.path) else {
            throw ManagedWorktreeError.creationFailed("The managed worktree destination is unavailable.")
        }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let repositoryKey = await canonicalRepositoryKey(for: repository)
        let result = try await runSerializedGitMutation(
            repositoryKey: repositoryKey,
            ["-C", repository.path, "worktree", "add", "--detach", checkout.path, "HEAD"],
            timeout: 120
        )
        guard result.status == 0 else {
            let diagnostic = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagedWorktreeError.creationFailed(
                diagnostic.isEmpty ? "Git exited with status \(result.status)." : diagnostic
            )
        }
        let relativeComponents = source.pathComponents.dropFirst(repository.pathComponents.count)
        return relativeComponents.reduce(checkout) { directory, component in
            directory.appending(path: component, directoryHint: .isDirectory)
        }
    }

    /// Used only for drafts that have never launched Pi, so no task changes can be lost.
    public func removeUntouched(at worktree: URL, from sourceDirectory: URL) async throws {
        guard let checkout = Self.managedCheckoutRoot(for: worktree, root: root) else { return }
        guard fileManager.fileExists(atPath: checkout.path) else { return }

        let repositoryKey = await canonicalRepositoryKey(for: sourceDirectory)
        let result = try await runSerializedGitMutation(
            repositoryKey: repositoryKey,
            ["-C", sourceDirectory.standardizedFileURL.path, "worktree", "remove", checkout.path],
            timeout: 30
        )
        guard result.status == 0 else {
            let diagnostic = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagedWorktreeError.removalFailed(
                diagnostic.isEmpty ? "Git exited with status \(result.status)." : diagnostic
            )
        }
    }

    public nonisolated static func isManagedDirectory(_ directory: URL, root: URL = AppPaths().managedWorktrees) -> Bool {
        contains(directory.standardizedFileURL, in: root.standardizedFileURL)
    }

    private nonisolated static func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath != rootPath && candidatePath.hasPrefix(rootPath + "/")
    }

    private nonisolated static func managedCheckoutRoot(for directory: URL, root: URL) -> URL? {
        let candidate = directory.standardizedFileURL
        let managedRoot = root.standardizedFileURL
        guard contains(candidate, in: managedRoot) else { return nil }
        let relativeComponents = candidate.pathComponents.dropFirst(managedRoot.pathComponents.count)
        guard let checkoutName = relativeComponents.first else { return nil }
        return managedRoot.appending(path: checkoutName, directoryHint: .isDirectory)
    }

    private func runGit(_ arguments: [String], timeout: TimeInterval) async throws -> CapturedProcessResult {
        try await gitRunner(arguments, timeout)
    }

    private func runSerializedGitMutation(
        repositoryKey: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) async throws -> CapturedProcessResult {
        await acquireMutationLock(repositoryKey: repositoryKey)
        defer { releaseMutationLock(repositoryKey: repositoryKey) }
        return try await runGit(arguments, timeout: timeout)
    }

    private func canonicalRepositoryKey(for directory: URL) async -> String {
        let fallback = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard let result = try? await runGit(
            ["-C", directory.standardizedFileURL.path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            timeout: 10
        ), result.status == 0 else { return fallback }
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return fallback }
        return URL(filePath: path, directoryHint: .isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func acquireMutationLock(repositoryKey: String) async {
        if lockedRepositoryKeys.insert(repositoryKey).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaitersByRepository[repositoryKey, default: []].append(continuation)
        }
    }

    private func releaseMutationLock(repositoryKey: String) {
        guard var waiters = mutationWaitersByRepository[repositoryKey], !waiters.isEmpty else {
            lockedRepositoryKeys.remove(repositoryKey)
            mutationWaitersByRepository.removeValue(forKey: repositoryKey)
            return
        }
        let next = waiters.removeFirst()
        if waiters.isEmpty { mutationWaitersByRepository.removeValue(forKey: repositoryKey) }
        else { mutationWaitersByRepository[repositoryKey] = waiters }
        next.resume()
    }
}
