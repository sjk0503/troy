import Foundation
import TroyCore

/// A tool call that cannot proceed. The message is what the agent reads.
public struct ToolError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Reads tool arguments forgivingly: ids may be numbers, floats, "42" or "#42"; lists may be
/// one comma-separated string. Every failure names the argument and shows a valid example.
struct Arguments {
    let tool: String
    let values: [String: JSON]

    init(tool: String, _ values: [String: JSON]) {
        self.tool = tool
        self.values = values
    }

    /// Rejects names the tool does not take, so a misspelled `body` is not silently dropped.
    func allow(_ names: [String]) throws {
        let unknown = values.keys.filter { !names.contains($0) }.sorted()
        guard !unknown.isEmpty else { return }
        throw ToolError(
            "\(tool) does not take \(unknown.map { "\"\($0)\"" }.joined(separator: ", ")). Arguments: \(names.joined(separator: ", "))."
        )
    }

    func has(_ key: String) -> Bool {
        if let value = values[key] { return !value.isNull }
        return false
    }

    // MARK: Scalars

    func string(_ key: String, example: String = "\"text\"") throws -> String? {
        guard let value = values[key], !value.isNull else { return nil }
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        // `Int64(exactly:)`: a whole number outside the Int64 range must not trap the server.
        case .double(let number): return Int64(exactly: number).map { String($0) } ?? String(number)
        default: throw ToolError("\"\(key)\" must be a string, for example \(key): \(example).")
        }
    }

    func requiredString(_ key: String, example: String = "\"text\"") throws -> String {
        guard let text = try string(key, example: example) else {
            throw ToolError("\"\(key)\" is required, for example \(key): \(example).")
        }
        return text
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key], !value.isNull else { return nil }
        switch value {
        case .bool(let flag): return flag
        case .string(let text):
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: break
            }
        default: break
        }
        throw ToolError("\"\(key)\" must be true or false.")
    }

    func int(_ key: String, in range: ClosedRange<Int>? = nil, clamp: Bool = false) throws -> Int? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let number = Arguments.integer(from: value) else {
            throw ToolError("\"\(key)\" must be a whole number, for example \(key): 10.")
        }
        guard let range else { return Int(clamping: number) }
        let clipped = Int(clamping: number)
        if range.contains(clipped) { return clipped }
        if clamp { return min(max(clipped, range.lowerBound), range.upperBound) }
        throw ToolError("\"\(key)\" must be between \(range.lowerBound) and \(range.upperBound), got \(number).")
    }

    // MARK: Ids

    /// `42`, `42.0`, `"42"`, `"#42"`.
    static func integer(from value: JSON) -> Int64? {
        switch value {
        case .int(let number): return number
        case .double(let number): return number == number.rounded() && abs(number) < 9e15 ? Int64(number) : nil
        case .string(let text):
            var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.hasPrefix("#") { clean.removeFirst() }
            if clean.hasSuffix(".0") { clean.removeLast(2) }
            guard !clean.isEmpty, clean.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int64(clean)
        default: return nil
        }
    }

    static func recordID(_ value: JSON, key: String) throws -> Int64 {
        guard let number = integer(from: value), number > 0 else {
            throw ToolError("\"\(key)\" must be a record number such as 42 or \"#42\"; got \(value.text).")
        }
        return number
    }

    func recordID(_ key: String) throws -> Int64? {
        guard let value = values[key], !value.isNull else { return nil }
        return try Arguments.recordID(value, key: key)
    }

    func requiredRecordID(_ key: String) throws -> Int64 {
        guard let id = try recordID(key) else {
            throw ToolError("\"\(key)\" is required: a record number such as 42 or \"#42\".")
        }
        return id
    }

    /// One id or an array of ids; also a string such as "12, 13" or "#12 #13".
    func recordIDs(_ key: String, max: Int) throws -> [Int64]? {
        guard let value = values[key], !value.isNull else { return nil }
        return try Arguments.recordIDs(value, key: key, max: max)
    }

    static func recordIDs(_ value: JSON, key: String, max: Int) throws -> [Int64] {
        var items: [JSON]
        switch value {
        case .array(let array): items = array
        case .string(let text):
            let parts = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map { JSON.string(String($0)) }
            items = parts
        default: items = [value]
        }
        guard !items.isEmpty else { throw ToolError("\"\(key)\" needs at least one record number, for example \(key): [42, 43].") }
        guard items.count <= max else { throw ToolError("\"\(key)\" takes at most \(max) records; got \(items.count).") }
        var seen = Set<Int64>()
        var ids: [Int64] = []
        for item in items {
            let id = try recordID(item, key: key)
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    // MARK: Lists and enums

    /// An array of strings, or one comma-separated string.
    func list(_ key: String, separators: Set<Character> = [","], example: String) throws -> [String]? {
        guard let value = values[key], !value.isNull else { return nil }
        switch value {
        case .array(let items):
            return try items.map { item in
                guard let text = item.string else {
                    throw ToolError("\"\(key)\" must be a list of strings, for example \(key): \(example).")
                }
                return text
            }
        case .string(let text):
            return text.split(whereSeparator: { separators.contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        default:
            throw ToolError("\"\(key)\" must be a list of strings, for example \(key): \(example).")
        }
    }

    func tags(_ key: String = "tags") throws -> [String]? {
        try list(key, example: "[\"core\", \"swift\"]")
    }

    func paths(_ key: String = "paths") throws -> [String]? {
        try list(key, separators: [",", "\n"], example: "[\"Sources/TroyCore\"]")
    }

    func choice<T: RawRepresentable & CaseIterable>(_ key: String, as type: T.Type, hint: String? = nil) throws -> T? where T.RawValue == String {
        guard let text = try string(key) else { return nil }
        return try Arguments.choice(text, key: key, as: type, hint: hint)
    }

    static func choice<T: RawRepresentable & CaseIterable>(_ text: String, key: String, as type: T.Type, hint: String? = nil) throws -> T where T.RawValue == String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        if let found = T.allCases.first(where: { $0.rawValue == normalized }) { return found }
        let valid = T.allCases.map(\.rawValue).joined(separator: ", ")
        throw ToolError("\"\(key)\" must be one of: \(valid); got \"\(text)\".\(hint.map { " " + $0 } ?? "")")
    }

    /// A project reference: an id (number, "3", "#3") or a name. Nil when absent or blank.
    func project(_ key: String = "project") throws -> String? {
        guard let value = values[key], !value.isNull else { return nil }
        switch value {
        case .string(let text):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.hasPrefix("#"), Int64(clean.dropFirst()) != nil { return String(clean.dropFirst()) }
            return clean.isEmpty ? nil : clean
        case .int, .double:
            guard let number = Arguments.integer(from: value) else { break }
            return String(number)
        default: break
        }
        throw ToolError("\"\(key)\" must be a project id or name, for example \(key): 3 or \(key): \"troy\".")
    }
}
