import Foundation
import os

public actor SessionIndexStore {
    private static let signposter = OSSignposter(
        subsystem: "com.paulsousa.ApplePi",
        category: .pointsOfInterest
    )

    public struct ScanMeasurement: Sendable, Equatable {
        public enum Mode: Sendable, Equatable {
            case fullFile
            case incremental
            case reused
        }

        public let path: URL
        public let mode: Mode
        public let bytesRead: Int64
    }

    private struct FileCheckpoint: Codable, Sendable, Hashable {
        let identity: String?
        let observedByteCount: Int64
        let lastCompleteJSONLOffset: Int64
        let modifiedAt: Date
    }

    private struct CachedRecord: Codable, Sendable, Hashable {
        var entry: SessionIndexEntry
        let checkpoint: FileCheckpoint
    }

    private struct CacheFile: Codable, Sendable {
        let version: Int
        let records: [CachedRecord]
    }

    private struct DiagnosticRecord: Sendable, Hashable {
        let path: URL
        let message: String
    }

    private struct ScanResult: Sendable {
        let recordsByPath: [String: CachedRecord]
        let diagnostics: [DiagnosticRecord]
    }

    public nonisolated let updates: AsyncStream<SessionIndexSnapshot>

    private let rootURL: URL
    private let cacheURL: URL
    private let presentationStore: PresentationStateStore
    private let scanObserver: (@Sendable (ScanMeasurement) -> Void)?
    private let updateContinuation: AsyncStream<SessionIndexSnapshot>.Continuation
    private var recordsByPath: [String: CachedRecord] = [:]
    private var diagnostics: [DiagnosticRecord] = []
    private var cacheLoaded = false
    private var isRefreshing = false
    private var pendingFullRefresh = false
    private var pendingPaths: Set<URL> = []
    private var pendingDirectoryPaths: Set<URL> = []
    private var refreshWaiters: [CheckedContinuation<SessionIndexSnapshot, Never>] = []
    private var watcher: RecursiveFileSystemWatcher?
    private var debounceTask: Task<Void, Never>?
    private var isWatching = false

    public init(
        rootURL: URL = SessionIndexStore.defaultSessionRoot(),
        cacheURL: URL = AppPaths().sessionIndexCache,
        presentationStore: PresentationStateStore = .init(),
        scanObserver: (@Sendable (ScanMeasurement) -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.cacheURL = cacheURL
        self.presentationStore = presentationStore
        self.scanObserver = scanObserver
        let stream = AsyncStream.makeStream(
            of: SessionIndexSnapshot.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        updates = stream.stream
        updateContinuation = stream.continuation
    }

    deinit {
        watcher?.stop()
        debounceTask?.cancel()
        updateContinuation.finish()
    }

    public func snapshot() -> [SessionIndexEntry] {
        sortedEntries(from: recordsByPath)
    }

    /// Requests an authoritative scan. Concurrent callers coalesce behind the
    /// active scan, with at most one dirty follow-up for a burst of requests.
    @discardableResult
    public func refresh() async -> SessionIndexSnapshot {
        pendingFullRefresh = true
        return await runRefreshLoopOrWait()
    }

    /// Refreshes known session paths without enumerating the entire session tree.
    @discardableResult
    public func refresh(paths: [URL]) async -> SessionIndexSnapshot {
        for path in paths where path.pathExtension.lowercased() == "jsonl" {
            pendingPaths.insert(path.standardizedFileURL)
        }
        guard !pendingPaths.isEmpty else { return makeSnapshot() }
        return await runRefreshLoopOrWait()
    }

    /// Applies a native filesystem change immediately. The watcher uses the same
    /// classification path with its normal debounce; this seam keeps recovery
    /// from dropped or root-invalidating events directly testable.
    @discardableResult
    func refresh(afterFileSystemChange change: RecursiveFileSystemChange) async -> SessionIndexSnapshot {
        record(change)
        debounceTask?.cancel()
        debounceTask = nil
        guard pendingFullRefresh || !pendingPaths.isEmpty || !pendingDirectoryPaths.isEmpty else {
            return makeSnapshot()
        }
        return await runRefreshLoopOrWait()
    }

    public func startWatching() throws {
        guard !isWatching else { return }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let newWatcher = RecursiveFileSystemWatcher(urls: [rootURL]) { [weak self] change in
            Task { await self?.scheduleRefresh(for: change) }
        }
        try newWatcher.start()
        watcher = newWatcher
        isWatching = true
    }

    public func stopWatching() {
        isWatching = false
        watcher?.stop()
        watcher = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Presentation data is already durably stored by `PresentationStateStore`.
    /// Re-project it over the in-memory index instead of rescanning JSONL files.
    public func presentationDidChange() async {
        loadCacheIfNeeded()
        let presentation = await presentationStore.allStates()
        var updated = recordsByPath
        for (path, var record) in updated {
            record.entry.presentation = presentation[path] ?? .init()
            updated[path] = record
        }
        commitVisible(records: updated, diagnostics: diagnostics, writeCache: false)
    }

    private func scheduleRefresh(for change: RecursiveFileSystemChange) {
        record(change)
        guard pendingFullRefresh || !pendingPaths.isEmpty || !pendingDirectoryPaths.isEmpty else { return }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard let self else { return }
            _ = await self.runRefreshLoopOrWait()
        }
    }

    private func record(_ change: RecursiveFileSystemChange) {
        if change.requiresFullScan {
            pendingFullRefresh = true
            pendingPaths.removeAll()
            pendingDirectoryPaths.removeAll()
        } else if !pendingFullRefresh {
            for path in change.paths where path.pathExtension.lowercased() == "jsonl" {
                pendingPaths.insert(path.standardizedFileURL)
            }
            let canonicalRoot = Self.canonicalPath(rootURL)
            for directory in change.directoryPaths
                where Self.canonicalPath(directory) != canonicalRoot {
                pendingDirectoryPaths.insert(directory.standardizedFileURL)
            }
        }
    }

    private func runRefreshLoopOrWait() async -> SessionIndexSnapshot {
        if isRefreshing {
            return await withCheckedContinuation { continuation in
                refreshWaiters.append(continuation)
            }
        }

        isRefreshing = true
        loadCacheIfNeeded()
        repeat {
            let fullRefresh = pendingFullRefresh
            let targetedPaths = pendingPaths
            let targetedDirectories = pendingDirectoryPaths
            pendingFullRefresh = false
            pendingPaths.removeAll()
            pendingDirectoryPaths.removeAll()

            let root = rootURL
            let baseline = recordsByPath
            let baselineDiagnostics = diagnostics
            let scanObserver = scanObserver
            let result = await Task.detached(priority: .utility) {
                let interval = Self.signposter.beginInterval("SessionIndexScan")
                defer { Self.signposter.endInterval("SessionIndexScan", interval) }
                if fullRefresh {
                    return Self.scanAll(root: root, cached: baseline, observer: scanObserver)
                }
                let expandedPaths = Self.expanding(
                    targetedPaths,
                    forChangedDirectories: targetedDirectories,
                    cached: baseline
                )
                return Self.scan(
                    paths: expandedPaths,
                    cached: baseline,
                    diagnostics: baselineDiagnostics,
                    observer: scanObserver
                )
            }.value
            let presentation = await presentationStore.allStates()
            let projected = Self.applying(presentation, to: result.recordsByPath)
            commitVisible(records: projected, diagnostics: result.diagnostics, writeCache: true)
        } while pendingFullRefresh || !pendingPaths.isEmpty || !pendingDirectoryPaths.isEmpty

        isRefreshing = false
        let snapshot = makeSnapshot()
        let waiters = refreshWaiters
        refreshWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume(returning: snapshot) }
        return snapshot
    }

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let file = try? AtomicJSONFile.read(CacheFile.self, from: cacheURL),
              file.version == 2 else { return }
        recordsByPath = Dictionary(
            file.records.map { (Self.canonicalPath($0.entry.path), $0) },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    private func commitVisible(
        records: [String: CachedRecord],
        diagnostics newDiagnostics: [DiagnosticRecord],
        writeCache: Bool
    ) {
        let visibleChanged = records != recordsByPath || newDiagnostics != diagnostics
        let cacheChanged = Self.cacheRecords(records) != Self.cacheRecords(recordsByPath)
        recordsByPath = records
        diagnostics = newDiagnostics

        if writeCache, cacheChanged {
            let cache = CacheFile(version: 2, records: Self.cacheRecords(records))
            try? AtomicJSONFile.write(cache, to: cacheURL)
        }
        guard visibleChanged else { return }
        updateContinuation.yield(makeSnapshot())
    }

    private func makeSnapshot() -> SessionIndexSnapshot {
        SessionIndexSnapshot(
            entries: sortedEntries(from: recordsByPath),
            diagnostics: diagnostics.map {
                SessionIndexDiagnostic(path: $0.path, message: $0.message)
            },
            refreshedAt: Date()
        )
    }

    private func sortedEntries(from records: [String: CachedRecord]) -> [SessionIndexEntry] {
        records.values.map(\.entry).sorted {
            if $0.presentation.isPinned != $1.presentation.isPinned {
                return $0.presentation.isPinned && !$1.presentation.isPinned
            }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    private static func applying(
        _ presentation: [String: SessionPresentationState],
        to records: [String: CachedRecord]
    ) -> [String: CachedRecord] {
        var projected = records
        for (path, var record) in projected {
            record.entry.presentation = presentation[path] ?? .init()
            projected[path] = record
        }
        return projected
    }

    private static func cacheRecords(_ records: [String: CachedRecord]) -> [CachedRecord] {
        records.values.map { record in
            var cacheRecord = record
            cacheRecord.entry.presentation = .init()
            return cacheRecord
        }.sorted { canonicalPath($0.entry.path) < canonicalPath($1.entry.path) }
    }

    private static func scanAll(
        root: URL,
        cached: [String: CachedRecord],
        observer: (@Sendable (ScanMeasurement) -> Void)?
    ) -> ScanResult {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ScanResult(recordsByPath: [:], diagnostics: [])
        }

        var records: [String: CachedRecord] = [:]
        var diagnostics: [DiagnosticRecord] = []
        let decoder = JSONDecoder()
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
            do {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { continue }
                let path = canonicalPath(url)
                records[path] = try scanFile(
                    url,
                    cached: cached[path],
                    decoder: decoder,
                    observer: observer
                )
            } catch {
                diagnostics.append(DiagnosticRecord(path: url, message: error.localizedDescription))
            }
        }
        return ScanResult(recordsByPath: records, diagnostics: diagnostics)
    }

    private static func scan(
        paths: Set<URL>,
        cached: [String: CachedRecord],
        diagnostics existingDiagnostics: [DiagnosticRecord],
        observer: (@Sendable (ScanMeasurement) -> Void)?
    ) -> ScanResult {
        var records = cached
        let refreshedPaths = Set(paths.map(canonicalPath))
        var diagnostics = existingDiagnostics.filter { !refreshedPaths.contains(canonicalPath($0.path)) }
        let decoder = JSONDecoder()

        for url in paths {
            let path = canonicalPath(url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                records.removeValue(forKey: path)
                continue
            }
            do {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else {
                    records.removeValue(forKey: path)
                    continue
                }
                records[path] = try scanFile(
                    url,
                    cached: records[path],
                    decoder: decoder,
                    observer: observer
                )
            } catch {
                records.removeValue(forKey: path)
                diagnostics.append(DiagnosticRecord(path: url, message: error.localizedDescription))
            }
        }
        return ScanResult(recordsByPath: records, diagnostics: diagnostics)
    }

    private static func expanding(
        _ paths: Set<URL>,
        forChangedDirectories directories: Set<URL>,
        cached: [String: CachedRecord]
    ) -> Set<URL> {
        guard !directories.isEmpty else { return paths }
        var expanded = paths
        let fileManager = FileManager.default

        for directory in directories {
            try? Task.checkCancellation()
            let directoryPath = canonicalPath(directory)
            let descendantPrefix = directoryPath.hasSuffix("/") ? directoryPath : "\(directoryPath)/"

            for record in cached.values {
                let recordPath = canonicalPath(record.entry.path)
                if recordPath.hasPrefix(descendantPrefix) {
                    expanded.insert(record.entry.path.standardizedFileURL)
                }
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                expanded.insert(url.standardizedFileURL)
            }
        }
        return expanded
    }

    private static func scanFile(
        _ url: URL,
        cached: CachedRecord?,
        decoder: JSONDecoder,
        observer: (@Sendable (ScanMeasurement) -> Void)?
    ) throws -> CachedRecord {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        let identity = fileIdentity(from: attributes)

        if let cached,
           identity != nil,
           cached.checkpoint.identity == identity,
           cached.checkpoint.observedByteCount == size,
           abs(cached.checkpoint.modifiedAt.timeIntervalSince(modified)) < 0.001 {
            observer?(ScanMeasurement(path: url, mode: .reused, bytesRead: 0))
            return cached
        }

        let lastCompleteJSONLOffset = try lastCompleteJSONLOffset(url, byteCount: size)
        let entry: SessionIndexEntry
        if let cached,
                  cached.checkpoint.identity != nil,
                  cached.checkpoint.identity == identity,
                  cached.checkpoint.lastCompleteJSONLOffset == cached.checkpoint.observedByteCount,
                  size > cached.checkpoint.observedByteCount {
            entry = try PiSessionParser.updatingIndexEntry(
                cached.entry,
                at: url,
                fromOffset: UInt64(cached.checkpoint.observedByteCount),
                decoder: decoder
            )
            observer?(ScanMeasurement(
                path: url,
                mode: .incremental,
                bytesRead: size - cached.checkpoint.observedByteCount
            ))
        } else {
            entry = try PiSessionParser.indexEntry(at: url, decoder: decoder)
            observer?(ScanMeasurement(path: url, mode: .fullFile, bytesRead: size))
        }

        var refreshedEntry = entry
        if refreshedEntry.byteCount != size ||
            abs(refreshedEntry.modifiedAt.timeIntervalSince(modified)) >= 0.001 {
            refreshedEntry = SessionIndexEntry(
                sessionID: entry.sessionID,
                path: url.standardizedFileURL,
                workingDirectory: entry.workingDirectory,
                name: entry.name,
                parentSessionPath: entry.parentSessionPath,
                createdAt: entry.createdAt,
                modifiedAt: modified,
                byteCount: size,
                messageCount: entry.messageCount,
                firstMessage: entry.firstMessage,
                leafEntryID: entry.leafEntryID,
                presentation: entry.presentation
            )
        }
        return CachedRecord(
            entry: refreshedEntry,
            checkpoint: FileCheckpoint(
                identity: identity,
                observedByteCount: size,
                lastCompleteJSONLOffset: lastCompleteJSONLOffset,
                modifiedAt: modified
            )
        )
    }

    private static func fileIdentity(from attributes: [FileAttributeKey: Any]) -> String? {
        guard let system = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(system.uint64Value):\(file.uint64Value)"
    }

    private static func lastCompleteJSONLOffset(_ url: URL, byteCount: Int64) throws -> Int64 {
        guard byteCount > 0 else { return 0 }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(byteCount - 1))
        if try handle.read(upToCount: 1)?.first == 0x0A { return byteCount }

        var cursor = byteCount - 1
        let chunkByteCount: Int64 = 64 * 1_024
        while cursor > 0 {
            let count = min(chunkByteCount, cursor)
            let offset = cursor - count
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: Int(count)) ?? Data()
            if let newline = data.lastIndex(of: 0x0A) {
                return offset + Int64(data.distance(from: data.startIndex, to: newline)) + 1
            }
            cursor = offset
        }
        return 0
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func defaultSessionRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["PI_CODING_AGENT_SESSION_DIR"], !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        let agentDirectory: URL
        if let override = environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            agentDirectory = URL(filePath: override, directoryHint: .isDirectory)
        } else {
            agentDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".pi/agent", directoryHint: .isDirectory)
        }
        return agentDirectory.appending(path: "sessions", directoryHint: .isDirectory)
    }
}
