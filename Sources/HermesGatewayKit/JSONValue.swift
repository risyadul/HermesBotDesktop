import Foundation
import os

/// Minimal dynamic JSON value. The gateway's wire shapes are open (extra keys appear over time),
/// so the spike decodes into this and reads fields by path instead of freezing Codable structs.
public enum JSONValue: Sendable, Equatable, Codable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var int: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    public func compactJSON(sortedKeys: Bool = true) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = sortedKeys ? [.sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        guard let data = try? enc.encode(self) else { return "<unencodable>" }
        return String(decoding: data, as: UTF8.self)
    }

    public var description: String { compactJSON() }
}

/// Lenient decoders tolerate missing keys (open schema) but say so: a missing top-level list key is
/// more likely a changed wire shape than an empty result. Messages carry key names only, never values.
enum SchemaLog {
    private static let logger = Logger(subsystem: "io.github.risyadul.hermesbot", category: "schema")

    /// Warns when `key` is absent (or not an array) in `result` of `method`; returns the array or [].
    static func array(_ result: JSONValue, _ key: String, method: String) -> [JSONValue] {
        if let a = result[key]?.array { return a }
        logger.warning("\(method, privacy: .public): result has no '\(key, privacy: .public)' array; treating as empty")
        return []
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}
