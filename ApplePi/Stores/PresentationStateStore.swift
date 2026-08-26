import Foundation

public actor PresentationStateStore {
    private struct FileContents: Codable {
        let version: Int
        var sessions: [String: SessionPresentationState]
    }

    private let fileURL: URL
    private var loaded = false
    private var states: [String: SessionPresentationState] = [:]

    public init(fileURL: URL = AppPaths().presentationState) {
        self.fileURL = fileURL
    }

    public func state(for sessionURL: URL) -> SessionPresentationState {
        loadIfNeeded()
        return states[key(for: sessionURL)] ?? .init()
    }

    public func allStates() -> [String: SessionPresentationState] {
        loadIfNeeded()
        return states
    }

    public func setPinned(_ pinned: Bool, for sessionURL: URL) throws {
        loadIfNeeded()
        let stateKey = key(for: sessionURL)
        var value = states[stateKey] ?? .init()
        guard value.isPinned != pinned else { return }
        value.isPinned = pinned
        states[stateKey] = value
        try save()
    }

    public func setArchived(_ archived: Bool, for sessionURL: URL) throws {
        loadIfNeeded()
        let stateKey = key(for: sessionURL)
        var value = states[stateKey] ?? .init()
        guard value.isArchived != archived else { return }
        value.isArchived = archived
        states[stateKey] = value
        try save()
    }

    public func setArchived(_ archived: Bool, for sessionURLs: [URL]) throws {
        loadIfNeeded()
        guard !sessionURLs.isEmpty else { return }
        var changed = false
        for sessionURL in sessionURLs {
            let stateKey = key(for: sessionURL)
            var value = states[stateKey] ?? .init()
            guard value.isArchived != archived else { continue }
            value.isArchived = archived
            states[stateKey] = value
            changed = true
        }
        if changed { try save() }
    }

    public func setProjectID(_ projectID: ApplePiProjectID?, for sessionURL: URL) throws {
        loadIfNeeded()
        let stateKey = key(for: sessionURL)
        var value = states[stateKey] ?? .init()
        guard value.projectID != projectID || value.hasExplicitProjectAssignment != true else { return }
        value.projectID = projectID
        value.hasExplicitProjectAssignment = true
        states[stateKey] = value
        try save()
    }

    public func removeProjectAssignments(for projectID: ApplePiProjectID) throws {
        loadIfNeeded()
        let matchingKeys = states.compactMap { key, state in
            state.projectID == projectID ? key : nil
        }
        for key in matchingKeys {
            states[key]?.projectID = nil
            states[key]?.hasExplicitProjectAssignment = true
        }
        if !matchingKeys.isEmpty { try save() }
    }

    public func removeState(for sessionURL: URL) throws {
        loadIfNeeded()
        guard states.removeValue(forKey: key(for: sessionURL)) != nil else { return }
        try save()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let contents = try? AtomicJSONFile.read(FileContents.self, from: fileURL),
              contents.version == 1 else { return }
        states = contents.sessions
    }

    private func save() throws {
        try AtomicJSONFile.write(
            FileContents(version: 1, sessions: states),
            to: fileURL,
            durability: .authoritative
        )
    }

    private func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
