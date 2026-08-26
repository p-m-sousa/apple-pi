import Foundation

public enum BridgeActionV1: String, Sendable, Codable, CaseIterable {
    case ping
    case capabilities
    case trustResolve = "trust_resolve"
    case trustSet = "trust_set"
    case navigateTree = "navigate_tree"
    case setLabel = "set_label"
    case packageSnapshot = "package_snapshot"
    case resourceSnapshot = "resource_snapshot"
    case setResourceEnabled = "set_resource_enabled"
    case reload
}

public struct BridgeEnvelopeV1: Sendable, Hashable, Codable {
    public let version: Int
    public let requestID: String
    public let nonce: String
    public let action: BridgeActionV1
    public let payload: JSONValue

    public init(
        requestID: String = UUID().uuidString,
        nonce: String,
        action: BridgeActionV1,
        payload: JSONValue = .object([:])
    ) {
        version = 1
        self.requestID = requestID
        self.nonce = nonce
        self.action = action
        self.payload = payload
    }
}

public struct BridgeResponseV1: Sendable, Hashable, Codable {
    public let version: Int
    public let requestID: String
    public let nonce: String
    public let success: Bool
    public let result: JSONValue?
    public let error: String?
}

public enum BridgeCodecError: LocalizedError, Sendable {
    case payloadTooLarge
    case malformedBase64
    case unsupportedVersion(Int)
    case responseMismatch

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge: "The ApplePi bridge payload exceeded its safety limit."
        case .malformedBase64: "The ApplePi bridge payload was not valid base64url data."
        case let .unsupportedVersion(version): "Unsupported ApplePi bridge version: \(version)."
        case .responseMismatch: "The ApplePi bridge response did not match the request."
        }
    }
}

public enum BridgeCodec {
    public static let commandName = "apple-pi-bridge"
    public static let notificationPrefix = "__APPLE_PI_BRIDGE_V1__:"
    public static let maximumEncodedBytes = 2 * 1_024 * 1_024

    public static func randomNonce() -> String {
        // Foundation UUIDs are generated from system randomness. Two UUIDs give
        // bridge requests 244 random bits without introducing a crypto dependency.
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    }

    public static func commandMessage(for envelope: BridgeEnvelopeV1) throws -> String {
        let encoded = try JSONEncoder.applePi.encode(envelope).base64URLEncodedString()
        guard encoded.utf8.count <= maximumEncodedBytes else { throw BridgeCodecError.payloadTooLarge }
        return "/\(commandName) \(encoded)"
    }

    public static func decodeNotification(_ message: String) throws -> BridgeResponseV1? {
        guard message.hasPrefix(notificationPrefix) else { return nil }
        let encoded = String(message.dropFirst(notificationPrefix.count))
        guard encoded.utf8.count <= maximumEncodedBytes else { throw BridgeCodecError.payloadTooLarge }
        guard let data = Data(base64URLEncoded: encoded) else { throw BridgeCodecError.malformedBase64 }
        let response = try JSONDecoder.applePi.decode(BridgeResponseV1.self, from: data)
        guard response.version == 1 else { throw BridgeCodecError.unsupportedVersion(response.version) }
        return response
    }

    public static func validate(_ response: BridgeResponseV1, for envelope: BridgeEnvelopeV1) throws {
        guard response.version == envelope.version,
              response.requestID == envelope.requestID,
              response.nonce == envelope.nonce else {
            throw BridgeCodecError.responseMismatch
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }
}
