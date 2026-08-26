import Foundation

/// A lossless, Sendable representation of an arbitrary JSON value.
///
/// Pi intentionally allows extensions to add fields and event types. Keeping the raw
/// JSON alongside typed projections lets ApplePi remain forward compatible without
/// silently discarding extension data.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        guard case let .number(value) = self else { return nil }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    public var decimalValue: Decimal? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public static func decode(data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func encodedData(sortedKeys: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        if sortedKeys {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        return try encoder.encode(self)
    }
}

public extension JSONValue {
    init(_ value: String) { self = .string(value) }
    init(_ value: Bool) { self = .bool(value) }
    init(_ value: Int) { self = .number(Decimal(value)) }
    init(_ value: Double) {
        self = .number(Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(value))
    }
}
