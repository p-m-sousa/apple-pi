import Darwin
import Foundation

public struct AppPaths: Sendable {
    public let applicationSupport: URL
    public let caches: URL

    public init(fileManager: FileManager = .default) {
        if let override = ProcessInfo.processInfo.environment["APPLE_PI_DATA_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let root = URL(filePath: override, directoryHint: .isDirectory).standardizedFileURL
            applicationSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
            caches = root.appending(path: "Caches", directoryHint: .isDirectory)
            return
        }
        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        applicationSupport = supportRoot.appending(path: "Apple Pi", directoryHint: .isDirectory)
        caches = cacheRoot.appending(path: "Apple Pi", directoryHint: .isDirectory)
    }

    public var sessionIndexCache: URL { caches.appending(path: "session-index-v2.json") }
    public var presentationState: URL { applicationSupport.appending(path: "session-presentation-v1.json") }
    public var projects: URL { applicationSupport.appending(path: "projects-v1.json") }
    public var managedWorktrees: URL { applicationSupport.appending(path: "worktrees", directoryHint: .isDirectory) }

    public func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: caches, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: managedWorktrees, withIntermediateDirectories: true)
    }
}

public enum AtomicJSONFile {
    public enum Durability: Sendable {
        case rebuildableCache
        case authoritative
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try JSONDecoder.applePi.decode(type, from: data)
    }

    public static func write<T: Encodable>(
        _ value: T,
        to url: URL,
        durability: Durability = .rebuildableCache
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.applePi.encode(value)
        switch durability {
        case .rebuildableCache:
            try data.write(to: url, options: .atomic)
        case .authoritative:
            try writeDurably(data, to: url)
        }
    }

    private static func writeDurably(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(
            path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        try data.write(to: temporary)
        let fileDescriptor = open(temporary.path, O_RDONLY | O_CLOEXEC)
        guard fileDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fileDescriptor) }
        guard fsync(fileDescriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}

public extension JSONDecoder {
    static var applePi: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public extension JSONEncoder {
    static var applePi: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
