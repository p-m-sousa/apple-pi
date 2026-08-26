import Foundation

public struct ApplePiProjectID: RawRepresentable, Sendable, Hashable, Codable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ApplePiProject: Sendable, Hashable, Codable, Identifiable {
    public let id: ApplePiProjectID
    public var name: String
    public var workingDirectory: URL
    public var isPinned: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ApplePiProjectID = ApplePiProjectID(),
        name: String,
        workingDirectory: URL,
        isPinned: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case workingDirectory
        case isPinned
        case createdAt
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ApplePiProjectID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        workingDirectory = try container.decode(URL.self, forKey: .workingDirectory)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

enum ProjectDirectoryMatcher {
    struct Prepared: Sendable {
        private struct Candidate: Sendable {
            let project: ApplePiProject
            let path: String
        }

        private let candidates: [Candidate]

        init(projects: [ApplePiProject]) {
            candidates = projects.map {
                Candidate(project: $0, path: ProjectDirectoryMatcher.canonicalPath($0.workingDirectory))
            }
        }

        func bestMatch(for workingDirectory: URL) -> ApplePiProject? {
            let workingPath = ProjectDirectoryMatcher.canonicalPath(workingDirectory)
            return candidates
                .filter { ProjectDirectoryMatcher.contains(workingPath, in: $0.path) }
                .max { $0.path.count < $1.path.count }?
                .project
        }
    }

    static func bestMatch(
        for workingDirectory: URL,
        among projects: [ApplePiProject]
    ) -> ApplePiProject? {
        Prepared(projects: projects).bestMatch(for: workingDirectory)
    }

    static func contains(_ workingDirectory: URL, in projectDirectory: URL) -> Bool {
        let workingPath = canonicalPath(workingDirectory)
        let projectPath = canonicalPath(projectDirectory)
        return contains(workingPath, in: projectPath)
    }

    private static func contains(_ workingPath: String, in projectPath: String) -> Bool {
        guard workingPath != projectPath else { return true }
        return projectPath == "/"
            ? workingPath.hasPrefix("/")
            : workingPath.hasPrefix(projectPath + "/")
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
