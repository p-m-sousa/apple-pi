import Foundation
import Testing
@testable import ApplePi

@Suite("Canonical Pi session storage")
struct SessionPersistenceTests {
    private final class MeasurementCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SessionIndexStore.ScanMeasurement] = []

        func append(_ measurement: SessionIndexStore.ScanMeasurement) {
            lock.withLock { storage.append(measurement) }
        }

        func reset() {
            lock.withLock { storage.removeAll() }
        }

        var values: [SessionIndexStore.ScanMeasurement] {
            lock.withLock { storage }
        }
    }

    @Test("Indexing tolerates unknown entries and extracts canonical session metadata")
    func parsesIndexMetadata() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "session.jsonl")
        try TestSupport.write(Self.sessionJSONL, to: sessionURL)

        let entry = try PiSessionParser.indexEntry(at: sessionURL)
        #expect(entry.sessionID == "session-1")
        #expect(entry.workingDirectory.path == "/tmp/apple-pi project")
        #expect(entry.parentSessionPath == "/tmp/parent.jsonl")
        #expect(entry.name == "Renamed task")
        #expect(entry.messageCount == 2)
        #expect(entry.firstMessage == "Build the app\nKeep it light")
        #expect(entry.leafEntryID == "info-1")
        #expect(entry.byteCount > 0)
    }

    @Test("Tree entries stay lossless and can be loaded lazily")
    func parsesEntriesLazily() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "session.jsonl")
        try TestSupport.write(Self.sessionJSONL, to: sessionURL)

        let index = try PiSessionParser.indexEntry(at: sessionURL)
        let firstTwo = try PiSessionParser.entries(at: sessionURL, maximumEntries: 2)
        #expect(firstTwo.map(\.id) == ["message-1", "future-1"])
        #expect(firstTwo[1].type == "extension_future_entry")
        #expect(firstTwo[1].raw["extensionPayload"]?["kept"]?.boolValue == true)

        let all = try await SessionFileService.loadEntries(from: index)
        #expect(all.count == 4)
        #expect(all.last?.parentID == "message-2")
    }

    @Test("Malformed or headerless files are reported without poisoning other sessions")
    func invalidFiles() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let empty = directory.appending(path: "empty.jsonl")
        try Data().write(to: empty)
        #expect(throws: PiSessionParserError.self) {
            try PiSessionParser.indexEntry(at: empty)
        }

        let headerless = directory.appending(path: "headerless.jsonl")
        try TestSupport.write(#"{"type":"message","id":"entry"}"#, to: headerless)
        #expect(throws: PiSessionParserError.self) {
            try PiSessionParser.indexEntry(at: headerless)
        }

        let corrupt = directory.appending(path: "corrupt.jsonl")
        try TestSupport.write("{not-json}\n", to: corrupt)
        #expect(throws: (any Error).self) {
            try PiSessionParser.indexEntry(at: corrupt)
        }
    }

    @Test("Session index cache is rebuildable and presentation state remains separate")
    func cacheRebuildAndPresentationState() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = directory.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionURL = sessions.appending(path: "session.jsonl")
        try TestSupport.write(Self.sessionJSONL, to: sessionURL)

        let cacheURL = directory.appending(path: "cache/session-index.json")
        let presentationURL = directory.appending(path: "support/presentation.json")
        let presentation = PresentationStateStore(fileURL: presentationURL)
        let projectID = ApplePiProjectID(
            rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        try await presentation.setPinned(true, for: sessionURL)
        try await presentation.setArchived(true, for: sessionURL)
        try await presentation.setProjectID(projectID, for: sessionURL)

        let firstStore = SessionIndexStore(
            rootURL: sessions,
            cacheURL: cacheURL,
            presentationStore: presentation
        )
        let first = await firstStore.refresh()
        #expect(first.entries.count == 1)
        #expect(first.entries[0].presentation == SessionPresentationState(
            isPinned: true,
            isArchived: true,
            projectID: projectID,
            hasExplicitProjectAssignment: true
        ))
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        // A cache is an optimization only. Invalid cache bytes must result in a clean scan.
        try TestSupport.write("not a cache", to: cacheURL)
        let reloadedPresentation = PresentationStateStore(fileURL: presentationURL)
        let rebuiltStore = SessionIndexStore(
            rootURL: sessions,
            cacheURL: cacheURL,
            presentationStore: reloadedPresentation
        )
        let rebuilt = await rebuiltStore.refresh()
        #expect(rebuilt.entries.map(\.sessionID) == ["session-1"])
        #expect(rebuilt.entries[0].presentation.isPinned)
        #expect(rebuilt.entries[0].presentation.isArchived)
        #expect(rebuilt.entries[0].presentation.projectID == projectID)
        #expect(rebuilt.entries[0].presentation.hasExplicitProjectAssignment == true)
        #expect(rebuilt.diagnostics.isEmpty)
    }

    @Test("Existing presentation v1 files decode without project membership")
    func presentationV1Migration() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "legacy.jsonl")
        let presentationURL = directory.appending(path: "presentation.json")
        let fixture: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionURL.standardizedFileURL.resolvingSymlinksInPath().path: [
                    "isPinned": true,
                    "isArchived": false,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
            .write(to: presentationURL, options: .atomic)

        let store = PresentationStateStore(fileURL: presentationURL)
        let legacyState = await store.state(for: sessionURL)
        #expect(legacyState.isPinned)
        #expect(!legacyState.isArchived)
        #expect(legacyState.projectID == nil)
        #expect(legacyState.hasExplicitProjectAssignment == nil)

        let projectID = ApplePiProjectID()
        try await store.setProjectID(projectID, for: sessionURL)
        let reloaded = await PresentationStateStore(fileURL: presentationURL).state(for: sessionURL)
        #expect(reloaded.isPinned)
        #expect(!reloaded.isArchived)
        #expect(reloaded.projectID == projectID)
        #expect(reloaded.hasExplicitProjectAssignment == true)
    }

    @Test("Clearing a project assignment preserves other presentation state")
    func clearingProjectAssignmentPreservesState() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "session.jsonl")
        let presentationURL = directory.appending(path: "presentation.json")
        let projectID = ApplePiProjectID()
        let store = PresentationStateStore(fileURL: presentationURL)

        try await store.setPinned(true, for: sessionURL)
        try await store.setArchived(true, for: sessionURL)
        try await store.setProjectID(projectID, for: sessionURL)
        try await store.removeProjectAssignments(for: projectID)

        let state = await store.state(for: sessionURL)
        #expect(state.isPinned)
        #expect(state.isArchived)
        #expect(state.projectID == nil)
        #expect(state.hasExplicitProjectAssignment == true)
    }

    @Test("Bulk archive persists all presentation changes in one store mutation")
    func bulkArchivePresentationState() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "first.jsonl")
        let second = directory.appending(path: "second.jsonl")
        let fileURL = directory.appending(path: "presentation.json")
        let store = PresentationStateStore(fileURL: fileURL)

        try await store.setArchived(true, for: [first, second])

        let reloaded = PresentationStateStore(fileURL: fileURL)
        #expect(await reloaded.state(for: first).isArchived)
        #expect(await reloaded.state(for: second).isArchived)
    }

    @Test("Moving a session to Tasks persists an explicit standalone assignment")
    func explicitStandaloneProjectAssignment() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "standalone.jsonl")
        let presentationURL = directory.appending(path: "presentation.json")
        let presentation = PresentationStateStore(fileURL: presentationURL)

        try await presentation.setProjectID(nil, for: sessionURL)

        let reloaded = await PresentationStateStore(fileURL: presentationURL).state(for: sessionURL)
        #expect(reloaded.projectID == nil)
        #expect(reloaded.hasExplicitProjectAssignment == true)
    }

    @Test("A bad JSONL file produces a scoped diagnostic while valid sessions remain")
    func scanDiagnosticsAreScoped() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appending(path: "good.jsonl")
        let bad = directory.appending(path: "bad.jsonl")
        try TestSupport.write(Self.sessionJSONL, to: good)
        try TestSupport.write("not-json\n", to: bad)

        let store = SessionIndexStore(
            rootURL: directory,
            cacheURL: directory.appending(path: "cache.json"),
            presentationStore: PresentationStateStore(fileURL: directory.appending(path: "presentation.json"))
        )
        let snapshot = await store.refresh()
        #expect(snapshot.entries.map(\.sessionID) == ["session-1"])
        #expect(snapshot.diagnostics.count == 1)
        #expect(snapshot.diagnostics[0].path.lastPathComponent == "bad.jsonl")
    }

    @Test("A deleted canonical session is not resurrected by the index cache")
    func deletedSessionStaysDeletedAfterRefresh() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = directory.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionURL = sessions.appending(path: "session.jsonl")
        try TestSupport.write(Self.sessionJSONL, to: sessionURL)

        let cacheURL = directory.appending(path: "cache/session-index.json")
        let presentationURL = directory.appending(path: "support/presentation.json")
        let store = SessionIndexStore(
            rootURL: sessions,
            cacheURL: cacheURL,
            presentationStore: PresentationStateStore(fileURL: presentationURL)
        )

        let indexed = await store.refresh()
        #expect(indexed.entries.map(\.sessionID) == ["session-1"])
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        try FileManager.default.removeItem(at: sessionURL)
        let refreshed = await store.refresh()
        #expect(refreshed.entries.isEmpty)

        let reloaded = SessionIndexStore(
            rootURL: sessions,
            cacheURL: cacheURL,
            presentationStore: PresentationStateStore(fileURL: presentationURL)
        )
        let rebuilt = await reloaded.refresh()
        #expect(rebuilt.entries.isEmpty)
        #expect(rebuilt.diagnostics.isEmpty)
    }

    @Test("Append-only session growth is indexed from the previous byte offset")
    func incrementalSessionIndexing() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "incremental.jsonl")
        let initial = """
        {"type":"session","version":3,"id":"session-incremental","timestamp":"2026-08-24T12:00:00Z","cwd":"/tmp"}
        {"type":"message","id":"message-1","timestamp":"2026-08-24T12:00:01Z","message":{"role":"user","content":"First"}}

        """
        try TestSupport.write(initial, to: sessionURL)
        let measurements = MeasurementCollector()
        let store = SessionIndexStore(
            rootURL: directory,
            cacheURL: directory.appending(path: "cache.json"),
            presentationStore: PresentationStateStore(fileURL: directory.appending(path: "presentation.json")),
            scanObserver: measurements.append
        )

        let first = await store.refresh()
        #expect(first.entries.first?.messageCount == 1)
        measurements.reset()

        let appended = Data("""
        {"type":"message","id":"message-2","timestamp":"2026-08-24T12:00:02Z","message":{"role":"assistant","content":"Second"}}

        """.utf8)
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended)
        try handle.close()

        let refreshed = await store.refresh(paths: [sessionURL])
        #expect(refreshed.entries.first?.messageCount == 2)
        #expect(refreshed.entries.first?.leafEntryID == "message-2")
        #expect(measurements.values == [SessionIndexStore.ScanMeasurement(
            path: sessionURL,
            mode: .incremental,
            bytesRead: Int64(appended.count)
        )])
    }

    @Test("A partial trailing line forces a safe full parse before future appends")
    func partialLineFallsBackToFullParse() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "partial.jsonl")
        try TestSupport.write("""
        {"type":"session","version":3,"id":"session-partial","timestamp":"2026-08-24T12:00:00Z","cwd":"/tmp"}
        {"type":"message","id":"message-1","timestamp":"2026-08-24T12:00:01Z","message":{"role":"user","content":"First"}}
        """, to: sessionURL)
        let measurements = MeasurementCollector()
        let store = SessionIndexStore(
            rootURL: directory,
            cacheURL: directory.appending(path: "cache.json"),
            presentationStore: PresentationStateStore(fileURL: directory.appending(path: "presentation.json")),
            scanObserver: measurements.append
        )
        _ = await store.refresh()
        measurements.reset()

        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let refreshed = await store.refresh(paths: [sessionURL])

        #expect(refreshed.entries.first?.messageCount == 1)
        #expect(measurements.values.count == 1)
        #expect(measurements.values.first?.mode == .fullFile)
    }

    @Test("Truncated and replaced sessions fall back to full-file indexing")
    func truncationAndReplacementFallBackToFullParse() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "session.jsonl")
        let initial = Self.indexFixture(
            sessionID: "initial-session",
            messages: ["one", "two", "three"]
        )
        try TestSupport.write(initial, to: sessionURL)
        let measurements = MeasurementCollector()
        let store = SessionIndexStore(
            rootURL: directory,
            cacheURL: directory.appending(path: "cache.json"),
            presentationStore: PresentationStateStore(fileURL: directory.appending(path: "presentation.json")),
            scanObserver: measurements.append
        )
        _ = await store.refresh()
        measurements.reset()

        let truncated = Self.indexFixture(sessionID: "initial-session", messages: ["short"])
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(truncated.utf8))
        try handle.close()

        let afterTruncation = await store.refresh(paths: [sessionURL])
        #expect(afterTruncation.entries.first?.sessionID == "initial-session")
        #expect(afterTruncation.entries.first?.messageCount == 1)
        #expect(measurements.values == [SessionIndexStore.ScanMeasurement(
            path: sessionURL,
            mode: .fullFile,
            bytesRead: Int64(Data(truncated.utf8).count)
        )])

        measurements.reset()
        let replacementURL = directory.appending(path: "replacement.jsonl")
        let replacement = Self.indexFixture(
            sessionID: "replacement-session",
            messages: ["alpha", "beta", "gamma", "delta"]
        )
        try TestSupport.write(replacement, to: replacementURL)
        try FileManager.default.removeItem(at: sessionURL)
        try FileManager.default.moveItem(at: replacementURL, to: sessionURL)

        let afterReplacement = await store.refresh(paths: [sessionURL])
        #expect(afterReplacement.entries.first?.sessionID == "replacement-session")
        #expect(afterReplacement.entries.first?.messageCount == 4)
        #expect(measurements.values == [SessionIndexStore.ScanMeasurement(
            path: sessionURL,
            mode: .fullFile,
            bytesRead: Int64(Data(replacement.utf8).count)
        )])
    }

    @Test("A same-size, same-mtime inode replacement is never reused")
    func matchingMetadataReplacementFallsBackToFullParse() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "session.jsonl")
        let replacementURL = directory.appending(path: "replacement.jsonl")
        let initial = Self.indexFixture(sessionID: "session-original", messages: ["one"])
        let replacement = Self.indexFixture(sessionID: "session-replaced", messages: ["two"])
        #expect(initial.utf8.count == replacement.utf8.count)
        try TestSupport.write(initial, to: sessionURL)
        let initialAttributes = try FileManager.default.attributesOfItem(atPath: sessionURL.path)
        let initialIdentity = try #require(initialAttributes[.systemFileNumber] as? NSNumber)
        let initialModifiedAt = try #require(initialAttributes[.modificationDate] as? Date)

        let measurements = MeasurementCollector()
        let store = SessionIndexStore(
            rootURL: directory,
            cacheURL: directory.appending(path: "cache.json"),
            presentationStore: PresentationStateStore(fileURL: directory.appending(path: "presentation.json")),
            scanObserver: measurements.append
        )
        _ = await store.refresh()
        measurements.reset()

        try TestSupport.write(replacement, to: replacementURL)
        try FileManager.default.setAttributes(
            [.modificationDate: initialModifiedAt],
            ofItemAtPath: replacementURL.path
        )
        try FileManager.default.removeItem(at: sessionURL)
        try FileManager.default.moveItem(at: replacementURL, to: sessionURL)
        try FileManager.default.setAttributes(
            [.modificationDate: initialModifiedAt],
            ofItemAtPath: sessionURL.path
        )
        let replacementAttributes = try FileManager.default.attributesOfItem(atPath: sessionURL.path)
        let replacementIdentity = try #require(replacementAttributes[.systemFileNumber] as? NSNumber)
        let replacementModifiedAt = try #require(replacementAttributes[.modificationDate] as? Date)
        #expect(initialIdentity != replacementIdentity)
        #expect(abs(initialModifiedAt.timeIntervalSince(replacementModifiedAt)) < 0.001)

        let refreshed = await store.refresh(paths: [sessionURL])

        #expect(refreshed.entries.first?.sessionID == "session-replaced")
        #expect(measurements.values == [SessionIndexStore.ScanMeasurement(
            path: sessionURL,
            mode: .fullFile,
            bytesRead: Int64(Data(replacement.utf8).count)
        )])
    }

    @Test("Renamed sessions remove the old path and index the new path")
    func sessionRenameUpdatesCanonicalPath() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appending(path: "old.jsonl")
        let newURL = directory.appending(path: "nested/new.jsonl")
        try TestSupport.write(Self.indexFixture(sessionID: "renamed-session", messages: ["one"]), to: oldURL)
        let store = SessionIndexStore(
            rootURL: directory,
            cacheURL: directory.appending(path: "cache.json"),
            presentationStore: PresentationStateStore(fileURL: directory.appending(path: "presentation.json"))
        )
        _ = await store.refresh()

        try FileManager.default.createDirectory(
            at: newURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        let refreshed = await store.refresh(paths: [oldURL, newURL])

        #expect(refreshed.entries.count == 1)
        #expect(refreshed.entries.first?.sessionID == "renamed-session")
        #expect(refreshed.entries.first?.path.standardizedFileURL == newURL.standardizedFileURL)
        #expect(!refreshed.entries.contains { $0.path.standardizedFileURL == oldURL.standardizedFileURL })
    }

    @Test("A version-1 index cache triggers one authoritative rebuild without touching sessions")
    func versionOneIndexCacheMigratesByRebuilding() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "session.jsonl")
        let sessionBytes = Data(Self.indexFixture(sessionID: "legacy-cache-session", messages: ["one"]).utf8)
        try sessionBytes.write(to: sessionURL)
        let cacheURL = directory.appending(path: "cache/index.json")
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"version":1,"records":[]}"#.utf8).write(to: cacheURL)
        let measurements = MeasurementCollector()
        let store = SessionIndexStore(
            rootURL: directory,
            cacheURL: cacheURL,
            presentationStore: PresentationStateStore(fileURL: directory.appending(path: "presentation.json")),
            scanObserver: measurements.append
        )

        let refreshed = await store.refresh()

        #expect(refreshed.entries.map(\.sessionID) == ["legacy-cache-session"])
        #expect(measurements.values.count == 1)
        #expect(
            measurements.values.first?.path.resolvingSymlinksInPath() ==
                sessionURL.resolvingSymlinksInPath()
        )
        #expect(measurements.values.first?.mode == .fullFile)
        #expect(measurements.values.first?.bytesRead == Int64(sessionBytes.count))
        #expect(try Data(contentsOf: sessionURL) == sessionBytes)
        let cacheObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        )
        #expect(cacheObject["version"] as? Int == 2)
    }

    @Test("A dropped or root-invalidating FSEvent forces a full authoritative scan")
    func invalidatingFileSystemEventForcesFullScan() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existingURL = directory.appending(path: "existing.jsonl")
        let unreportedURL = directory.appending(path: "unreported.jsonl")
        try TestSupport.write(
            Self.indexFixture(sessionID: "existing-session", messages: ["one"]),
            to: existingURL
        )
        let measurements = MeasurementCollector()
        let store = SessionIndexStore(
            rootURL: directory,
            cacheURL: directory.appending(path: "cache.json"),
            presentationStore: PresentationStateStore(fileURL: directory.appending(path: "presentation.json")),
            scanObserver: measurements.append
        )
        _ = await store.refresh()
        measurements.reset()
        try TestSupport.write(
            Self.indexFixture(sessionID: "unreported-session", messages: ["two"]),
            to: unreportedURL
        )

        let refreshed = await store.refresh(afterFileSystemChange: RecursiveFileSystemChange(
            paths: [],
            requiresFullScan: true
        ))

        #expect(Set(refreshed.entries.map(\.sessionID)) == ["existing-session", "unreported-session"])
        #expect(measurements.values.count == 2)
        #expect(measurements.values.contains {
            $0.path.standardizedFileURL == unreportedURL.standardizedFileURL && $0.mode == .fullFile
        })
    }

    @Test("Ordinary directory events reconcile only the changed subtree")
    func directoryEventsStayTargeted() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstDirectory = directory.appending(path: "first", directoryHint: .isDirectory)
        let secondDirectory = directory.appending(path: "second", directoryHint: .isDirectory)
        let oldURL = firstDirectory.appending(path: "old.jsonl")
        let unaffectedURL = secondDirectory.appending(path: "unaffected.jsonl")
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try TestSupport.write(Self.indexFixture(sessionID: "moving", messages: ["one"]), to: oldURL)
        try TestSupport.write(Self.indexFixture(sessionID: "unaffected", messages: ["two"]), to: unaffectedURL)
        let measurements = MeasurementCollector()
        let store = SessionIndexStore(
            rootURL: directory,
            cacheURL: directory.appending(path: "cache.json"),
            presentationStore: PresentationStateStore(fileURL: directory.appending(path: "presentation.json")),
            scanObserver: measurements.append
        )
        _ = await store.refresh()
        measurements.reset()

        let renamedDirectory = directory.appending(path: "renamed", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: firstDirectory, to: renamedDirectory)
        let refreshed = await store.refresh(afterFileSystemChange: RecursiveFileSystemChange(
            paths: [firstDirectory, renamedDirectory],
            directoryPaths: [firstDirectory, renamedDirectory],
            requiresFullScan: false
        ))

        #expect(Set(refreshed.entries.map(\.sessionID)) == ["moving", "unaffected"])
        #expect(refreshed.entries.first { $0.sessionID == "moving" }?.path.deletingLastPathComponent()
            .standardizedFileURL == renamedDirectory.standardizedFileURL)
        #expect(!measurements.values.contains {
            $0.path.standardizedFileURL == unaffectedURL.standardizedFileURL
        })
        #expect(measurements.values.count == 1)
    }

    @Test("Concurrent refresh requests share one scan and one dirty follow-up")
    func concurrentRefreshesAreSingleFlight() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "session.jsonl")
        let messages = (0..<4_000).map { index in
            #"{"type":"message","id":"message-\#(index)","message":{"role":"assistant","content":"value"}}"#
        }.joined(separator: "\n")
        try TestSupport.write("""
        {"type":"session","version":3,"id":"session-single-flight","timestamp":"2026-08-24T12:00:00Z","cwd":"/tmp"}
        \(messages)

        """, to: sessionURL)
        let measurements = MeasurementCollector()
        let store = SessionIndexStore(
            rootURL: directory,
            cacheURL: directory.appending(path: "cache.json"),
            presentationStore: PresentationStateStore(fileURL: directory.appending(path: "presentation.json")),
            scanObserver: measurements.append
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = await store.refresh() }
            }
        }

        #expect(await store.snapshot().first?.messageCount == 4_000)
        #expect(measurements.values.count <= 2)
    }

    @Test("Session directory overrides follow Pi's environment variables")
    func sessionRootOverrides() {
        #expect(SessionIndexStore.defaultSessionRoot(environment: [
            "PI_CODING_AGENT_SESSION_DIR": "/tmp/custom-sessions",
            "PI_CODING_AGENT_DIR": "/tmp/ignored-agent",
        ]).path == "/tmp/custom-sessions")

        #expect(SessionIndexStore.defaultSessionRoot(environment: [
            "PI_CODING_AGENT_DIR": "/tmp/custom-agent",
        ]).path == "/tmp/custom-agent/sessions")
    }

    @Test("Raw exports copy canonical JSONL bytes exactly")
    func rawExport() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.jsonl")
        let destination = directory.appending(path: "export.jsonl")
        try TestSupport.write(Self.sessionJSONL, to: source)
        let session = try PiSessionParser.indexEntry(at: source)

        try SessionFileService.exportRawJSONL(session, to: destination)
        #expect(try Data(contentsOf: destination) == Data(Self.sessionJSONL.utf8))
        try SessionFileService.exportRawJSONL(session, to: source)
        #expect(try Data(contentsOf: source) == Data(Self.sessionJSONL.utf8))
    }

    @Test("Transcript loading projects branches and content-hash caches images off the UI model")
    func transcriptProjectionAndImageCache() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "session.jsonl")
        let imageCache = directory.appending(path: "images", directoryHint: .isDirectory)
        let encodedPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let originalPNG = try #require(Data(base64Encoded: encodedPNG))
        try TestSupport.write("""
        {"type":"session","version":3,"id":"loader-session","timestamp":"2026-08-24T12:00:00Z","cwd":"/tmp"}
        {"type":"message","id":"user-1","timestamp":"2026-08-24T12:00:01Z","message":{"role":"user","content":[{"type":"text","text":"Hello"},{"type":"image","mimeType":"image/png","data":"\(encodedPNG)"}]}}
        {"type":"message","id":"assistant-1","parentId":"user-1","timestamp":"2026-08-24T12:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Done"}]}}

        """, to: sessionURL)
        let session = try PiSessionParser.indexEntry(at: sessionURL)
        let oldCacheFile = imageCache.appending(path: "expired.png")
        try FileManager.default.createDirectory(at: imageCache, withIntermediateDirectories: true)
        try Data([0]).write(to: oldCacheFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-31 * 24 * 60 * 60)],
            ofItemAtPath: oldCacheFile.path
        )
        let loader = SessionTranscriptLoader(imageCacheDirectory: imageCache)

        let first = try await loader.load(session)
        let second = try await loader.load(session)

        #expect(first.items.map(\.content) == ["Hello", "Done"])
        #expect(first.branches.map(\.id) == ["user-1", "assistant-1"])
        #expect(first.branches.last?.isCurrent == true)
        let firstAttachment = try #require(first.items.first?.attachments.first)
        let secondAttachment = try #require(second.items.first?.attachments.first)
        #expect(firstAttachment.url == secondAttachment.url)
        #expect(firstAttachment.url.lastPathComponent.count == 68)
        #expect(firstAttachment.url.pathExtension == "png")
        #expect(try Data(contentsOf: firstAttachment.url) == originalPNG)
        #expect(!FileManager.default.fileExists(atPath: oldCacheFile.path))
    }

    @Test("Transcript image cache enforces its byte budget after every growth")
    func transcriptImageCacheByteEviction() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "session.jsonl")
        let imageCache = directory.appending(path: "images", directoryHint: .isDirectory)
        let firstImage = Data(repeating: 0x11, count: 80).base64EncodedString()
        let secondImage = Data(repeating: 0x22, count: 80).base64EncodedString()
        try TestSupport.write("""
        {"type":"session","version":3,"id":"cache-budget-session","timestamp":"2026-08-24T12:00:00Z","cwd":"/tmp"}
        {"type":"message","id":"user-1","timestamp":"2026-08-24T12:00:01Z","message":{"role":"user","content":[{"type":"image","mimeType":"image/png","data":"\(firstImage)"},{"type":"image","mimeType":"image/png","data":"\(secondImage)"}]}}

        """, to: sessionURL)
        let session = try PiSessionParser.indexEntry(at: sessionURL)
        let loader = SessionTranscriptLoader(
            imageCacheDirectory: imageCache,
            maximumImageCacheBytes: 100
        )

        let projection = try await loader.load(session)
        #expect(projection.items.first?.attachments.count == 2)
        let cachedFiles = try FileManager.default.contentsOfDirectory(
            at: imageCache,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        let cachedBytes = try cachedFiles.reduce(Int64(0)) { total, url in
            total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        #expect(cachedFiles.count == 1)
        #expect(cachedBytes <= 100)
    }

    private static let sessionJSONL = """
    {"type":"session","version":3,"id":"session-1","timestamp":"2026-08-24T12:00:00.000Z","cwd":"/tmp/apple-pi project","parentSession":"/tmp/parent.jsonl"}
    {"type":"message","id":"message-1","timestamp":"2026-08-24T12:00:01Z","message":{"role":"user","content":[{"type":"text","text":" Build the app "},{"type":"image","data":"ignored"},{"type":"text","text":"Keep it light"}]}}
    {"type":"extension_future_entry","id":"future-1","parentId":"message-1","timestamp":"2026-08-24T12:00:02Z","extensionPayload":{"kept":true}}
    {"type":"message","id":"message-2","parentId":"future-1","timestamp":"2026-08-24T12:00:03Z","message":{"role":"assistant","content":"Done"}}
    {"type":"session_info","id":"info-1","parentId":"message-2","timestamp":"2026-08-24T12:00:04Z","name":"Renamed task"}
    """

    private static func indexFixture(sessionID: String, messages: [String]) -> String {
        let records = messages.enumerated().map { index, content in
            #"{"type":"message","id":"message-\#(index)","timestamp":"2026-08-24T12:00:01Z","message":{"role":"assistant","content":"\#(content)"}}"#
        }
        return ([
            #"{"type":"session","version":3,"id":"\#(sessionID)","timestamp":"2026-08-24T12:00:00Z","cwd":"/tmp"}"#,
        ] + records).joined(separator: "\n") + "\n"
    }
}
