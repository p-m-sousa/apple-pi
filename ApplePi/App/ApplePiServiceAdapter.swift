import AppKit
import Foundation
import UniformTypeIdentifiers
import UserNotifications

enum ApplePiServiceError: LocalizedError {
    case runtimeUnavailable
    case nativeRuntimeUnavailable(String)
    case sessionNotFound
    case taskNotRunning
    case bridgeUnavailable
    case bridgeFailed(String)
    case packageNotFound
    case packageOperationFailed(String)
    case projectRequired
    case projectNotFound
    case projectDirectoryMismatch
    case sessionChangedExternally
    case worktreeCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            "No Pi runtime could be found. Choose an executable in Settings or install Pi."
        case let .nativeRuntimeUnavailable(detail):
            "This Pi runtime is available only in the terminal. \(detail)"
        case .sessionNotFound:
            "The Pi session no longer exists. Refresh the task list and try again."
        case .taskNotRunning:
            "Start the task before using this action."
        case .bridgeUnavailable:
            "The bundled ApplePi bridge resource is unavailable."
        case let .bridgeFailed(message):
            "The Pi bridge rejected the request: \(message)"
        case .packageNotFound:
            "The selected Pi package resource is no longer installed."
        case let .packageOperationFailed(message):
            "Pi could not complete the package operation. \(message)"
        case .projectRequired:
            "Choose a project folder before using project-local resources."
        case .projectNotFound:
            "The selected project no longer exists."
        case .projectDirectoryMismatch:
            "A task can only move to a project that uses the same working folder."
        case .sessionChangedExternally:
            "This session changed on disk. ApplePi refreshed it so you can review the newer version before trying again."
        case let .worktreeCreationFailed(message):
            "ApplePi could not create the permanent worktree. \(message)"
        }
    }
}

enum GitWorktreeService {
    static func create(
        from sourceDirectory: URL,
        branchName: String,
        destination: URL
    ) async throws {
        let normalizedBranchName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBranchName.isEmpty else {
            throw ApplePiServiceError.worktreeCreationFailed("Enter a branch name.")
        }

        let source = sourceDirectory.standardizedFileURL
        let target = destination.standardizedFileURL
        guard source.path != target.path else {
            throw ApplePiServiceError.worktreeCreationFailed(
                "Choose a destination outside the source project."
            )
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw ApplePiServiceError.worktreeCreationFailed(
                "The destination already exists. Choose a new folder."
            )
        }

        let repositoryCheck = try await ProcessCapture.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-C", source.path, "rev-parse", "--show-toplevel"],
            timeout: 10,
            maximumOutputBytes: 16 * 1_024
        )
        guard repositoryCheck.status == 0 else {
            throw ApplePiServiceError.worktreeCreationFailed(
                "The project source folder is not inside a Git repository."
            )
        }

        let branchCheck = try await ProcessCapture.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["check-ref-format", "--branch", normalizedBranchName],
            timeout: 10,
            maximumOutputBytes: 16 * 1_024
        )
        guard branchCheck.status == 0 else {
            throw ApplePiServiceError.worktreeCreationFailed("Enter a valid Git branch name.")
        }

        let result = try await ProcessCapture.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: [
                "-C", source.path,
                "worktree", "add",
                "-b", normalizedBranchName,
                target.path,
            ],
            timeout: 120,
            maximumOutputBytes: 64 * 1_024
        )
        guard result.status == 0 else {
            let diagnostic = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ApplePiServiceError.worktreeCreationFailed(
                diagnostic.isEmpty ? "Git exited with status \(result.status)." : diagnostic
            )
        }
    }
}

enum ApplePiAssistantDeltaPresentation {
    static func transcriptKind(for eventType: String?) -> ApplePiTranscriptKind? {
        guard let eventType else { return .answer }
        let normalized = eventType.lowercased()

        // Pi streams tool arguments through message_update before emitting the
        // dedicated tool execution event. The tool row owns that payload, so
        // rendering this delta as answer text would duplicate raw JSON.
        if normalized.contains("toolcall") || normalized.contains("tool_call") {
            return nil
        }
        if normalized.contains("thinking") || normalized.contains("reasoning") {
            return .thinking
        }
        return .answer
    }
}

/// Connects the native surface to Pi without introducing a second agent or
/// transcript database. Pi's JSONL files and RPC process remain authoritative.
@MainActor
final class ApplePiServiceAdapter: ApplePiUIActions {
    private static let maximumRetainedRuntimeBytesPerTask = 8 * 1_024 * 1_024
    private static let maximumRetainedRuntimeBytesGlobally = 32 * 1_024 * 1_024

    private struct ResourceBridgeRecord {
        let source: String
        let scope: ApplePiPackageScope
        let kind: String
        let origin: String
        let pattern: String
        let path: String
        let isToggleable: Bool
        let workingDirectory: URL
    }

    private struct PackageInventoryRecord {
        let source: String
        let scope: ApplePiPackageScope
        let isFiltered: Bool
        let installedPath: String?
        let installedVersion: String?
        let hasUpdate: Bool
    }

    private struct ExtensionPromptRecord {
        let taskID: PiTaskID
        let request: PiExtensionUIRequest
    }

    private struct StreamState {
        var answerID: String?
        var thinkingID: String?
        var toolIDs: [String: String] = [:]
        var serial = 0
    }

    private struct BridgeWaiter {
        let envelope: BridgeEnvelopeV1
        let continuation: CheckedContinuation<BridgeResponseV1, any Error>
        let timeout: Task<Void, Never>
    }

    weak var model: AppModel?

    private let paths = AppPaths()
    private let presentationStore: PresentationStateStore
    private let projectStore: ProjectStore
    private let managedWorktreeService: ManagedWorktreeService
    private let transcriptLoader = SessionTranscriptLoader()
    private var sessionIndex: SessionIndexStore?
    private var runtimeResolution: PiRuntimeResolution?
    private var coordinator: PiTaskRuntimeCoordinator?
    private var coordinatorListener: Task<Void, Never>?
    private var indexListener: Task<Void, Never>?

    private var indexedSessions: [SessionIndexEntry] = []
    private var drafts: [String: ApplePiUISession] = [:]
    private var canonicalToUIID: [String: String] = [:]
    private var canonicalByUIID: [String: String] = [:]
    private var appCreatedCanonicalIDs = Set<String>()
    private var taskByUIID: [String: PiTaskID] = [:]
    private var uiIDByTask: [PiTaskID: String] = [:]
    private var runtimeSnapshots: [PiTaskID: PiTaskSnapshot] = [:]

    private var resourceRecords: [String: ResourceBridgeRecord] = [:]
    private var extensionLoadErrors: [String: String] = [:]
    private var extensionPrompts: [String: ExtensionPromptRecord] = [:]
    private var streamStates: [PiTaskID: StreamState] = [:]
    private var liveItemsByTask: [PiTaskID: [String: ApplePiTranscriptItem]] = [:]
    private var liveItemOrderByTask: [PiTaskID: [String]] = [:]
    private var liveBytesByTask: [PiTaskID: Int] = [:]
    private var totalLiveBytes = 0
    private var pendingDeltasByTask: [PiTaskID: [String: String]] = [:]
    private var pendingDeltaBytesByTask: [PiTaskID: Int] = [:]
    private var totalPendingDeltaBytes = 0
    private var deltaFlushTasks: [PiTaskID: Task<Void, Never>] = [:]
    private var tasksNeedingTranscriptResync = Set<PiTaskID>()
    private var bridgeWaiters: [String: BridgeWaiter] = [:]
    private var localPackageWatcher: RecursiveFileSystemWatcher?
    private var localPackageWatcherPaths = Set<String>()
    private var localPackageReloadTask: Task<Void, Never>?
    private var localPackageReloadPending = false
    private var isReloadingLocalPackages = false

    init(
        presentationStore: PresentationStateStore = PresentationStateStore(),
        projectStore: ProjectStore = ProjectStore(),
        managedWorktreeService: ManagedWorktreeService = ManagedWorktreeService()
    ) {
        self.presentationStore = presentationStore
        self.projectStore = projectStore
        self.managedWorktreeService = managedWorktreeService
    }

    deinit {
        coordinatorListener?.cancel()
        indexListener?.cancel()
        for task in deltaFlushTasks.values { task.cancel() }
        localPackageReloadTask?.cancel()
        localPackageWatcher?.stop()
        for waiter in bridgeWaiters.values {
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    func attach(to model: AppModel) {
        self.model = model
        model.actions = self
    }

    func perform(_ action: ApplePiAction) async throws -> ApplePiActionResult {
        switch action {
        case .initialSnapshot:
            try await bootstrapIfNeeded()
            return .snapshot(await snapshot(refreshIndex: true, refreshPackages: false))

        case .refresh:
            try await bootstrapIfNeeded(forceRuntimeResolution: true)
            if let coordinator {
                await coordinator.setMaximumConcurrentTurns(model?.maximumConcurrentTurns ?? 2)
            }
            return .snapshot(await snapshot(refreshIndex: true, refreshPackages: true))

        case let .createTask(projectID):
            try await bootstrapIfNeeded()
            let project: ApplePiProject?
            if let projectID {
                guard let savedProject = await projectStore.project(id: projectID) else {
                    throw ApplePiServiceError.projectNotFound
                }
                project = savedProject
            } else {
                project = nil
            }
            let draftID = "draft-\(UUID().uuidString)"
            let localDirectory = project?.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            let managedDirectory: URL? = if let project {
                try await managedWorktreeService.createIfSupported(
                    from: project.workingDirectory,
                    taskID: draftID
                )
            } else {
                nil
            }
            let directory = managedDirectory ?? localDirectory
            let draft = ApplePiUISession(
                id: draftID,
                title: "New task",
                workingDirectory: directory.standardizedFileURL,
                sessionURL: nil,
                modifiedAt: .now,
                state: .stopped,
                isPinned: false,
                isArchived: false,
                wasCreatedByCLI: false,
                hasUserExtensions: false,
                projectID: project?.id,
                environment: managedDirectory == nil ? .local : .managedWorktree
            )
            drafts[draft.id] = draft
            return .session(draft)

        case let .createProject(name, workingDirectory):
            try await bootstrapIfNeeded()
            return .project(try await projectStore.create(
                name: name,
                workingDirectory: workingDirectory
            ))

        case let .mutateProject(id, mutation):
            try await bootstrapIfNeeded()
            switch mutation {
            case let .rename(name):
                _ = try await projectStore.update(id: id, name: name)
            case let .update(name, workingDirectory):
                _ = try await projectStore.update(
                    id: id,
                    name: name,
                    workingDirectory: workingDirectory
                )
            case let .pin(pinned):
                _ = try await projectStore.update(id: id, isPinned: pinned)
            case .remove:
                _ = try await projectStore.delete(id: id)
                let associatedDraftIDs = drafts.compactMap { key, draft in
                    draft.projectID == id ? key : nil
                }
                for draftID in associatedDraftIDs {
                    drafts[draftID]?.projectID = nil
                }
                try? await presentationStore.removeProjectAssignments(for: id)
                await sessionIndex?.presentationDidChange()
            }
            return .snapshot(await snapshot(refreshIndex: true, refreshPackages: false))

        case let .createPermanentWorktree(projectID, branchName, destination):
            try await bootstrapIfNeeded()
            guard let project = await projectStore.project(id: projectID) else {
                throw ApplePiServiceError.projectNotFound
            }
            try await GitWorktreeService.create(
                from: project.workingDirectory,
                branchName: branchName,
                destination: destination
            )
            return .none

        case let .loadTranscript(sessionID):
            return .transcript(try await loadTranscript(sessionID: sessionID))

        case let .submit(submission, sessionID):
            try await submit(submission, sessionID: sessionID)
            return .snapshot(await snapshot(refreshIndex: false, refreshPackages: false))

        case let .abort(sessionID):
            guard let taskID = taskByUIID[sessionID], let coordinator else { return .none }
            try await coordinator.abort(taskID)
            return .none

        case let .stopRuntime(sessionID):
            guard let taskID = taskByUIID[sessionID], let coordinator else { return .none }
            await coordinator.stop(taskID)
            return .snapshot(await snapshot(refreshIndex: false, refreshPackages: false))

        case let .mutateSession(sessionID, mutation):
            try await mutateSession(sessionID, mutation: mutation)
            return .snapshot(await snapshot(refreshIndex: true, refreshPackages: false))

        case let .archiveSessions(sessionIDs, archived):
            try await archiveSessions(sessionIDs, archived: archived)
            return .snapshot(await snapshot(refreshIndex: false, refreshPackages: false))

        case let .installPackage(source, scope, projectURL):
            let cwd = try packageWorkingDirectory(scope: scope, projectURL: projectURL)
            try await runPackageOperation(.install(source: source, scope: runtimeScope(scope)), cwd: cwd)
            return .packages(try await refreshPackageResources(cwd: cwd))

        case let .updatePackage(id):
            guard let record = resourceRecords[id] else { throw ApplePiServiceError.packageNotFound }
            let cwd = try packageWorkingDirectory(
                scope: record.scope,
                projectURL: record.scope == .project ? record.workingDirectory : nil
            )
            try await runPackageOperation(.update(source: record.source), cwd: cwd)
            return .packages(try await refreshPackageResources(cwd: cwd))

        case let .removePackage(id):
            guard let record = resourceRecords[id] else { throw ApplePiServiceError.packageNotFound }
            let cwd = try packageWorkingDirectory(
                scope: record.scope,
                projectURL: record.scope == .project ? record.workingDirectory : nil
            )
            try await runPackageOperation(
                .remove(source: record.source, scope: runtimeScope(record.scope)),
                cwd: cwd
            )
            return .packages(try await refreshPackageResources(cwd: cwd))

        case let .setResourceEnabled(id, enabled):
            try await setResourceEnabled(id: id, enabled: enabled)
            let cwd = model?.selectedProjectURL ?? FileManager.default.homeDirectoryForCurrentUser
            return .packages(try await refreshPackageResources(cwd: cwd))

        case let .installLocalPackage(url, scope, projectURL):
            let cwd = try packageWorkingDirectory(scope: scope, projectURL: projectURL)
            try await runPackageOperation(.install(source: url.path, scope: runtimeScope(scope)), cwd: cwd)
            return .packages(try await refreshPackageResources(cwd: cwd))

        case let .reloadLocalPackage(id):
            guard resourceRecords[id] != nil else { throw ApplePiServiceError.packageNotFound }
            try await reloadActiveRuntimes()
            return .none

        case let .extensionPromptResponse(id, value, accepted):
            try await respondToExtensionPrompt(id: id, value: value, accepted: accepted)
            return .none

        case let .terminalRequest(purpose, sessionID):
            return .terminal(try await terminalRequest(purpose: purpose, sessionID: sessionID))

        case let .navigateBranch(sessionID, branchID):
            guard let taskID = taskByUIID[sessionID] else { throw ApplePiServiceError.taskNotRunning }
            _ = try await invokeBridge(
                taskID: taskID,
                action: .navigateTree,
                payload: .object(["targetID": .string(branchID), "summarize": .bool(false)])
            )
            try await refreshRuntimeInspector(taskID: taskID)
            return .transcript(try await loadTranscript(sessionID: sessionID))

        case let .refreshRuntimeOptions(sessionID):
            return .runtimeOptions(try await runtimeOptions(sessionID: sessionID))

        case let .setModel(sessionID, provider, modelID):
            let taskID = try await ensureTask(sessionID: sessionID)
            guard let client = await coordinator?.client(for: taskID) else {
                throw ApplePiServiceError.taskNotRunning
            }
            _ = try await client.send(.setModel(provider: provider, modelID: modelID), timeout: 30)
            if let state = try? await client.send(.getState, timeout: 10),
               let data = state.data?.objectValue {
                applyState(data)
            }
            return .runtimeOptions(try await runtimeOptions(taskID: taskID))

        case let .setThinkingLevel(sessionID, level):
            let taskID = try await ensureTask(sessionID: sessionID)
            guard let client = await coordinator?.client(for: taskID) else {
                throw ApplePiServiceError.taskNotRunning
            }
            _ = try await client.send(.setThinkingLevel(level), timeout: 30)
            model?.inspector.thinkingLevel = level
            return .runtimeOptions(try await runtimeOptions(taskID: taskID))
        }
    }

    func shutdown() async {
        for task in deltaFlushTasks.values { task.cancel() }
        deltaFlushTasks.removeAll()
        pendingDeltasByTask.removeAll()
        pendingDeltaBytesByTask.removeAll()
        totalPendingDeltaBytes = 0
        liveItemsByTask.removeAll()
        liveItemOrderByTask.removeAll()
        liveBytesByTask.removeAll()
        totalLiveBytes = 0
        tasksNeedingTranscriptResync.removeAll()
        localPackageReloadTask?.cancel()
        localPackageReloadTask = nil
        localPackageReloadPending = false
        await coordinator?.stopAll()
        await sessionIndex?.stopWatching()
        localPackageWatcher?.stop()
        localPackageWatcher = nil
        localPackageWatcherPaths.removeAll()
    }

    // MARK: - Bootstrap and snapshots

    private func bootstrapIfNeeded(forceRuntimeResolution: Bool = false) async throws {
        try paths.prepare()
        if runtimeResolution == nil || forceRuntimeResolution {
            let saved = model?.savedExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolver = PiRuntimeResolver(configuration: .init(
                savedExecutable: saved.isEmpty ? nil : URL(filePath: saved),
                allowAdvancedOverride: model?.advancedRuntimeOverride ?? false,
                bundledExecutable: PiRuntimeResolver.defaultBundledExecutable()
            ))
            runtimeResolution = await resolver.resolve()
        }

        if sessionIndex == nil {
            let environment = runtimeResolution?.environment ?? ProcessInfo.processInfo.environment
            let index = SessionIndexStore(
                rootURL: SessionIndexStore.defaultSessionRoot(environment: environment),
                cacheURL: paths.sessionIndexCache,
                presentationStore: presentationStore
            )
            sessionIndex = index
            try? await index.startWatching()
            indexListener = Task { [weak self, index] in
                for await update in index.updates {
                    guard let self else { return }
                    self.consumeIndex(update)
                }
            }
        }

        if coordinator == nil {
            let coordinator = PiTaskRuntimeCoordinator(
                maximumConcurrentTurns: model?.maximumConcurrentTurns ?? 2,
                idleGracePeriod: TimeInterval(model?.idleRuntimeGraceSeconds ?? 30)
            )
            self.coordinator = coordinator
            coordinatorListener = Task { [weak self, coordinator] in
                for await event in coordinator.events {
                    guard let self else { return }
                    await self.consumeCoordinator(event)
                }
            }
        }
    }

    private func snapshot(refreshIndex: Bool, refreshPackages: Bool) async -> ApplePiUISnapshot {
        if refreshIndex, let sessionIndex {
            let update = await sessionIndex.refresh()
            indexedSessions = update.entries
        }

        if let coordinator {
            runtimeSnapshots = Dictionary(uniqueKeysWithValues: await coordinator.snapshots().map { ($0.id, $0) })
        }

        var packages = model?.packages ?? []
        if refreshPackages, runtimeResolution?.selected?.supportsNativeTasks == true {
            let cwd = model?.selectedProjectURL ?? FileManager.default.homeDirectoryForCurrentUser
            packages = (try? await refreshPackageResources(cwd: cwd)) ?? packages
        }

        let projects = await projectStore.allProjects()
        return ApplePiUISnapshot(
            projects: projects,
            sessions: makeUISessions(projects: projects),
            packages: packages,
            runtime: runtimeSummary,
            inspector: model?.inspector ?? .empty,
            commands: model?.availableCommands ?? []
        )
    }

    private var runtimeSummary: ApplePiRuntimeSummary {
        guard let selected = runtimeResolution?.selected else {
            return ApplePiRuntimeSummary(
                displayName: "Pi",
                executableURL: nil,
                version: nil,
                source: "Not found",
                compatibility: .unavailable,
                detail: "Install Pi or choose its executable in Settings. Release builds also include the verified fallback."
            )
        }
        let source: String = switch selected.source {
        case .savedExecutable: "Selected executable"
        case .loginShellPath: "Login shell PATH"
        case .commonLocation: "Common install location"
        case .bundledFallback: "Bundled fallback"
        }
        let compatibility: ApplePiRuntimeSummary.Compatibility = selected.supportsNativeTasks
            ? .compatible
            : (selected.compatibility == .incompatible ? .unavailable : .terminalOnly)
        let detail = selected.supportsNativeTasks
            ? "Pi \(selected.version) is ready for native RPC tasks."
            : (selected.diagnostic ?? "Use this Pi version in the embedded terminal.")
        return ApplePiRuntimeSummary(
            displayName: "Pi",
            executableURL: selected.executable,
            version: selected.version.description,
            source: source,
            compatibility: compatibility,
            detail: detail
        )
    }

    private func makeUISessions(projects: [ApplePiProject]? = nil) -> [ApplePiUISession] {
        let availableProjects = projects ?? model?.projects ?? []
        let projectMatcher = ProjectDirectoryMatcher.Prepared(projects: availableProjects)
        var result: [ApplePiUISession] = indexedSessions.map { entry in
            let uiID = canonicalToUIID[entry.sessionID] ?? entry.sessionID
            canonicalToUIID[entry.sessionID] = uiID
            canonicalByUIID[uiID] = entry.sessionID
            let runtime = taskByUIID[uiID].flatMap { runtimeSnapshots[$0] }
            return ApplePiUISession(
                id: uiID,
                title: sessionTitle(entry),
                workingDirectory: entry.workingDirectory,
                sessionURL: entry.path,
                modifiedAt: entry.modifiedAt,
                state: uiState(runtime?.state),
                isPinned: entry.presentation.isPinned,
                isArchived: entry.presentation.isArchived,
                wasCreatedByCLI: !appCreatedCanonicalIDs.contains(entry.sessionID),
                hasUserExtensions: runtime?.hasUserExtensions ?? hasEnabledExtension(for: entry.workingDirectory),
                projectID: resolvedProjectID(for: entry, projectMatcher: projectMatcher),
                environment: ManagedWorktreeService.isManagedDirectory(
                    entry.workingDirectory,
                    root: paths.managedWorktrees
                ) ? .managedWorktree : .local
            )
        }

        let indexedPaths = Set(indexedSessions.map { $0.path.standardizedFileURL.path })
        for (id, var draft) in drafts {
            if let path = draft.sessionURL?.standardizedFileURL.path, indexedPaths.contains(path) { continue }
            if let taskID = taskByUIID[id], let runtime = runtimeSnapshots[taskID] {
                draft.state = uiState(runtime.state)
                draft.hasUserExtensions = runtime.hasUserExtensions
            }
            result.append(draft)
        }

        return result.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    private func resolvedProjectID(
        for entry: SessionIndexEntry,
        projectMatcher: ProjectDirectoryMatcher.Prepared
    ) -> ApplePiProjectID? {
        if entry.presentation.hasExplicitProjectAssignment == true {
            return entry.presentation.projectID
        }
        if let projectID = entry.presentation.projectID {
            return projectID
        }
        return projectMatcher.bestMatch(for: entry.workingDirectory)?.id
    }

    private func sessionTitle(_ entry: SessionIndexEntry) -> String {
        if let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let first = entry.firstMessage.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if !first.isEmpty { return String(first.prefix(72)) }
        return "Untitled task"
    }

    private func uiState(_ state: TaskRuntimeState?) -> ApplePiTaskState {
        guard let state else { return .stopped }
        return switch state.phase {
        case .stopped: .stopped
        case .starting: .starting
        case .ready: .ready
        case .generating: .generating
        case .awaitingInput: .awaitingInput
        case .queued: .queued
        case .failed: .failed
        }
    }

    // MARK: - Tasks and events

    private func submit(_ submission: ApplePiComposerSubmission, sessionID: String) async throws {
        let taskID = try await ensureTask(sessionID: sessionID)
        guard let coordinator else { throw ApplePiServiceError.taskNotRunning }
        let trimmed = submission.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("!") {
            guard let client = await coordinator.client(for: taskID) else { throw ApplePiServiceError.taskNotRunning }
            let excluded = trimmed.hasPrefix("!!")
            let command = String(trimmed.dropFirst(excluded ? 2 : 1)).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return }
            _ = try await client.send(.bash(command: command, excludeFromContext: excluded), timeout: 3_600)
            return
        }

        let images = submission.images.map {
            PiImageAttachment(data: $0.data.base64EncodedString(), mimeType: $0.mimeType)
        }
        try await coordinator.submit(
            to: taskID,
            message: submission.text,
            images: images,
            behavior: submission.queueBehavior == .steer ? .steer : .followUp
        )
    }

    private func ensureTask(sessionID: String) async throws -> PiTaskID {
        if let taskID = taskByUIID[sessionID],
           let coordinator,
           let snapshot = await coordinator.snapshot(for: taskID) {
            if snapshot.state.phase != .failed {
                _ = try await coordinator.ensureRunning(taskID)
                return taskID
            }
            await coordinator.close(taskID)
            taskByUIID.removeValue(forKey: sessionID)
            uiIDByTask.removeValue(forKey: taskID)
        }
        guard let selected = runtimeResolution?.selected else { throw ApplePiServiceError.runtimeUnavailable }
        guard selected.supportsNativeTasks else {
            throw ApplePiServiceError.nativeRuntimeUnavailable(selected.diagnostic ?? "")
        }
        guard let coordinator else { throw ApplePiServiceError.taskNotRunning }

        let indexed = indexedEntry(uiID: sessionID)
        let draft = drafts[sessionID]
        guard let workingDirectory = indexed?.workingDirectory ?? draft?.workingDirectory else {
            throw ApplePiServiceError.sessionNotFound
        }
        let projectTrusted = try await resolveProjectTrust(cwd: workingDirectory)
        let taskID = PiTaskID()
        let configuration = PiTaskLaunchConfiguration(
            id: taskID,
            workingDirectory: workingDirectory,
            sessionPath: indexed?.path ?? draft?.sessionURL,
            projectTrusted: projectTrusted,
            hasUserExtensions: hasEnabledExtension(for: workingDirectory),
            runtime: selected,
            environment: runtimeResolution?.environment ?? ProcessInfo.processInfo.environment,
            bridgeURL: bridgeURL
        )
        taskByUIID[sessionID] = taskID
        uiIDByTask[taskID] = sessionID
        _ = try await coordinator.open(configuration)

        if let client = await coordinator.client(for: taskID) {
            let state = try? await client.send(.getState, timeout: 10)
            if let data = state?.data?.objectValue {
                if let sessionPath = canonicalSessionPath(from: data) {
                    await coordinator.setResumeSessionPath(sessionPath, for: taskID)
                }
                await adoptCanonicalSession(from: data, draftUIID: sessionID)
                applyState(data)
            }
            try? await refreshRuntimeInspector(taskID: taskID)
            if let resources = try? await invokeBridge(taskID: taskID, action: .resourceSnapshot),
               let mapped = mapPackageResources(resources.result, cwd: workingDirectory) {
                model?.packages = mapped
                await coordinator.setPreservesRuntime(mapped.contains {
                    $0.kind == .extensionResource && $0.isEnabled && $0.isToggleable
                }, for: taskID)
            }
        }
        return taskID
    }

    private func adoptCanonicalSession(from state: [String: JSONValue], draftUIID: String) async {
        guard drafts[draftUIID] != nil,
              let canonicalID = state["sessionId"]?.stringValue else { return }
        canonicalToUIID[canonicalID] = draftUIID
        canonicalByUIID[draftUIID] = canonicalID
        appCreatedCanonicalIDs.insert(canonicalID)
        if let path = state["sessionFile"]?.stringValue, !path.isEmpty {
            let sessionURL = URL(filePath: path).standardizedFileURL
            drafts[draftUIID]?.sessionURL = sessionURL
            if let draft = drafts[draftUIID] {
                try? await presentationStore.setProjectID(draft.projectID, for: sessionURL)
            }
        }
    }

    private func canonicalSessionPath(from state: [String: JSONValue]) -> URL? {
        guard let path = state["sessionFile"]?.stringValue, !path.isEmpty else { return nil }
        return URL(filePath: path).standardizedFileURL
    }

    private func adoptClonedSession(
        canonicalID: String,
        sessionPath: URL,
        originalUIID: String,
        taskID: PiTaskID
    ) async {
        let inheritedProjectID = model?.sessions.first(where: { $0.id == originalUIID })?.projectID
            ?? drafts[originalUIID]?.projectID
        let clonedUIID = canonicalToUIID[canonicalID] ?? canonicalID
        canonicalToUIID[canonicalID] = clonedUIID
        canonicalByUIID[clonedUIID] = canonicalID
        appCreatedCanonicalIDs.insert(canonicalID)

        taskByUIID.removeValue(forKey: originalUIID)
        taskByUIID[clonedUIID] = taskID
        uiIDByTask[taskID] = clonedUIID
        await coordinator?.setResumeSessionPath(sessionPath, for: taskID)

        try? await presentationStore.setProjectID(inheritedProjectID, for: sessionPath)

        if let sessionIndex { indexedSessions = await sessionIndex.refresh().entries }
        model?.replaceSessionsIfChanged(makeUISessions())
        model?.selection = .session(clonedUIID)
        let transcript = (try? await loadTranscript(sessionID: clonedUIID)) ?? []
        if model?.selection == .session(clonedUIID) {
            model?.replaceTranscript(transcript)
        }
    }

    private func consumeCoordinator(_ event: PiTaskCoordinatorEvent) async {
        switch event {
        case .streamGap:
            for taskID in uiIDByTask.keys {
                discardRetainedRuntimeDataAndMarkForResync(taskID)
            }
            if let coordinator {
                for snapshot in await coordinator.snapshots() {
                    runtimeSnapshots[snapshot.id] = snapshot
                }
            }

        case let .changed(snapshot):
            runtimeSnapshots[snapshot.id] = snapshot
            guard let uiID = uiIDByTask[snapshot.id], let model,
                  let index = model.sessions.firstIndex(where: { $0.id == uiID }) else { return }
            model.sessions[index].state = uiState(snapshot.state)
            model.sessions[index].hasUserExtensions = snapshot.hasUserExtensions
            if model.selection == .session(uiID) {
                model.inspector.queuedMessages = snapshot.pendingTurnCount
            }

        case let .removed(taskID):
            runtimeSnapshots.removeValue(forKey: taskID)
            if let uiID = uiIDByTask.removeValue(forKey: taskID) {
                taskByUIID.removeValue(forKey: uiID)
            }
            clearRetainedRuntimeData(for: taskID)
            streamStates.removeValue(forKey: taskID)
            tasksNeedingTranscriptResync.remove(taskID)

        case let .rpc(taskID, rpcEvent):
            await consumeRPC(rpcEvent, taskID: taskID)
        }
    }

    private func consumeRPC(_ event: PiRPCEvent, taskID: PiTaskID) async {
        guard let uiID = uiIDByTask[taskID] else { return }
        switch event {
        case .streamGap:
            discardRetainedRuntimeDataAndMarkForResync(taskID)

        case .messageStarted:
            var stream = streamStates[taskID] ?? StreamState()
            stream.serial += 1
            stream.answerID = "stream-\(taskID.rawValue.uuidString)-\(stream.serial)-answer"
            stream.thinkingID = nil
            streamStates[taskID] = stream

        case let .messageUpdated(kind, delta, raw):
            handleMessageDelta(kind: kind, delta: delta, raw: raw, taskID: taskID)

        case .messageEnded:
            completeStream(taskID: taskID)
            await refreshSessionIndex(for: uiID)
            await resynchronizeTranscriptIfNeeded(taskID: taskID, uiID: uiID)
            clearRetainedRuntimeData(for: taskID)

        case let .toolStarted(id, name, raw):
            upsertTool(taskID: taskID, toolCallID: id, name: name, raw: raw, ended: false, isError: false)

        case let .toolUpdated(id, name, raw):
            upsertTool(taskID: taskID, toolCallID: id, name: name, raw: raw, ended: false, isError: false)

        case let .toolEnded(id, name, isError, raw):
            upsertTool(taskID: taskID, toolCallID: id, name: name, raw: raw, ended: true, isError: isError)

        case let .bashUpdated(id, delta, _):
            let itemID = "bash-\(taskID.rawValue.uuidString)-\(id ?? "default")"
            ensureTranscriptItem(id: itemID, kind: .tool, title: "Shell", taskID: taskID)
            enqueueDelta(taskID: taskID, itemID: itemID, delta: delta)

        case let .extensionUI(request):
            handleExtensionUI(request, taskID: taskID)

        case let .extensionError(path, eventName, message, _):
            let displayPath = path ?? "Unknown extension"
            if let path {
                extensionLoadErrors[URL(filePath: path).standardizedFileURL.path] = message
            }
            if isTaskSelected(taskID) {
                upsertInspectorExtensionError(path: displayPath, message: message)
            }
            appendStatus(
                eventName.map { "\(message) (\($0))" } ?? message,
                title: "Extension error",
                taskID: taskID,
                streaming: false,
                isError: true
            )

        case let .bridge(response):
            resolveBridge(response)

        case let .queueUpdated(steering, followUp, _):
            if model?.selection == .session(uiID) {
                model?.inspector.queuedMessages = steering.count + followUp.count
            }

        case .compactionStarted:
            appendStatus("Compacting context…", title: "Compaction", taskID: taskID, streaming: true)

        case let .compactionEnded(aborted, error, _):
            appendStatus(
                error ?? (aborted ? "Compaction was cancelled." : "Context compaction completed."),
                title: "Compaction",
                taskID: taskID,
                streaming: false,
                isError: error != nil
            )

        case let .thinkingLevelChanged(level, _):
            if isTaskSelected(taskID), let level { model?.inspector.thinkingLevel = level }

        case let .sessionInfoChanged(name, _):
            if let name, let index = model?.sessions.firstIndex(where: { $0.id == uiID }) {
                model?.sessions[index].title = name
            }

        case .entryAppended:
            await refreshSessionIndex(for: uiID)

        case let .processTerminated(status, stderr):
            if status != 0 {
                appendStatus(
                    stderr.isEmpty ? "Pi exited with status \(status)." : stderr,
                    title: "Pi runtime stopped",
                    taskID: taskID,
                    streaming: false,
                    isError: true
                )
                notifyIfBackground(
                    title: "Pi runtime error",
                    body: stderr.isEmpty ? "Task stopped with status \(status)." : String(stderr.prefix(220))
                )
            }

        case .agentSettled:
            notifyIfBackground(title: "Pi finished", body: sessionName(uiID: uiID))
            await resynchronizeTranscriptIfNeeded(taskID: taskID, uiID: uiID)
            if isTaskSelected(taskID) {
                try? await refreshRuntimeInspector(taskID: taskID, expectedSessionID: uiID)
            }
            clearRetainedRuntimeData(for: taskID)

        case .malformedLine(let message):
            appendStatus(message, title: "Pi protocol warning", taskID: taskID, streaming: false, isError: true)

        default:
            break
        }
    }

    private func isTaskSelected(_ taskID: PiTaskID) -> Bool {
        guard let uiID = uiIDByTask[taskID] else { return false }
        return model?.selection == .session(uiID)
    }

    private func refreshSessionIndex(for uiID: String) async {
        guard let sessionIndex else { return }
        let update: SessionIndexSnapshot
        if let sessionURL = indexedEntry(uiID: uiID)?.path ?? drafts[uiID]?.sessionURL {
            update = await sessionIndex.refresh(paths: [sessionURL])
        } else {
            update = await sessionIndex.refresh()
        }
        indexedSessions = update.entries
    }

    private func resynchronizeTranscriptIfNeeded(taskID: PiTaskID, uiID: String) async {
        guard tasksNeedingTranscriptResync.contains(taskID), isTaskSelected(taskID) else { return }
        do {
            // At a message boundary the JSONL projection is authoritative. Do
            // not merge the lossy live accumulator back into it: that
            // accumulator may contain only the suffix retained after a gap.
            let items = try await loadTranscript(sessionID: uiID, includeLiveRuntime: false)
            guard isTaskSelected(taskID) else { return }
            model?.replaceTranscript(items)
            tasksNeedingTranscriptResync.remove(taskID)
        } catch is CancellationError {
            return
        } catch {
            // The canonical entry can lag the completion event by one append.
            // Keep the marker so selection or the next completion retries it.
        }
    }

    private func handleMessageDelta(kind: String?, delta: String?, raw: JSONValue, taskID: PiTaskID) {
        guard
            let delta,
            !delta.isEmpty,
            let transcriptKind = ApplePiAssistantDeltaPresentation.transcriptKind(for: kind)
        else { return }
        var stream = streamStates[taskID] ?? StreamState()
        stream.serial += stream.answerID == nil ? 1 : 0
        let itemID: String
        if transcriptKind == .thinking {
            if stream.thinkingID == nil {
                stream.thinkingID = "stream-\(taskID.rawValue.uuidString)-\(stream.serial)-thinking"
            }
            itemID = stream.thinkingID!
            ensureTranscriptItem(id: itemID, kind: .thinking, title: "Thinking", taskID: taskID)
        } else {
            if stream.answerID == nil {
                stream.answerID = "stream-\(taskID.rawValue.uuidString)-\(stream.serial)-answer"
            }
            itemID = stream.answerID!
            ensureTranscriptItem(id: itemID, kind: .answer, title: nil, taskID: taskID)
        }
        streamStates[taskID] = stream
        enqueueDelta(taskID: taskID, itemID: itemID, delta: delta)
        _ = raw
    }

    private func ensureTranscriptItem(
        id: String,
        kind: ApplePiTranscriptKind,
        title: String?,
        taskID: PiTaskID
    ) {
        if liveItemsByTask[taskID]?[id] == nil {
            _ = storeLiveItem(ApplePiTranscriptItem(
                id: id,
                role: .assistant,
                kind: kind,
                title: title,
                content: "",
                timestamp: .now,
                isStreaming: true,
                attachments: []
            ), for: taskID)
        }
        guard isTaskSelected(taskID), let model, !model.containsTranscriptItem(id: id) else { return }
        model.upsertTranscriptItem(ApplePiTranscriptItem(
            id: id,
            role: .assistant,
            kind: kind,
            title: title,
            content: "",
            timestamp: .now,
            isStreaming: true,
            attachments: []
        ))
    }

    private func enqueueDelta(taskID: PiTaskID, itemID: String, delta: String) {
        let byteCount = delta.utf8.count
        guard reserveRetainedBytes(
            for: taskID,
            additionalLiveBytes: byteCount,
            additionalPendingBytes: byteCount
        ) else {
            discardRetainedRuntimeDataAndMarkForResync(taskID)
            return
        }
        guard var item = liveItemsByTask[taskID]?[itemID] else {
            releaseRetainedBytes(
                for: taskID,
                liveBytes: byteCount,
                pendingBytes: byteCount
            )
            tasksNeedingTranscriptResync.insert(taskID)
            return
        }
        item.content.append(delta)
        liveItemsByTask[taskID]?[itemID] = item
        pendingDeltasByTask[taskID, default: [:]][itemID, default: ""].append(delta)
        guard deltaFlushTasks[taskID] == nil else { return }
        deltaFlushTasks[taskID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.flushDeltas(for: taskID)
        }
    }

    private func flushDeltas(for taskID: PiTaskID) {
        deltaFlushTasks.removeValue(forKey: taskID)?.cancel()
        let deltas = pendingDeltasByTask.removeValue(forKey: taskID) ?? [:]
        let releasedBytes = pendingDeltaBytesByTask.removeValue(forKey: taskID) ?? 0
        totalPendingDeltaBytes = max(0, totalPendingDeltaBytes - releasedBytes)
        guard isTaskSelected(taskID) else { return }
        model?.appendTranscriptDeltas(deltas)
    }

    private func completeStream(taskID: PiTaskID) {
        flushDeltas(for: taskID)
        guard let stream = streamStates[taskID] else { return }
        var itemIDs = [stream.answerID, stream.thinkingID].compactMap { $0 }
        itemIDs.append(contentsOf: stream.toolIDs.values)
        for itemID in itemIDs {
            guard var item = liveItemsByTask[taskID]?[itemID] else { continue }
            item.isStreaming = false
            liveItemsByTask[taskID]?[itemID] = item
        }
        if isTaskSelected(taskID) {
            model?.completeTranscriptItems(itemIDs: itemIDs)
        }
    }

    private func upsertTool(
        taskID: PiTaskID,
        toolCallID: String?,
        name: String?,
        raw: JSONValue,
        ended: Bool,
        isError: Bool
    ) {
        var stream = streamStates[taskID] ?? StreamState()
        let key = toolCallID ?? UUID().uuidString
        let itemID = stream.toolIDs[key] ?? "tool-\(taskID.rawValue.uuidString)-\(key)"
        stream.toolIDs[key] = itemID
        streamStates[taskID] = stream
        let object = raw.objectValue ?? [:]
        let details = object["result"] ?? object["args"] ?? object["arguments"] ?? raw
        let content = prettyJSON(details, maximumCharacters: 65_536)
        let item = ApplePiTranscriptItem(
            id: itemID,
            role: .assistant,
            kind: isError ? .error : .tool,
            title: name ?? "Extension tool",
            content: content,
            timestamp: .now,
            isStreaming: !ended,
            attachments: []
        )
        guard storeLiveItem(item, for: taskID), isTaskSelected(taskID) else { return }
        model?.upsertTranscriptItem(item)
    }

    private func appendStatus(
        _ content: String,
        title: String,
        taskID: PiTaskID,
        streaming: Bool,
        isError: Bool = false
    ) {
        let item = ApplePiTranscriptItem(
            id: "status-\(UUID().uuidString)",
            role: .system,
            kind: isError ? .error : .status,
            title: title,
            content: String(content.prefix(65_536)),
            timestamp: .now,
            isStreaming: streaming,
            attachments: []
        )
        guard storeLiveItem(item, for: taskID), isTaskSelected(taskID) else { return }
        model?.upsertTranscriptItem(item)
    }

    @discardableResult
    private func storeLiveItem(_ item: ApplePiTranscriptItem, for taskID: PiTaskID) -> Bool {
        let existing = liveItemsByTask[taskID]?[item.id]
        let oldByteCount = existing.map(estimatedRetainedByteCount) ?? 0
        let newByteCount = estimatedRetainedByteCount(item)
        if newByteCount > oldByteCount {
            guard reserveRetainedBytes(
                for: taskID,
                additionalLiveBytes: newByteCount - oldByteCount,
                additionalPendingBytes: 0
            ) else {
                discardRetainedRuntimeDataAndMarkForResync(taskID)
                return false
            }
        } else if oldByteCount > newByteCount {
            releaseRetainedBytes(
                for: taskID,
                liveBytes: oldByteCount - newByteCount,
                pendingBytes: 0
            )
        }
        if existing == nil {
            liveItemOrderByTask[taskID, default: []].append(item.id)
        }
        liveItemsByTask[taskID, default: [:]][item.id] = item
        return true
    }

    private func reserveRetainedBytes(
        for taskID: PiTaskID,
        additionalLiveBytes: Int,
        additionalPendingBytes: Int
    ) -> Bool {
        let live = max(0, additionalLiveBytes)
        let pending = max(0, additionalPendingBytes)
        let additional = live + pending
        let taskTotal = (liveBytesByTask[taskID] ?? 0)
            + (pendingDeltaBytesByTask[taskID] ?? 0)
            + additional
        let globalTotal = totalLiveBytes + totalPendingDeltaBytes + additional
        guard taskTotal <= Self.maximumRetainedRuntimeBytesPerTask,
              globalTotal <= Self.maximumRetainedRuntimeBytesGlobally else { return false }

        if live > 0 {
            liveBytesByTask[taskID, default: 0] += live
            totalLiveBytes += live
        }
        if pending > 0 {
            pendingDeltaBytesByTask[taskID, default: 0] += pending
            totalPendingDeltaBytes += pending
        }
        return true
    }

    private func releaseRetainedBytes(
        for taskID: PiTaskID,
        liveBytes: Int,
        pendingBytes: Int
    ) {
        if liveBytes > 0 {
            let released = min(liveBytesByTask[taskID] ?? 0, liveBytes)
            let remaining = (liveBytesByTask[taskID] ?? 0) - released
            if remaining == 0 { liveBytesByTask.removeValue(forKey: taskID) }
            else { liveBytesByTask[taskID] = remaining }
            totalLiveBytes = max(0, totalLiveBytes - released)
        }
        if pendingBytes > 0 {
            let released = min(pendingDeltaBytesByTask[taskID] ?? 0, pendingBytes)
            let remaining = (pendingDeltaBytesByTask[taskID] ?? 0) - released
            if remaining == 0 { pendingDeltaBytesByTask.removeValue(forKey: taskID) }
            else { pendingDeltaBytesByTask[taskID] = remaining }
            totalPendingDeltaBytes = max(0, totalPendingDeltaBytes - released)
        }
    }

    private func clearRetainedRuntimeData(for taskID: PiTaskID) {
        deltaFlushTasks.removeValue(forKey: taskID)?.cancel()
        pendingDeltasByTask.removeValue(forKey: taskID)
        liveItemsByTask.removeValue(forKey: taskID)
        liveItemOrderByTask.removeValue(forKey: taskID)
        let liveBytes = liveBytesByTask.removeValue(forKey: taskID) ?? 0
        let pendingBytes = pendingDeltaBytesByTask.removeValue(forKey: taskID) ?? 0
        totalLiveBytes = max(0, totalLiveBytes - liveBytes)
        totalPendingDeltaBytes = max(0, totalPendingDeltaBytes - pendingBytes)
    }

    private func discardRetainedRuntimeDataAndMarkForResync(_ taskID: PiTaskID) {
        clearRetainedRuntimeData(for: taskID)
        tasksNeedingTranscriptResync.insert(taskID)
    }

    private func estimatedRetainedByteCount(_ item: ApplePiTranscriptItem) -> Int {
        256 + item.id.utf8.count + (item.title?.utf8.count ?? 0) + item.content.utf8.count
    }

    private func combiningLiveItems(
        with canonicalItems: [ApplePiTranscriptItem],
        taskID: PiTaskID
    ) -> [ApplePiTranscriptItem] {
        guard let liveItems = liveItemsByTask[taskID], !liveItems.isEmpty else {
            return canonicalItems
        }
        var result = canonicalItems
        var indexByID = Dictionary(uniqueKeysWithValues: result.indices.map { (result[$0].id, $0) })
        for itemID in liveItemOrderByTask[taskID] ?? [] {
            guard let item = liveItems[itemID] else { continue }
            if let index = indexByID[itemID] {
                result[index] = item
            } else {
                indexByID[itemID] = result.count
                result.append(item)
            }
        }
        return result
    }

    // MARK: - Extension UI and bridge

    private func handleExtensionUI(_ request: PiExtensionUIRequest, taskID: PiTaskID) {
        switch request.method {
        case .select, .confirm, .input, .editor:
            let kind: ApplePiExtensionPrompt.Kind = switch request.method {
            case .select: .select(options: request.options)
            case .confirm: .confirm
            case .input: .input
            case .editor: .editor
            default: .input
            }
            extensionPrompts[request.id] = ExtensionPromptRecord(taskID: taskID, request: request)
            model?.extensionPrompt = ApplePiExtensionPrompt(
                id: request.id,
                title: request.title ?? "Pi extension",
                message: request.message,
                kind: kind,
                defaultValue: request.prefill ?? "",
                placeholder: request.placeholder
            )
            notifyIfBackground(
                title: request.title ?? "Pi needs input",
                body: request.message ?? "An extension is waiting for your response."
            )

        case .notify:
            appendStatus(
                request.message ?? "Extension notification",
                title: "Extension",
                taskID: taskID,
                streaming: false,
                isError: request.notificationType == "error"
            )

        case .setStatus:
            if isTaskSelected(taskID), let key = request.statusKey {
                if let value = request.statusText { model?.inspector.statusItems[key] = value }
                else { model?.inspector.statusItems.removeValue(forKey: key) }
            }

        case .setWidget:
            if isTaskSelected(taskID), let key = request.widgetKey {
                if let lines = request.widgetLines { model?.inspector.statusItems[key] = lines.joined(separator: "\n") }
                else { model?.inspector.statusItems.removeValue(forKey: key) }
            }

        case .setTitle:
            guard let title = request.title, let uiID = uiIDByTask[taskID],
                  let index = model?.sessions.firstIndex(where: { $0.id == uiID }) else { return }
            model?.sessions[index].title = title

        case .setEditorText:
            if isTaskSelected(taskID) { model?.composerText = request.text ?? "" }

        case .unknown:
            appendStatus(
                "This extension requested an unsupported native interface. Open the task in Pi Terminal to continue.",
                title: "Terminal interface required",
                taskID: taskID,
                streaming: false
            )
        }
    }

    private func respondToExtensionPrompt(id: String, value: String?, accepted: Bool) async throws {
        guard let record = extensionPrompts.removeValue(forKey: id), let coordinator else { return }
        let response: PiExtensionUIResponse
        if !accepted {
            response = .cancelled(id: id)
        } else if record.request.method == .confirm {
            response = .confirmed(id: id, true)
        } else {
            response = .value(id: id, value ?? "")
        }
        try await coordinator.respond(response, to: record.request, task: record.taskID)
    }

    private func invokeBridge(
        taskID: PiTaskID,
        action: BridgeActionV1,
        payload: JSONValue = .object([:])
    ) async throws -> BridgeResponseV1 {
        guard let coordinator, let client = await coordinator.client(for: taskID) else {
            throw ApplePiServiceError.taskNotRunning
        }
        let envelope = BridgeEnvelopeV1(nonce: BridgeCodec.randomNonce(), action: action, payload: payload)
        let message = try BridgeCodec.commandMessage(for: envelope)
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                self.failBridge(requestID: envelope.requestID, error: PiRPCClientError.requestTimedOut(command: action.rawValue))
            }
            bridgeWaiters[envelope.requestID] = BridgeWaiter(
                envelope: envelope,
                continuation: continuation,
                timeout: timeout
            )
            Task { [weak self, client] in
                do {
                    _ = try await client.send(.prompt(message: message, images: [], behavior: nil), timeout: 15)
                } catch {
                    self?.failBridge(requestID: envelope.requestID, error: error)
                }
            }
        }
    }

    private func resolveBridge(_ response: BridgeResponseV1) {
        guard let waiter = bridgeWaiters.removeValue(forKey: response.requestID) else { return }
        waiter.timeout.cancel()
        do {
            try BridgeCodec.validate(response, for: waiter.envelope)
            guard response.success else { throw ApplePiServiceError.bridgeFailed(response.error ?? "Unknown error") }
            waiter.continuation.resume(returning: response)
        } catch {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func failBridge(requestID: String, error: any Error) {
        guard let waiter = bridgeWaiters.removeValue(forKey: requestID) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
    }

    // MARK: - Session loading and mutation

    private func loadTranscript(
        sessionID: String,
        includeLiveRuntime: Bool = true
    ) async throws -> [ApplePiTranscriptItem] {
        if drafts[sessionID]?.sessionURL == nil { return [] }
        guard let entry = indexedEntry(uiID: sessionID) ?? draftIndexEntry(uiID: sessionID) else {
            throw ApplePiServiceError.sessionNotFound
        }
        let projection = try await transcriptLoader.load(entry)
        try Task.checkCancellation()
        guard model?.selection == .session(sessionID) else { throw CancellationError() }
        if model?.inspector.branches != projection.branches {
            model?.inspector.branches = projection.branches
        }
        if let taskID = taskByUIID[sessionID] {
            try? await refreshRuntimeInspector(taskID: taskID, expectedSessionID: sessionID)
            try Task.checkCancellation()
            guard model?.selection == .session(sessionID) else { throw CancellationError() }
            guard includeLiveRuntime else { return projection.items }
            if tasksNeedingTranscriptResync.contains(taskID),
               runtimeSnapshots[taskID]?.state.phase != .generating,
               runtimeSnapshots[taskID]?.state.phase != .queued,
               runtimeSnapshots[taskID]?.state.phase != .starting {
                tasksNeedingTranscriptResync.remove(taskID)
                clearRetainedRuntimeData(for: taskID)
                return projection.items
            }
            return combiningLiveItems(with: projection.items, taskID: taskID)
        }
        return projection.items
    }

    private func contentText(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        if let string = content.stringValue { return string }
        let pieces: [String] = content.arrayValue?.compactMap { block -> String? in
            guard let object = block.objectValue else { return nil }
            return switch object["type"]?.stringValue {
            case "text": object["text"]?.stringValue
            case "thinking": object["thinking"]?.stringValue
            default: nil
            }
        } ?? []
        return pieces.joined(separator: "\n")
    }

    private func mutateSession(_ uiID: String, mutation: ApplePiSessionMutation) async throws {
        if case .moveToTrash = mutation {
            try await deleteSession(uiID: uiID)
            return
        }

        if case let .moveToProject(projectID) = mutation {
            let targetProject: ApplePiProject?
            if let projectID {
                guard let project = await projectStore.project(id: projectID) else {
                    throw ApplePiServiceError.projectNotFound
                }
                targetProject = project
            } else {
                targetProject = nil
            }
            let entry = indexedEntry(uiID: uiID) ?? draftIndexEntry(uiID: uiID)
            let hasDraft = drafts[uiID] != nil
            guard let workingDirectory = entry?.workingDirectory ?? drafts[uiID]?.workingDirectory else {
                throw ApplePiServiceError.sessionNotFound
            }
            if let targetProject,
               !ProjectDirectoryMatcher.contains(workingDirectory, in: targetProject.workingDirectory) {
                throw ApplePiServiceError.projectDirectoryMismatch
            }
            drafts[uiID]?.projectID = projectID
            if let entry {
                try await presentationStore.setProjectID(projectID, for: entry.path)
                await sessionIndex?.presentationDidChange()
            } else if !hasDraft {
                throw ApplePiServiceError.sessionNotFound
            }
            return
        }

        if indexedEntry(uiID: uiID) == nil,
           draftIndexEntry(uiID: uiID) == nil,
           drafts[uiID] != nil {
            switch mutation {
            case let .pin(pinned):
                drafts[uiID]?.isPinned = pinned
            case let .archive(archived):
                drafts[uiID]?.isArchived = archived
                if archived, let taskID = taskByUIID[uiID] { await coordinator?.stop(taskID) }
            case let .rename(name):
                drafts[uiID]?.title = name
            case .moveToProject:
                break
            case .fork, .clone, .export, .reveal, .moveToTrash:
                throw ApplePiServiceError.sessionNotFound
            }
            return
        }

        guard var entry = indexedEntry(uiID: uiID) ?? draftIndexEntry(uiID: uiID) else {
            throw ApplePiServiceError.sessionNotFound
        }
        switch mutation {
        case let .pin(pinned):
            try await presentationStore.setPinned(pinned, for: entry.path)
            await sessionIndex?.presentationDidChange()

        case let .archive(archived):
            try await presentationStore.setArchived(archived, for: entry.path)
            if archived, let taskID = taskByUIID[uiID] { await coordinator?.stop(taskID) }
            await sessionIndex?.presentationDidChange()

        case .moveToProject:
            // Handled before canonical entry resolution so unsaved drafts can move too.
            break

        case let .rename(name):
            try await assertSessionUnchanged(entry)
            let taskID = try await ensureTask(sessionID: uiID)
            guard let client = await coordinator?.client(for: taskID) else { throw ApplePiServiceError.taskNotRunning }
            _ = try await client.send(.setSessionName(name))

        case .fork:
            try await assertSessionUnchanged(entry)
            let taskID = try await ensureTask(sessionID: uiID)
            guard let client = await coordinator?.client(for: taskID), let leaf = entry.leafEntryID else { return }
            let response = try await client.send(.fork(entryID: leaf), timeout: 60)
            guard response.data?.objectValue?["cancelled"]?.boolValue != true else { return }
            if let text = response.data?.objectValue?["text"]?.stringValue { model?.composerText = text }
            try? await refreshRuntimeInspector(taskID: taskID)
            if let sessionIndex { indexedSessions = await sessionIndex.refresh().entries }
            if let transcript = try? await loadTranscript(sessionID: uiID),
               model?.selection == .session(uiID) {
                model?.replaceTranscript(transcript)
            }

        case .clone:
            try await assertSessionUnchanged(entry)
            let taskID = try await ensureTask(sessionID: uiID)
            guard let client = await coordinator?.client(for: taskID) else { return }
            let response = try await client.send(.clone, timeout: 60)
            guard response.data?.objectValue?["cancelled"]?.boolValue != true else { return }
            guard let state = try? await client.send(.getState, timeout: 10),
                  let data = state.data?.objectValue,
                  let canonicalID = data["sessionId"]?.stringValue,
                  let sessionPath = canonicalSessionPath(from: data) else {
                // Pi may already have switched sessions. Do not leave that
                // process associated with the original sidebar identity.
                await coordinator?.close(taskID)
                taskByUIID.removeValue(forKey: uiID)
                uiIDByTask.removeValue(forKey: taskID)
                throw ApplePiServiceError.sessionNotFound
            }
            await adoptClonedSession(
                canonicalID: canonicalID,
                sessionPath: sessionPath,
                originalUIID: uiID,
                taskID: taskID
            )

        case let .export(format):
            try await assertSessionUnchanged(entry)
            guard let destination = saveDestination(for: entry, format: format) else { return }
            switch format {
            case .rawJSONL:
                try SessionFileService.exportRawJSONL(entry, to: destination)
            case .html:
                try await exportHTML(entry, to: destination)
            }

        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([entry.path])

        case .moveToTrash:
            // Handled before entry resolution so an unsaved draft, which has
            // no canonical JSONL file yet, can still be deleted.
            break
        }
        if let refreshed = indexedEntry(uiID: uiID) { entry = refreshed }
        _ = entry
    }

    private func archiveSessions(_ uiIDs: [String], archived: Bool) async throws {
        let uniqueIDs = Set(uiIDs)
        var sessionURLs = Set<URL>()
        var affectedTaskIDs = Set<PiTaskID>()

        for uiID in uniqueIDs {
            if drafts[uiID] != nil {
                drafts[uiID]?.isArchived = archived
            }
            if let entry = indexedEntry(uiID: uiID) ?? draftIndexEntry(uiID: uiID) {
                sessionURLs.insert(entry.path.standardizedFileURL)
            }
            if archived, let taskID = taskByUIID[uiID] {
                affectedTaskIDs.insert(taskID)
            }
        }

        let URLs = Array(sessionURLs)
        try await presentationStore.setArchived(archived, for: URLs)
        if archived {
            for taskID in affectedTaskIDs {
                await coordinator?.stop(taskID)
            }
        }
        if !URLs.isEmpty, let sessionIndex {
            await sessionIndex.presentationDidChange()
            indexedSessions = await sessionIndex.snapshot()
        }
    }

    private func deleteSession(uiID: String) async throws {
        let indexed = indexedEntry(uiID: uiID)
        let draft = drafts[uiID]

        if indexed == nil,
           let draft,
           draft.environment == .managedWorktree,
           let projectID = draft.projectID,
           let project = await projectStore.project(id: projectID) {
            try await managedWorktreeService.removeUntouched(
                at: draft.workingDirectory,
                from: project.workingDirectory
            )
        }

        if let taskID = taskByUIID[uiID] {
            await coordinator?.close(taskID)
            taskByUIID.removeValue(forKey: uiID)
            uiIDByTask.removeValue(forKey: taskID)
            runtimeSnapshots.removeValue(forKey: taskID)
            streamStates.removeValue(forKey: taskID)
        }

        let sessionURL = indexed?.path ?? draft?.sessionURL
        if let sessionURL {
            // Trash is synchronous. If an external writer already removed the
            // file, consider the requested end state satisfied and prune the
            // stale index row instead of surfacing a second deletion failure.
            if FileManager.default.fileExists(atPath: sessionURL.path) {
                _ = try SessionFileService.moveToTrash(at: sessionURL)
            }

            // Presentation metadata is rebuildable app state. A failure to
            // rewrite it must not make an already-trashed canonical session
            // remain visible in the sidebar.
            try? await presentationStore.removeState(for: sessionURL)
            indexedSessions.removeAll {
                $0.path.standardizedFileURL == sessionURL.standardizedFileURL
            }
        }

        drafts.removeValue(forKey: uiID)
        let canonicalID = canonicalByUIID.removeValue(forKey: uiID) ?? indexed?.sessionID
        if let canonicalID {
            if canonicalToUIID[canonicalID] == uiID {
                canonicalToUIID.removeValue(forKey: canonicalID)
            }
            appCreatedCanonicalIDs.remove(canonicalID)
            indexedSessions.removeAll { $0.sessionID == canonicalID }
        }
    }

    private func assertSessionUnchanged(_ entry: SessionIndexEntry) async throws {
        guard let values = try? entry.path.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate,
              let size = values.fileSize else { return }
        if Int64(size) != entry.byteCount || abs(modified.timeIntervalSince(entry.modifiedAt)) > 0.001 {
            if let sessionIndex { _ = await sessionIndex.refresh() }
            throw ApplePiServiceError.sessionChangedExternally
        }
    }

    private func exportHTML(_ entry: SessionIndexEntry, to destination: URL) async throws {
        if let uiID = canonicalToUIID[entry.sessionID], let taskID = taskByUIID[uiID],
           let client = await coordinator?.client(for: taskID) {
            _ = try await client.send(.exportHTML(outputPath: destination.path), timeout: 120)
            return
        }
        guard let runtime = runtimeResolution?.selected else { throw ApplePiServiceError.runtimeUnavailable }
        let result = try await ProcessCapture.run(
            executable: runtime.executable,
            arguments: [
                "--offline", "--no-session", "--no-extensions", "--no-skills",
                "--no-prompt-templates", "--no-themes", "--no-context-files",
                "--no-approve", "--export", entry.path.path, destination.path,
            ],
            environment: runtimeResolution?.environment,
            currentDirectory: entry.workingDirectory,
            timeout: 120,
            maximumOutputBytes: 1_024 * 1_024
        )
        guard result.status == 0 else {
            throw ApplePiServiceError.packageOperationFailed(DiagnosticsRedactor.redact(result.stderrString))
        }
    }

    private func saveDestination(for entry: SessionIndexEntry, format: ApplePiExportFormat) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (entry.name ?? "Pi Session") + (format == .html ? ".html" : ".jsonl")
        panel.allowedContentTypes = format == .html ? [.html] : [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Runtime inspector

    private func runtimeOptions(sessionID: String) async throws -> ApplePiRuntimeOptions {
        let taskID = try await ensureTask(sessionID: sessionID)
        return try await runtimeOptions(taskID: taskID)
    }

    private func runtimeOptions(taskID: PiTaskID) async throws -> ApplePiRuntimeOptions {
        guard let client = await coordinator?.client(for: taskID) else {
            throw ApplePiServiceError.taskNotRunning
        }
        async let modelsResponse = client.send(.getAvailableModels, timeout: 30)
        async let levelsResponse = client.send(.getAvailableThinkingLevels, timeout: 10)
        let models = try await modelsResponse.data?.objectValue?["models"]?.arrayValue ?? []
        let levels = try await levelsResponse.data?.objectValue?["levels"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        let options = models.compactMap { value -> ApplePiModelOption? in
            guard let object = value.objectValue,
                  let provider = object["provider"]?.stringValue,
                  let modelID = object["id"]?.stringValue else { return nil }
            return ApplePiModelOption(
                provider: provider,
                modelID: modelID,
                displayName: object["name"]?.stringValue ?? modelID
            )
        }.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return ApplePiRuntimeOptions(models: options, thinkingLevels: levels)
    }

    private func refreshRuntimeInspector(
        taskID: PiTaskID,
        expectedSessionID: String? = nil
    ) async throws {
        guard let client = await coordinator?.client(for: taskID) else { return }
        func remainsSelected() -> Bool {
            guard isTaskSelected(taskID) else { return false }
            guard let expectedSessionID else { return true }
            return model?.selection == .session(expectedSessionID)
        }
        guard remainsSelected() else { return }
        async let state = client.send(.getState, timeout: 10)
        async let stats = client.send(.getSessionStats, timeout: 10)
        async let tree = client.send(.getTree, timeout: 10)
        async let commands = client.send(.getCommands, timeout: 10)

        if let response = try? await state, remainsSelected(), let data = response.data?.objectValue {
            applyState(data)
        }
        if let response = try? await stats, remainsSelected(), let data = response.data?.objectValue {
            applyStats(data)
        }
        if let response = try? await tree, remainsSelected() { applyTree(response.data) }
        if let response = try? await commands, remainsSelected() { applyCommands(response.data) }
    }

    private func applyState(_ data: [String: JSONValue]) {
        if let modelValue = data["model"]?.objectValue {
            let provider = modelValue["provider"]?.stringValue
            let name = modelValue["name"]?.stringValue ?? modelValue["id"]?.stringValue
            model?.inspector.model = [provider, name].compactMap { $0 }.joined(separator: "/")
        }
        if let level = data["thinkingLevel"]?.stringValue { model?.inspector.thinkingLevel = level }
        if let count = data["pendingMessageCount"]?.numberValue { model?.inspector.queuedMessages = Int(count) }
    }

    private func applyStats(_ data: [String: JSONValue]) {
        let tokens = data["tokens"]?.objectValue
        model?.inspector.inputTokens = Int(tokens?["input"]?.numberValue ?? 0)
        model?.inspector.outputTokens = Int(tokens?["output"]?.numberValue ?? 0)
        let context = data["contextUsage"]?.objectValue
        model?.inspector.contextUsed = Int(context?["tokens"]?.numberValue ?? 0)
        model?.inspector.contextLimit = Int(context?["contextWindow"]?.numberValue ?? 0)
    }

    private func applyTree(_ data: JSONValue?) {
        guard let object = data?.objectValue else { return }
        let leaf = object["leafId"]?.stringValue
        var branches: [ApplePiInspectorSnapshot.Branch] = []
        func walk(_ nodes: [JSONValue]) {
            for node in nodes {
                guard let value = node.objectValue, let entry = value["entry"]?.objectValue,
                      let id = entry["id"]?.stringValue else { continue }
                let label = value["label"]?.stringValue
                    ?? entry["message"]?.objectValue.flatMap { contentText($0["content"]) }
                let title = label?.split(separator: "\n").first.map(String.init) ?? entry["type"]?.stringValue ?? "Entry"
                branches.append(.init(id: id, title: String(title.prefix(60)), isCurrent: id == leaf))
                walk(value["children"]?.arrayValue ?? [])
            }
        }
        walk(object["tree"]?.arrayValue ?? [])
        model?.inspector.branches = branches
    }

    private func applyCommands(_ data: JSONValue?) {
        guard let commands = data?.objectValue?["commands"]?.arrayValue else { return }
        let mapped = commands.compactMap { value -> ApplePiComposerCommand? in
            guard let object = value.objectValue, let name = object["name"]?.stringValue else { return nil }
            return ApplePiComposerCommand(
                name: name.hasPrefix("/") ? name : "/\(name)",
                detail: object["description"]?.stringValue ?? object["source"]?.stringValue ?? "Pi command"
            )
        }
        if !mapped.isEmpty { model?.availableCommands = mapped }
    }

    // MARK: - Packages and trust

    private func runPackageOperation(_ operation: PackageOperation, cwd: URL) async throws {
        guard let runtime = runtimeResolution?.selected else { throw ApplePiServiceError.runtimeUnavailable }
        let trusted = try await resolveProjectTrust(cwd: cwd)
        let service = PiPackageCLIService(
            runtime: runtime,
            environment: runtimeResolution?.environment ?? ProcessInfo.processInfo.environment,
            workingDirectory: cwd,
            projectTrusted: trusted
        )
        let result = try await service.perform(operation)
        guard result.succeeded else {
            let message = result.errorOutput.isEmpty ? result.output : result.errorOutput
            throw ApplePiServiceError.packageOperationFailed(message)
        }
        try await reloadActiveRuntimes()
    }

    private func refreshPackageResources(cwd: URL) async throws -> [ApplePiPackageResource] {
        let trusted = try await resolveProjectTrust(cwd: cwd)
        // Package refresh is an explicit operation, so it may check registries
        // and git remotes. The transient process remains session-free and all
        // discovered resources stay disabled; only the bundled bridge executes.
        let response = try await temporaryBridge(
            action: .packageSnapshot,
            cwd: cwd,
            offlineStartup: false,
            projectTrusted: trusted,
            timeout: 60
        )
        return mapPackageResources(response.result, cwd: cwd) ?? []
    }

    private func mapPackageResources(_ result: JSONValue?, cwd: URL) -> [ApplePiPackageResource]? {
        guard let object = result?.objectValue,
              let resources = object["resources"]?.arrayValue else { return nil }
        var inventory: [String: PackageInventoryRecord] = [:]
        for value in object["configuredPackages"]?.arrayValue ?? [] {
            guard let package = value.objectValue,
                  let source = package["source"]?.stringValue else { continue }
            let scope: ApplePiPackageScope = package["scope"]?.stringValue == "project" ? .project : .global
            let record = PackageInventoryRecord(
                source: source,
                scope: scope,
                isFiltered: package["filtered"]?.boolValue ?? false,
                installedPath: package["installedPath"]?.stringValue,
                installedVersion: package["installedVersion"]?.stringValue,
                hasUpdate: package["hasUpdate"]?.boolValue ?? false
            )
            inventory[packageInventoryKey(scope: scope, source: source)] = record
        }

        resourceRecords.removeAll(keepingCapacity: true)
        var representedPackages = Set<String>()
        var mapped = resources.compactMap { value -> ApplePiPackageResource? in
            guard let object = value.objectValue,
                  let source = object["source"]?.stringValue,
                  let path = object["path"]?.stringValue,
                  let kindValue = object["kind"]?.stringValue else { return nil }
            let scope: ApplePiPackageScope = object["scope"]?.stringValue == "project" ? .project : .global
            let kind: ApplePiResourceKind = switch kindValue {
            case "extensions": .extensionResource
            case "skills": .skill
            case "prompts": .prompt
            case "themes": .theme
            default: .extensionResource
            }
            let id = "\(scope.rawValue):\(kindValue):\(path)"
            let origin = object["origin"]?.stringValue ?? "top-level"
            let pattern = object["pattern"]?.stringValue ?? path
            let packageKey = packageInventoryKey(scope: scope, source: source)
            let package = origin == "package" ? inventory[packageKey] : nil
            if package != nil { representedPackages.insert(packageKey) }
            resourceRecords[id] = ResourceBridgeRecord(
                source: source,
                scope: scope,
                kind: kindValue,
                origin: origin,
                pattern: pattern,
                path: path,
                isToggleable: true,
                workingDirectory: cwd.standardizedFileURL
            )
            let localURL = localPackageURL(source: source, baseDirectory: object["baseDir"]?.stringValue)
                ?? package?.installedPath.map { URL(filePath: $0) }
            var details: [String] = []
            if object["enabled"]?.boolValue == false { details.append("Disabled in Pi settings") }
            if package?.isFiltered == true { details.append("Package filters configured") }
            return ApplePiPackageResource(
                id: id,
                packageSource: source,
                name: URL(filePath: path).lastPathComponent,
                version: package?.installedVersion,
                scope: scope,
                kind: kind,
                isEnabled: object["enabled"]?.boolValue ?? true,
                isToggleable: true,
                hasUpdate: package?.hasUpdate ?? false,
                statusDetail: details.isEmpty ? nil : details.joined(separator: " • "),
                localURL: localURL
            )
        }

        // Keep configured packages visible even when every resource is filtered,
        // missing, or the package intentionally contains no Pi resources.
        for (key, package) in inventory where !representedPackages.contains(key) {
            let id = "\(package.scope.rawValue):package:\(package.source)"
            let path = package.installedPath ?? package.source
            resourceRecords[id] = ResourceBridgeRecord(
                source: package.source,
                scope: package.scope,
                kind: "extensions",
                origin: "package-inventory",
                pattern: "",
                path: path,
                isToggleable: false,
                workingDirectory: cwd.standardizedFileURL
            )
            mapped.append(ApplePiPackageResource(
                id: id,
                packageSource: package.source,
                name: packageDisplayName(package.source),
                version: package.installedVersion,
                scope: package.scope,
                kind: .extensionResource,
                isEnabled: true,
                isToggleable: false,
                hasUpdate: package.hasUpdate,
                statusDetail: package.isFiltered
                    ? "Installed package • Filters configured • No resolved resources"
                    : "Installed package • No resolved resources",
                localURL: package.installedPath.map { URL(filePath: $0) }
                    ?? localPackageURL(source: package.source, baseDirectory: nil)
            ))
        }

        mapped.sort {
            if $0.scope != $1.scope { return $0.scope.rawValue < $1.scope.rawValue }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        configureLocalWatchers(for: mapped)
        updateInspectorExtensions(from: mapped)
        return mapped
    }

    private func packageInventoryKey(scope: ApplePiPackageScope, source: String) -> String {
        "\(scope.rawValue)\u{0}\(source)"
    }

    private func packageDisplayName(_ source: String) -> String {
        let withoutPrefix = source.hasPrefix("npm:") ? String(source.dropFirst(4)) : source
        if withoutPrefix.hasPrefix("@") {
            let components = withoutPrefix.split(separator: "@", omittingEmptySubsequences: true)
            return components.first.map { "@\($0)" } ?? withoutPrefix
        }
        return withoutPrefix.split(separator: "@").first.map(String.init) ?? withoutPrefix
    }

    private func updateInspectorExtensions(from resources: [ApplePiPackageResource]) {
        model?.inspector.extensions = resources.compactMap { resource in
            guard resource.kind == .extensionResource,
                  resourceRecords[resource.id]?.isToggleable == true else { return nil }
            let normalizedPath = resourceRecords[resource.id].map {
                URL(filePath: $0.path).standardizedFileURL.path
            }
            let loadError = normalizedPath.flatMap { extensionLoadErrors[$0] }
            return ApplePiInspectorSnapshot.ExtensionStatus(
                id: resource.id,
                name: resource.name,
                status: loadError ?? (resource.isEnabled ? "Enabled" : "Disabled"),
                isHealthy: loadError == nil
            )
        }
    }

    private func upsertInspectorExtensionError(path: String, message: String) {
        let normalized = URL(filePath: path).standardizedFileURL.path
        if let index = model?.inspector.extensions.firstIndex(where: { status in
            guard let record = resourceRecords[status.id] else { return false }
            return URL(filePath: record.path).standardizedFileURL.path == normalized
        }) {
            model?.inspector.extensions[index].status = message
            model?.inspector.extensions[index].isHealthy = false
            return
        }
        model?.inspector.extensions.append(.init(
            id: "extension-error:\(normalized)",
            name: URL(filePath: path).lastPathComponent,
            status: message,
            isHealthy: false
        ))
    }

    private func setResourceEnabled(id: String, enabled: Bool) async throws {
        guard let record = resourceRecords[id] else { throw ApplePiServiceError.packageNotFound }
        guard record.isToggleable else {
            throw ApplePiServiceError.bridgeFailed(
                "This installed package has no resolved Pi resource that can be enabled or disabled."
            )
        }
        let cwd = try packageWorkingDirectory(
            scope: record.scope,
            projectURL: record.scope == .project ? record.workingDirectory : nil
        )
        let payload: JSONValue = .object([
            "kind": .string(record.kind),
            "scope": .string(record.scope == .project ? "project" : "user"),
            "origin": .string(record.origin),
            "source": .string(record.source),
            "pattern": .string(record.pattern),
            "enabled": .bool(enabled),
        ])
        let trusted = record.scope == .project ? try await resolveProjectTrust(cwd: cwd) : false
        _ = try await temporaryBridge(
            action: .setResourceEnabled,
            payload: payload,
            cwd: cwd,
            projectTrusted: trusted
        )
        try await reloadActiveRuntimes()
    }

    private func reloadActiveRuntimes() async throws {
        guard let coordinator else { return }
        for snapshot in await coordinator.snapshots() where snapshot.state.phase != .stopped {
            _ = try? await invokeBridge(taskID: snapshot.id, action: .reload)
        }
    }

    private func configureLocalWatchers(for packages: [ApplePiPackageResource]) {
        var desired: [String: URL] = [:]
        for package in packages {
            guard let url = package.localURL else { continue }
            let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            let canonicalDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
            desired[canonicalDirectory.path] = canonicalDirectory
        }
        let paths = Set(desired.keys)
        guard paths != localPackageWatcherPaths else { return }
        localPackageWatcher?.stop()
        localPackageWatcher = nil
        localPackageWatcherPaths = paths
        guard !desired.isEmpty else { return }

        let watcher = RecursiveFileSystemWatcher(urls: Array(desired.values)) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleLocalPackageReload()
            }
        }
        do {
            try watcher.start()
            localPackageWatcher = watcher
        } catch {
            localPackageWatcherPaths.removeAll()
        }
    }

    private func scheduleLocalPackageReload() {
        localPackageReloadPending = true
        guard !isReloadingLocalPackages else { return }
        localPackageReloadTask?.cancel()
        localPackageReloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard let self else { return }
            await self.performScheduledLocalPackageReload()
        }
    }

    private func performScheduledLocalPackageReload() async {
        guard !isReloadingLocalPackages else { return }
        isReloadingLocalPackages = true
        localPackageReloadPending = false
        try? await reloadActiveRuntimes()
        isReloadingLocalPackages = false
        localPackageReloadTask = nil
        if localPackageReloadPending {
            scheduleLocalPackageReload()
        }
    }

    private func resolveProjectTrust(cwd: URL) async throws -> Bool {
        guard bridgeURL != nil else { return false }
        let response = try await temporaryBridge(action: .trustResolve, payload: .object([
            "cwd": .string(cwd.path),
        ]), cwd: cwd)
        let result = response.result?.objectValue
        let requiresTrust = result?["requiresTrust"]?.boolValue ?? (result?["entry"] != nil)
        if !requiresTrust { return true }
        if let decision = result?["entry"]?.objectValue?["decision"]?.boolValue { return decision }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Trust Pi resources in this project?"
        alert.informativeText = "Project-local Pi extensions and packages run with your filesystem and network authority. ApplePi does not sandbox them."
        alert.addButton(withTitle: "Trust Project")
        alert.addButton(withTitle: "Do Not Load")
        let decision = alert.runModal() == .alertFirstButtonReturn
        _ = try await temporaryBridge(action: .trustSet, payload: .object([
            "cwd": .string(cwd.path),
            "decision": .bool(decision),
        ]), cwd: cwd)
        return decision
    }

    private func temporaryBridge(
        action: BridgeActionV1,
        payload: JSONValue = .object([:]),
        cwd: URL,
        offlineStartup: Bool = true,
        projectTrusted: Bool = false,
        timeout: TimeInterval = 15
    ) async throws -> BridgeResponseV1 {
        guard let runtime = runtimeResolution?.selected, runtime.supportsNativeTasks else {
            throw ApplePiServiceError.runtimeUnavailable
        }
        guard let bridgeURL else { throw ApplePiServiceError.bridgeUnavailable }
        let configuration = PiRPCClient.Configuration(
            runtime: runtime,
            workingDirectory: cwd,
            sessionPath: nil,
            projectTrusted: projectTrusted,
            bridgeURL: bridgeURL,
            environment: runtimeResolution?.environment ?? ProcessInfo.processInfo.environment,
            offlineStartup: offlineStartup,
            noSession: true,
            // The bridge reads Pi's settings/package metadata directly. Loading
            // arbitrary user or project resources into this short-lived probe
            // would execute third-party code for no functional benefit.
            disableDiscoveredResources: true
        )
        let client = PiRPCClient(configuration: configuration)
        try await client.start()
        let envelope = BridgeEnvelopeV1(nonce: BridgeCodec.randomNonce(), action: action, payload: payload)
        do {
            let message = try BridgeCodec.commandMessage(for: envelope)
            _ = try await client.send(.prompt(message: message, images: [], behavior: nil), timeout: timeout)
            let response = try await withThrowingTaskGroup(of: BridgeResponseV1.self) { group in
                group.addTask {
                    for await event in client.events {
                        if case let .bridge(response) = event,
                           response.requestID == envelope.requestID {
                            try BridgeCodec.validate(response, for: envelope)
                            guard response.success else {
                                throw ApplePiServiceError.bridgeFailed(response.error ?? "Unknown error")
                            }
                            return response
                        }
                        if case let .processTerminated(status, _) = event {
                            throw PiRPCClientError.processExited(status: status)
                        }
                    }
                    throw ApplePiServiceError.bridgeUnavailable
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    // A throwing task group waits for all children. Stop Pi
                    // inside the timeout branch so the event iterator settles
                    // before the group scope unwinds.
                    await client.stop(gracePeriod: 0)
                    throw PiRPCClientError.requestTimedOut(command: action.rawValue)
                }
                guard let first = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return first
            }
            await client.stop(gracePeriod: 0.15)
            return response
        } catch {
            await client.stop(gracePeriod: 0.15)
            throw error
        }
    }

    private func packageWorkingDirectory(scope: ApplePiPackageScope, projectURL: URL?) throws -> URL {
        if scope == .project {
            guard let projectURL else { throw ApplePiServiceError.projectRequired }
            return projectURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func runtimeScope(_ scope: ApplePiPackageScope) -> PackageScope {
        scope == .project ? .project : .user
    }

    private func hasEnabledExtension(for cwd: URL) -> Bool {
        model?.packages.contains {
            $0.kind == .extensionResource && $0.isEnabled && $0.isToggleable
                && ($0.scope == .global || cwd.standardizedFileURL == model?.selectedProjectURL?.standardizedFileURL)
        } == true
    }

    private func localPackageURL(source: String, baseDirectory: String?) -> URL? {
        if source.hasPrefix("/") { return URL(filePath: source) }
        if source.hasPrefix("./") || source.hasPrefix("../") {
            let base = baseDirectory.map { URL(filePath: $0) } ?? model?.selectedProjectURL
            return base?.appending(path: source).standardizedFileURL
        }
        if source.hasPrefix("file:") { return URL(string: source) }
        return nil
    }

    // MARK: - Index and utility

    private func consumeIndex(_ update: SessionIndexSnapshot) {
        indexedSessions = update.entries
        guard let model else { return }
        model.replaceSessionsIfChanged(makeUISessions())
    }

    private func indexedEntry(uiID: String) -> SessionIndexEntry? {
        let canonical = canonicalByUIID[uiID] ?? uiID
        return indexedSessions.first { $0.sessionID == canonical }
            ?? drafts[uiID]?.sessionURL.flatMap { url in indexedSessions.first { $0.path == url } }
    }

    private func draftIndexEntry(uiID: String) -> SessionIndexEntry? {
        guard let draft = drafts[uiID], let path = draft.sessionURL,
              FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try? PiSessionParser.indexEntry(at: path)
    }

    private func selectedTaskID() -> PiTaskID? {
        guard case let .session(uiID) = model?.selection else { return nil }
        return taskByUIID[uiID]
    }

    private var bridgeURL: URL? {
        Bundle.main.url(forResource: "apple-pi-bridge", withExtension: "ts", subdirectory: "Bridge")
            ?? Bundle.main.url(forResource: "apple-pi-bridge", withExtension: "ts")
    }

    private func terminalRequest(
        purpose: ApplePiTerminalRequest.Purpose,
        sessionID: String?
    ) async throws -> ApplePiTerminalRequest {
        guard let runtime = runtimeResolution?.selected else { throw ApplePiServiceError.runtimeUnavailable }
        let session = sessionID.flatMap(indexedEntry)
        let arguments: [String]
        switch purpose {
        case .configuration:
            arguments = []
        case .session, .extensionFallback:
            arguments = session.map { ["--session", $0.path.path] } ?? []
        }
        let environment = (runtimeResolution?.environment ?? ProcessInfo.processInfo.environment)
            .map { "\($0.key)=\($0.value)" }
        return ApplePiTerminalRequest(
            title: purpose == .configuration ? "Pi Provider Configuration" : "Pi Terminal",
            executable: runtime.executable.path,
            arguments: arguments,
            environment: environment,
            currentDirectory: session?.workingDirectory.path ?? model?.selectedProjectURL?.path,
            purpose: purpose
        )
    }

    private func notifyIfBackground(title: String, body: String) {
        guard NSApp.isActive == false else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    #if DEBUG
    struct RuntimeRetentionTestSnapshot: Equatable {
        let taskBytes: Int
        let globalBytes: Int
        let needsCanonicalResynchronization: Bool
    }

    func registerRuntimeTaskForTesting(_ taskID: PiTaskID, sessionID: String) {
        taskByUIID[sessionID] = taskID
        uiIDByTask[taskID] = sessionID
    }

    func consumeRPCForTesting(_ event: PiRPCEvent, taskID: PiTaskID) async {
        await consumeRPC(event, taskID: taskID)
    }

    func runtimeRetentionForTesting(taskID: PiTaskID) -> RuntimeRetentionTestSnapshot {
        RuntimeRetentionTestSnapshot(
            taskBytes: (liveBytesByTask[taskID] ?? 0) + (pendingDeltaBytesByTask[taskID] ?? 0),
            globalBytes: totalLiveBytes + totalPendingDeltaBytes,
            needsCanonicalResynchronization: tasksNeedingTranscriptResync.contains(taskID)
        )
    }
    #endif

    private func sessionName(uiID: String) -> String {
        model?.sessions.first(where: { $0.id == uiID })?.title ?? "Task completed."
    }

    private func prettyJSON(_ value: JSONValue, maximumCharacters: Int) -> String {
        guard let data = try? value.encodedData(sortedKeys: true),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return String(String(describing: value).prefix(maximumCharacters))
        }
        return String(String(decoding: pretty, as: UTF8.self).prefix(maximumCharacters))
    }
}
