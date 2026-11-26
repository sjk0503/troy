import Foundation

/// Wrong command line: printed with the usage line, exit status 2.
struct UsageError: Error {
    var message: String
    var usage: String?
}

/// A failure while running: printed on stderr, exit status 1.
struct Failure: Error {
    var message: String
}

struct Parsed {
    var positionals: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    func int(_ name: String) throws -> Int? {
        guard let text = options[name] else { return nil }
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
            throw UsageError(message: "--\(name) needs a whole number, got \"\(text)\".")
        }
        return value
    }
}

struct Command: Sendable {
    var name: String
    /// What follows `troy <name>`, for example `<words…> [--project <id|name>]`.
    var synopsis: String
    var summary: String
    var flags: [String] = []
    var options: [String] = []
    var run: @Sendable (Parsed, Console, CLIContext) throws -> Int32

    var usage: String { "usage: troy [--db <path>] \(name)\(synopsis.isEmpty ? "" : " " + synopsis)" }

    func parse(_ arguments: [String]) throws -> Parsed {
        var parsed = Parsed()
        var index = 0
        var onlyPositionals = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if onlyPositionals || !argument.hasPrefix("-") || argument == "-" {
                parsed.positionals.append(argument)
                continue
            }
            if argument == "--" { onlyPositionals = true; continue }
            guard argument.hasPrefix("--") else {
                throw UsageError(message: "unknown option \(argument) for '\(name)'.", usage: usage)
            }
            var option = String(argument.dropFirst(2))
            var inline: String?
            if let equals = option.firstIndex(of: "=") {
                inline = String(option[option.index(after: equals)...])
                option = String(option[..<equals])
            }
            if flags.contains(option) {
                if inline != nil { throw UsageError(message: "--\(option) takes no value.", usage: usage) }
                parsed.flags.insert(option)
            } else if options.contains(option) {
                if let inline {
                    parsed.options[option] = inline
                } else if index < arguments.count {
                    parsed.options[option] = arguments[index]
                    index += 1
                } else {
                    throw UsageError(message: "--\(option) needs a value.", usage: usage)
                }
            } else {
                throw UsageError(message: "unknown option --\(option) for '\(name)'.", usage: usage)
            }
        }
        return parsed
    }
}

struct CLIContext {
    var db: String?
}

final class Console {
    func out(_ text: String) {
        FileHandle.standardOutput.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
    }

    func err(_ text: String) {
        FileHandle.standardError.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
    }
}
