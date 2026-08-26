import Foundation

public enum PiSessionParserError: LocalizedError, Sendable {
    case emptyFile
    case missingHeader
    case invalidHeader

    public var errorDescription: String? {
        switch self {
        case .emptyFile: "The Pi session file is empty."
        case .missingHeader: "The Pi session file has no session header."
        case .invalidHeader: "The Pi session header is invalid."
        }
    }
}

public enum PiSessionParser {
    private struct IndexLine: Decodable {
        struct Message: Decodable {
            let role: String?
            let content: MessageContent?

            private enum CodingKeys: String, CodingKey {
                case role
                case content
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                role = try? container.decode(String.self, forKey: .role)
                content = try? container.decode(MessageContent.self, forKey: .content)
            }
        }

        let type: String?
        let id: String?
        let cwd: String?
        let timestamp: String?
        let parentSession: String?
        let name: String?
        let message: Message?

        private enum CodingKeys: String, CodingKey {
            case type
            case id
            case cwd
            case timestamp
            case parentSession
            case name
            case message
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decode(String.self, forKey: .type)
            id = try? container.decode(String.self, forKey: .id)
            cwd = try? container.decode(String.self, forKey: .cwd)
            timestamp = try? container.decode(String.self, forKey: .timestamp)
            parentSession = try? container.decode(String.self, forKey: .parentSession)
            name = try? container.decode(String.self, forKey: .name)
            message = try? container.decode(Message.self, forKey: .message)
        }
    }

    private enum MessageContent: Decodable {
        struct Block: Decodable {
            let type: String?
            let text: String?
        }

        case text(String)
        case blocks([Block])
        case unsupported

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else if let blocks = try? container.decode([Block].self) {
                self = .blocks(blocks)
            } else {
                self = .unsupported
            }
        }
    }

    private struct IndexAccumulator {
        var header: IndexLine?
        var messageCount: Int
        var firstMessage: String
        var sessionName: String?
        var leafEntryID: String?

        init(existing: SessionIndexEntry? = nil) {
            header = nil
            messageCount = existing?.messageCount ?? 0
            firstMessage = existing?.firstMessage ?? ""
            sessionName = existing?.name
            leafEntryID = existing?.leafEntryID
        }

        mutating func consume(_ line: IndexLine) {
            if header == nil, line.type == "session" {
                header = line
                return
            }
            if line.type == "message" {
                messageCount += 1
                if firstMessage.isEmpty,
                   line.message?.role == "user",
                   let content = line.message?.content {
                    firstMessage = PiSessionParser.messageText(content)
                }
            } else if line.type == "session_info" {
                sessionName = line.name
            }
            if let id = line.id { leafEntryID = id }
        }
    }

    private static let fractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    public static func indexEntry(at url: URL) throws -> SessionIndexEntry {
        try indexEntry(at: url, decoder: JSONDecoder())
    }

    static func indexEntry(at url: URL, decoder: JSONDecoder) throws -> SessionIndexEntry {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        let createdFromFile = (attributes[.creationDate] as? Date) ?? modified
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        var accumulator = IndexAccumulator()

        let sawBytes = try forEachLine(at: url) { line in
            accumulator.consume(try decoder.decode(IndexLine.self, from: line))
            return true
        }
        guard sawBytes else { throw PiSessionParserError.emptyFile }
        guard let header = accumulator.header else { throw PiSessionParserError.missingHeader }
        guard let sessionID = header.id, let cwd = header.cwd else {
            throw PiSessionParserError.invalidHeader
        }
        let workingDirectory = cwd.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser
            : URL(filePath: cwd, directoryHint: .isDirectory)

        return SessionIndexEntry(
            sessionID: sessionID,
            path: url.standardizedFileURL,
            workingDirectory: workingDirectory,
            name: accumulator.sessionName,
            parentSessionPath: header.parentSession,
            createdAt: header.timestamp.flatMap(parseDate) ?? createdFromFile,
            modifiedAt: modified,
            byteCount: byteCount,
            messageCount: accumulator.messageCount,
            firstMessage: accumulator.firstMessage,
            leafEntryID: accumulator.leafEntryID
        )
    }

    static func updatingIndexEntry(
        _ existing: SessionIndexEntry,
        at url: URL,
        fromOffset offset: UInt64,
        decoder: JSONDecoder
    ) throws -> SessionIndexEntry {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes[.modificationDate] as? Date) ?? existing.modifiedAt
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? existing.byteCount
        var accumulator = IndexAccumulator(existing: existing)

        _ = try forEachLine(at: url, startingAt: offset) { line in
            accumulator.consume(try decoder.decode(IndexLine.self, from: line))
            return true
        }

        return SessionIndexEntry(
            sessionID: existing.sessionID,
            path: url.standardizedFileURL,
            workingDirectory: existing.workingDirectory,
            name: accumulator.sessionName,
            parentSessionPath: existing.parentSessionPath,
            createdAt: existing.createdAt,
            modifiedAt: modified,
            byteCount: byteCount,
            messageCount: accumulator.messageCount,
            firstMessage: accumulator.firstMessage,
            leafEntryID: accumulator.leafEntryID,
            presentation: existing.presentation
        )
    }

    public static func entries(at url: URL, maximumEntries: Int? = nil) throws -> [PiSessionEntry] {
        var entries: [PiSessionEntry] = []
        let decoder = JSONDecoder()
        _ = try forEachLine(at: url) { line in
            guard maximumEntries.map({ entries.count < $0 }) ?? true else { return false }
            let value = try decoder.decode(JSONValue.self, from: line)
            guard let object = value.objectValue,
                  object["type"]?.stringValue != "session",
                  let id = object["id"]?.stringValue,
                  let type = object["type"]?.stringValue else { return true }
            entries.append(PiSessionEntry(
                id: id,
                parentID: object["parentId"]?.stringValue,
                type: type,
                timestamp: object["timestamp"]?.stringValue.flatMap(parseDate),
                raw: value
            ))
            return maximumEntries.map { entries.count < $0 } ?? true
        }
        return entries
    }

    @discardableResult
    private static func forEachLine(
        at url: URL,
        startingAt offset: UInt64 = 0,
        body: (Data) throws -> Bool
    ) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if offset > 0 { try handle.seek(toOffset: offset) }
        var framer = BoundedLineBuffer()
        var sawBytes = false

        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 256 * 1_024) ?? Data()
            guard !data.isEmpty else { break }
            sawBytes = true
            for line in try framer.append(data) where !line.isEmpty {
                try Task.checkCancellation()
                guard try body(line) else { return sawBytes }
            }
        }
        if let final = try framer.finish(), !final.isEmpty {
            _ = try body(final)
        }
        return sawBytes
    }

    private static func messageText(_ content: MessageContent) -> String {
        switch content {
        case let .text(text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .blocks(blocks):
            return blocks.compactMap { block in
                guard block.type == "text" else { return nil }
                return block.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        case .unsupported:
            return ""
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        (try? Date(value, strategy: fractionalDateStyle)) ??
            (try? Date(value, strategy: wholeSecondDateStyle))
    }
}
