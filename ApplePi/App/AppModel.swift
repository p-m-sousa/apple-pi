import Foundation
import Dispatch
import Observation
import UserNotifications

enum ApplePiAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum ApplePiDestination: Hashable, Sendable {
    case home
    case extensions
    case project(ApplePiProjectID)
    case session(String)
}

enum ApplePiTaskState: String, Sendable {
    case stopped
    case starting
    case ready
    case generating
    case awaitingInput
    case queued
    case failed

    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .ready: "Ready"
        case .generating: "Working"
        case .awaitingInput: "Needs input"
        case .queued: "Queued"
        case .failed: "Failed"
        }
    }

    var isLive: Bool {
        switch self {
        case .starting, .ready, .generating, .awaitingInput, .queued: true
        case .stopped, .failed: false
        }
    }

    var isExecuting: Bool {
        switch self {
        case .starting, .generating: true
        case .stopped, .ready, .awaitingInput, .queued, .failed: false
        }
    }
}

enum ApplePiTaskEnvironment: String, Sendable {
    case local
    case managedWorktree

    var title: String {
        switch self {
        case .local: "Local"
        case .managedWorktree: "Worktree"
        }
    }

    var systemImage: String {
        switch self {
        case .local: "folder"
        case .managedWorktree: "arrow.triangle.branch"
        }
    }
}

struct ApplePiUISession: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var workingDirectory: URL
    var sessionURL: URL?
    var modifiedAt: Date
    var state: ApplePiTaskState
    var isPinned: Bool
    var isArchived: Bool
    var wasCreatedByCLI: Bool
    var hasUserExtensions: Bool
    var projectID: ApplePiProjectID?
    var environment: ApplePiTaskEnvironment = .local

    var projectName: String {
        let name = workingDirectory.lastPathComponent
        return name.isEmpty ? workingDirectory.path : name
    }
}

enum ApplePiTranscriptRole: String, Sendable {
    case user
    case assistant
    case system
    case extensionUI
}

enum ApplePiTranscriptKind: String, Sendable {
    case answer
    case thinking
    case tool
    case status
    case error
}

struct ApplePiAttachment: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case image
        case file
    }

    let id: String
    var kind: Kind
    var url: URL
    var name: String
    var mimeType: String?
}

struct ApplePiTranscriptItem: Identifiable, Hashable, Sendable {
    let id: String
    var role: ApplePiTranscriptRole
    var kind: ApplePiTranscriptKind
    var title: String?
    var content: String
    var timestamp: Date
    var isStreaming: Bool
    var attachments: [ApplePiAttachment]
}

struct ApplePiPastedImage: Identifiable, Hashable, Sendable {
    let id: UUID
    var data: Data
    var suggestedName: String
    var mimeType: String

    init(id: UUID = UUID(), data: Data, suggestedName: String, mimeType: String = "image/png") {
        self.id = id
        self.data = data
        self.suggestedName = suggestedName
        self.mimeType = mimeType
    }
}

struct ApplePiComposerSubmission: Hashable, Sendable {
    var text: String
    var images: [ApplePiPastedImage]
    var queueBehavior: ApplePiQueueBehavior
}

enum ApplePiQueueBehavior: String, CaseIterable, Identifiable, Sendable {
    case steer
    case followUp

    var id: String { rawValue }
    var title: String { self == .steer ? "Steer" : "Follow up" }
}

struct ApplePiComposerCommand: Identifiable, Hashable, Sendable {
    var name: String
    var detail: String
    var id: String { name }
}

struct ApplePiModelOption: Identifiable, Hashable, Sendable {
    var provider: String
    var modelID: String
    var displayName: String

    var id: String { "\(provider)/\(modelID)" }
}

struct ApplePiRuntimeOptions: Hashable, Sendable {
    var models: [ApplePiModelOption]
    var thinkingLevels: [String]

    static let empty = ApplePiRuntimeOptions(models: [], thinkingLevels: [])
}

struct ApplePiRuntimeSummary: Hashable, Sendable {
    enum Compatibility: String, Sendable {
        case checking
        case compatible
        case terminalOnly
        case unavailable
    }

    var displayName: String
    var executableURL: URL?
    var version: String?
    var source: String
    var compatibility: Compatibility
    var detail: String

    static let checking = ApplePiRuntimeSummary(
        displayName: "Pi",
        executableURL: nil,
        version: nil,
        source: "Searching",
        compatibility: .checking,
        detail: "Looking for a compatible Pi runtime…"
    )
}

struct ApplePiInspectorSnapshot: Hashable, Sendable {
    struct Branch: Identifiable, Hashable, Sendable {
        let id: String
        var title: String
        var isCurrent: Bool
    }

    struct ExtensionStatus: Identifiable, Hashable, Sendable {
        let id: String
        var name: String
        var status: String
        var isHealthy: Bool
    }

    var model: String
    var thinkingLevel: String
    var contextUsed: Int
    var contextLimit: Int
    var inputTokens: Int
    var outputTokens: Int
    var queuedMessages: Int
    var branches: [Branch]
    var extensions: [ExtensionStatus]
    var statusItems: [String: String]

    static let empty = ApplePiInspectorSnapshot(
        model: "Pi default",
        thinkingLevel: "Default",
        contextUsed: 0,
        contextLimit: 0,
        inputTokens: 0,
        outputTokens: 0,
        queuedMessages: 0,
        branches: [],
        extensions: [],
        statusItems: [:]
    )
}

enum ApplePiPackageScope: String, CaseIterable, Identifiable, Sendable {
    case global
    case project

    var id: String { rawValue }
    var title: String { self == .global ? "Global" : "Project" }
}

enum ApplePiResourceKind: String, CaseIterable, Identifiable, Sendable {
    case extensionResource = "Extension"
    case skill = "Skill"
    case prompt = "Prompt"
    case theme = "Theme"

    var id: String { rawValue }
}

struct ApplePiPackageResource: Identifiable, Hashable, Sendable {
    let id: String
    var packageSource: String
    var name: String
    var version: String?
    var scope: ApplePiPackageScope
    var kind: ApplePiResourceKind
    var isEnabled: Bool
    var isToggleable: Bool = true
    var hasUpdate: Bool
    var statusDetail: String?
    var localURL: URL?
}

struct ApplePiUISnapshot: Hashable, Sendable {
    var projects: [ApplePiProject]
    var sessions: [ApplePiUISession]
    var packages: [ApplePiPackageResource]
    var runtime: ApplePiRuntimeSummary
    var inspector: ApplePiInspectorSnapshot
    var commands: [ApplePiComposerCommand] = []
}

enum ApplePiSidebarTaskSortOrder: String, CaseIterable, Identifiable, Sendable {
    case priority
    case lastUpdated
    case manual

    var id: Self { self }

    var title: String {
        switch self {
        case .priority: "Priority"
        case .lastUpdated: "Last updated"
        case .manual: "Manual order"
        }
    }
}

struct ApplePiSidebarProjection {
    let filteredProjects: [ApplePiProject]
    let unassignedTasks: [ApplePiUISession]
    let allVisibleTasks: [ApplePiUISession]
    let archivedSessions: [ApplePiUISession]
    let sessionsByProject: [ApplePiProjectID: [ApplePiUISession]]
    let activeTaskCountByProject: [ApplePiProjectID: Int]

    init(
        projects: [ApplePiProject],
        sessions: [ApplePiUISession],
        knownProjectIDs: Set<ApplePiProjectID>,
        query rawQuery: String,
        sortOrder: ApplePiSidebarTaskSortOrder
    ) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingProjectIDs = Set<ApplePiProjectID>(projects.compactMap { project in
            guard !query.isEmpty,
                  project.name.localizedCaseInsensitiveContains(query)
                    || project.workingDirectory.path.localizedCaseInsensitiveContains(query) else {
                return nil
            }
            return project.id
        })

        var activeCounts: [ApplePiProjectID: Int] = [:]
        var groupedSessions: [ApplePiProjectID: [ApplePiUISession]] = [:]
        var matchingActiveSessions: [ApplePiUISession] = []
        var matchingArchivedSessions: [ApplePiUISession] = []
        activeCounts.reserveCapacity(knownProjectIDs.count)
        groupedSessions.reserveCapacity(knownProjectIDs.count)
        matchingActiveSessions.reserveCapacity(sessions.count)

        for session in sessions {
            let matchesListQuery = query.isEmpty
                || session.title.localizedCaseInsensitiveContains(rawQuery)
                || session.workingDirectory.path.localizedCaseInsensitiveContains(rawQuery)
            let matchesProjectQuery = query.isEmpty
                || session.title.localizedCaseInsensitiveContains(query)
                || session.workingDirectory.path.localizedCaseInsensitiveContains(query)

            if session.isArchived {
                if matchesListQuery { matchingArchivedSessions.append(session) }
                continue
            }

            if matchesListQuery { matchingActiveSessions.append(session) }
            guard let projectID = session.projectID, knownProjectIDs.contains(projectID) else { continue }
            activeCounts[projectID, default: 0] += 1
            if matchingProjectIDs.contains(projectID) || matchesProjectQuery {
                groupedSessions[projectID, default: []].append(session)
            }
        }

        for projectID in Array(groupedSessions.keys) {
            groupedSessions[projectID] = Self.ordered(
                groupedSessions[projectID] ?? [],
                by: sortOrder
            )
        }

        filteredProjects = projects.filter { project in
            query.isEmpty
                || matchingProjectIDs.contains(project.id)
                || groupedSessions[project.id]?.isEmpty == false
        }
        .sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        allVisibleTasks = Self.ordered(matchingActiveSessions, by: sortOrder)
        unassignedTasks = Self.ordered(matchingActiveSessions.filter { session in
            guard let projectID = session.projectID else { return true }
            return !knownProjectIDs.contains(projectID)
        }, by: sortOrder)
        archivedSessions = matchingArchivedSessions.sorted { $0.modifiedAt > $1.modifiedAt }
        sessionsByProject = groupedSessions
        activeTaskCountByProject = activeCounts
    }

    private static func ordered(
        _ sessions: [ApplePiUISession],
        by sortOrder: ApplePiSidebarTaskSortOrder
    ) -> [ApplePiUISession] {
        switch sortOrder {
        case .priority:
            sessions.sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.modifiedAt > rhs.modifiedAt
            }
        case .lastUpdated:
            sessions.sorted { $0.modifiedAt > $1.modifiedAt }
        case .manual:
            sessions
        }
    }
}

struct ApplePiSearchProjection {
    let queryIsEmpty: Bool
    let projectResults: [ApplePiSearchResult]
    let taskResults: [ApplePiSearchResult]

    init(
        projects: [ApplePiProject],
        sessions: [ApplePiUISession],
        projectNamesByID: [ApplePiProjectID: String],
        query: String
    ) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        queryIsEmpty = normalizedQuery.isEmpty

        projectResults = projects
            .filter { project in
                normalizedQuery.isEmpty
                    || project.name.localizedCaseInsensitiveContains(normalizedQuery)
                    || project.workingDirectory.path.localizedCaseInsensitiveContains(normalizedQuery)
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(queryIsEmpty ? 4 : 6)
            .map(ApplePiSearchResult.project)

        taskResults = sessions
            .filter { !$0.isArchived }
            .filter { session in
                let projectName = session.projectID.flatMap { projectNamesByID[$0] }
                return normalizedQuery.isEmpty
                    || session.title.localizedCaseInsensitiveContains(normalizedQuery)
                    || session.workingDirectory.path.localizedCaseInsensitiveContains(normalizedQuery)
                    || projectName?.localizedCaseInsensitiveContains(normalizedQuery) == true
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.modifiedAt > rhs.modifiedAt
            }
            .prefix(queryIsEmpty ? 6 : 10)
            .map { session in
                ApplePiSearchResult.session(
                    session,
                    projectName: session.projectID.flatMap { projectNamesByID[$0] }
                )
            }
    }
}

enum ApplePiSearchResult: Identifiable {
    case project(ApplePiProject)
    case session(ApplePiUISession, projectName: String?)

    var id: String {
        switch self {
        case let .project(project): "project-\(project.id.rawValue.uuidString)"
        case let .session(session, _): "session-\(session.id)"
        }
    }

    var title: String {
        switch self {
        case let .project(project): project.name
        case let .session(session, _): session.title
        }
    }

    var subtitle: String {
        switch self {
        case let .project(project): project.workingDirectory.path
        case let .session(session, _): session.workingDirectory.path
        }
    }

    var context: String? {
        switch self {
        case .project: nil
        case let .session(_, projectName): projectName
        }
    }

    var systemImage: String {
        switch self {
        case .project: "folder"
        case let .session(session, _): session.wasCreatedByCLI ? "terminal" : "bubble.left"
        }
    }

    var destination: ApplePiDestination {
        switch self {
        case let .project(project): .project(project.id)
        case let .session(session, _): .session(session.id)
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case let .project(project): "applepi.search-result.project.\(project.id.rawValue.uuidString)"
        case let .session(session, _): "applepi.search-result.session.\(session.id)"
        }
    }
}

struct ApplePiProjectionMetrics: Equatable, Sendable {
    var sidebarBuildCount = 0
    var searchBuildCount = 0
    var projectLookupBuildCount = 0
}

struct ApplePiTerminalRequest: Hashable, Identifiable, Sendable {
    enum Purpose: String, Sendable {
        case session
        case configuration
        case extensionFallback
    }

    let id: UUID
    var title: String
    var executable: String
    var arguments: [String]
    var environment: [String]
    var currentDirectory: String?
    var purpose: Purpose

    init(
        id: UUID = UUID(),
        title: String,
        executable: String,
        arguments: [String] = [],
        environment: [String] = [],
        currentDirectory: String? = nil,
        purpose: Purpose
    ) {
        self.id = id
        self.title = title
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.purpose = purpose
    }
}

struct ApplePiExtensionPrompt: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case select(options: [String])
        case confirm
        case input
        case editor
    }

    let id: String
    var title: String
    var message: String?
    var kind: Kind
    var defaultValue: String
    var placeholder: String?
}

/// Presentation-only structure for Pi's string-based `ui.select` protocol.
/// The original value remains intact so ApplePi always returns exactly the
/// option Pi supplied, even when it can present numbered choices more richly.
struct ApplePiExtensionChoice: Hashable, Sendable {
    let rawValue: String
    let title: String
    let detail: String?
    let isRecommended: Bool

    init(rawValue: String) {
        self.rawValue = rawValue

        var body = Self.removingOrdinalPrefix(from: rawValue)
        var detail: String?
        if let separator = body.range(of: " — ") {
            let candidate = body[separator.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            detail = candidate.isEmpty ? nil : candidate
            body = String(body[..<separator.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let recommendation = " (Recommended)"
        if body.lowercased().hasSuffix(recommendation.lowercased()) {
            body.removeLast(recommendation.count)
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            isRecommended = true
        } else {
            isRecommended = false
        }

        title = body.isEmpty ? rawValue : body
        self.detail = detail
    }

    private static func removingOrdinalPrefix(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let period = trimmed.firstIndex(of: ".") else { return trimmed }
        let prefix = trimmed[..<period]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return trimmed }
        return trimmed[trimmed.index(after: period)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ApplePiExportFormat: String, Sendable {
    case html
    case rawJSONL
}

enum ApplePiSessionMutation: Sendable {
    case rename(String)
    case pin(Bool)
    case archive(Bool)
    case moveToProject(ApplePiProjectID?)
    case fork
    case clone
    case export(ApplePiExportFormat)
    case reveal
    case moveToTrash
}

enum ApplePiProjectMutation: Sendable {
    case rename(String)
    case update(name: String, workingDirectory: URL)
    case pin(Bool)
    case remove
}

enum ApplePiAction: Sendable {
    case initialSnapshot
    case refresh
    case createTask(projectID: ApplePiProjectID?)
    case createProject(name: String, workingDirectory: URL)
    case mutateProject(id: ApplePiProjectID, mutation: ApplePiProjectMutation)
    case createPermanentWorktree(
        projectID: ApplePiProjectID,
        branchName: String,
        destination: URL
    )
    case loadTranscript(sessionID: String)
    case submit(ApplePiComposerSubmission, sessionID: String)
    case abort(sessionID: String)
    case stopRuntime(sessionID: String)
    case mutateSession(sessionID: String, mutation: ApplePiSessionMutation)
    case archiveSessions(sessionIDs: [String], archived: Bool)
    case installPackage(source: String, scope: ApplePiPackageScope, projectURL: URL?)
    case updatePackage(id: String)
    case removePackage(id: String)
    case setResourceEnabled(id: String, enabled: Bool)
    case installLocalPackage(URL, scope: ApplePiPackageScope, projectURL: URL?)
    case reloadLocalPackage(id: String)
    case extensionPromptResponse(id: String, value: String?, accepted: Bool)
    case terminalRequest(purpose: ApplePiTerminalRequest.Purpose, sessionID: String?)
    case navigateBranch(sessionID: String, branchID: String)
    case refreshRuntimeOptions(sessionID: String)
    case setModel(sessionID: String, provider: String, modelID: String)
    case setThinkingLevel(sessionID: String, level: String)
}

enum ApplePiActionResult: Sendable {
    case none
    case snapshot(ApplePiUISnapshot)
    case session(ApplePiUISession)
    case project(ApplePiProject)
    case transcript([ApplePiTranscriptItem])
    case packages([ApplePiPackageResource])
    case terminal(ApplePiTerminalRequest)
    case runtimeOptions(ApplePiRuntimeOptions)
}

@MainActor
protocol ApplePiUIActions: AnyObject {
    func perform(_ action: ApplePiAction) async throws -> ApplePiActionResult
}

/// View-facing state only. Runtime and persistence layers integrate by assigning an
/// `ApplePiUIActions` adapter; views never reach into service implementations directly.
@MainActor
@Observable
final class AppModel {
    private struct SidebarProjectionCacheKey: Equatable {
        var revision: UInt64
        var query: String
        var sortOrder: ApplePiSidebarTaskSortOrder
    }

    private struct SearchProjectionCacheKey: Equatable {
        var revision: UInt64
        var query: String
    }

    private struct ProjectLookup {
        var ids: Set<ApplePiProjectID>
        var namesByID: [ApplePiProjectID: String]
    }

    private struct ComposerDraft {
        var text: String
        var images: [DraftAttachmentFile]
        var queueBehavior: ApplePiQueueBehavior

        var isEmpty: Bool {
            text.isEmpty && images.isEmpty
        }
    }

    @ObservationIgnored var actions: (any ApplePiUIActions)?

    var selection: ApplePiDestination = .home {
        willSet {
            guard newValue != selection else { return }
            storeComposerDraft(for: selection)
        }
        didSet {
            guard oldValue != selection else { return }
            selectionGeneration &+= 1
            cancelSelectionScopedLoads()
            restoreComposerDraft(for: selection)
        }
    }
    var projects: [ApplePiProject] = [] {
        didSet {
            guard projects != oldValue else { return }
            invalidateNavigationProjections(projectsChanged: true)
        }
    }
    var sessions: [ApplePiUISession] = [] {
        didSet {
            guard sessions != oldValue else { return }
            invalidateNavigationProjections(projectsChanged: false)
        }
    }
    private(set) var transcript: [ApplePiTranscriptItem] = []
    var packages: [ApplePiPackageResource] = []
    var runtime: ApplePiRuntimeSummary = .checking
    var inspector: ApplePiInspectorSnapshot = .empty
    var availableCommands: [ApplePiComposerCommand] = [
        .init(name: "/model", detail: "Choose model"),
        .init(name: "/thinking", detail: "Set thinking level"),
        .init(name: "/compact", detail: "Compact context"),
        .init(name: "/tree", detail: "Browse session tree"),
        .init(name: "/fork", detail: "Fork session"),
        .init(name: "/name", detail: "Name session"),
        .init(name: "/reload", detail: "Reload resources")
    ]
    var runtimeOptions: ApplePiRuntimeOptions = .empty
    var extensionPrompt: ApplePiExtensionPrompt?

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            cachedSidebarProjection = nil
        }
    }
    var composerText = "" {
        didSet { updateSelectedTextDraftMarker() }
    }
    var composerImages: [DraftAttachmentFile] = []
    var queueBehavior: ApplePiQueueBehavior = .steer
    var isLoadingTranscript = false
    var isLoadingRuntimeOptions = false
    private(set) var transcriptTrimmedItemCount = 0
    var isRefreshing = false
    var inspectorPresented = true
    var projectImporterPresented = false
    var pendingTerminal: ApplePiTerminalRequest?
    @ObservationIgnored private(set) var terminalRequests: [UUID: ApplePiTerminalRequest] = [:]
    var alertMessage: String?
    private(set) var selectedProjectID: ApplePiProjectID?

    var selectedProjectURL: URL? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }?.workingDirectory
    }

    var appearance: ApplePiAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    var maximumConcurrentTurns: Int {
        didSet { defaults.set(maximumConcurrentTurns, forKey: Keys.maximumConcurrentTurns) }
    }
    var idleRuntimeGraceSeconds: Int {
        didSet { defaults.set(idleRuntimeGraceSeconds, forKey: Keys.idleRuntimeGraceSeconds) }
    }
    var advancedRuntimeOverride = false {
        didSet { defaults.set(advancedRuntimeOverride, forKey: Keys.advancedRuntimeOverride) }
    }
    var savedExecutablePath: String {
        didSet { defaults.set(savedExecutablePath, forKey: Keys.savedExecutablePath) }
    }
    var showSetup: Bool

    private let defaults: UserDefaults
    private var didBootstrap = false
    @ObservationIgnored private var composerDrafts: [String: ComposerDraft] = [:]
    @ObservationIgnored private var draftAttachmentCache: DraftAttachmentCache? = try? DraftAttachmentCache()
    private(set) var textDraftSessionIDs = Set<String>()
    @ObservationIgnored private var unsubmittedTaskIDs = Set<String>()
    @ObservationIgnored private var transcriptIndexByID: [String: Int] = [:]
    @ObservationIgnored private var selectionGeneration: UInt64 = 0
    @ObservationIgnored private var transcriptLoadTask: Task<ApplePiActionResult, any Error>?
    @ObservationIgnored private var runtimeOptionsLoadTask: Task<ApplePiActionResult, any Error>?
    @ObservationIgnored private var activeTranscriptLoadID: UUID?
    @ObservationIgnored private var activeRuntimeOptionsLoadID: UUID?
    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var navigationProjectionRevision: UInt64 = 0
    @ObservationIgnored private var cachedProjectLookup: ProjectLookup?
    @ObservationIgnored private var cachedSidebarProjection: (
        key: SidebarProjectionCacheKey,
        value: ApplePiSidebarProjection
    )?
    @ObservationIgnored private var cachedSearchProjection: (
        key: SearchProjectionCacheKey,
        value: ApplePiSearchProjection
    )?
    @ObservationIgnored private(set) var projectionMetrics = ApplePiProjectionMetrics()

    private enum Keys {
        static let appearance = "ApplePiAppearance"
        static let maximumConcurrentTurns = "ApplePiMaximumConcurrentTurns"
        static let idleRuntimeGraceSeconds = "ApplePiIdleRuntimeGraceSeconds"
        static let advancedRuntimeOverride = "ApplePiAdvancedRuntimeOverride"
        static let savedExecutablePath = "ApplePiSavedExecutablePath"
        static let completedSetup = "ApplePiCompletedSetup"
        static let skipOnboarding = "ApplePiSkipOnboarding"
    }

    init(defaults: UserDefaults = .standard, actions: (any ApplePiUIActions)? = nil) {
        self.defaults = defaults
        self.actions = actions
        self.appearance = ApplePiAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        let maximum = defaults.integer(forKey: Keys.maximumConcurrentTurns)
        self.maximumConcurrentTurns = maximum == 0 ? 2 : min(maximum, 8)
        let grace = defaults.integer(forKey: Keys.idleRuntimeGraceSeconds)
        self.idleRuntimeGraceSeconds = grace == 0 ? 30 : grace
        self.advancedRuntimeOverride = defaults.bool(forKey: Keys.advancedRuntimeOverride)
        self.savedExecutablePath = defaults.string(forKey: Keys.savedExecutablePath) ?? ""

        let arguments = ProcessInfo.processInfo.arguments
        let skipOnboarding = arguments.contains("--skip-onboarding") || defaults.bool(forKey: Keys.skipOnboarding)
        self.showSetup = !skipOnboarding && !defaults.bool(forKey: Keys.completedSetup)
        installMemoryPressureHandler()
    }

    var selectedSession: ApplePiUISession? {
        guard case let .session(id) = selection else { return nil }
        return sessions.first { $0.id == id }
    }

    var selectedProject: ApplePiProject? {
        guard case let .project(id) = selection else { return nil }
        return projects.first { $0.id == id }
    }

    func project(for session: ApplePiUISession) -> ApplePiProject? {
        guard let projectID = session.projectID else { return nil }
        return projects.first { $0.id == projectID }
    }

    /// Returns the most recent pure sidebar projection. The cache is deliberately
    /// observation-ignored; `navigationProjectionRevision` is the lightweight
    /// dependency views observe when projects or sessions materially change.
    func sidebarProjection(
        sortOrder: ApplePiSidebarTaskSortOrder
    ) -> ApplePiSidebarProjection {
        let revision = navigationProjectionRevision
        let key = SidebarProjectionCacheKey(
            revision: revision,
            query: searchText,
            sortOrder: sortOrder
        )
        if let cachedSidebarProjection, cachedSidebarProjection.key == key {
            return cachedSidebarProjection.value
        }

        let lookup = projectLookup()
        let projection = ApplePiSidebarProjection(
            projects: projects,
            sessions: sessions,
            knownProjectIDs: lookup.ids,
            query: searchText,
            sortOrder: sortOrder
        )
        projectionMetrics.sidebarBuildCount += 1
        cachedSidebarProjection = (key, projection)
        return projection
    }

    /// Search results are cached by normalized query and source revision. The
    /// project-name lookup is shared with sidebar projection work and rebuilt
    /// only when the project collection changes.
    func searchProjection(query: String) -> ApplePiSearchProjection {
        let revision = navigationProjectionRevision
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SearchProjectionCacheKey(revision: revision, query: normalizedQuery)
        if let cachedSearchProjection, cachedSearchProjection.key == key {
            return cachedSearchProjection.value
        }

        let projection = ApplePiSearchProjection(
            projects: projects,
            sessions: sessions,
            projectNamesByID: projectLookup().namesByID,
            query: normalizedQuery
        )
        projectionMetrics.searchBuildCount += 1
        cachedSearchProjection = (key, projection)
        return projection
    }

    /// Internal deterministic instrumentation used by projection acceptance
    /// tests. Production code never needs to reset or sample these counters.
    func resetProjectionMetrics() {
        projectionMetrics = ApplePiProjectionMetrics()
        cachedProjectLookup = nil
        cachedSidebarProjection = nil
        cachedSearchProjection = nil
    }

    var hasLiveTasks: Bool { sessions.contains { $0.state.isLive } }

    var canSend: Bool {
        selectedSession != nil
            && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty)
    }

    func hasTextDraft(for sessionID: String) -> Bool {
        textDraftSessionIDs.contains(sessionID)
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await refresh(initial: true)
    }

    func refresh(initial: Bool = false) async {
        guard let actions else {
            runtime = ApplePiRuntimeSummary(
                displayName: "Pi",
                executableURL: nil,
                version: nil,
                source: "Not connected",
                compatibility: .unavailable,
                detail: "The native service adapter has not been connected."
            )
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await actions.perform(initial ? .initialSnapshot : .refresh)
            consume(result)
        } catch {
            present(error)
        }
    }

    func activate(
        _ destination: ApplePiDestination,
        departingFrom previousDestination: ApplePiDestination? = nil
    ) async {
        let departure = previousDestination ?? selection
        if selection != destination {
            selection = destination
        }
        if departure != destination {
            await discardUntouchedTaskIfNeeded(departure)
        }

        // Selection changes can overlap while an automatic draft cleanup is
        // awaiting the service. Do not let an older activation overwrite the
        // detail state for the destination the user chose most recently.
        guard selection == destination else { return }

        switch destination {
        case .home:
            selectedProjectID = nil
            return
        case .extensions:
            await refresh()
            return
        case let .project(id):
            selectedProjectID = projects.contains { $0.id == id } ? id : nil
            replaceTranscript([])
            transcriptTrimmedItemCount = 0
            return
        case let .session(id):
            let session = sessions.first { $0.id == id }
            selectedProjectID = session.flatMap(project(for:))?.id
            transcriptTrimmedItemCount = 0
            if runtimeOptions != .empty {
                runtimeOptions = .empty
            }
            if unsubmittedTaskIDs.contains(id) {
                replaceTranscript([])
                return
            }
            await loadTranscript(for: id, generation: selectionGeneration)
        }
    }

    func createTask(in project: ApplePiProject? = nil) async {
        guard let actions else {
            let id = "draft-\(UUID().uuidString)"
            let cwd = project?.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            let session = ApplePiUISession(
                id: id,
                title: "New task",
                workingDirectory: cwd,
                sessionURL: nil,
                modifiedAt: .now,
                state: .stopped,
                isPinned: false,
                isArchived: false,
                wasCreatedByCLI: false,
                hasUserExtensions: false,
                projectID: project?.id
            )
            sessions.insert(session, at: 0)
            unsubmittedTaskIDs.insert(id)
            selection = .session(id)
            selectedProjectID = project?.id
            replaceTranscript([])
            if runtimeOptions != .empty { runtimeOptions = .empty }
            return
        }
        do {
            consume(try await actions.perform(.createTask(projectID: project?.id)))
        } catch {
            present(error)
        }
    }

    func addProject(workingDirectory: URL, name: String? = nil) async {
        let normalizedDirectory = workingDirectory.standardizedFileURL
        let fallbackName = normalizedDirectory.lastPathComponent.isEmpty
            ? normalizedDirectory.path
            : normalizedDirectory.lastPathComponent
        let projectName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackName

        guard let actions else {
            if let existing = projects.first(where: {
                $0.workingDirectory.resolvingSymlinksInPath().path
                    == normalizedDirectory.resolvingSymlinksInPath().path
            }) {
                selection = .project(existing.id)
                selectedProjectID = existing.id
                return
            }
            let project = ApplePiProject(name: projectName, workingDirectory: normalizedDirectory)
            projects.append(project)
            sortProjects()
            selection = .project(project.id)
            selectedProjectID = project.id
            replaceTranscript([])
            transcriptTrimmedItemCount = 0
            return
        }

        do {
            consume(try await actions.perform(.createProject(
                name: projectName,
                workingDirectory: normalizedDirectory
            )))
        } catch {
            present(error)
        }
    }

    func renameProject(_ project: ApplePiProject, to name: String) async {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        guard let actions else {
            guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
            projects[index].name = normalizedName
            projects[index].updatedAt = .now
            sortProjects()
            return
        }
        do {
            consume(try await actions.perform(.mutateProject(
                id: project.id,
                mutation: .rename(normalizedName)
            )))
        } catch {
            present(error)
        }
    }

    func updateProject(
        _ project: ApplePiProject,
        name: String,
        workingDirectory: URL
    ) async {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        let normalizedDirectory = workingDirectory.standardizedFileURL
        guard let actions else {
            guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
            projects[index].name = normalizedName
            projects[index].workingDirectory = normalizedDirectory
            projects[index].updatedAt = .now
            sortProjects()
            return
        }
        do {
            consume(try await actions.perform(.mutateProject(
                id: project.id,
                mutation: .update(
                    name: normalizedName,
                    workingDirectory: normalizedDirectory
                )
            )))
        } catch {
            present(error)
        }
    }

    func setProjectPinned(_ project: ApplePiProject, pinned: Bool) async {
        guard let actions else {
            guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
            projects[index].isPinned = pinned
            projects[index].updatedAt = .now
            sortProjects()
            return
        }
        do {
            consume(try await actions.perform(.mutateProject(
                id: project.id,
                mutation: .pin(pinned)
            )))
        } catch {
            present(error)
        }
    }

    func archiveTasks(in project: ApplePiProject) async {
        let sessionIDs = sessions.compactMap { session in
            session.projectID == project.id && !session.isArchived ? session.id : nil
        }
        guard !sessionIDs.isEmpty else { return }

        guard let actions else {
            let matchingIDs = Set(sessionIDs)
            for index in sessions.indices where matchingIDs.contains(sessions[index].id) {
                sessions[index].isArchived = true
            }
            if case let .session(selectedID) = selection, matchingIDs.contains(selectedID) {
                selection = .home
            }
            return
        }

        do {
            consume(try await actions.perform(.archiveSessions(
                sessionIDs: sessionIDs,
                archived: true
            )))
        } catch {
            present(error)
        }
    }

    func createPermanentWorktree(
        for project: ApplePiProject,
        branchName: String,
        destination: URL
    ) async -> Bool {
        let normalizedBranchName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBranchName.isEmpty else { return false }
        guard let actions else {
            alertMessage = "Connect the native service before creating a permanent worktree."
            return false
        }
        do {
            consume(try await actions.perform(.createPermanentWorktree(
                projectID: project.id,
                branchName: normalizedBranchName,
                destination: destination.standardizedFileURL
            )))
            return true
        } catch {
            present(error)
            return false
        }
    }

    func removeProject(_ project: ApplePiProject) async {
        guard let actions else {
            projects.removeAll { $0.id == project.id }
            for index in sessions.indices where sessions[index].projectID == project.id {
                sessions[index].projectID = nil
            }
            if selection == .project(project.id) { selection = .home }
            if selectedProjectID == project.id { selectedProjectID = nil }
            return
        }
        do {
            consume(try await actions.perform(.mutateProject(id: project.id, mutation: .remove)))
        } catch {
            present(error)
        }
    }

    func move(_ session: ApplePiUISession, to project: ApplePiProject?) async {
        await mutate(session, .moveToProject(project?.id))
        if selection == .session(session.id) {
            selectedProjectID = project?.id
        }
    }

    func sendComposer() async {
        guard canSend, let session = selectedSession else { return }
        let draftImages = composerImages
        let materializedImages: [ApplePiPastedImage]
        do {
            materializedImages = try await materializeDraftAttachments(draftImages)
        } catch {
            present(error)
            return
        }
        let submission = ApplePiComposerSubmission(
            text: composerText,
            images: materializedImages,
            queueBehavior: queueBehavior
        )
        unsubmittedTaskIDs.remove(session.id)
        composerDrafts.removeValue(forKey: session.id)
        composerText = ""
        composerImages = []

        let optimistic = ApplePiTranscriptItem(
            id: "local-\(UUID().uuidString)",
            role: .user,
            kind: .answer,
            title: nil,
            content: submission.text,
            timestamp: .now,
            isStreaming: false,
            attachments: []
        )
        upsertTranscriptItem(optimistic)

        guard let actions else {
            removeDraftAttachments(draftImages)
            upsertTranscriptItem(ApplePiTranscriptItem(
                id: "local-error-\(UUID().uuidString)",
                role: .system,
                kind: .error,
                title: "Pi runtime unavailable",
                content: "Connect the native service adapter before sending this task.",
                timestamp: .now,
                isStreaming: false,
                attachments: []
            ))
            return
        }
        do {
            consume(try await actions.perform(.submit(submission, sessionID: session.id)))
            removeDraftAttachments(draftImages)
        } catch {
            composerText = submission.text
            composerImages = draftImages
            present(error)
        }
    }

    func addComposerImages(_ images: [ApplePiPastedImage]) async {
        guard !images.isEmpty else { return }
        guard let draftAttachmentCache else {
            present(DraftAttachmentCacheError.unavailable)
            return
        }
        var stored: [DraftAttachmentFile] = []
        do {
            for image in images {
                try Task.checkCancellation()
                stored.append(try await draftAttachmentCache.store(
                    data: image.data,
                    suggestedName: image.suggestedName,
                    mimeType: image.mimeType
                ))
            }
            composerImages.append(contentsOf: stored)
        } catch {
            for attachment in stored { try? await draftAttachmentCache.remove(attachment) }
            present(error)
        }
    }

    func removeComposerImage(_ attachment: DraftAttachmentFile) {
        composerImages.removeAll { $0.id == attachment.id }
        guard let draftAttachmentCache else { return }
        Task { try? await draftAttachmentCache.remove(attachment) }
    }

    func abortSelectedTask() async {
        guard let id = selectedSession?.id, let actions else { return }
        do { consume(try await actions.perform(.abort(sessionID: id))) }
        catch { present(error) }
    }

    func stopSelectedRuntime() async {
        guard let id = selectedSession?.id, let actions else { return }
        do { consume(try await actions.perform(.stopRuntime(sessionID: id))) }
        catch { present(error) }
    }

    func mutate(_ session: ApplePiUISession, _ mutation: ApplePiSessionMutation) async {
        guard let actions else {
            applyLocalMutation(sessionID: session.id, mutation)
            return
        }
        do {
            consume(try await actions.perform(.mutateSession(sessionID: session.id, mutation: mutation)))
            if case .moveToTrash = mutation {
                removeComposerDraft(for: session.id)
            }
        }
        catch { present(error) }
    }

    func installPackage(source: String, scope: ApplePiPackageScope) async {
        guard let actions else { return }
        do {
            consume(try await actions.perform(.installPackage(
                source: source,
                scope: scope,
                projectURL: scope == .project ? selectedProjectURL : nil
            )))
        } catch { present(error) }
    }

    func installLocalPackage(_ url: URL, scope: ApplePiPackageScope) async {
        guard let actions else { return }
        do {
            consume(try await actions.perform(.installLocalPackage(
                url,
                scope: scope,
                projectURL: scope == .project ? selectedProjectURL : nil
            )))
        } catch { present(error) }
    }

    func updatePackage(_ package: ApplePiPackageResource) async {
        guard let actions else { return }
        do { consume(try await actions.perform(.updatePackage(id: package.id))) }
        catch { present(error) }
    }

    func removePackage(_ package: ApplePiPackageResource) async {
        guard let actions else { return }
        do { consume(try await actions.perform(.removePackage(id: package.id))) }
        catch { present(error) }
    }

    func setPackage(_ package: ApplePiPackageResource, enabled: Bool) async {
        guard let actions else {
            if let index = packages.firstIndex(where: { $0.id == package.id }) {
                packages[index].isEnabled = enabled
            }
            return
        }
        do { consume(try await actions.perform(.setResourceEnabled(id: package.id, enabled: enabled))) }
        catch { present(error) }
    }

    func reloadLocalPackage(_ package: ApplePiPackageResource) async {
        guard let actions else { return }
        do { consume(try await actions.perform(.reloadLocalPackage(id: package.id))) }
        catch { present(error) }
    }

    func requestTerminal(
        _ purpose: ApplePiTerminalRequest.Purpose,
        sessionID: String? = nil
    ) async -> ApplePiTerminalRequest? {
        if let actions {
            do {
                if case let .terminal(request) = try await actions.perform(.terminalRequest(
                    purpose: purpose,
                    sessionID: sessionID
                )) {
                    terminalRequests[request.id] = request
                    pendingTerminal = request
                    return request
                }
            } catch { present(error) }
        }

        guard let executable = runtime.executableURL?.path ?? (savedExecutablePath.isEmpty ? nil : savedExecutablePath) else {
            return nil
        }
        let arguments: [String]
        switch purpose {
        case .configuration:
            arguments = ["config"]
        case .session, .extensionFallback:
            if let sessionID, let session = sessions.first(where: { $0.id == sessionID }), let sessionURL = session.sessionURL {
                arguments = ["--session", sessionURL.path]
            } else {
                arguments = []
            }
        }
        let request = ApplePiTerminalRequest(
            title: purpose == .configuration ? "Pi Configuration" : "Pi Terminal",
            executable: executable,
            arguments: arguments,
            currentDirectory: selectedSession?.workingDirectory.path ?? selectedProjectURL?.path,
            purpose: purpose
        )
        terminalRequests[request.id] = request
        pendingTerminal = request
        return request
    }

    func terminalRequest(id: UUID) -> ApplePiTerminalRequest? {
        terminalRequests[id]
    }

    func releaseTerminalRequest(id: UUID) {
        terminalRequests.removeValue(forKey: id)
    }

    func respondToExtensionPrompt(value: String?, accepted: Bool) async {
        guard let prompt = extensionPrompt else { return }
        extensionPrompt = nil
        guard let actions else { return }
        do {
            consume(try await actions.perform(.extensionPromptResponse(
                id: prompt.id,
                value: value,
                accepted: accepted
            )))
        } catch { present(error) }
    }

    func navigate(to branchID: String) async {
        guard let id = selectedSession?.id, let actions else { return }
        do { consume(try await actions.perform(.navigateBranch(sessionID: id, branchID: branchID))) }
        catch { present(error) }
    }

    func refreshRuntimeOptions() async {
        guard let sessionID = selectedSession?.id, let actions else { return }
        let generation = selectionGeneration
        runtimeOptionsLoadTask?.cancel()
        let requestID = UUID()
        activeRuntimeOptionsLoadID = requestID
        isLoadingRuntimeOptions = true
        let task = Task {
            try await actions.perform(.refreshRuntimeOptions(sessionID: sessionID))
        }
        runtimeOptionsLoadTask = task
        defer { finishRuntimeOptionsLoad(requestID: requestID) }
        do {
            let result = try await task.value
            guard isCurrentSession(sessionID, generation: generation),
                  activeRuntimeOptionsLoadID == requestID else { return }
            consume(result)
        } catch is CancellationError {
            return
        } catch {
            if isCurrentSession(sessionID, generation: generation),
               activeRuntimeOptionsLoadID == requestID {
                present(error)
            }
        }
    }

    func selectModel(_ option: ApplePiModelOption) async {
        guard let sessionID = selectedSession?.id, let actions else { return }
        let generation = selectionGeneration
        do {
            let result = try await actions.perform(.setModel(
                sessionID: sessionID,
                provider: option.provider,
                modelID: option.modelID
            ))
            guard isCurrentSession(sessionID, generation: generation) else { return }
            consume(result)
        } catch is CancellationError {
            return
        } catch {
            if isCurrentSession(sessionID, generation: generation) {
                present(error)
            }
        }
    }

    func selectThinkingLevel(_ level: String) async {
        guard let sessionID = selectedSession?.id, let actions else { return }
        let generation = selectionGeneration
        do {
            let result = try await actions.perform(.setThinkingLevel(sessionID: sessionID, level: level))
            guard isCurrentSession(sessionID, generation: generation) else { return }
            consume(result)
        } catch is CancellationError {
            return
        } catch {
            if isCurrentSession(sessionID, generation: generation) {
                present(error)
            }
        }
    }

    func reloadFullTranscript() async {
        guard let sessionID = selectedSession?.id else { return }
        await loadTranscript(for: sessionID, generation: selectionGeneration)
    }

    private func loadTranscript(for sessionID: String, generation: UInt64) async {
        guard let actions, isCurrentSession(sessionID, generation: generation) else { return }
        transcriptLoadTask?.cancel()
        let requestID = UUID()
        activeTranscriptLoadID = requestID
        isLoadingTranscript = true
        let task = Task {
            try await actions.perform(.loadTranscript(sessionID: sessionID))
        }
        transcriptLoadTask = task
        defer { finishTranscriptLoad(requestID: requestID) }

        do {
            let result = try await task.value
            guard isCurrentSession(sessionID, generation: generation),
                  activeTranscriptLoadID == requestID else { return }
            consume(result)
        } catch is CancellationError {
            return
        } catch {
            if isCurrentSession(sessionID, generation: generation),
               activeTranscriptLoadID == requestID {
                present(error)
            }
        }
    }

    private func isCurrentSession(_ sessionID: String, generation: UInt64) -> Bool {
        selectionGeneration == generation && selection == .session(sessionID)
    }

    private func finishTranscriptLoad(requestID: UUID) {
        guard activeTranscriptLoadID == requestID else { return }
        activeTranscriptLoadID = nil
        transcriptLoadTask = nil
        isLoadingTranscript = false
    }

    private func finishRuntimeOptionsLoad(requestID: UUID) {
        guard activeRuntimeOptionsLoadID == requestID else { return }
        activeRuntimeOptionsLoadID = nil
        runtimeOptionsLoadTask = nil
        isLoadingRuntimeOptions = false
    }

    private func cancelSelectionScopedLoads() {
        transcriptLoadTask?.cancel()
        transcriptLoadTask = nil
        activeTranscriptLoadID = nil
        runtimeOptionsLoadTask?.cancel()
        runtimeOptionsLoadTask = nil
        activeRuntimeOptionsLoadID = nil
        if isLoadingTranscript { isLoadingTranscript = false }
        if isLoadingRuntimeOptions { isLoadingRuntimeOptions = false }
    }

    /// Drops only rebuildable, already-rendered history. Pi's JSONL session remains
    /// authoritative and the transcript surface offers an explicit reload action.
    func releaseTranscriptSegmentsUnderMemoryPressure(
        retainingMostRecent minimumRetainedCount: Int = 1,
        targetByteCount: Int = 32 * 1_024 * 1_024
    ) {
        let countToKeep = min(transcript.count, max(1, minimumRetainedCount))
        guard transcript.count > countToKeep else { return }

        var estimatedBytes = transcript.reduce(into: 0) { total, item in
            total += estimatedTranscriptByteCount(item)
        }
        let targetBytes = max(0, targetByteCount)
        guard estimatedBytes > targetBytes else { return }

        var firstRetainedIndex = 0
        let maximumRemovableCount = transcript.count - countToKeep
        while firstRetainedIndex < maximumRemovableCount, estimatedBytes > targetBytes {
            estimatedBytes -= estimatedTranscriptByteCount(transcript[firstRetainedIndex])
            firstRetainedIndex += 1
        }
        guard firstRetainedIndex > 0 else { return }

        let removedCount = firstRetainedIndex
        replaceTranscript(Array(transcript.dropFirst(removedCount)), resetTrimmedCount: false)
        transcriptTrimmedItemCount += removedCount
    }

    private func estimatedTranscriptByteCount(_ item: ApplePiTranscriptItem) -> Int {
        var total = 256
        total += item.id.utf8.count
        total += item.title?.utf8.count ?? 0
        total += item.content.utf8.count
        for attachment in item.attachments {
            total += 128
            total += attachment.id.utf8.count
            total += attachment.name.utf8.count
            total += attachment.mimeType?.utf8.count ?? 0
            total += attachment.url.absoluteString.utf8.count
        }
        return total
    }

    func finishSetup() {
        defaults.set(true, forKey: Keys.completedSetup)
        showSetup = false
    }

    func resetSetup() {
        defaults.set(false, forKey: Keys.completedSetup)
        showSetup = true
    }

    func requestNotificationPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            present(error)
            return false
        }
    }

    func apply(snapshot: ApplePiUISnapshot) {
        var incomingProjects = snapshot.projects
        incomingProjects.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        if projects != incomingProjects { projects = incomingProjects }
        if sessions != snapshot.sessions { sessions = snapshot.sessions }
        let sessionIDs = Set(sessions.map(\.id))
        unsubmittedTaskIDs.formIntersection(sessionIDs)
        let retainedTextDraftSessionIDs = textDraftSessionIDs.intersection(sessionIDs)
        if textDraftSessionIDs != retainedTextDraftSessionIDs {
            textDraftSessionIDs = retainedTextDraftSessionIDs
        }
        if packages != snapshot.packages { packages = snapshot.packages }
        if runtime != snapshot.runtime { runtime = snapshot.runtime }
        if inspector != snapshot.inspector { inspector = snapshot.inspector }
        if !snapshot.commands.isEmpty, availableCommands != snapshot.commands {
            availableCommands = snapshot.commands
        }
        if case let .session(id) = selection, !sessions.contains(where: { $0.id == id }) {
            selection = .home
            selectedProjectID = nil
            replaceTranscript([])
            transcriptTrimmedItemCount = 0
        }
        if case let .project(id) = selection, !projects.contains(where: { $0.id == id }) {
            selection = .home
            selectedProjectID = nil
        }
        switch selection {
        case let .project(id):
            let projectID = projects.contains { $0.id == id } ? id : nil
            if selectedProjectID != projectID { selectedProjectID = projectID }
        case let .session(id):
            let projectID = sessions.first(where: { $0.id == id }).flatMap(project(for:))?.id
            if selectedProjectID != projectID { selectedProjectID = projectID }
        case .home:
            if selectedProjectID != nil { selectedProjectID = nil }
        case .extensions:
            if let selectedProjectID, !projects.contains(where: { $0.id == selectedProjectID }) {
                self.selectedProjectID = nil
            }
        }
        if composerDrafts.keys.contains(where: { !sessionIDs.contains($0) }) {
            var retainedDrafts: [String: ComposerDraft] = [:]
            var removedAttachments: [DraftAttachmentFile] = []
            retainedDrafts.reserveCapacity(composerDrafts.count)
            for (sessionID, draft) in composerDrafts {
                if sessionIDs.contains(sessionID) {
                    retainedDrafts[sessionID] = draft
                } else {
                    removedAttachments.append(contentsOf: draft.images)
                }
            }
            composerDrafts = retainedDrafts
            removeDraftAttachments(removedAttachments)
        }
    }

    func replaceSessionsIfChanged(_ updatedSessions: [ApplePiUISession]) {
        if sessions != updatedSessions { sessions = updatedSessions }
    }

    func replaceTranscript(
        _ items: [ApplePiTranscriptItem],
        resetTrimmedCount: Bool = true
    ) {
        if transcript != items {
            transcript = items
            rebuildTranscriptIndex()
        }
        if resetTrimmedCount, transcriptTrimmedItemCount != 0 {
            transcriptTrimmedItemCount = 0
        }
    }

    func containsTranscriptItem(id: String) -> Bool {
        transcriptIndexByID[id] != nil
    }

    func upsertTranscriptItem(_ item: ApplePiTranscriptItem) {
        if let index = transcriptIndexByID[item.id] {
            if transcript[index] != item { transcript[index] = item }
        } else {
            transcriptIndexByID[item.id] = transcript.endIndex
            transcript.append(item)
        }
    }

    func appendTranscriptDelta(itemID: String, delta: String) {
        appendTranscriptDeltas([itemID: delta])
    }

    func appendTranscriptDeltas(_ deltas: [String: String]) {
        guard !deltas.isEmpty else { return }
        let updates = deltas.compactMap { itemID, delta -> (Int, String)? in
            guard !delta.isEmpty, let index = transcriptIndexByID[itemID] else { return nil }
            return (index, delta)
        }
        guard !updates.isEmpty else { return }
        transcript.withUnsafeMutableBufferPointer { buffer in
            for (index, delta) in updates {
                buffer[index].content.append(delta)
                buffer[index].isStreaming = true
            }
        }
    }

    func completeTranscriptItem(itemID: String) {
        completeTranscriptItems(itemIDs: [itemID])
    }

    func completeTranscriptItems(itemIDs: [String]) {
        let indexes = itemIDs.compactMap { itemID -> Int? in
            guard let index = transcriptIndexByID[itemID], transcript[index].isStreaming else { return nil }
            return index
        }
        guard !indexes.isEmpty else { return }
        transcript.withUnsafeMutableBufferPointer { buffer in
            for index in indexes {
                buffer[index].isStreaming = false
            }
        }
    }

    private func consume(_ result: ApplePiActionResult) {
        switch result {
        case .none:
            break
        case let .snapshot(snapshot):
            apply(snapshot: snapshot)
        case let .session(session):
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index] = session
            } else {
                sessions.insert(session, at: 0)
            }
            unsubmittedTaskIDs.insert(session.id)
            selection = .session(session.id)
            selectedProjectID = project(for: session)?.id
            replaceTranscript([])
            transcriptTrimmedItemCount = 0
            if runtimeOptions != .empty { runtimeOptions = .empty }
        case let .project(project):
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index] = project
            } else {
                projects.append(project)
            }
            sortProjects()
            selection = .project(project.id)
            selectedProjectID = project.id
            replaceTranscript([])
            transcriptTrimmedItemCount = 0
        case let .transcript(items):
            replaceTranscript(items)
        case let .packages(resources):
            if packages != resources { packages = resources }
        case let .terminal(request):
            terminalRequests[request.id] = request
            pendingTerminal = request
        case let .runtimeOptions(options):
            if runtimeOptions != options { runtimeOptions = options }
        }
    }

    private func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                TranscriptResourceCaches.purgeForMemoryPressure()
                self?.releaseTranscriptSegmentsUnderMemoryPressure()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func invalidateNavigationProjections(projectsChanged: Bool) {
        navigationProjectionRevision &+= 1
        cachedSidebarProjection = nil
        cachedSearchProjection = nil
        if projectsChanged {
            cachedProjectLookup = nil
        }
    }

    private func projectLookup() -> ProjectLookup {
        if let cachedProjectLookup { return cachedProjectLookup }

        var ids = Set<ApplePiProjectID>()
        var namesByID: [ApplePiProjectID: String] = [:]
        ids.reserveCapacity(projects.count)
        namesByID.reserveCapacity(projects.count)
        for project in projects {
            ids.insert(project.id)
            namesByID[project.id] = project.name
        }
        let lookup = ProjectLookup(ids: ids, namesByID: namesByID)
        cachedProjectLookup = lookup
        projectionMetrics.projectLookupBuildCount += 1
        return lookup
    }

    private func sortProjects() {
        projects.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func rebuildTranscriptIndex() {
        transcriptIndexByID.removeAll(keepingCapacity: true)
        transcriptIndexByID.reserveCapacity(transcript.count)
        for (index, item) in transcript.enumerated() {
            transcriptIndexByID[item.id] = index
        }
    }

    private func applyLocalMutation(sessionID: String, _ mutation: ApplePiSessionMutation) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        switch mutation {
        case let .rename(title): sessions[index].title = title
        case let .pin(pinned): sessions[index].isPinned = pinned
        case let .archive(archived):
            sessions[index].isArchived = archived
            if archived, selection == .session(sessionID) { selection = .home }
        case let .moveToProject(projectID):
            sessions[index].projectID = projectID
        case .moveToTrash:
            sessions.remove(at: index)
            unsubmittedTaskIDs.remove(sessionID)
            if selection == .session(sessionID) { selection = .home }
            removeComposerDraft(for: sessionID)
            textDraftSessionIDs.remove(sessionID)
        case .fork, .clone, .export, .reveal:
            break
        }
    }

    private func present(_ error: Error) {
        alertMessage = error.localizedDescription
    }

    private func storeComposerDraft(for destination: ApplePiDestination) {
        guard case let .session(sessionID) = destination else { return }
        let draft = ComposerDraft(
            text: composerText,
            images: composerImages,
            queueBehavior: queueBehavior
        )
        updateTextDraftMarker(for: sessionID, hasText: !draft.text.isEmpty)
        if draft.isEmpty {
            composerDrafts.removeValue(forKey: sessionID)
        } else {
            composerDrafts[sessionID] = draft
        }
    }

    private func materializeDraftAttachments(
        _ attachments: [DraftAttachmentFile]
    ) async throws -> [ApplePiPastedImage] {
        guard !attachments.isEmpty else { return [] }
        guard let draftAttachmentCache else { throw DraftAttachmentCacheError.unavailable }
        var images: [ApplePiPastedImage] = []
        images.reserveCapacity(attachments.count)
        for attachment in attachments {
            try Task.checkCancellation()
            images.append(ApplePiPastedImage(
                id: attachment.id,
                data: try await draftAttachmentCache.data(for: attachment),
                suggestedName: attachment.suggestedName,
                mimeType: attachment.mimeType
            ))
        }
        return images
    }

    private func removeDraftAttachments(_ attachments: [DraftAttachmentFile]) {
        guard !attachments.isEmpty, let draftAttachmentCache else { return }
        Task {
            for attachment in attachments {
                try? await draftAttachmentCache.remove(attachment)
            }
        }
    }

    private func removeComposerDraft(for sessionID: String) {
        guard let draft = composerDrafts.removeValue(forKey: sessionID) else { return }
        removeDraftAttachments(draft.images)
    }

    private func updateSelectedTextDraftMarker() {
        guard case let .session(sessionID) = selection else { return }
        updateTextDraftMarker(for: sessionID, hasText: !composerText.isEmpty)
    }

    private func updateTextDraftMarker(for sessionID: String, hasText: Bool) {
        if hasText {
            if !textDraftSessionIDs.contains(sessionID) {
                textDraftSessionIDs.insert(sessionID)
            }
        } else if textDraftSessionIDs.contains(sessionID) {
            textDraftSessionIDs.remove(sessionID)
        }
    }

    private func restoreComposerDraft(for destination: ApplePiDestination) {
        guard case let .session(sessionID) = destination,
              let draft = composerDrafts[sessionID] else {
            composerText = ""
            composerImages = []
            return
        }
        composerText = draft.text
        composerImages = draft.images
        queueBehavior = draft.queueBehavior
    }

    private func discardUntouchedTaskIfNeeded(_ destination: ApplePiDestination) async {
        guard case let .session(sessionID) = destination,
              unsubmittedTaskIDs.contains(sessionID),
              composerDrafts[sessionID] == nil,
              let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        let session = sessions.remove(at: index)
        unsubmittedTaskIDs.remove(sessionID)
        textDraftSessionIDs.remove(sessionID)

        guard let actions else { return }
        do {
            consume(try await actions.perform(.mutateSession(
                sessionID: sessionID,
                mutation: .moveToTrash
            )))
        } catch {
            if !sessions.contains(where: { $0.id == sessionID }) {
                sessions.insert(session, at: min(index, sessions.endIndex))
            }
            unsubmittedTaskIDs.insert(sessionID)
            present(error)
        }
    }
}
