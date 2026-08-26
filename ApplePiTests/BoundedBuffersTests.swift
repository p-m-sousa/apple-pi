import Foundation
import Testing
@testable import ApplePi

@Suite("Bounded process buffers")
struct BoundedBuffersTests {
    @Test("JSONL fragments and CRLF are framed without loss")
    func fragmentedLines() throws {
        var buffer = BoundedLineBuffer(maximumLineBytes: 64, maximumBufferedBytes: 128)
        #expect(try buffer.append(Data("{\"a\":".utf8)).isEmpty)
        let lines = try buffer.append(Data("1}\r\n{\"b\":2}\npartial".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
        let remainder = try buffer.finish()
        #expect(String(decoding: try #require(remainder), as: UTF8.self) == "partial")
    }

    @Test("Oversized unterminated lines fail before unbounded growth")
    func oversizedLine() throws {
        var buffer = BoundedLineBuffer(maximumLineBytes: 4, maximumBufferedBytes: 8)
        #expect(throws: BoundedBufferError.self) {
            try buffer.append(Data("12345".utf8))
        }
    }

    @Test("A single chunk cannot exceed the total buffer cap")
    func oversizedChunk() throws {
        var buffer = BoundedLineBuffer(maximumLineBytes: 4, maximumBufferedBytes: 8)
        #expect(throws: BoundedBufferError.self) {
            try buffer.append(Data(repeating: UInt8(ascii: "x"), count: 9))
        }
        #expect(try buffer.finish() == nil)
    }

    @Test("One-byte fragments preserve a maximum-size line")
    func oneByteFragments() throws {
        var buffer = BoundedLineBuffer(maximumLineBytes: 4_096, maximumBufferedBytes: 8_192)
        for _ in 0..<4_096 {
            #expect(try buffer.append(Data([UInt8(ascii: "x")])).isEmpty)
        }
        let lines = try buffer.append(Data([0x0A]))
        #expect(lines.count == 1)
        #expect(lines[0].count == 4_096)
    }

    @Test("Diagnostic tails retain only the newest bytes")
    func stderrTail() {
        var buffer = ByteTailBuffer(capacity: 5)
        buffer.append(Data("abc".utf8))
        buffer.append(Data("defg".utf8))
        #expect(buffer.string == "cdefg")
    }

    @Test("Diagnostic tails stay correct across repeated compaction")
    func stderrTailCompaction() {
        var buffer = ByteTailBuffer(capacity: 32)
        var expected = Data()
        for value in 0..<1_000 {
            let chunk = Data("\(value),".utf8)
            expected.append(chunk)
            if expected.count > 32 { expected = Data(expected.suffix(32)) }
            buffer.append(chunk)
        }
        #expect(buffer.data == expected)
        #expect(buffer.string == String(decoding: expected, as: UTF8.self))
    }

    @Test("Byte-bounded streams surface an explicit recovery boundary")
    func byteBoundedStreamGap() async {
        let source = ByteBoundedAsyncStream<String>(
            maximumBufferedBytes: 10,
            makeGap: { ("gap", 1) }
        )
        #expect(source.yield("first", byteCost: 4) == .enqueued)
        #expect(source.yield("second", byteCost: 4) == .enqueued)
        #expect(source.bufferedByteCount == 8)
        #expect(source.yield("newest", byteCost: 4) == .dropped)
        #expect(source.bufferedByteCount == 5)

        var iterator = source.stream.makeAsyncIterator()
        #expect(await iterator.next() == "gap")
        #expect(await iterator.next() == "newest")
        source.finish()
        #expect(await iterator.next() == nil)
    }

    @Test("Byte-bounded streams discard only lossy entries and preserve control order")
    func byteBoundedStreamPreservesReliableEntries() async {
        enum Event: Sendable, Equatable {
            case control(String)
            case delta(String)
            case gap
        }

        let source = ByteBoundedAsyncStream<Event>(
            maximumBufferedBytes: 10,
            makeGap: { (.gap, 1) },
            isLossy: { event in
                if case .delta = event { return true }
                return false
            }
        )
        #expect(source.yield(.control("start"), byteCost: 100) == .enqueued)
        #expect(source.yield(.delta("one"), byteCost: 4) == .enqueued)
        #expect(source.yield(.delta("two"), byteCost: 4) == .enqueued)
        #expect(source.yield(.control("middle"), byteCost: 100) == .enqueued)
        #expect(source.yield(.delta("newest"), byteCost: 4) == .dropped)
        #expect(source.lossyBufferedByteCount == 4)

        var iterator = source.stream.makeAsyncIterator()
        #expect(await iterator.next() == .control("start"))
        #expect(await iterator.next() == .gap)
        #expect(await iterator.next() == .control("middle"))
        #expect(await iterator.next() == .delta("newest"))
        source.finish()
        #expect(await iterator.next() == nil)
    }

    @Test("Diagnostics redact common secrets and the home path")
    func redaction() {
        let text = "api_key=sk-example Bearer abc.def /Users/test/project"
        let result = DiagnosticsRedactor.redact(text, homeDirectory: URL(fileURLWithPath: "/Users/test"))
        #expect(!result.contains("sk-example"))
        #expect(!result.contains("abc.def"))
        #expect(result.contains("~/project"))
    }
}
