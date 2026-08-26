import Foundation
import Testing
@testable import ApplePi

@MainActor
@Suite("Adapter runtime isolation", .serialized)
struct AdapterRuntimeIsolationTests {
    @Test("Background task events never mutate the selected transcript or inspector")
    func backgroundEventsStayTaskLocal() async throws {
        let defaultsName = "AdapterRuntimeIsolationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let model = AppModel(defaults: defaults)
        let foreground = session(id: "foreground")
        let background = session(id: "background")
        model.sessions = [foreground, background]
        model.selection = .session(foreground.id)
        let originalItem = ApplePiTranscriptItem(
            id: "foreground-item",
            role: .assistant,
            kind: .answer,
            title: nil,
            content: "Foreground transcript",
            timestamp: .distantPast,
            isStreaming: false,
            attachments: []
        )
        model.replaceTranscript([originalItem])
        var inspector = ApplePiInspectorSnapshot.empty
        inspector.queuedMessages = 7
        inspector.thinkingLevel = "Foreground"
        model.inspector = inspector

        let adapter = ApplePiServiceAdapter()
        adapter.attach(to: model)
        let backgroundTaskID = PiTaskID()
        adapter.registerRuntimeTaskForTesting(backgroundTaskID, sessionID: background.id)
        let raw: JSONValue = .object(["arguments": .object(["value": .string("tool payload")])])

        await adapter.consumeRPCForTesting(.messageStarted(raw: .object([:])), taskID: backgroundTaskID)
        await adapter.consumeRPCForTesting(
            .messageUpdated(kind: "text", delta: "Background answer", raw: raw),
            taskID: backgroundTaskID
        )
        await adapter.consumeRPCForTesting(
            .toolStarted(id: "tool-1", name: "Background tool", raw: raw),
            taskID: backgroundTaskID
        )
        await adapter.consumeRPCForTesting(
            .queueUpdated(steering: ["one"], followUp: ["two"], raw: raw),
            taskID: backgroundTaskID
        )
        await adapter.consumeRPCForTesting(
            .thinkingLevelChanged(level: "Background", raw: raw),
            taskID: backgroundTaskID
        )
        try await Task.sleep(for: .milliseconds(75))

        #expect(model.selection == .session(foreground.id))
        #expect(model.transcript == [originalItem])
        #expect(model.inspector == inspector)
        let retained = adapter.runtimeRetentionForTesting(taskID: backgroundTaskID)
        #expect(retained.taskBytes > 0)
        #expect(retained.taskBytes <= 8 * 1_024 * 1_024)
        #expect(retained.globalBytes <= 32 * 1_024 * 1_024)
        #expect(!retained.needsCanonicalResynchronization)

        await adapter.consumeRPCForTesting(.messageEnded(raw: raw), taskID: backgroundTaskID)
        #expect(model.transcript == [originalItem])
        #expect(adapter.runtimeRetentionForTesting(taskID: backgroundTaskID).taskBytes == 0)
    }

    private func session(id: String) -> ApplePiUISession {
        ApplePiUISession(
            id: id,
            title: id.capitalized,
            workingDirectory: URL(filePath: "/tmp/\(id)", directoryHint: .isDirectory),
            sessionURL: nil,
            modifiedAt: .distantPast,
            state: .ready,
            isPinned: false,
            isArchived: false,
            wasCreatedByCLI: false,
            hasUserExtensions: false,
            projectID: nil
        )
    }
}
