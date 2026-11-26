import Foundation

// A small Markdown block parser. It is pure and `nonisolated`, so a 100,000 character body is
// parsed off the main actor, and it is `package` so the preview executable can assert on it.
//
// Supported blocks: headings, paragraphs, bullet / numbered / task lists (nesting by indentation),
// block quotes, fenced code, tables, horizontal rules. Everything else is a paragraph of plain text.

package nonisolated enum MarkdownListMarker: Sendable, Equatable {
    case bullet
    case number(Int)
    case task(done: Bool)
}

package nonisolated enum MarkdownAlignment: Sendable, Equatable {
    case leading, center, trailing
}

package nonisolated struct MarkdownTable: Sendable, Equatable {
    package var header: [AttributedString]
    package var alignments: [MarkdownAlignment]
    package var rows: [[AttributedString]]
}

package nonisolated enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case listItem(depth: Int, marker: MarkdownListMarker, text: AttributedString)
    case quote([MarkdownBlock])
    /// `continued` is true for the second and later pieces of a very long code block.
    case code(language: String?, text: String, continued: Bool, indent: Int)
    case table(MarkdownTable)
    case rule
}

package nonisolated struct MarkdownDocument: Sendable, Equatable {
    package var blocks: [MarkdownBlock]
    /// Blocks left out because the document is longer than `MarkdownParser.maxBlocks`.
    package var hiddenBlocks: Int
}

package nonisolated enum MarkdownParser {
    /// Blocks rendered at most. A list item or a code chunk counts as one.
    package static let maxBlocks = 600
    /// Longest paragraph kept in one piece; longer ones are split so layout stays quick.
    static let paragraphChunk = 3_000
    /// Longest code block kept in one piece, in lines.
    package static let codeChunkLines = 250
    static let maxQuoteDepth = 4

    package static func parse(_ source: String) -> MarkdownDocument {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let blocks = parseBlocks(lines, quoteDepth: 0)
        if blocks.count > maxBlocks {
            return MarkdownDocument(blocks: Array(blocks.prefix(maxBlocks)), hiddenBlocks: blocks.count - maxBlocks)
        }
        return MarkdownDocument(blocks: blocks, hiddenBlocks: 0)
    }

    // MARK: Inline

    /// Bold, italic, inline code, links and strikethrough. Never fails: bad input stays plain text.
    package static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        if let parsed = try? AttributedString(markdown: text, options: options) { return parsed }
        return AttributedString(text)
    }

    // MARK: Line classification

    private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private struct Fence { var character: Character; var length: Int; var info: String; var indent: Int }

    private static func fence(_ line: String) -> Fence? {
        let indent = indentWidth(line)
        let body = trimmed(line)
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let length = body.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        let info = body.dropFirst(length).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string may not contain a backtick: that is inline code.
        if first == "`", info.contains("`") { return nil }
        return Fence(character: first, length: length, info: info, indent: indent)
    }

    private static func closes(_ line: String, _ open: Fence) -> Bool {
        let body = trimmed(line)
        guard let first = body.first, first == open.character else { return false }
        let run = body.prefix { $0 == first }.count
        return run >= open.length && body.dropFirst(run).allSatisfy { $0 == " " }
    }

    private static func heading(_ line: String) -> (Int, String)? {
        guard indentWidth(line) < 4 else { return nil }
        let body = trimmed(line)
        let hashes = body.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = body.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing sequence: "## Title ##".
        if text.hasSuffix("#") {
            let stripped = text.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            if stripped.isEmpty {
                text = ""
            } else if stripped.hasSuffix(" ") {
                text = stripped.trimmingCharacters(in: .whitespaces)
            }
        }
        return (min(hashes, 4), text)
    }

    private static func isRule(_ line: String) -> Bool {
        guard indentWidth(line) < 4 else { return false }
        let body = line.filter { $0 != " " && $0 != "\t" }
        guard body.count >= 3, let first = body.first, first == "-" || first == "*" || first == "_" else { return false }
        return body.allSatisfy { $0 == first }
    }

    private struct ListLine { var indent: Int; var marker: MarkdownListMarker; var text: String }

    private static func listLine(_ line: String) -> ListLine? {
        let indent = indentWidth(line)
        let body = Substring(trimmed(line))
        guard let first = body.first else { return nil }
        var rest: Substring
        var marker: MarkdownListMarker
        if first == "-" || first == "*" || first == "+" {
            rest = body.dropFirst()
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            marker = .bullet
        } else if first.isASCII, first.isNumber {
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            guard digits.count <= 9, let number = Int(digits) else { return nil }
            let after = body.dropFirst(digits.count)
            guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return nil }
            rest = after.dropFirst()
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            marker = .number(number)
        } else {
            return nil
        }
        var text = rest.trimmingCharacters(in: .whitespaces)
        if case .bullet = marker {
            if text.hasPrefix("[ ]") || text.hasPrefix("[x]") || text.hasPrefix("[X]") {
                let after = text.dropFirst(3)
                if after.isEmpty || after.first == " " {
                    marker = .task(done: text.hasPrefix("[x]") || text.hasPrefix("[X]"))
                    text = after.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return ListLine(indent: indent, marker: marker, text: text)
    }

    private static func tableCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var body = trimmed(line)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|", !inCode {
                cells.append(trimmed(current))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(trimmed(current))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    private static func delimiterRow(_ line: String) -> [MarkdownAlignment]? {
        guard let cells = tableCells(line), !cells.isEmpty else { return nil }
        var result: [MarkdownAlignment] = []
        for cell in cells {
            guard !cell.isEmpty else { return nil }
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            result.append(left && right ? .center : right ? .trailing : .leading)
        }
        return result
    }

    /// True when `lines[index]` starts a block that ends a running paragraph.
    private static func startsBlock(_ lines: [String], _ index: Int) -> Bool {
        let line = lines[index]
        if heading(line) != nil || fence(line) != nil || isRule(line) || listLine(line) != nil { return true }
        if trimmed(line).hasPrefix(">") { return true }
        if index + 1 < lines.count, line.contains("|"), delimiterRow(lines[index + 1]) != nil { return true }
        return false
    }

    // MARK: Blocks

    private static func parseBlocks(_ lines: [String], quoteDepth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = 0
        // Nesting state for list items: indentation of each open level and counters for numbered levels.
        var levels: [Int] = []
        var counters: [Int?] = []

        func appendParagraph(_ text: String) {
            var rest = Substring(text)
            while rest.count > paragraphChunk {
                var cut = rest.index(rest.startIndex, offsetBy: paragraphChunk)
                if let space = rest[..<cut].lastIndex(where: { $0 == "\n" || $0 == " " }), space > rest.startIndex {
                    cut = rest.index(after: space)
                }
                blocks.append(.paragraph(inline(String(rest[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))))
                rest = rest[cut...]
            }
            let tail = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { blocks.append(.paragraph(inline(tail))) }
        }

        func appendCode(language: String?, lines code: [String], indent: Int) {
            if code.isEmpty {
                blocks.append(.code(language: language, text: "", continued: false, indent: indent))
                return
            }
            var start = 0
            while start < code.count {
                let end = min(start + codeChunkLines, code.count)
                blocks.append(.code(
                    language: language, text: code[start..<end].joined(separator: "\n"),
                    continued: start > 0, indent: indent))
                start = end
            }
        }

        while index < lines.count {
            let line = lines[index]

            if isBlank(line) {
                index += 1
                continue
            }

            // Fenced code, possibly indented inside a list item.
            if let open = fence(line) {
                var code: [String] = []
                index += 1
                while index < lines.count, !closes(lines[index], open) {
                    code.append(dedent(lines[index], by: open.indent))
                    index += 1
                }
                if index < lines.count { index += 1 }  // the closing fence; an unterminated fence runs to the end
                let language = open.info.split(separator: " ").first.map(String.init)
                appendCode(language: language, lines: code, indent: open.indent > 0 && !levels.isEmpty ? open.indent : 0)
                if open.indent == 0 || levels.isEmpty { levels = []; counters = [] }
                continue
            }

            if let (level, text) = heading(line) {
                blocks.append(.heading(level: level, text: inline(text)))
                levels = []; counters = []
                index += 1
                continue
            }

            if isRule(line) {
                blocks.append(.rule)
                levels = []; counters = []
                index += 1
                continue
            }

            if trimmed(line).hasPrefix(">") {
                var inner: [String] = []
                while index < lines.count, trimmed(lines[index]).hasPrefix(">") {
                    var body = Substring(trimmed(lines[index])).dropFirst()
                    if body.first == " " { body = body.dropFirst() }
                    inner.append(String(body))
                    index += 1
                }
                if quoteDepth >= maxQuoteDepth {
                    appendParagraph(inner.joined(separator: "\n"))
                } else {
                    blocks.append(.quote(parseBlocks(inner, quoteDepth: quoteDepth + 1)))
                }
                levels = []; counters = []
                continue
            }

            if index + 1 < lines.count, line.contains("|"), let alignments = delimiterRow(lines[index + 1]),
               let headerCells = tableCells(line), headerCells.count == alignments.count {
                var rows: [[AttributedString]] = []
                index += 2
                while index < lines.count, !isBlank(lines[index]), lines[index].contains("|"),
                      fence(lines[index]) == nil {
                    var cells = tableCells(lines[index]) ?? []
                    if cells.count > alignments.count { cells = Array(cells.prefix(alignments.count)) }
                    while cells.count < alignments.count { cells.append("") }
                    rows.append(cells.map(inline))
                    index += 1
                }
                blocks.append(.table(MarkdownTable(
                    header: headerCells.map(inline), alignments: alignments, rows: rows)))
                levels = []; counters = []
                continue
            }

            if let item = listLine(line) {
                // Find this item's depth from its indentation.
                while let last = levels.last, last > item.indent {
                    levels.removeLast()
                    counters.removeLast()
                }
                if levels.last != item.indent {
                    levels.append(item.indent)
                    counters.append(nil)
                }
                let depth = levels.count - 1
                var marker = item.marker
                if case .number(let written) = item.marker {
                    let next = counters[depth].map { $0 + 1 } ?? written
                    counters[depth] = next
                    marker = .number(next)
                } else {
                    counters[depth] = nil
                }
                var text = item.text
                index += 1
                // Continuation lines: indented deeper than the marker, or lazy text that starts no block.
                while index < lines.count, !isBlank(lines[index]) {
                    let next = lines[index]
                    if listLine(next) != nil || fence(next) != nil || heading(next) != nil || isRule(next) { break }
                    if !(indentWidth(next) > item.indent) && startsBlock(lines, index) { break }
                    text += "\n" + trimmed(next)
                    index += 1
                }
                blocks.append(.listItem(depth: min(depth, 6), marker: marker, text: inline(hardBreaks(text))))
                continue
            }

            // Paragraph: runs until a blank line or the start of another block.
            levels = []; counters = []
            var paragraph: [String] = [trimmed(line)]
            index += 1
            while index < lines.count, !isBlank(lines[index]), !startsBlock(lines, index) {
                paragraph.append(trimmed(lines[index]))
                index += 1
            }
            appendParagraph(hardBreaks(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    /// Every newline in a paragraph is shown as a line break, so a backslash or two spaces at the
    /// end of a line (the Markdown hard break) are dropped rather than printed.
    private static func hardBreaks(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var line = String(line)
            if line.hasSuffix("\\") { line.removeLast() }
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }.joined(separator: "\n")
    }

    private static func dedent(_ line: String, by width: Int) -> String {
        var remaining = width
        var index = line.startIndex
        while remaining > 0, index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
            remaining -= 1
        }
        return String(line[index...])
    }
}
