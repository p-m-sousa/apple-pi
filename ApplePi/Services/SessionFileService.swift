import Darwin
import Foundation

public enum SessionFileService {
    public static func loadEntries(from session: SessionIndexEntry, maximumEntries: Int? = nil) async throws -> [PiSessionEntry] {
        let worker = Task.detached(priority: .userInitiated) {
            try PiSessionParser.entries(at: session.path, maximumEntries: maximumEntries)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public static func exportRawJSONL(_ session: SessionIndexEntry, to destination: URL) throws {
        guard session.path.standardizedFileURL != destination.standardizedFileURL else { return }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_DATA)
        guard copyfile(session.path.path, temporary.path, nil, flags) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    public static func moveToTrash(_ session: SessionIndexEntry) throws -> URL {
        try moveToTrash(at: session.path)
    }

    public static func moveToTrash(at sessionURL: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: sessionURL, resultingItemURL: &resultingURL)
        return (resultingURL as URL?) ?? sessionURL
    }
}
