import Foundation

/// Any JSON value. Open-ended API objects (`data`, `metadata`, `brand`, ...)
/// come back as this, and free-form request fields (automation steps,
/// opt-in proof, registration fields) take it. Literals work:
/// `["type": "send_sms", "body": "Hi", "seconds": 60]`.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d: return Int64(exactly: d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool { self == .null }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// `[String]` as a JSON array.
    public init(_ strings: [String]) { self = .array(strings.map { .string($0) }) }
    /// `[String: String]` as a JSON object.
    public init(_ strings: [String: String]) { self = .object(strings.mapValues { .string($0) }) }
}

/// A field you can set or clear in an update. Unset is `nil` (the parameter's
/// default); `.clear` sends JSON null, which removes the stored value.
/// String, integer and boolean literals work directly: `name: "Acme"`.
public enum Clearable<Wrapped: Sendable>: Sendable {
    case set(Wrapped)
    case clear
}

extension Clearable: ExpressibleByUnicodeScalarLiteral where Wrapped == String {
    public init(unicodeScalarLiteral value: String) { self = .set(value) }
}

extension Clearable: ExpressibleByExtendedGraphemeClusterLiteral where Wrapped == String {
    public init(extendedGraphemeClusterLiteral value: String) { self = .set(value) }
}

extension Clearable: ExpressibleByStringLiteral where Wrapped == String {
    public init(stringLiteral value: String) { self = .set(value) }
}

extension Clearable: ExpressibleByIntegerLiteral where Wrapped == Int {
    public init(integerLiteral value: Int) { self = .set(value) }
}
