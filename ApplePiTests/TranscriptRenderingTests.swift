import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ApplePi

@Suite("Bounded transcript rendering")
struct TranscriptRenderingTests {
    @Test("Custom Markdown plans preserve prose, fenced code, and tables")
    func markdownGoldenPlan() async throws {
        let source = """
        Hello **world**.

        ```swift
        let value = 42
        ```

        | Name | Value |
        | --- | ---: |
        | answer | 42 |
        """

        let blocks = try await TranscriptRenderingTestSupport.render(source)

        #expect(blocks == [
            .prose("Hello world."),
            .code(language: "swift", source: "let value = 42"),
            .prose(""),
            .table(headers: ["Name", "Value"], rows: [["answer", "42"]]),
        ])
    }

    @Test("A 100 KB streaming response never renders concurrently and finishes exactly")
    func streamingMarkdownIsSerialized() async throws {
        await TranscriptRenderingTestSupport.resetMarkdownStatistics()
        let prose = String(repeating: "A bounded streaming paragraph.\n", count: 3_500)
        let finalSource = prose + "\n```text\nfinal block\n```"
        var latest: Task<[TranscriptRenderingTestSupport.Block], any Error>?

        for end in stride(from: 2_048, to: finalSource.utf8.count, by: 2_048) {
            latest?.cancel()
            let prefix = String(finalSource.prefix(end))
            latest = Task { try await TranscriptRenderingTestSupport.render(prefix) }
        }
        latest?.cancel()
        let finalBlocks = try await TranscriptRenderingTestSupport.render(finalSource)
        let statistics = await TranscriptRenderingTestSupport.markdownStatistics()

        #expect(statistics.maximumActive == 1)
        #expect(finalBlocks.last == .code(language: "text", source: "final block"))
        let renderedProse = Array(repeating: "A bounded streaming paragraph.", count: 3_500)
            .joined(separator: " ")
        #expect(finalBlocks.first == .prose(renderedProse))
    }

    @Test("ImageIO thumbnails are capped, cached, purgeable, and leave originals untouched")
    func imageThumbnailCache() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appending(path: "large.png")
        try writePNG(width: 2_240, height: 1_520, to: imageURL)
        let original = try Data(contentsOf: imageURL)
        await TranscriptRenderingTestSupport.resetThumbnailStatistics()

        let first = try #require(await TranscriptRenderingTestSupport.thumbnailPixelSize(for: imageURL))
        let second = try #require(await TranscriptRenderingTestSupport.thumbnailPixelSize(for: imageURL))
        #expect(first.width <= 1_120)
        #expect(first.height <= 760)
        #expect(first.width == second.width && first.height == second.height)
        #expect(await TranscriptRenderingTestSupport.thumbnailDecodeCount() == 1)
        #expect(try Data(contentsOf: imageURL) == original)

        await TranscriptRenderingTestSupport.purge()
        _ = await TranscriptRenderingTestSupport.thumbnailPixelSize(for: imageURL)
        #expect(await TranscriptRenderingTestSupport.thumbnailDecodeCount() == 2)
        #expect(try Data(contentsOf: imageURL) == original)
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
