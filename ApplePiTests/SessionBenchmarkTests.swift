import Darwin.Mach
import Foundation
import Testing
@testable import ApplePi

@Suite("Session resource benchmarks", .serialized)
struct SessionBenchmarkTests {
    @Test("Index and lossless transcript trends for 1, 10, and 100 MiB JSONL")
    func sessionFixtureTrends() throws {
        #if APPLE_PI_SESSION_BENCHMARKS
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ContinuousClock()
        var output = Data()

        for mebibytes in [1, 10, 100] {
            let fixture = directory.appending(path: "session-\(mebibytes)MiB.jsonl")
            try writeFixture(mebibytes: mebibytes, to: fixture)
            let actualBytes = (try fixture.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            let indexStart = clock.now
            let index = try PiSessionParser.indexEntry(at: fixture)
            let indexDuration = indexStart.duration(to: clock.now)
            let rssAfterIndex = residentByteCount()

            let transcriptStart = clock.now
            let entries = try PiSessionParser.entries(at: fixture)
            let transcriptDuration = transcriptStart.duration(to: clock.now)
            let rssAfterTranscript = residentByteCount()

            let record: [String: Any] = [
                "fixtureMiB": mebibytes,
                "fixtureBytes": actualBytes,
                "messageCount": index.messageCount,
                "entryCount": entries.count,
                "indexSeconds": seconds(indexDuration),
                "transcriptSeconds": seconds(transcriptDuration),
                "rssAfterIndexBytes": rssAfterIndex,
                "rssAfterTranscriptBytes": rssAfterTranscript,
            ]
            let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            output.append(json)
            output.append(0x0A)

            #expect(index.messageCount == entries.count)
            #expect(actualBytes <= mebibytes * 1_024 * 1_024)
            #expect(actualBytes >= (mebibytes * 1_024 * 1_024) - 8_192)
        }

        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let benchmarkDirectory = repositoryRoot.appending(path: ".build/Benchmark", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: benchmarkDirectory, withIntermediateDirectories: true)
        try output.write(
            to: benchmarkDirectory.appending(path: "session-fixtures.jsonl"),
            options: .atomic
        )
        #endif
    }

    private func writeFixture(mebibytes: Int, to url: URL) throws {
        let targetBytes = mebibytes * 1_024 * 1_024
        let header = Data("""
        {"type":"session","version":3,"id":"benchmark-\(mebibytes)","timestamp":"2026-08-24T12:00:00Z","cwd":"/tmp"}

        """.utf8)
        let payload = String(repeating: "x", count: 3_840)
        let message = Data("""
        {"type":"message","id":"message","timestamp":"2026-08-24T12:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"\(payload)"}]}}

        """.utf8)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: header)
        var written = header.count
        while written + message.count <= targetBytes {
            try Task.checkCancellation()
            try handle.write(contentsOf: message)
            written += message.count
        }
    }

    private func residentByteCount() -> UInt64 {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(information.resident_size) : 0
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
