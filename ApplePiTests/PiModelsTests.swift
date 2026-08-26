import Foundation
import Testing
@testable import ApplePi

@Suite("Pi model contracts")
struct PiModelsTests {
    @Test("Semantic versions enforce the native compatibility window")
    func semanticVersionWindow() {
        #expect(SemanticVersion("pi 0.84.3") == SemanticVersion(major: 0, minor: 84, patch: 3))
        #expect(PiRuntimeVersionRange.nativeV1.contains(SemanticVersion(major: 0, minor: 84, patch: 2)))
        #expect(PiRuntimeVersionRange.nativeV1.contains(SemanticVersion(major: 0, minor: 84, patch: 99)))
        #expect(!PiRuntimeVersionRange.nativeV1.contains(SemanticVersion(major: 0, minor: 85, patch: 0)))
        #expect(SemanticVersion(major: 0, minor: 84, patch: 2, prerelease: "beta")
            < SemanticVersion(major: 0, minor: 84, patch: 2))
    }

    @Test("Runtime discovery has no bundled source")
    func runtimeDiscoverySources() {
        #expect(PiRuntimeSource.allCases == [
            .savedExecutable,
            .loginShellPath,
            .commonLocation,
        ])
    }

    @Test("Unknown JSON is preserved through a round trip")
    func jsonValueRoundTrip() throws {
        let source = Data(#"{"type":"future_event","nested":{"enabled":true},"items":[1,"two",null]}"#.utf8)
        let value = try JSONValue.decode(data: source)
        let reparsed = try JSONValue.decode(data: value.encodedData(sortedKeys: true))
        #expect(reparsed == value)
        #expect(value["nested"]?["enabled"]?.boolValue == true)
    }

    @Test("Prompt commands use Pi's exact streaming and image keys")
    func promptEncoding() throws {
        let command = PiRPCCommand.prompt(
            message: "Inspect this",
            images: [PiImageAttachment(data: "aGVsbG8=", mimeType: "image/png")],
            behavior: .followUp
        )
        let object = JSONValue.object(command.jsonObject(id: "request-1"))
        let decoded = try JSONSerialization.jsonObject(with: object.encodedData()) as? [String: Any]

        #expect(decoded?["id"] as? String == "request-1")
        #expect(decoded?["type"] as? String == "prompt")
        #expect(decoded?["streamingBehavior"] as? String == "followUp")
        let images = decoded?["images"] as? [[String: Any]]
        #expect(images?.first?["mimeType"] as? String == "image/png")
    }

    @Test("Extension responses match the dialog sub-protocol")
    func extensionUIResponseEncoding() {
        let response = PiRPCCommand.extensionUIResponse(.confirmed(id: "dialog-1", true))
        let object = response.jsonObject(id: "ignored")
        #expect(object["type"]?.stringValue == "extension_ui_response")
        #expect(object["id"]?.stringValue == "dialog-1")
        #expect(object["confirmed"]?.boolValue == true)
    }

    @Test("Numbered extension choices become native titles and descriptions without changing the response")
    func extensionChoicePresentation() {
        let rawValue = "1. Native SwiftUI (Recommended) — Uses platform controls and system behavior."
        let choice = ApplePiExtensionChoice(rawValue: rawValue)

        #expect(choice.rawValue == rawValue)
        #expect(choice.title == "Native SwiftUI")
        #expect(choice.detail == "Uses platform controls and system behavior.")
        #expect(choice.isRecommended)
    }

    @Test("Unstructured extension choices remain intact")
    func unstructuredExtensionChoicePresentation() {
        let choice = ApplePiExtensionChoice(rawValue: "Keep the existing behavior")

        #expect(choice.rawValue == "Keep the existing behavior")
        #expect(choice.title == "Keep the existing behavior")
        #expect(choice.detail == nil)
        #expect(!choice.isRecommended)
    }

    @Test("Tool-call argument deltas stay in the collapsible tool row")
    func toolCallDeltasAreNotTranscriptAnswers() {
        #expect(ApplePiAssistantDeltaPresentation.transcriptKind(for: "toolcall_delta") == nil)
        #expect(ApplePiAssistantDeltaPresentation.transcriptKind(for: "tool_call_delta") == nil)
        #expect(ApplePiAssistantDeltaPresentation.transcriptKind(for: "text_delta")?.rawValue == "answer")
        #expect(ApplePiAssistantDeltaPresentation.transcriptKind(for: "thinking_delta")?.rawValue == "thinking")
    }
}
