import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ApplePi

@Suite("Pasted image processing")
struct PastedImageProcessorTests {
    @Test("PNG and JPEG payloads remain byte-exact")
    func preservesEncodedBytes() async throws {
        let processor = PastedImageProcessor()
        for type in [UTType.png, UTType.jpeg] {
            let original = try Self.encodedPixel(type: type)
            let result = try #require(
                try await processor.processEncodedData(
                    original,
                    suggestedBaseName: "pasted"
                )
            )
            #expect(result.data == original)
            #expect(result.mimeType == type.preferredMIMEType)
            #expect(result.suggestedName.hasSuffix(".\(try #require(type.preferredFilenameExtension))"))
        }
    }

    @Test("Other image encodings are transcoded to PNG")
    func transcodesOtherFormats() async throws {
        let processor = PastedImageProcessor()
        let tiff = try Self.encodedPixel(type: .tiff)
        let result = try #require(
            try await processor.processEncodedData(tiff, suggestedBaseName: "pasted")
        )

        #expect(result.mimeType == "image/png")
        #expect(result.suggestedName == "pasted.png")
        #expect(result.data != tiff)
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
    }

    @Test("File processing preserves images and reports non-images")
    func processesFileURLs() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pngURL = directory.appending(path: "pixel.png")
        let textURL = directory.appending(path: "notes.txt")
        let png = try Self.encodedPixel(type: .png)
        try png.write(to: pngURL)
        try Data("notes".utf8).write(to: textURL)

        let result = try await PastedImageProcessor().process(
            fileURLs: [pngURL, textURL],
            fallbackPasteboardData: nil
        )

        #expect(result.images.count == 1)
        #expect(result.images[0].data == png)
        #expect(result.images[0].suggestedName == "pixel.png")
        #expect(result.nonImageFileURLs == [textURL])
    }

    @Test("Draft attachment cache is file-backed and explicitly cleans up")
    func draftAttachmentCacheLifecycle() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheRoot = directory.appending(path: "drafts", directoryHint: .isDirectory)
        let cache = try DraftAttachmentCache(rootDirectory: cacheRoot)
        let original = Data(repeating: 0xA5, count: 128 * 1_024)

        let first = try await cache.store(
            data: original,
            suggestedName: "camera-original.jpg",
            mimeType: "image/jpeg"
        )
        #expect(first.byteCount == original.count)
        #expect(["jpg", "jpeg"].contains(first.url.pathExtension))
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        #expect(try await cache.data(for: first) == original)
        #expect(await cache.count == 1)

        try await cache.remove(first)
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(await cache.count == 0)

        let second = try await cache.store(
            data: original,
            suggestedName: "second.png",
            mimeType: "image/png"
        )
        try await cache.removeAll()
        #expect(!FileManager.default.fileExists(atPath: second.url.path))
        #expect(await cache.count == 0)
    }

    private static func encodedPixel(type: UTType) throws -> Data {
        let pixels = Data([0x22, 0x88, 0xEE, 0xFF])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
