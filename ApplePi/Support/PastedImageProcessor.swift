import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PastedImageMaterial: Hashable, Sendable {
    var data: Data
    var suggestedName: String
    var mimeType: String
}

struct PastedImageProcessingResult: Hashable, Sendable {
    var images: [PastedImageMaterial]
    var nonImageFileURLs: [URL]
}

/// Performs image validation and transcoding away from the main actor. PNG and JPEG
/// inputs are passed through byte-for-byte; other ImageIO-supported formats become PNG.
actor PastedImageProcessor {
    static let shared = PastedImageProcessor()

    func process(
        fileURLs: [URL],
        fallbackPasteboardData: Data?
    ) throws -> PastedImageProcessingResult {
        var images: [PastedImageMaterial] = []
        var nonImageFileURLs: [URL] = []

        for url in fileURLs {
            try Task.checkCancellation()
            if let image = try processFile(at: url) {
                images.append(image)
            } else {
                nonImageFileURLs.append(url)
            }
        }

        // Match the existing composer behavior: pasteboard image data is a fallback
        // when file URLs did not yield an image, rather than a second copy of it.
        if images.isEmpty,
           let fallbackPasteboardData,
           let image = try processEncodedData(
               fallbackPasteboardData,
               suggestedBaseName: "pasted-image-1"
           ) {
            images.append(image)
        }

        return PastedImageProcessingResult(
            images: images,
            nonImageFileURLs: nonImageFileURLs
        )
    }

    func processFile(at url: URL) throws -> PastedImageMaterial? {
        try Task.checkCancellation()
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        let type = sourceType(source)
        if type.isBytePreservingFormat {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return PastedImageMaterial(
                data: data,
                suggestedName: url.lastPathComponent,
                mimeType: type.mimeType
            )
        }

        guard let data = transcodeToPNG(source) else { return nil }
        return PastedImageMaterial(
            data: data,
            suggestedName: url.lastPathComponent,
            mimeType: UTType.png.preferredMIMEType ?? "image/png"
        )
    }

    func processEncodedData(
        _ data: Data,
        suggestedBaseName: String
    ) throws -> PastedImageMaterial? {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        let type = sourceType(source)
        if type.isBytePreservingFormat {
            return PastedImageMaterial(
                data: data,
                suggestedName: "\(suggestedBaseName).\(type.filenameExtension)",
                mimeType: type.mimeType
            )
        }

        guard let png = transcodeToPNG(source) else { return nil }
        return PastedImageMaterial(
            data: png,
            suggestedName: "\(suggestedBaseName).png",
            mimeType: UTType.png.preferredMIMEType ?? "image/png"
        )
    }

    private func sourceType(_ source: CGImageSource) -> SourceImageType {
        let identifier = CGImageSourceGetType(source) as String?
        return SourceImageType(identifier: identifier)
    }

    private func transcodeToPNG(_ source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private struct SourceImageType: Sendable {
    let identifier: String?

    var uniformType: UTType? {
        identifier.flatMap(UTType.init)
    }

    var isBytePreservingFormat: Bool {
        guard let uniformType else { return false }
        return uniformType.conforms(to: .png) || uniformType.conforms(to: .jpeg)
    }

    var mimeType: String {
        uniformType?.preferredMIMEType ?? "application/octet-stream"
    }

    var filenameExtension: String {
        uniformType?.preferredFilenameExtension ?? "image"
    }
}

struct DraftAttachmentFile: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let suggestedName: String
    let mimeType: String
    let byteCount: Int
}

enum DraftAttachmentCacheError: LocalizedError {
    case unknownAttachment
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unknownAttachment:
            "The draft attachment is no longer available. Paste it again and retry."
        case .unavailable:
            "ApplePi could not create its temporary draft attachment cache."
        }
    }
}

/// A transient, explicitly managed cache for draft attachment payloads. Its root is
/// unique per instance and is removed both by `removeAll()` and when the cache dies.
actor DraftAttachmentCache {
    private let rootDirectory: URL
    private var attachments: [UUID: DraftAttachmentFile] = [:]

    init(rootDirectory: URL? = nil) throws {
        self.rootDirectory = rootDirectory ?? FileManager.default.temporaryDirectory
            .appending(
                component: "ApplePi-DraftAttachments-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: self.rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func store(
        data: Data,
        suggestedName: String,
        mimeType: String
    ) throws -> DraftAttachmentFile {
        let id = UUID()
        let fileExtension = Self.fileExtension(mimeType: mimeType, suggestedName: suggestedName)
        let filename = fileExtension.isEmpty ? id.uuidString : "\(id.uuidString).\(fileExtension)"
        let url = rootDirectory.appending(component: filename, directoryHint: .notDirectory)
        try data.write(to: url, options: [.atomic])

        let attachment = DraftAttachmentFile(
            id: id,
            url: url,
            suggestedName: suggestedName,
            mimeType: mimeType,
            byteCount: data.count
        )
        attachments[id] = attachment
        return attachment
    }

    func data(for attachment: DraftAttachmentFile) throws -> Data {
        guard attachments[attachment.id] == attachment else {
            throw DraftAttachmentCacheError.unknownAttachment
        }
        return try Data(contentsOf: attachment.url, options: [.mappedIfSafe])
    }

    func remove(_ attachment: DraftAttachmentFile) throws {
        guard attachments[attachment.id] == attachment else {
            throw DraftAttachmentCacheError.unknownAttachment
        }
        if FileManager.default.fileExists(atPath: attachment.url.path) {
            try FileManager.default.removeItem(at: attachment.url)
        }
        attachments.removeValue(forKey: attachment.id)
    }

    func removeAll() throws {
        if FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.removeItem(at: rootDirectory)
        }
        attachments.removeAll(keepingCapacity: false)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    var count: Int { attachments.count }

    private static func fileExtension(mimeType: String, suggestedName: String) -> String {
        if let type = UTType(mimeType: mimeType), let preferred = type.preferredFilenameExtension {
            return preferred
        }
        let candidate = URL(fileURLWithPath: suggestedName).pathExtension
        guard !candidate.isEmpty,
              candidate.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return ""
        }
        return String(candidate.prefix(12)).lowercased()
    }
}
