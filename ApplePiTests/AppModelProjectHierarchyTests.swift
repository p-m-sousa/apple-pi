import AppKit
import Foundation
import Observation
import os
import Testing
@testable import ApplePi

@MainActor
@Suite("Application appearance")
struct ApplePiAppearanceTests {
    @Test("System and Light transitions clear and restore the app override")
    func systemAndLightAppearanceMapping() {
        let sequence = [ApplePiAppearance.system, .light, .system]
            .map { $0.applicationAppearance?.name }

        #expect(sequence == [nil, .aqua, nil])
    }

    @Test("System and Dark transitions clear and restore the app override")
    func systemAndDarkAppearanceMapping() {
        let sequence = [ApplePiAppearance.system, .dark, .system]
            .map { $0.applicationAppearance?.name }

        #expect(sequence == [nil, .darkAqua, nil])
    }
}

@MainActor
@Suite("Project and standalone task hierarchy")
struct AppModelProjectHierarchyTests {
    @Test("Global creation stays standalone even when a project is selected")
    func globalCreationIsStandalone() async {
        let model = makeModel()
        let project = ApplePiProject(
            name: "Workspace",
            workingDirectory: URL(filePath: "/tmp/apple-pi-workspace", directoryHint: .isDirectory)
        )
        model.projects = [project]
        await model.activate(.project(project.id))

        await model.createTask()

        let task = model.sessions[0]
        #expect(task.projectID == nil)
        #expect(task.workingDirectory == FileManager.default.homeDirectoryForCurrentUser)
        #expect(model.selection == .session(task.id))
        #expect(model.selectedProjectURL == nil)
    }

    @Test("Project creation carries identity and working folder")
    func projectCreationIsScoped() async {
        let model = makeModel()
        let directory = URL(filePath: "/tmp/apple-pi-project", directoryHint: .isDirectory)
        let project = ApplePiProject(name: "Apple Pi", workingDirectory: directory)
        model.projects = [project]

        await model.createTask(in: project)

        let task = model.sessions[0]
        #expect(task.projectID == project.id)
        #expect(task.workingDirectory == directory)
        #expect(model.selectedProjectURL == directory)
    }

    @Test("Leaving an untouched new task removes it from the project")
    func untouchedTaskIsDiscardedOnDeparture() async {
        let model = makeModel()
        let project = ApplePiProject(
            name: "Workspace",
            workingDirectory: URL(filePath: "/tmp/apple-pi-workspace", directoryHint: .isDirectory)
        )
        model.projects = [project]
        await model.createTask(in: project)

        await model.activate(.project(project.id))

        #expect(model.sessions.isEmpty)
        #expect(model.selection == .project(project.id))
        #expect(model.alertMessage == nil)
    }

    @Test("Typed text keeps a new task and restores its per-task draft")
    func typedTaskDraftSurvivesNavigation() async {
        let model = makeModel()
        let project = ApplePiProject(
            name: "Workspace",
            workingDirectory: URL(filePath: "/tmp/apple-pi-workspace", directoryHint: .isDirectory)
        )
        model.projects = [project]
        await model.createTask(in: project)
        let taskID = model.sessions[0].id
        model.composerText = "Keep this as a draft"

        await model.activate(.project(project.id))

        #expect(model.sessions.map(\.id) == [taskID])
        #expect(model.composerText.isEmpty)
        #expect(model.hasTextDraft(for: taskID))

        await model.activate(.session(taskID))

        #expect(model.composerText == "Keep this as a draft")
        #expect(model.hasTextDraft(for: taskID))
        #expect(model.alertMessage == nil)

        model.composerText = ""
        #expect(!model.hasTextDraft(for: taskID))
    }

    @Test("A submitted new task is never treated as an untouched draft")
    func submittedTaskSurvivesNavigation() async {
        let model = makeModel()
        let project = ApplePiProject(
            name: "Workspace",
            workingDirectory: URL(filePath: "/tmp/apple-pi-workspace", directoryHint: .isDirectory)
        )
        model.projects = [project]
        await model.createTask(in: project)
        let taskID = model.sessions[0].id
        model.composerText = "Run this"

        await model.sendComposer()
        await model.activate(.project(project.id))

        #expect(model.sessions.map(\.id) == [taskID])
    }

    @Test("Connected cleanup routes untouched drafts through the session service")
    func connectedCleanupDeletesTheDraftSession() async {
        let project = ApplePiProject(
            name: "Workspace",
            workingDirectory: URL(filePath: "/tmp/apple-pi-workspace", directoryHint: .isDirectory)
        )
        let actions = DraftCleanupActions(project: project)
        let model = makeModel(actions: actions)
        model.projects = [project]
        await model.createTask(in: project)
        let taskID = model.sessions[0].id

        await model.activate(.project(project.id))

        #expect(actions.deletedSessionIDs == [taskID])
        #expect(model.sessions.isEmpty)
        #expect(model.alertMessage == nil)
    }

    @Test("Connected typed drafts restore without loading a nonexistent Pi session")
    func connectedTypedDraftDoesNotLoadTranscript() async {
        let project = ApplePiProject(
            name: "Workspace",
            workingDirectory: URL(filePath: "/tmp/apple-pi-workspace", directoryHint: .isDirectory)
        )
        let actions = DraftCleanupActions(project: project)
        let model = makeModel(actions: actions)
        model.projects = [project]
        await model.createTask(in: project)
        let taskID = model.sessions[0].id
        model.composerText = "This should still be here"

        await model.activate(.project(project.id))
        await model.activate(.session(taskID))

        #expect(model.composerText == "This should still be here")
        #expect(actions.loadedTranscriptSessionIDs.isEmpty)
        #expect(model.alertMessage == nil)
    }

    @Test("Removing a project demotes its tasks without removing them")
    func removingProjectDemotesTasks() async {
        let model = makeModel()
        let project = ApplePiProject(
            name: "Workspace",
            workingDirectory: URL(filePath: "/tmp/apple-pi-workspace", directoryHint: .isDirectory)
        )
        model.projects = [project]
        await model.createTask(in: project)
        let taskID = model.sessions[0].id

        await model.removeProject(project)

        #expect(model.projects.isEmpty)
        #expect(model.sessions.map(\.id) == [taskID])
        #expect(model.sessions[0].projectID == nil)
        #expect(model.selectedProjectURL == nil)
    }

    @Test("Pinned projects sort before unpinned projects")
    func pinningProjectUpdatesStateAndOrder() async {
        let model = makeModel()
        let alpha = ApplePiProject(
            name: "Alpha",
            workingDirectory: URL(filePath: "/tmp/alpha", directoryHint: .isDirectory)
        )
        let zulu = ApplePiProject(
            name: "Zulu",
            workingDirectory: URL(filePath: "/tmp/zulu", directoryHint: .isDirectory)
        )
        model.projects = [alpha, zulu]

        await model.setProjectPinned(zulu, pinned: true)

        #expect(model.projects.map(\.id) == [zulu.id, alpha.id])
        #expect(model.projects[0].isPinned)
    }

    @Test("Editing a project updates its name and source folder")
    func editingProjectUpdatesSavedFields() async {
        let model = makeModel()
        let project = ApplePiProject(
            name: "Before",
            workingDirectory: URL(filePath: "/tmp/before", directoryHint: .isDirectory)
        )
        model.projects = [project]
        let updatedDirectory = URL(filePath: "/tmp/after", directoryHint: .isDirectory)

        await model.updateProject(project, name: "After", workingDirectory: updatedDirectory)

        #expect(model.projects[0].name == "After")
        #expect(model.projects[0].workingDirectory == updatedDirectory.standardizedFileURL)
    }

    @Test("Archiving a project archives only its active tasks")
    func archivingProjectTasksDoesNotTouchStandaloneTasks() async {
        let model = makeModel()
        let project = ApplePiProject(
            name: "Workspace",
            workingDirectory: URL(filePath: "/tmp/workspace", directoryHint: .isDirectory)
        )
        model.projects = [project]
        await model.createTask(in: project)
        let projectTaskID = model.sessions[0].id
        await model.createTask()
        let standaloneTaskID = model.sessions[0].id

        await model.archiveTasks(in: project)

        #expect(model.sessions.first { $0.id == projectTaskID }?.isArchived == true)
        #expect(model.sessions.first { $0.id == standaloneTaskID }?.isArchived == false)
    }

    @Test("Connected project archiving uses one bulk action")
    func connectedProjectArchivingIsBatched() async {
        let project = ApplePiProject(
            name: "Workspace",
            workingDirectory: URL(filePath: "/tmp/workspace", directoryHint: .isDirectory)
        )
        let actions = DraftCleanupActions(project: project)
        let model = makeModel(actions: actions)
        model.projects = [project]
        await model.createTask(in: project)
        let projectTaskID = model.sessions[0].id
        await model.createTask()
        let standaloneTaskID = model.sessions[0].id

        await model.archiveTasks(in: project)

        #expect(actions.archivedSessionIDBatches == [[projectTaskID]])
        #expect(model.sessions.first { $0.id == projectTaskID }?.isArchived == true)
        #expect(model.sessions.first { $0.id == standaloneTaskID }?.isArchived == false)
    }

    @Test("Three transcript loads resolving in reverse order commit only the latest selection")
    func staleTranscriptLoadIsIgnored() async {
        let actions = DeferredTranscriptActions()
        let model = makeModel(actions: actions)
        let first = makeSession(id: "first")
        let second = makeSession(id: "second")
        let third = makeSession(id: "third")
        model.sessions = [first, second, third]

        let firstLoad = Task { @MainActor in
            await model.activate(.session(first.id))
        }
        #expect(await actions.waitUntilRequested(first.id))

        let secondLoad = Task { @MainActor in
            await model.activate(.session(second.id))
        }
        #expect(await actions.waitUntilRequested(second.id))

        let thirdLoad = Task { @MainActor in
            await model.activate(.session(third.id))
        }
        #expect(await actions.waitUntilRequested(third.id))

        let thirdItem = makeTranscriptItem(id: "third-item", content: "Newest selection")
        actions.resume(sessionID: third.id, with: .transcript([thirdItem]))
        await thirdLoad.value
        #expect(model.transcript == [thirdItem])
        #expect(!model.isLoadingTranscript)

        let secondItem = makeTranscriptItem(id: "second-item", content: "Stale second selection")
        actions.resume(sessionID: second.id, with: .transcript([secondItem]))
        await secondLoad.value
        #expect(model.transcript == [thirdItem])
        #expect(!model.isLoadingTranscript)

        let firstItem = makeTranscriptItem(id: "first-item", content: "Stale first selection")
        actions.resume(sessionID: first.id, with: .transcript([firstItem]))
        await firstLoad.value

        #expect(model.selection == .session(third.id))
        #expect(model.transcript == [thirdItem])
        #expect(!model.isLoadingTranscript)
        #expect(model.alertMessage == nil)
    }

    @Test("Transcript mutation index survives batching and byte-aware trimming")
    func transcriptIndexAndMemoryPressureTrimmingStayConsistent() {
        let model = makeModel()
        let first = makeTranscriptItem(id: "first", content: String(repeating: "a", count: 800))
        let second = makeTranscriptItem(id: "second", content: String(repeating: "b", count: 800))
        let third = makeTranscriptItem(id: "third", content: String(repeating: "c", count: 800))
        model.replaceTranscript([first, second, third])
        model.appendTranscriptDeltas([
            first.id: "-delta",
            third.id: "-delta",
        ])
        model.completeTranscriptItems(itemIDs: [first.id, third.id])

        #expect(model.transcript[0].content.hasSuffix("-delta"))
        #expect(!model.transcript[0].isStreaming)
        #expect(model.containsTranscriptItem(id: second.id))

        model.releaseTranscriptSegmentsUnderMemoryPressure(
            retainingMostRecent: 1,
            targetByteCount: 1_500
        )

        #expect(model.transcript.map(\.id) == [third.id])
        #expect(!model.containsTranscriptItem(id: first.id))
        #expect(model.containsTranscriptItem(id: third.id))
        #expect(model.transcriptTrimmedItemCount == 2)

        model.replaceTranscript([first, second, third])
        #expect(model.transcriptTrimmedItemCount == 0)
    }

    @Test("Applying an equal snapshot does not invalidate observed session state")
    func equalSnapshotDoesNotInvalidateSessions() {
        let model = makeModel()
        model.sessions = [makeSession(id: "session")]
        let snapshot = ApplePiUISnapshot(
            projects: model.projects,
            sessions: model.sessions,
            packages: model.packages,
            runtime: model.runtime,
            inspector: model.inspector,
            commands: model.availableCommands
        )
        let didInvalidate = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.sessions
        } onChange: {
            didInvalidate.withLock { $0 = true }
        }

        model.apply(snapshot: snapshot)

        #expect(!didInvalidate.withLock { $0 })
    }

    @Test("A 1,000-session sidebar projection is reused while an existing draft grows")
    func sidebarProjectionIgnoresComposerTypingAfterNonemptyTransition() {
        let model = makeModel()
        let projects = (0..<10).map { index in
            ApplePiProject(
                name: "Project \(index)",
                workingDirectory: URL(
                    filePath: "/tmp/apple-pi-projection/project-\(index)",
                    directoryHint: .isDirectory
                )
            )
        }
        let sessions = (0..<1_000).map { index in
            ApplePiUISession(
                id: "session-\(index)",
                title: "Task \(index)",
                workingDirectory: URL(
                    filePath: "/tmp/apple-pi-projection/task-\(index)",
                    directoryHint: .isDirectory
                ),
                sessionURL: URL(filePath: "/tmp/apple-pi-projection/session-\(index).jsonl"),
                modifiedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index)),
                state: .stopped,
                isPinned: index.isMultiple(of: 19),
                isArchived: index.isMultiple(of: 13),
                wasCreatedByCLI: index.isMultiple(of: 2),
                hasUserExtensions: false,
                projectID: index.isMultiple(of: 17) ? nil : projects[index % projects.count].id
            )
        }
        model.projects = projects
        model.sessions = sessions
        model.selection = .session(sessions[1].id)

        // The first character is the only transition that changes the stored
        // nonempty-draft set. Projection work starts after that transition.
        model.composerText = "x"
        model.resetProjectionMetrics()
        let baseline = model.sidebarProjection(sortOrder: .priority)
        #expect(baseline.filteredProjects.count == projects.count)

        for _ in 0..<99 {
            model.composerText.append("x")
            _ = model.sidebarProjection(sortOrder: .priority)
        }

        #expect(model.composerText.count == 100)
        #expect(model.projectionMetrics.sidebarBuildCount == 1)
        #expect(model.projectionMetrics.projectLookupBuildCount == 1)
    }

    @Test("Search builds one result projection per query and reuses one project lookup")
    func searchProjectionReusesLookupAndIdenticalQuery() {
        let model = makeModel()
        let projects = (0..<10).map { index in
            ApplePiProject(
                name: "Project \(index)",
                workingDirectory: URL(
                    filePath: "/tmp/apple-pi-search/project-\(index)",
                    directoryHint: .isDirectory
                )
            )
        }
        model.projects = projects
        model.sessions = (0..<1_000).map { index in
            ApplePiUISession(
                id: "search-session-\(index)",
                title: "Task \(index)",
                workingDirectory: projects[index % projects.count].workingDirectory,
                sessionURL: nil,
                modifiedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index)),
                state: .stopped,
                isPinned: false,
                isArchived: false,
                wasCreatedByCLI: false,
                hasUserExtensions: false,
                projectID: projects[index % projects.count].id
            )
        }
        model.resetProjectionMetrics()

        let first = model.searchProjection(query: "Project 7")
        for _ in 0..<20 {
            _ = model.searchProjection(query: "  Project 7  ")
        }

        #expect(!first.taskResults.isEmpty)
        #expect(first.taskResults.allSatisfy { $0.context == "Project 7" })
        #expect(model.projectionMetrics.searchBuildCount == 1)
        #expect(model.projectionMetrics.projectLookupBuildCount == 1)

        let second = model.searchProjection(query: "Task 999")
        #expect(second.taskResults.first?.title == "Task 999")
        #expect(model.projectionMetrics.searchBuildCount == 2)
        #expect(model.projectionMetrics.projectLookupBuildCount == 1)
    }

    @Test("Removing a session snapshot cleans its file-backed draft attachments")
    func removedSessionSnapshotCleansDraftAttachments() async throws {
        let model = makeModel()
        let session = makeSession(id: "draft-to-remove")
        model.sessions = [session]
        model.selection = .session(session.id)
        await model.addComposerImages([ApplePiPastedImage(
            data: Data(repeating: 0x3C, count: 64 * 1_024),
            suggestedName: "draft.png",
            mimeType: "image/png"
        )])
        let attachmentURL = try #require(model.composerImages.first?.url)
        model.selection = .home
        #expect(FileManager.default.fileExists(atPath: attachmentURL.path))

        model.apply(snapshot: ApplePiUISnapshot(
            projects: [],
            sessions: [],
            packages: [],
            runtime: .checking,
            inspector: .empty
        ))

        try await TestSupport.waitUntil {
            !FileManager.default.fileExists(atPath: attachmentURL.path)
        }
    }

    @Test("Draft images stay file-backed until submission and are then cleaned up")
    func draftImagesAreFileBackedUntilSubmission() async throws {
        let project = ApplePiProject(
            name: "Workspace",
            workingDirectory: URL(filePath: "/tmp/workspace", directoryHint: .isDirectory)
        )
        let actions = DraftCleanupActions(project: project)
        let model = makeModel(actions: actions)
        model.projects = [project]
        await model.createTask(in: project)
        let original = Data(repeating: 0x4A, count: 512 * 1_024)

        await model.addComposerImages([ApplePiPastedImage(
            data: original,
            suggestedName: "original.jpg",
            mimeType: "image/jpeg"
        )])

        let draft = try #require(model.composerImages.first)
        #expect(draft.byteCount == original.count)
        #expect(FileManager.default.fileExists(atPath: draft.url.path))
        model.composerText = "Use this image"
        await model.sendComposer()

        #expect(actions.submissions.first?.images.first?.data == original)
        try await TestSupport.waitUntil {
            !FileManager.default.fileExists(atPath: draft.url.path)
        }
    }

    private func makeSession(id: String) -> ApplePiUISession {
        ApplePiUISession(
            id: id,
            title: id,
            workingDirectory: URL(filePath: "/tmp/\(id)", directoryHint: .isDirectory),
            sessionURL: URL(filePath: "/tmp/\(id).jsonl"),
            modifiedAt: .now,
            state: .stopped,
            isPinned: false,
            isArchived: false,
            wasCreatedByCLI: false,
            hasUserExtensions: false,
            projectID: nil
        )
    }

    private func makeTranscriptItem(id: String, content: String) -> ApplePiTranscriptItem {
        ApplePiTranscriptItem(
            id: id,
            role: .assistant,
            kind: .answer,
            title: nil,
            content: content,
            timestamp: .now,
            isStreaming: true,
            attachments: []
        )
    }

    private func makeModel(actions: (any ApplePiUIActions)? = nil) -> AppModel {
        let suiteName = "AppModelProjectHierarchyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: "ApplePiSkipOnboarding")
        return AppModel(defaults: defaults, actions: actions)
    }
}

@MainActor
private final class DraftCleanupActions: ApplePiUIActions {
    private let project: ApplePiProject
    private var sessions: [ApplePiUISession] = []
    private(set) var deletedSessionIDs: [String] = []
    private(set) var loadedTranscriptSessionIDs: [String] = []
    private(set) var archivedSessionIDBatches: [[String]] = []
    private(set) var submissions: [ApplePiComposerSubmission] = []

    init(project: ApplePiProject) {
        self.project = project
    }

    func perform(_ action: ApplePiAction) async throws -> ApplePiActionResult {
        switch action {
        case let .createTask(projectID):
            let session = ApplePiUISession(
                id: "draft-\(UUID().uuidString)",
                title: "New task",
                workingDirectory: project.workingDirectory,
                sessionURL: nil,
                modifiedAt: .now,
                state: .stopped,
                isPinned: false,
                isArchived: false,
                wasCreatedByCLI: false,
                hasUserExtensions: false,
                projectID: projectID
            )
            sessions.insert(session, at: 0)
            return .session(session)

        case let .mutateSession(sessionID, mutation):
            if case .moveToTrash = mutation {
                deletedSessionIDs.append(sessionID)
                sessions.removeAll { $0.id == sessionID }
            }
            return .snapshot(snapshot)

        case let .loadTranscript(sessionID):
            loadedTranscriptSessionIDs.append(sessionID)
            return .transcript([])

        case let .archiveSessions(sessionIDs, archived):
            archivedSessionIDBatches.append(sessionIDs)
            let matchingIDs = Set(sessionIDs)
            for index in sessions.indices where matchingIDs.contains(sessions[index].id) {
                sessions[index].isArchived = archived
            }
            return .snapshot(snapshot)

        case let .submit(submission, _):
            submissions.append(submission)
            return .none

        default:
            return .none
        }
    }

    private var snapshot: ApplePiUISnapshot {
        ApplePiUISnapshot(
            projects: [project],
            sessions: sessions,
            packages: [],
            runtime: .checking,
            inspector: .empty
        )
    }
}

@MainActor
private final class DeferredTranscriptActions: ApplePiUIActions {
    private var requestedSessionIDs = Set<String>()
    private var continuations: [
        String: CheckedContinuation<ApplePiActionResult, any Error>
    ] = [:]

    func perform(_ action: ApplePiAction) async throws -> ApplePiActionResult {
        guard case let .loadTranscript(sessionID) = action else { return .none }
        requestedSessionIDs.insert(sessionID)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[sessionID] = continuation
        }
    }

    func waitUntilRequested(_ sessionID: String) async -> Bool {
        for _ in 0..<1_000 {
            if requestedSessionIDs.contains(sessionID) { return true }
            await Task.yield()
        }
        return false
    }

    func resume(sessionID: String, with result: ApplePiActionResult) {
        continuations.removeValue(forKey: sessionID)?.resume(returning: result)
    }
}
