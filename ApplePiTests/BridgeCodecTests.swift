import Foundation
import Testing
@testable import ApplePi

@Suite("ApplePi bridge protocol")
struct BridgeCodecTests {
    @Test("Bridge commands contain an exact, versioned base64url envelope")
    func commandEnvelopeRoundTrip() throws {
        let envelope = BridgeEnvelopeV1(
            requestID: "request-42",
            nonce: "nonce-42",
            action: .navigateTree,
            payload: .object(["entryID": .string("entry-9")])
        )

        let command = try BridgeCodec.commandMessage(for: envelope)
        #expect(command.hasPrefix("/apple-pi-bridge "))

        let encoded = String(command.dropFirst("/apple-pi-bridge ".count))
        let data = try #require(decodeBase64URL(encoded))
        let decoded = try JSONDecoder.applePi.decode(BridgeEnvelopeV1.self, from: data)
        #expect(decoded == envelope)
        #expect(decoded.version == 1)
    }

    @Test("Reserved notifications decode and validate request identity and nonce")
    func responseValidation() throws {
        let envelope = BridgeEnvelopeV1(
            requestID: "request-a",
            nonce: "nonce-a",
            action: .capabilities
        )
        let response = BridgeResponseV1(
            version: 1,
            requestID: envelope.requestID,
            nonce: envelope.nonce,
            success: true,
            result: .object(["rpc": .bool(true)]),
            error: nil
        )
        let notification = BridgeCodec.notificationPrefix
            + encodeBase64URL(try JSONEncoder.applePi.encode(response))

        let decodedNotification = try BridgeCodec.decodeNotification(notification)
        let decoded = try #require(decodedNotification)
        try BridgeCodec.validate(decoded, for: envelope)
        #expect(decoded.result?["rpc"]?.boolValue == true)
        #expect(try BridgeCodec.decodeNotification("ordinary extension notification") == nil)
    }

    @Test("A response cannot be replayed for another request")
    func replayRejected() {
        let envelope = BridgeEnvelopeV1(
            requestID: "request-a",
            nonce: "fresh-nonce",
            action: .ping
        )
        let replay = BridgeResponseV1(
            version: 1,
            requestID: "request-a",
            nonce: "old-nonce",
            success: true,
            result: nil,
            error: nil
        )

        #expect(throws: BridgeCodecError.self) {
            try BridgeCodec.validate(replay, for: envelope)
        }
    }

    @Test("Malformed, oversized, and future-version notifications are rejected")
    func invalidNotifications() throws {
        #expect(throws: BridgeCodecError.self) {
            try BridgeCodec.decodeNotification(BridgeCodec.notificationPrefix + "%%%")
        }
        #expect(throws: BridgeCodecError.self) {
            try BridgeCodec.decodeNotification(
                BridgeCodec.notificationPrefix
                    + String(repeating: "a", count: BridgeCodec.maximumEncodedBytes + 1)
            )
        }

        let future = BridgeResponseV1(
            version: 2,
            requestID: "request",
            nonce: "nonce",
            success: true,
            result: nil,
            error: nil
        )
        let message = BridgeCodec.notificationPrefix
            + encodeBase64URL(try JSONEncoder.applePi.encode(future))
        #expect(throws: BridgeCodecError.self) {
            try BridgeCodec.decodeNotification(message)
        }
    }

    @Test("Bridge nonces are substantial and non-repeating")
    func generatedNonces() {
        let first = BridgeCodec.randomNonce()
        let second = BridgeCodec.randomNonce()
        let nonceIsHex = first.allSatisfy { $0.isHexDigit }
        #expect(first.count == 64)
        #expect(first != second)
        #expect(nonceIsHex)
    }

    private func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
