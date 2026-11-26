import Foundation

/// A JSON value. Parsing goes through `JSONSerialization`; writing is done here so the
/// output is always one line with deterministic key order.
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: Reading

    /// Parses one JSON document. Returns nil when the text is not valid JSON.
    public static func parse(_ text: String) -> JSON? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return convert(value)
    }

    private static func convert(_ value: Any) -> JSON {
        switch value {
        case is NSNull: return .null
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.map(convert))
        case let object as [String: Any]: return .object(object.mapValues(convert))
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            switch String(cString: number.objCType) {
            case "d", "f":
                let double = number.doubleValue
                return .double(double)
            case "Q":
                return number.uint64Value > UInt64(Int64.max) ? .double(number.doubleValue) : .int(Int64(number.uint64Value))
            default:
                return .int(number.int64Value)
            }
        default: return .null
        }
    }

    public subscript(key: String) -> JSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? { if case .string(let value) = self { return value } else { return nil } }
    public var object: [String: JSON]? { if case .object(let value) = self { return value } else { return nil } }
    public var array: [JSON]? { if case .array(let value) = self { return value } else { return nil } }
    public var bool: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    public var isNull: Bool { self == .null }

    // MARK: Writing

    /// Compact JSON on a single line. Keys are sorted; control characters and U+2028/U+2029 are escaped.
    public var text: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .double(let value):
            if value.isFinite {
                if value == value.rounded(), abs(value) < 1e15 { out += String(Int64(value)) } else { out += String(value) }
            } else {
                out += "null"
            }
        case .string(let value): JSON.writeString(value, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                JSON.writeString(key, into: &out)
                out += ":"
                members[key]?.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension JSON: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(stringInterpolation: DefaultStringInterpolation) { self = .string(String(stringInterpolation: stringInterpolation)) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
