import Foundation

public enum BoundedBufferError: LocalizedError, Sendable {
    case bufferedBytesExceeded(limit: Int)
    case lineBytesExceeded(limit: Int)

    public var errorDescription: String? {
        switch self {
        case let .bufferedBytesExceeded(limit):
            "Pi produced more than \(limit) buffered bytes without a complete JSON line."
        case let .lineBytesExceeded(limit):
            "Pi produced a JSON line larger than the \(limit)-byte safety limit."
        }
    }
}

enum ByteBoundedStreamYieldResult: Sendable, Equatable {
    case delivered
    case enqueued
    case dropped
    case terminated
}

/// A single-consumer async sequence whose high-rate payload cost is bounded in
/// bytes rather than only by element count. Callers may mark lifecycle/control
/// entries as reliable; overflow then removes only lossy entries and inserts a
/// recovery marker at the first discarded position without reordering controls.
final class ByteBoundedAsyncStream<Element: Sendable>: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private struct Entry {
            let element: Element
            let byteCost: Int
            let isLossy: Bool
            let isGap: Bool
        }

        private let lock = NSLock()
        private let maximumBufferedBytes: Int
        private let makeGap: @Sendable () -> (element: Element, byteCost: Int)
        private let isLossy: @Sendable (Element) -> Bool
        private var entries: [Entry] = []
        private var head = 0
        private var bufferedBytes = 0
        private var lossyBufferedBytes = 0
        private var waiters: [CheckedContinuation<Element?, Never>] = []
        private var isFinished = false

        init(
            maximumBufferedBytes: Int,
            makeGap: @escaping @Sendable () -> (element: Element, byteCost: Int),
            isLossy: @escaping @Sendable (Element) -> Bool
        ) {
            self.maximumBufferedBytes = max(1, maximumBufferedBytes)
            self.makeGap = makeGap
            self.isLossy = isLossy
        }

        func yield(_ element: Element, byteCost: Int) -> ByteBoundedStreamYieldResult {
            var waiter: CheckedContinuation<Element?, Never>?
            var result = ByteBoundedStreamYieldResult.enqueued
            lock.lock()
            if isFinished {
                result = .terminated
            } else if !waiters.isEmpty {
                waiter = waiters.removeFirst()
                result = .delivered
            } else {
                let cost = max(1, byteCost)
                let lossy = isLossy(element)
                if !lossy {
                    entries.append(Entry(element: element, byteCost: cost, isLossy: false, isGap: false))
                    bufferedBytes += cost
                } else if cost <= maximumBufferedBytes - lossyBufferedBytes {
                    entries.append(Entry(element: element, byteCost: cost, isLossy: true, isGap: false))
                    bufferedBytes += cost
                    lossyBufferedBytes += cost
                } else {
                    discardLossyEntriesAndInsertGapLocked()
                    if cost <= maximumBufferedBytes {
                        entries.append(Entry(element: element, byteCost: cost, isLossy: true, isGap: false))
                        bufferedBytes += cost
                        lossyBufferedBytes = cost
                    }
                    result = .dropped
                }
            }
            lock.unlock()
            waiter?.resume(returning: element)
            return result
        }

        func next() async -> Element? {
            await withCheckedContinuation { continuation in
                var immediate: Element?
                var shouldResume = false
                lock.lock()
                if head < entries.count {
                    let entry = entries[head]
                    head += 1
                    bufferedBytes -= entry.byteCost
                    if entry.isLossy { lossyBufferedBytes -= entry.byteCost }
                    immediate = entry.element
                    shouldResume = true
                    compactIfNeededLocked()
                } else if isFinished {
                    shouldResume = true
                } else {
                    waiters.append(continuation)
                }
                lock.unlock()
                if shouldResume { continuation.resume(returning: immediate) }
            }
        }

        func finish() {
            var pendingWaiters: [CheckedContinuation<Element?, Never>] = []
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            pendingWaiters = waiters
            waiters.removeAll(keepingCapacity: false)
            lock.unlock()
            for waiter in pendingWaiters { waiter.resume(returning: nil) }
        }

        var bufferedByteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return bufferedBytes
        }

        var lossyBufferedByteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return lossyBufferedBytes
        }

        private func discardLossyEntriesAndInsertGapLocked() {
            let activeEntries = entries[head...]
            let firstDiscardedIndex = activeEntries.firstIndex(where: \.isLossy)
            let gap = makeGap()
            let gapEntry = Entry(
                element: gap.element,
                byteCost: max(1, gap.byteCost),
                isLossy: false,
                isGap: true
            )
            let alreadyHasGap = activeEntries.contains(where: \.isGap)
            var retained: [Entry] = []
            retained.reserveCapacity(activeEntries.count + 1)
            var insertedGap = false
            for index in activeEntries.indices {
                let entry = activeEntries[index]
                if entry.isLossy {
                    if !insertedGap, firstDiscardedIndex == index {
                            if !alreadyHasGap { retained.append(gapEntry) }
                            insertedGap = true
                    }
                } else {
                    retained.append(entry)
                }
            }
            if !insertedGap, !alreadyHasGap { retained.append(gapEntry) }
            entries = retained
            head = 0
            lossyBufferedBytes = 0
            bufferedBytes = retained.reduce(0) { $0 + $1.byteCost }
        }

        private func compactIfNeededLocked() {
            guard head > 1_024, head * 2 >= entries.count else { return }
            entries.removeFirst(head)
            head = 0
        }
    }

    let stream: AsyncStream<Element>
    private let state: State

    init(
        maximumBufferedBytes: Int,
        makeGap: @escaping @Sendable () -> (element: Element, byteCost: Int),
        isLossy: @escaping @Sendable (Element) -> Bool = { _ in true }
    ) {
        let state = State(
            maximumBufferedBytes: maximumBufferedBytes,
            makeGap: makeGap,
            isLossy: isLossy
        )
        self.state = state
        stream = AsyncStream(
            unfolding: { await state.next() },
            onCancel: { state.finish() }
        )
    }

    @discardableResult
    func yield(_ element: Element, byteCost: Int) -> ByteBoundedStreamYieldResult {
        state.yield(element, byteCost: byteCost)
    }

    func finish() { state.finish() }

    var bufferedByteCount: Int { state.bufferedByteCount }
    var lossyBufferedByteCount: Int { state.lossyBufferedByteCount }
}

/// Incrementally frames UTF-8/JSONL output while enforcing memory limits.
public struct BoundedLineBuffer: Sendable {
    public let maximumLineBytes: Int
    public let maximumBufferedBytes: Int
    private var storage = Data()
    /// Number of bytes in `storage` already checked for a newline. Keeping this
    /// cursor avoids rescanning a fragmented long line from byte zero on every
    /// pipe read.
    private var scannedByteCount = 0

    public init(maximumLineBytes: Int = 8 * 1_024 * 1_024, maximumBufferedBytes: Int = 16 * 1_024 * 1_024) {
        precondition(maximumLineBytes > 0)
        precondition(maximumBufferedBytes >= maximumLineBytes)
        self.maximumLineBytes = maximumLineBytes
        self.maximumBufferedBytes = maximumBufferedBytes
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        guard !data.isEmpty else { return [] }
        guard storage.count <= maximumBufferedBytes,
              data.count <= maximumBufferedBytes - storage.count else {
            throw BoundedBufferError.bufferedBytesExceeded(limit: maximumBufferedBytes)
        }
        storage.append(data)

        var lines: [Data] = []
        var lineStart = storage.startIndex
        var index = storage.index(storage.startIndex, offsetBy: scannedByteCount)
        while index < storage.endIndex {
            if storage[index] == 0x0A {
                var end = index
                if end > lineStart, storage[storage.index(before: end)] == 0x0D {
                    end = storage.index(before: end)
                }
                let length = storage.distance(from: lineStart, to: end)
                guard length <= maximumLineBytes else {
                    throw BoundedBufferError.lineBytesExceeded(limit: maximumLineBytes)
                }
                lines.append(storage.subdata(in: lineStart..<end))
                lineStart = storage.index(after: index)
            }
            index = storage.index(after: index)
        }

        if lineStart > storage.startIndex {
            storage.removeSubrange(storage.startIndex..<lineStart)
        }
        guard storage.count <= maximumLineBytes else {
            throw BoundedBufferError.lineBytesExceeded(limit: maximumLineBytes)
        }
        // Every retained byte belongs to the current unterminated line and was
        // inspected above. Only bytes appended by the next call need scanning.
        scannedByteCount = storage.count
        return lines
    }

    public mutating func finish() throws -> Data? {
        guard !storage.isEmpty else { return nil }
        guard storage.count <= maximumLineBytes else {
            throw BoundedBufferError.lineBytesExceeded(limit: maximumLineBytes)
        }
        defer {
            storage.removeAll(keepingCapacity: false)
            scannedByteCount = 0
        }
        return storage
    }
}

/// A byte-capped tail buffer suitable for stderr and command diagnostics.
public struct ByteTailBuffer: Sendable {
    public let capacity: Int
    private var storage: Data
    private var startIndex = 0
    private var retainedCount = 0

    public init(capacity: Int = 256 * 1_024) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Data()
    }

    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        if data.count >= capacity {
            storage = Data(data.suffix(capacity))
            startIndex = 0
            retainedCount = capacity
            return
        }

        var ringBytes = data[data.startIndex...]
        if storage.count < capacity {
            let fillCount = min(ringBytes.count, capacity - storage.count)
            storage.append(ringBytes.prefix(fillCount))
            retainedCount = storage.count
            guard fillCount < ringBytes.count else { return }
            ringBytes = ringBytes.dropFirst(fillCount)
        }

        // Once full, `startIndex` is both the oldest retained byte and the next
        // overwrite position. Storage never shifts or grows beyond `capacity`.
        let incomingCount = ringBytes.count
        let writeIndex = startIndex
        let firstCount = min(incomingCount, capacity - writeIndex)
        storage.replaceSubrange(
            writeIndex ..< writeIndex + firstCount,
            with: ringBytes.prefix(firstCount)
        )
        if firstCount < incomingCount {
            storage.replaceSubrange(
                0 ..< incomingCount - firstCount,
                with: ringBytes.suffix(incomingCount - firstCount)
            )
        }

        startIndex = (startIndex + incomingCount) % capacity
        retainedCount = capacity
    }

    public var data: Data {
        guard retainedCount > 0 else { return Data() }
        let firstCount = min(retainedCount, capacity - startIndex)
        var result = Data()
        result.reserveCapacity(retainedCount)
        result.append(storage[startIndex ..< startIndex + firstCount])
        if firstCount < retainedCount {
            result.append(storage[0 ..< retainedCount - firstCount])
        }
        return result
    }

    public var string: String { String(decoding: data, as: UTF8.self) }
}
