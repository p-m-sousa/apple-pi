import Foundation

public struct PiImageAttachment: Sendable, Hashable, Codable {
    public let type = "image"
    public let data: String
    public let mimeType: String

    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    private enum CodingKeys: String, CodingKey {
        case type, data, mimeType
    }
}

public enum PiStreamingBehavior: String, Sendable, Codable {
    case steer
    case followUp
}

public enum PiRPCCommand: Sendable, Hashable {
    case prompt(message: String, images: [PiImageAttachment], behavior: PiStreamingBehavior?)
    case steer(message: String, images: [PiImageAttachment])
    case followUp(message: String, images: [PiImageAttachment])
    case abort
    case newSession(parentSession: String?)
    case getState
    case setModel(provider: String, modelID: String)
    case cycleModel
    case getAvailableModels
    case setThinkingLevel(String)
    case cycleThinkingLevel
    case getAvailableThinkingLevels
    case setSteeringMode(String)
    case setFollowUpMode(String)
    case compact(customInstructions: String?)
    case setAutoCompaction(Bool)
    case setAutoRetry(Bool)
    case abortRetry
    case bash(command: String, excludeFromContext: Bool)
    case abortBash
    case getSessionStats
    case exportHTML(outputPath: String?)
    case switchSession(path: String)
    case fork(entryID: String)
    case clone
    case getForkMessages
    case getEntries(since: String?)
    case getTree
    case getLastAssistantText
    case setSessionName(String)
    case getMessages
    case getCommands
    case extensionUIResponse(PiExtensionUIResponse)

    public var commandName: String {
        switch self {
        case .prompt: "prompt"
        case .steer: "steer"
        case .followUp: "follow_up"
        case .abort: "abort"
        case .newSession: "new_session"
        case .getState: "get_state"
        case .setModel: "set_model"
        case .cycleModel: "cycle_model"
        case .getAvailableModels: "get_available_models"
        case .setThinkingLevel: "set_thinking_level"
        case .cycleThinkingLevel: "cycle_thinking_level"
        case .getAvailableThinkingLevels: "get_available_thinking_levels"
        case .setSteeringMode: "set_steering_mode"
        case .setFollowUpMode: "set_follow_up_mode"
        case .compact: "compact"
        case .setAutoCompaction: "set_auto_compaction"
        case .setAutoRetry: "set_auto_retry"
        case .abortRetry: "abort_retry"
        case .bash: "bash"
        case .abortBash: "abort_bash"
        case .getSessionStats: "get_session_stats"
        case .exportHTML: "export_html"
        case .switchSession: "switch_session"
        case .fork: "fork"
        case .clone: "clone"
        case .getForkMessages: "get_fork_messages"
        case .getEntries: "get_entries"
        case .getTree: "get_tree"
        case .getLastAssistantText: "get_last_assistant_text"
        case .setSessionName: "set_session_name"
        case .getMessages: "get_messages"
        case .getCommands: "get_commands"
        case .extensionUIResponse: "extension_ui_response"
        }
    }

    public func jsonObject(id: String?) -> [String: JSONValue] {
        var object: [String: JSONValue] = ["type": .string(commandName)]
        if let id { object["id"] = .string(id) }

        switch self {
        case let .prompt(message, images, behavior):
            object["message"] = .string(message)
            object.addImages(images)
            if let behavior { object["streamingBehavior"] = .string(behavior.rawValue) }
        case let .steer(message, images), let .followUp(message, images):
            object["message"] = .string(message)
            object.addImages(images)
        case let .newSession(parentSession):
            if let parentSession { object["parentSession"] = .string(parentSession) }
        case let .setModel(provider, modelID):
            object["provider"] = .string(provider)
            object["modelId"] = .string(modelID)
        case let .setThinkingLevel(level):
            object["level"] = .string(level)
        case let .setSteeringMode(mode), let .setFollowUpMode(mode):
            object["mode"] = .string(mode)
        case let .compact(instructions):
            if let instructions { object["customInstructions"] = .string(instructions) }
        case let .setAutoCompaction(enabled), let .setAutoRetry(enabled):
            object["enabled"] = .bool(enabled)
        case let .bash(command, exclude):
            object["command"] = .string(command)
            object["excludeFromContext"] = .bool(exclude)
        case let .exportHTML(outputPath):
            if let outputPath { object["outputPath"] = .string(outputPath) }
        case let .switchSession(path):
            object["sessionPath"] = .string(path)
        case let .fork(entryID):
            object["entryId"] = .string(entryID)
        case let .getEntries(since):
            if let since { object["since"] = .string(since) }
        case let .setSessionName(name):
            object["name"] = .string(name)
        case let .extensionUIResponse(response):
            object = response.jsonObject
        default:
            break
        }
        return object
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    mutating func addImages(_ images: [PiImageAttachment]) {
        guard !images.isEmpty else { return }
        self["images"] = .array(images.map {
            .object([
                "type": .string($0.type),
                "data": .string($0.data),
                "mimeType": .string($0.mimeType),
            ])
        })
    }
}

public struct PiRPCResponse: Sendable, Hashable {
    public let id: String?
    public let command: String
    public let success: Bool
    public let data: JSONValue?
    public let error: String?
    public let raw: JSONValue
}

public enum PiExtensionUIMethod: String, Sendable, Codable {
    case select, confirm, input, editor, notify, setStatus, setWidget, setTitle
    case setEditorText = "set_editor_text"
    case unknown
}

public struct PiExtensionUIRequest: Sendable, Hashable, Identifiable {
    public let id: String
    public let method: PiExtensionUIMethod
    public let title: String?
    public let message: String?
    public let options: [String]
    public let placeholder: String?
    public let prefill: String?
    public let timeoutMilliseconds: Int?
    public let notificationType: String?
    public let statusKey: String?
    public let statusText: String?
    public let widgetKey: String?
    public let widgetLines: [String]?
    public let widgetPlacement: String?
    public let text: String?
    public let raw: JSONValue
}

public enum PiExtensionUIResponse: Sendable, Hashable {
    case value(id: String, String)
    case confirmed(id: String, Bool)
    case cancelled(id: String)

    var jsonObject: [String: JSONValue] {
        switch self {
        case let .value(id, value):
            ["type": .string("extension_ui_response"), "id": .string(id), "value": .string(value)]
        case let .confirmed(id, confirmed):
            ["type": .string("extension_ui_response"), "id": .string(id), "confirmed": .bool(confirmed)]
        case let .cancelled(id):
            ["type": .string("extension_ui_response"), "id": .string(id), "cancelled": .bool(true)]
        }
    }
}

public enum PiRPCEvent: Sendable, Hashable {
    /// One or more buffered events were discarded because the consumer fell
    /// behind. Consumers should rebuild derived transcript state from the
    /// durable session file before applying later deltas.
    case streamGap
    case response(PiRPCResponse)
    case agentStarted(raw: JSONValue)
    case agentEnded(willRetry: Bool, raw: JSONValue)
    case agentSettled(raw: JSONValue)
    case turnStarted(raw: JSONValue)
    case turnEnded(raw: JSONValue)
    case messageStarted(raw: JSONValue)
    case messageUpdated(kind: String?, delta: String?, raw: JSONValue)
    case messageEnded(raw: JSONValue)
    case toolStarted(id: String?, name: String?, raw: JSONValue)
    case toolUpdated(id: String?, name: String?, raw: JSONValue)
    case toolEnded(id: String?, name: String?, isError: Bool, raw: JSONValue)
    case queueUpdated(steering: [String], followUp: [String], raw: JSONValue)
    case compactionStarted(raw: JSONValue)
    case compactionEnded(aborted: Bool, error: String?, raw: JSONValue)
    case retry(raw: JSONValue)
    case bashUpdated(id: String?, delta: String, raw: JSONValue)
    case entryAppended(raw: JSONValue)
    case sessionInfoChanged(name: String?, raw: JSONValue)
    case thinkingLevelChanged(level: String?, raw: JSONValue)
    case extensionError(path: String?, event: String?, message: String, raw: JSONValue)
    case extensionUI(PiExtensionUIRequest)
    case bridge(BridgeResponseV1)
    case unknown(type: String?, raw: JSONValue)
    case malformedLine(String)
    case processTerminated(status: Int32, stderr: String)
}

extension PiRPCEvent {
    var isLossyStreamDelta: Bool {
        switch self {
        case .messageUpdated, .toolUpdated, .bashUpdated:
            true
        default:
            false
        }
    }

    var estimatedBufferedByteCount: Int {
        switch self {
        case .streamGap:
            1
        case let .response(response):
            response.raw.estimatedBufferedByteCount
        case let .agentStarted(raw), let .agentSettled(raw), let .turnStarted(raw),
             let .turnEnded(raw), let .messageStarted(raw), let .messageEnded(raw),
             let .compactionStarted(raw), let .retry(raw), let .entryAppended(raw):
            raw.estimatedBufferedByteCount
        case let .agentEnded(_, raw), let .toolStarted(_, _, raw),
             let .toolUpdated(_, _, raw), let .queueUpdated(_, _, raw),
             let .compactionEnded(_, _, raw), let .sessionInfoChanged(_, raw),
             let .thinkingLevelChanged(_, raw), let .unknown(_, raw):
            raw.estimatedBufferedByteCount
        case let .messageUpdated(_, _, raw), let .toolEnded(_, _, _, raw),
             let .extensionError(_, _, _, raw):
            raw.estimatedBufferedByteCount
        case let .bashUpdated(_, _, raw):
            raw.estimatedBufferedByteCount
        case let .extensionUI(request):
            request.raw.estimatedBufferedByteCount
        case let .bridge(response):
            (response.result?.estimatedBufferedByteCount ?? 0)
                + response.nonce.utf8.count
                + (response.error?.utf8.count ?? 0)
                + 128
        case let .malformedLine(message):
            message.utf8.count + 32
        case let .processTerminated(_, stderr):
            stderr.utf8.count + 64
        }
    }
}

private extension JSONValue {
    var estimatedBufferedByteCount: Int {
        switch self {
        case .null, .bool:
            8
        case .number:
            32
        case let .string(value):
            value.utf8.count + 32
        case let .array(values):
            values.reduce(32) { $0 + $1.estimatedBufferedByteCount + 16 }
        case let .object(values):
            values.reduce(64) { partial, pair in
                partial + pair.key.utf8.count + pair.value.estimatedBufferedByteCount + 32
            }
        }
    }
}
