import Foundation

public enum ProjectStoreError: Error, Equatable, Sendable, LocalizedError {
    case emptyName
    case projectNotFound(ApplePiProjectID)
    case workingDirectoryAlreadyExists(URL)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "A project name is required."
        case .projectNotFound:
            "The project no longer exists."
        case let .workingDirectoryAlreadyExists(url):
            "A project already exists for \(url.path)."
        }
    }
}

public actor ProjectStore {
    private struct FileContents: Codable, Sendable {
        let version: Int
        var projects: [ApplePiProject]
    }

    private static let currentVersion = 1

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var loaded = false
    private var projects: [ApplePiProject] = []

    public init(
        fileURL: URL = AppPaths().projects,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.now = now
    }

    public func allProjects() -> [ApplePiProject] {
        loadIfNeeded()
        return projects
    }

    public func project(id: ApplePiProjectID) -> ApplePiProject? {
        loadIfNeeded()
        return projects.first { $0.id == id }
    }

    /// Looks up an explicitly saved project. Callers must not use this to infer
    /// task membership; standalone tasks may share a working directory with a project.
    public func project(forWorkingDirectory workingDirectory: URL) -> ApplePiProject? {
        loadIfNeeded()
        let requestedKey = directoryKey(for: workingDirectory)
        return projects.first { directoryKey(for: $0.workingDirectory) == requestedKey }
    }

    @discardableResult
    public func create(name: String, workingDirectory: URL) throws -> ApplePiProject {
        loadIfNeeded()
        let normalizedName = try validatedName(name)
        let normalizedDirectory = workingDirectory.standardizedFileURL
        try ensureDirectoryIsAvailable(normalizedDirectory)

        let timestamp = now()
        let project = ApplePiProject(
            name: normalizedName,
            workingDirectory: normalizedDirectory,
            createdAt: timestamp
        )
        projects.append(project)
        do {
            try save()
            return project
        } catch {
            projects.removeLast()
            throw error
        }
    }

    @discardableResult
    public func update(
        id: ApplePiProjectID,
        name: String? = nil,
        workingDirectory: URL? = nil,
        isPinned: Bool? = nil
    ) throws -> ApplePiProject {
        loadIfNeeded()
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw ProjectStoreError.projectNotFound(id)
        }

        let previous = projects[index]
        let updatedName = try name.map(validatedName) ?? previous.name
        let updatedDirectory = workingDirectory?.standardizedFileURL ?? previous.workingDirectory
        try ensureDirectoryIsAvailable(updatedDirectory, excluding: id)

        var updated = previous
        updated.name = updatedName
        updated.workingDirectory = updatedDirectory
        updated.isPinned = isPinned ?? previous.isPinned
        updated.updatedAt = now()
        projects[index] = updated
        do {
            try save()
            return updated
        } catch {
            projects[index] = previous
            throw error
        }
    }

    @discardableResult
    public func delete(id: ApplePiProjectID) throws -> ApplePiProject {
        loadIfNeeded()
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw ProjectStoreError.projectNotFound(id)
        }

        let removed = projects.remove(at: index)
        do {
            try save()
            return removed
        } catch {
            projects.insert(removed, at: index)
            throw error
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        if let contents = try? AtomicJSONFile.read(FileContents.self, from: fileURL),
           contents.version == Self.currentVersion {
            projects = contents.projects
            return
        }

        // Early development builds stored the project array without an envelope.
        // Read that shape once and rewrite it in the versioned format.
        if let legacyProjects = try? AtomicJSONFile.read([ApplePiProject].self, from: fileURL) {
            projects = legacyProjects
            try? save()
        }
    }

    private func save() throws {
        try AtomicJSONFile.write(
            FileContents(version: Self.currentVersion, projects: projects),
            to: fileURL,
            durability: .authoritative
        )
    }

    private func validatedName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ProjectStoreError.emptyName }
        return normalized
    }

    private func ensureDirectoryIsAvailable(
        _ workingDirectory: URL,
        excluding excludedID: ApplePiProjectID? = nil
    ) throws {
        let requestedKey = directoryKey(for: workingDirectory)
        if projects.contains(where: {
            $0.id != excludedID && directoryKey(for: $0.workingDirectory) == requestedKey
        }) {
            throw ProjectStoreError.workingDirectoryAlreadyExists(workingDirectory)
        }
    }

    private func directoryKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
