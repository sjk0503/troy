import Foundation

// Small pure helpers. They hold the input rules from docs/ARCHITECTURE.md and have no database access.

/// Text validation shared by every write.
enum TextRules {
    static func checkNoNUL(_ text: String, field: String) throws {
        if text.utf8.contains(0) {
            throw TroyError.invalid("\(field) must not contain the character U+0000.")
        }
    }

    /// Trimmed, not empty, within `max` characters.
    static func required(_ text: String, field: String, max: Int) throws -> String {
        try checkNoNUL(text, field: field)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TroyError.invalid("\(field) must not be empty.") }
        try checkLength(trimmed, field: field, max: max)
        return trimmed
    }

    /// Kept as given (not trimmed), may be empty, within `max` characters.
    static func verbatim(_ text: String, field: String, max: Int) throws -> String {
        try checkNoNUL(text, field: field)
        try checkLength(text, field: field, max: max)
        return text
    }

    /// Trimmed, may be empty, within `max` characters.
    static func optional(_ text: String, field: String, max: Int) throws -> String {
        try checkNoNUL(text, field: field)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try checkLength(trimmed, field: field, max: max)
        return trimmed
    }

    private static func checkLength(_ text: String, field: String, max: Int) throws {
        // Cheap bound first: a string cannot have more characters than UTF-8 bytes.
        if text.utf8.count <= max { return }
        let count = text.count
        if count > max {
            throw TroyError.invalid("\(field) is \(count) characters long; the limit is \(max).")
        }
    }
}

enum TagRules {
    /// Trimmed, empty ones dropped, duplicates removed (first wins, compared without case), order kept.
    static func normalize(_ tags: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            try TextRules.checkNoNUL(raw, field: "A tag")
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.isEmpty { continue }
            // Tags are stored as JSON and indexed as that text. A tag that needed escaping would be
            // findable by one search path and not by the other.
            if tag.unicodeScalars.contains(where: { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }) {
                throw TroyError.invalid("Tag \"\(tag.prefix(20))\" contains a quote, a backslash or a control character. Use plain words.")
            }
            guard tag.count <= Limits.tagLength else {
                throw TroyError.invalid("Tag \"\(tag.prefix(20))…\" is \(tag.count) characters long; the limit is \(Limits.tagLength).")
            }
            if seen.insert(tag.lowercased()).inserted { result.append(tag) }
        }
        guard result.count <= Limits.tagCount else {
            throw TroyError.invalid("A record can have at most \(Limits.tagCount) tags; got \(result.count).")
        }
        return result
    }
}

enum PathRules {
    /// One record path: trimmed, leading `./` and trailing `/` removed, repeated `/` collapsed.
    /// From the first `*`, `?` or `[` on, the path is cut back to its last complete folder.
    /// Returns an empty string when nothing is left.
    static func recordPath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wildcard = path.firstIndex(where: { $0 == "*" || $0 == "?" || $0 == "[" }) {
            let prefix = path[..<wildcard]
            if let slash = prefix.lastIndex(of: "/") {
                path = String(prefix[..<slash])
                if path.isEmpty && raw.trimmingCharacters(in: .whitespaces).hasPrefix("/") { return "" }
            } else {
                return ""
            }
        }
        let absolute = path.hasPrefix("/")
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        while components.first == "." { components.removeFirst() }
        let joined = components.joined(separator: "/")
        if joined.isEmpty || joined == "." { return "" }
        return absolute ? "/" + joined : joined
    }

    static func recordPaths(_ paths: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in paths {
            try TextRules.checkNoNUL(raw, field: "A path")
            let path = recordPath(raw)
            if path.isEmpty { continue }
            guard path.count <= Limits.recordPathLength else {
                throw TroyError.invalid("Path \"\(path.prefix(40))…\" is \(path.count) characters long; the limit is \(Limits.recordPathLength).")
            }
            if seen.insert(path).inserted { result.append(path) }
        }
        guard result.count <= Limits.recordPaths else {
            throw TroyError.invalid("A record can touch at most \(Limits.recordPaths) paths; got \(result.count).")
        }
        return result
    }

    /// Two paths overlap when they are equal or one is a folder that contains the other.
    static func overlap(_ a: String, _ b: String) -> Bool {
        a == b || b.hasPrefix(a + "/") || a.hasPrefix(b + "/")
    }

    /// The more specific of two overlapping paths.
    static func shared(_ a: String, _ b: String) -> String {
        b.hasPrefix(a + "/") ? b : a
    }

    /// Paths of `a` and `b` that overlap, as the more specific side of each pair, without repeats.
    static func sharedPaths(_ a: [String], _ b: [String]) -> [String] {
        var result: [String] = []
        for left in a {
            for right in b where overlap(left, right) {
                let path = shared(left, right)
                if !result.contains(path) { result.append(path) }
            }
        }
        return result
    }

    /// True when `directory` is `ancestor` or lies below it, compared by path components.
    static func contains(ancestor: String, _ directory: String) -> Bool {
        ancestor == "/" || directory == ancestor || directory.hasPrefix(ancestor + "/")
    }

    /// Absolute after expanding `~`, `.` and `..` resolved, no trailing slash.
    static func projectPath(_ raw: String) throws -> String {
        try TextRules.checkNoNUL(raw, field: "A path")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TroyError.invalid("A project path must not be empty.") }
        let normalized = try normalizeDirectory(trimmed)
        guard normalized.count <= Limits.projectPathLength else {
            throw TroyError.invalid("A project path is \(normalized.count) characters long; the limit is \(Limits.projectPathLength).")
        }
        return normalized
    }

    static func normalizeDirectory(_ raw: String) throws -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw TroyError.invalid("\"\(raw)\" is not an absolute path. Use a full path such as /Users/me/dev/app.")
        }
        var stack: [Substring] = []
        for component in expanded.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(component)
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    /// The one spelling of a folder the file system itself uses: case as stored on disk, symlinks
    /// and firmlinks (`/System/Volumes/Data/Users` → `/Users`) resolved. Folder links are compared
    /// by this on both sides, so two spellings of one folder never become two projects. For a path
    /// that does not exist, its closest existing ancestor is canonicalized and the rest kept as typed.
    static func canonical(_ path: String) -> String {
        // An existing path is resolved as typed first: `..` right after a symlink leaves the
        // symlink's target, which textual clean-up would get wrong.
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded), let real = realpath(expanded, nil) {
            let typed = String(cString: real)
            free(real)
            if let clean = try? normalizeDirectory(typed), clean != (try? normalizeDirectory(expanded)) { return canonical(clean) }
        }
        guard let normalized = try? normalizeDirectory(path) else { return path }
        var existing = normalized
        var rest: [String] = []
        while existing != "/" {
            if FileManager.default.fileExists(atPath: existing) { break }
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        // `realpath` resolves every symlink, the last component's too, which the canonical path
        // key leaves alone; the key then fixes case and firmlinks.
        var resolved = existing
        if let real = realpath(existing, nil) {
            resolved = String(cString: real)
            free(real)
        }
        guard let base = (try? URL(fileURLWithPath: resolved).resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath,
              base.hasPrefix("/") else { return normalized }
        let joined = rest.isEmpty ? base : (base == "/" ? "" : base) + "/" + rest.joined(separator: "/")
        return (try? normalizeDirectory(joined)) ?? normalized
    }

    static func projectPaths(_ paths: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in paths {
            let path = try projectPath(raw)
            if seen.insert(path).inserted { result.append(path) }
        }
        guard result.count <= Limits.projectPaths else {
            throw TroyError.invalid("A project can link at most \(Limits.projectPaths) folders; got \(result.count).")
        }
        return result
    }
}

enum SearchTerms {
    /// Whitespace separated terms, at most `Limits.searchTerms`.
    static func split(_ text: String) -> [String] {
        Array(text.split(whereSeparator: { $0.isWhitespace }).prefix(Limits.searchTerms).map(String.init))
    }

    /// A LIKE pattern matching `term` anywhere. Use with `ESCAPE '\'`.
    static func likePattern(_ term: String) -> String {
        // Scalar by scalar: `_` followed by a combining mark is one Character that is not "_",
        // and would slip through a character comparison as a live wildcard.
        var escaped = String.UnicodeScalarView()
        for scalar in term.unicodeScalars {
            if scalar == "\\" || scalar == "%" || scalar == "_" { escaped.append("\\") }
            escaped.append(scalar)
        }
        var pattern = String.UnicodeScalarView()
        pattern.append("%")
        pattern.append(contentsOf: escaped)
        pattern.append("%")
        return String(pattern)
    }

    /// An FTS5 phrase: quoted, with `"` doubled (scalar by scalar, for the same reason as above).
    static func ftsPhrase(_ term: String) -> String {
        var phrase = String.UnicodeScalarView()
        phrase.append("\"")
        for scalar in term.unicodeScalars {
            if scalar == "\"" { phrase.append("\"") }
            phrase.append(scalar)
        }
        phrase.append("\"")
        return String(phrase)
    }

    /// The trigram index only knows substrings of three or more characters.
    static func usesIndex(_ term: String) -> Bool { term.unicodeScalars.count >= 3 }
}

enum Similarity {
    /// A word is a run of letters, digits and their combining marks.
    static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 128 {
            return (value >= 48 && value <= 57) || (value >= 97 && value <= 122) || (value >= 65 && value <= 90)
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    /// Character bigrams inside each word of the lowercased text. A one-character word counts as itself.
    static func bigrams(_ text: String) -> Set<UInt64> {
        var result = Set<UInt64>()
        var previous: UInt32?
        var length = 0
        func endWord() {
            if length == 1, let single = previous { result.insert(UInt64(single) << 32 | UInt64(UInt32.max)) }
            previous = nil
            length = 0
        }
        for scalar in text.lowercased().unicodeScalars {
            if isWord(scalar) {
                if let before = previous { result.insert(UInt64(before) << 32 | UInt64(scalar.value)) }
                previous = scalar.value
                length += 1
            } else {
                endWord()
            }
        }
        endWord()
        return result
    }

    /// Dice coefficient of two bigram sets, 0…1.
    static func dice(_ a: Set<UInt64>, _ b: Set<UInt64>) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        var shared = 0
        for item in small where large.contains(item) { shared += 1 }
        return 2 * Double(shared) / Double(a.count + b.count)
    }

    static func score(_ a: String, _ b: String) -> Double { dice(bigrams(a), bigrams(b)) }
}

/// "5m", "2h", "3d", "2w", then a date.
enum Age {
    static func short(since then: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(then))
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 14 { return "\(days)d" }
        let weeks = days / 7
        if weeks < 9 { return "\(weeks)w" }
        return date(then)
    }

    /// The same as a phrase: "just now", "5m ago", "3d ago", and "on 2026-09-01" once it is a date.
    static func ago(since then: Date, now: Date = Date()) -> String {
        let text = short(since: then, now: now)
        if text == "0m" { return "just now" }
        return text.contains("-") ? "on \(text)" : "\(text) ago"
    }

    static func date(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(in: TimeZone.current, from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
