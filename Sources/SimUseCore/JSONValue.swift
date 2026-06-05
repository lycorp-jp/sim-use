// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Native Swift representation of an arbitrary JSON value. Codable round-trips
/// cleanly through `JSONEncoder` / `JSONDecoder` without an envelope or type
/// tag, so it can carry opaque payloads like the accessibility tree across
/// the daemon wire while staying readable in local APIs.
///
/// Decoder ordering matters: scalar dispatch tries `Bool` →
/// `Int64` → `Double` → `String` in that order. A JSON literal
/// `3` decodes as `.integer(3)`; a literal `3.14` decodes as
/// `.double(3.14)`; a `3.0` decodes as `.double(3.0)` because the
/// JSON tokenizer preserves the trailing zero. Consumers that
/// care about the integer-vs-double distinction (e.g. some
/// platforms' a11y APIs emit `AXValue: 1` vs `AXValue: 1.0` for
/// distinct semantics) should branch on the case discriminator
/// rather than reaching for `.double` or `.integer` in isolation.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value was not a valid JSON scalar, array, or object."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .integer(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}

extension JSONValue {
    public static func decode(from data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func encode(options: JSONSerialization.WritingOptions = []) throws -> Data {
        let object = foundationObject
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    public var foundationObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let v):
            return v
        case .integer(let v):
            return NSNumber(value: v)
        case .double(let v):
            return NSNumber(value: v)
        case .string(let v):
            return v
        case .array(let v):
            return v.map { $0.foundationObject }
        case .object(let v):
            var dict: [String: Any] = [:]
            dict.reserveCapacity(v.count)
            for (key, value) in v {
                dict[key] = value.foundationObject
            }
            return dict
        }
    }
}