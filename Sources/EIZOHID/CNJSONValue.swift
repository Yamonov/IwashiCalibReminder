import Foundation

/// Preserves optional CN detail fields without making them mandatory for the countdown.
/// The original database bytes are still validated by the read-only LevelDB reader.
public enum CNJSONValue: Codable, Sendable, Equatable {
    case object([String: CNJSONValue]), array([CNJSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= 64 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "CN detail nesting is too deep"))
        }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? value.decode([CNJSONValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: CNJSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(_ key: String) -> CNJSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var boolean: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var array: [CNJSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: CNJSONValue]? { if case .object(let value) = self { value } else { nil } }
}
