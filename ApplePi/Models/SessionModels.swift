import Foundation

public struct SessionPresentationState: Sendable, Hashable, Codable {
    public var isPinned: Bool
    public var isArchived: Bool
    public var projectID: ApplePiProjectID?
    public var hasExplicitProjectAssignment: Bool?

    public init(
        isPinned: Bool = false,
        isArchived: Bool = false,
        projectID: ApplePiProjectID? = nil,
        hasExplicitProjectAssignment: Bool? = nil
    ) {
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.projectID = projectID
        self.hasExplicitProjectAssignment = hasExplicitProjectAssignment
    }
}

public struct SessionIndexEntry: Sendable, Hashable, Codable, Identifiable {
    public var id: String { sessionID }

    public let sessionID: String
    public let path: URL
    public let workingDirectory: URL
    public let name: String?
    public let parentSessionPath: String?
    public let createdAt: Date
    public let modifiedAt: Date
    public let byteCount: Int64
    public let messageCount: Int
    public let firstMessage: String
    public let leafEntryID: String?
    public var presentation: SessionPresentationState

    public init(
        sessionID: String,
        path: URL,
        workingDirectory: URL,
        name: String?,
        parentSessionPath: String?,
        createdAt: Date,
        modifiedAt: Date,
        byteCount: Int64,
        messageCount: Int,
        firstMessage: String,
        leafEntryID: String?,
        presentation: SessionPresentationState = .init()
    ) {
        self.sessionID = sessionID
        self.path = path
        self.workingDirectory = workingDirectory
        self.name = name
        self.parentSessionPath = parentSessionPath
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.byteCount = byteCount
        self.messageCount = messageCount
        self.firstMessage = firstMessage
        self.leafEntryID = leafEntryID
        self.presentation = presentation
    }
}

public struct PiSessionEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public let parentID: String?
    public let type: String
    public let timestamp: Date?
    public let raw: JSONValue
}

public struct SessionIndexDiagnostic: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let path: URL
    public let message: String
}

public struct SessionIndexSnapshot: Sendable {
    public let entries: [SessionIndexEntry]
    public let diagnostics: [SessionIndexDiagnostic]
    public let refreshedAt: Date
}
