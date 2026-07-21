import Foundation

enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self, value.isFinite else { return nil }
        return Int(value)
    }

    var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    subscript(_ key: String) -> JSONValue? { objectValue?[key] }
}

extension JSONValue {
    static func from(_ value: Any?) -> JSONValue {
        switch value {
        case nil, is NSNull: return .null
        case let value as Bool: return .bool(value)
        case let value as Int: return .number(Double(value))
        case let value as Int64: return .number(Double(value))
        case let value as Double: return .number(value)
        case let value as String: return .string(value)
        case let value as [Any?]: return .array(value.map(JSONValue.from))
        case let value as [String: Any?]:
            return .object(value.mapValues(JSONValue.from))
        case let value as [String: Any]:
            return .object(value.mapValues { JSONValue.from($0) })
        default: return .string(String(describing: value!))
        }
    }
}

struct AnyJSON: Codable, Sendable {
    let value: JSONValue
    init(_ value: JSONValue) { self.value = value }
    init(from decoder: Decoder) throws { value = try JSONValue(from: decoder) }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

func atlasNow() -> String {
    // Foundation's formatter is mutable and therefore deliberately kept local.
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}
