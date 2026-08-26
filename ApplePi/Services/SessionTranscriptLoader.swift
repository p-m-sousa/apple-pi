import CryptoKit
import Foundation
import os

struct SessionTranscriptProjection: Sendable {
    let items: [ApplePiTranscriptItem]
    let branches: [ApplePiInspectorSnapshot.Branch]
}

/// Performs lossless transcript parsing and every reconstructible projection away
/// from the main actor. Pi's JSONL remains authoritative; this actor owns only
/// display projections and its bounded, disposable image cache.
actor SessionTranscriptLoader {
    private static let signposter = OSSignposter(
        subsystem: "com.paulsousa.ApplePi",
        category: .pointsOfInterest
    )

    private let imageCacheDirectory: URL
    private let maximumImageCacheBytes: Int64
    private let maximumImageAge: TimeInterval
    private var lastImageCachePrune: Date = .distantPast
    private var imageCacheMayHaveGrown = false

    init(
        imageCacheDirectory: URL = AppPaths().caches.appending(
            path: "TranscriptImages",
            directoryHint: .isDirectory
        ),
        maximumImageCacheBytes: Int64 = 256 * 1_024 * 1_024,
        maximumImageAge: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.imageCacheDirectory = imageCacheDirectory
        self.maximumImageCacheBytes = maximumImageCacheBytes
        self.maximumImageAge = maximumImageAge
    }

    func load(_ session: SessionIndexEntry) throws -> SessionTranscriptProjection {
        let interval = Self.signposter.beginInterval("TranscriptLoad")
        defer { Self.signposter.endInterval("TranscriptLoad", interval) }

        try Task.checkCancellation()
        let entries = try PiSessionParser.entries(at: session.path)
        try Task.checkCancellation()
        let branch = activeBranch(entries, leafID: session.leafEntryID)
        var items: [ApplePiTranscriptItem] = []
        items.reserveCapacity(branch.count)
        for entry in branch {
            try Task.checkCancellation()
            items.append(contentsOf: transcriptItems(entry))
        }
        let branches = entries.map { entry in
            ApplePiInspectorSnapshot.Branch(
                id: entry.id,
                title: entry.type.replacingOccurrences(of: "_", with: " ").capitalized,
                isCurrent: entry.id == session.leafEntryID
            )
        }
        pruneImageCacheIfNeeded(now: .now, force: imageCacheMayHaveGrown)
        imageCacheMayHaveGrown = false
        return SessionTranscriptProjection(items: items, branches: branches)
    }

    func purgeReconstructibleImages() {
        try? FileManager.default.removeItem(at: imageCacheDirectory)
        lastImageCachePrune = .distantPast
    }

    private func activeBranch(_ entries: [PiSessionEntry], leafID: String?) -> [PiSessionEntry] {
        guard let leafID, !leafID.isEmpty else { return entries }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var branch: [PiSessionEntry] = []
        var cursor: String? = leafID
        var seen = Set<String>()
        while let id = cursor, seen.insert(id).inserted, let entry = byID[id] {
            branch.append(entry)
            cursor = entry.parentID
        }
        return branch.reversed()
    }

    private func transcriptItems(_ entry: PiSessionEntry) -> [ApplePiTranscriptItem] {
        guard let object = entry.raw.objectValue else { return [] }
        let date = entry.timestamp ?? .distantPast
        switch entry.type {
        case "message":
            guard let message = object["message"]?.objectValue else { return [] }
            return messageItems(message, entryID: entry.id, date: date)
        case "compaction":
            return [statusItem(
                id: entry.id,
                title: "Compaction",
                content: object["summary"]?.stringValue ?? "Context was compacted.",
                date: date
            )]
        case "branch_summary":
            return [statusItem(
                id: entry.id,
                title: "Branch summary",
                content: object["summary"]?.stringValue ?? "Session branch changed.",
                date: date
            )]
        case "model_change":
            let provider = object["provider"]?.stringValue ?? ""
            let model = object["modelId"]?.stringValue ?? ""
            return [statusItem(id: entry.id, title: "Model", content: "\(provider)/\(model)", date: date)]
        case "thinking_level_change":
            return [statusItem(
                id: entry.id,
                title: "Thinking",
                content: object["thinkingLevel"]?.stringValue ?? "Changed",
                date: date
            )]
        case "custom_message":
            guard object["display"]?.boolValue != false else { return [] }
            return [statusItem(
                id: entry.id,
                title: object["customType"]?.stringValue ?? "Extension",
                content: contentText(object["content"]),
                date: date
            )]
        default:
            return []
        }
    }

    private func messageItems(
        _ message: [String: JSONValue],
        entryID: String,
        date: Date
    ) -> [ApplePiTranscriptItem] {
        let role = message["role"]?.stringValue ?? "unknown"
        if role == "user" {
            return [ApplePiTranscriptItem(
                id: entryID,
                role: .user,
                kind: .answer,
                title: nil,
                content: contentText(message["content"]),
                timestamp: date,
                isStreaming: false,
                attachments: imageAttachments(message["content"], entryID: entryID)
            )]
        }
        if role == "assistant" {
            var result: [ApplePiTranscriptItem] = []
            let blocks = message["content"]?.arrayValue ?? []
            let text = blocks.compactMap { block -> String? in
                guard let value = block.objectValue, value["type"]?.stringValue == "text" else { return nil }
                return value["text"]?.stringValue
            }.joined(separator: "\n")
            if !text.isEmpty {
                result.append(ApplePiTranscriptItem(
                    id: "\(entryID)-answer",
                    role: .assistant,
                    kind: .answer,
                    title: nil,
                    content: text,
                    timestamp: date,
                    isStreaming: false,
                    attachments: []
                ))
            }
            let thinking = blocks.compactMap { block -> String? in
                guard let value = block.objectValue, value["type"]?.stringValue == "thinking" else { return nil }
                return value["thinking"]?.stringValue
            }.joined(separator: "\n")
            if !thinking.isEmpty {
                result.insert(ApplePiTranscriptItem(
                    id: "\(entryID)-thinking",
                    role: .assistant,
                    kind: .thinking,
                    title: "Thinking",
                    content: thinking,
                    timestamp: date,
                    isStreaming: false,
                    attachments: []
                ), at: 0)
            }
            for (offset, block) in blocks.enumerated() {
                guard let value = block.objectValue, value["type"]?.stringValue == "toolCall" else { continue }
                result.append(ApplePiTranscriptItem(
                    id: value["id"]?.stringValue ?? "\(entryID)-tool-\(offset)",
                    role: .assistant,
                    kind: .tool,
                    title: value["name"]?.stringValue ?? "Tool",
                    content: prettyJSON(value["arguments"] ?? .object([:]), maximumCharacters: 65_536),
                    timestamp: date,
                    isStreaming: false,
                    attachments: []
                ))
            }
            if let error = message["errorMessage"]?.stringValue, !error.isEmpty {
                result.append(ApplePiTranscriptItem(
                    id: "\(entryID)-error",
                    role: .assistant,
                    kind: .error,
                    title: "Pi error",
                    content: error,
                    timestamp: date,
                    isStreaming: false,
                    attachments: []
                ))
            }
            return result
        }
        if role == "toolResult" {
            var content = contentText(message["content"])
            if let details = message["details"], details != .null {
                let rendered = prettyJSON(details, maximumCharacters: 65_536)
                if !rendered.isEmpty { content += content.isEmpty ? rendered : "\n\n\(rendered)" }
            }
            return [ApplePiTranscriptItem(
                id: entryID,
                role: .assistant,
                kind: message["isError"]?.boolValue == true ? .error : .tool,
                title: message["toolName"]?.stringValue ?? "Tool result",
                content: String(content.prefix(65_536)),
                timestamp: date,
                isStreaming: false,
                attachments: imageAttachments(message["content"], entryID: entryID)
            )]
        }
        if role == "bashExecution" {
            let command = message["command"]?.stringValue ?? "Shell command"
            let output = message["output"]?.stringValue ?? ""
            return [ApplePiTranscriptItem(
                id: entryID,
                role: .assistant,
                kind: (message["exitCode"]?.numberValue ?? 0) == 0 ? .tool : .error,
                title: command,
                content: String(output.prefix(65_536)),
                timestamp: date,
                isStreaming: false,
                attachments: []
            )]
        }
        if role == "custom", message["display"]?.boolValue != false {
            return [statusItem(
                id: entryID,
                title: message["customType"]?.stringValue ?? "Extension",
                content: contentText(message["content"]),
                date: date
            )]
        }
        if role == "branchSummary" || role == "compactionSummary" {
            return [statusItem(
                id: entryID,
                title: role == "branchSummary" ? "Branch summary" : "Compaction summary",
                content: message["summary"]?.stringValue ?? "",
                date: date
            )]
        }
        return []
    }

    private func statusItem(id: String, title: String, content: String, date: Date) -> ApplePiTranscriptItem {
        ApplePiTranscriptItem(
            id: id,
            role: .system,
            kind: .status,
            title: title,
            content: content,
            timestamp: date,
            isStreaming: false,
            attachments: []
        )
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

    private func imageAttachments(_ content: JSONValue?, entryID: String) -> [ApplePiAttachment] {
        guard let blocks = content?.arrayValue else { return [] }
        try? FileManager.default.createDirectory(
            at: imageCacheDirectory,
            withIntermediateDirectories: true
        )
        var attachments: [ApplePiAttachment] = []
        for (index, block) in blocks.enumerated() {
            guard let object = block.objectValue,
                  object["type"]?.stringValue == "image",
                  let encoded = object["data"]?.stringValue,
                  let data = Data(base64Encoded: encoded) else { continue }
            let mime = object["mimeType"]?.stringValue ?? "image/png"
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let url = imageCacheDirectory.appending(path: "\(digest).\(fileExtension(for: mime))")
            if FileManager.default.fileExists(atPath: url.path) {
                touchForLRUIfNeeded(url, now: .now)
            } else {
                do {
                    try data.write(to: url, options: .atomic)
                    imageCacheMayHaveGrown = true
                } catch {
                    continue
                }
            }
            attachments.append(ApplePiAttachment(
                id: "\(entryID)-image-\(index)",
                kind: .image,
                url: url,
                name: url.lastPathComponent,
                mimeType: mime
            ))
        }
        return attachments
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/gif": "gif"
        case "image/heic", "image/heif": "heic"
        case "image/tiff": "tiff"
        case "image/webp": "webp"
        default: "png"
        }
    }

    private func touchForLRUIfNeeded(_ url: URL, now: Date) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        guard now.timeIntervalSince(values?.contentModificationDate ?? .distantPast) > 24 * 60 * 60 else {
            return
        }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    private func pruneImageCacheIfNeeded(now: Date, force: Bool = false) {
        guard force || now.timeIntervalSince(lastImageCachePrune) >= 60 * 60 else { return }
        lastImageCachePrune = now
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: imageCacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let expiration = now.addingTimeInterval(-maximumImageAge)
        var retained: [(url: URL, bytes: Int64, usedAt: Date)] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            let usedAt = values?.contentModificationDate ?? .distantPast
            if usedAt < expiration {
                try? FileManager.default.removeItem(at: url)
            } else {
                retained.append((url, Int64(values?.fileSize ?? 0), usedAt))
            }
        }

        var total = retained.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > maximumImageCacheBytes else { return }
        for record in retained.sorted(by: { $0.usedAt < $1.usedAt }) where total > maximumImageCacheBytes {
            guard (try? FileManager.default.removeItem(at: record.url)) != nil else { continue }
            total -= record.bytes
        }
    }

    private func prettyJSON(_ value: JSONValue, maximumCharacters: Int) -> String {
        guard let data = try? value.encodedData(sortedKeys: true),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return String(String(describing: value).prefix(maximumCharacters))
        }
        return String(String(decoding: pretty, as: UTF8.self).prefix(maximumCharacters))
    }
}
