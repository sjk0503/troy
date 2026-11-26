import Foundation
import Testing
import TroyMainUI

// The parser is `package` API, so the tests reach it without `@testable`.

private func check(_ condition: @autoclosure () -> Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(condition(), Comment(rawValue: message), sourceLocation: sourceLocation)
}

private func plain(_ text: AttributedString) -> String { String(text.characters) }

private func describe(_ blocks: [MarkdownBlock]) -> [String] {
    blocks.map { block in
        switch block {
        case .heading(let level, let text): "h\(level):\(plain(text))"
        case .paragraph(let text): "p:\(plain(text))"
        case .listItem(let depth, let marker, let text):
            switch marker {
            case .bullet: "li\(depth):•:\(plain(text))"
            case .number(let n): "li\(depth):\(n).:\(plain(text))"
            case .task(let done): "li\(depth):\(done ? "[x]" : "[ ]"):\(plain(text))"
            }
        case .quote(let inner): "quote(\(describe(inner).joined(separator: " | ")))"
        case .code(let language, let text, let continued, _): "code(\(language ?? "-")\(continued ? "+" : "")):\(text)"
        case .table(let table): "table:\(table.header.map(plain)):\(table.rows.map { $0.map(plain) })"
        case .rule: "rule"
        }
    }
}

@Suite struct MarkdownParserTests {
    @Test func blocksInlineStylesAndVeryLongInput() {
        // Headings
        var d = describe(MarkdownParser.parse("# One\n## Two\n### Three\n#### Four\n##### Five\n#NoSpace\n## Closed ##").blocks)
        check(d == ["h1:One", "h2:Two", "h3:Three", "h4:Four", "h4:Five", "p:#NoSpace", "h2:Closed"], "headings: \(d)")

        // Nested lists and numbering
        d = describe(MarkdownParser.parse("- a\n  - b\n    - c\n- d\n\n1. x\n2. y\n   - z\n\nbreak\n\n1. 1\n1. 1\n1. 1").blocks)
        check(d == ["li0:•:a", "li1:•:b", "li2:•:c", "li0:•:d", "li0:1.:x", "li0:2.:y", "li1:•:z", "p:break", "li0:1.:1", "li0:2.:1", "li0:3.:1"],
              "nested lists: \(d)")

        // A list item with a lazy continuation line
        d = describe(MarkdownParser.parse("- first line\n  second line\n- next").blocks)
        check(d == ["li0:•:first line\nsecond line", "li0:•:next"], "continuation: \(d)")

        // Task items
        d = describe(MarkdownParser.parse("- [ ] open\n- [x] done\n* [X] also done\n- [] not a task").blocks)
        check(d == ["li0:[ ]:open", "li0:[x]:done", "li0:[x]:also done", "li0:•:[] not a task"], "tasks: \(d)")

        // Fenced code with a language, blank lines kept, markdown inside left alone
        d = describe(MarkdownParser.parse("before\n\n```swift\nlet a = 1\n\n# not a heading\n```\nafter").blocks)
        check(d == ["p:before", "code(swift):let a = 1\n\n# not a heading", "p:after"], "fenced code: \(d)")

        // Unterminated fence runs to the end
        d = describe(MarkdownParser.parse("```\nabc\ndef").blocks)
        check(d == ["code(-):abc\ndef"], "unterminated fence: \(d)")

        // Tilde fence, and an indented fence inside a list item
        d = describe(MarkdownParser.parse("~~~\nx\n~~~\n\n1. step\n   ```sh\n   run it\n   ```\n2. next").blocks)
        check(d == ["code(-):x", "li0:1.:step", "code(sh):run it", "li0:2.:next"], "tilde and indented fence: \(d)")

        // Table with alignment, ragged rows, escaped pipe
        let tableDoc = MarkdownParser.parse("| Name | Qty | Note |\n|:--|:-:|--:|\n| a | 1 | x \\| y |\n| b | 2 |\n| c | 3 | z | extra |\nafter")
        if case .table(let table) = tableDoc.blocks.first {
            check(table.header.map(plain) == ["Name", "Qty", "Note"], "table header")
            check(table.alignments == [.leading, .center, .trailing], "table alignments \(table.alignments)")
            check(table.rows.count == 3 && table.rows.allSatisfy { $0.count == 3 }, "table rows normalized")
            check(plain(table.rows[0][2]) == "x | y", "table escaped pipe: \(plain(table.rows[0][2]))")
            check(plain(table.rows[1][2]) == "", "table short row padded")
        } else {
            check(false, "table not parsed: \(describe(tableDoc.blocks))")
        }
        check(describe(tableDoc.blocks).last == "p:after", "paragraph after table")

        // A pipe line without a delimiter row is just text
        d = describe(MarkdownParser.parse("a | b\nc | d").blocks)
        check(d == ["p:a | b\nc | d"], "pipes without delimiter: \(d)")

        // Quotes, with blocks inside
        d = describe(MarkdownParser.parse("> quoted\n> - item\n>\n> more").blocks)
        check(d == ["quote(p:quoted | li0:•:item | p:more)"], "quote: \(d)")

        // Rule and hard breaks
        d = describe(MarkdownParser.parse("a  \nb\\\nc\n\n---\n\n* * *").blocks)
        check(d == ["p:a\nb\nc", "rule", "rule"], "rule and hard breaks: \(d)")

        // Inline styles
        let inline = MarkdownParser.parse("**bold** *italic* `code` ~~gone~~ [site](https://example.com)").blocks
        if case .paragraph(let text) = inline.first {
            check(plain(text) == "bold italic code gone site", "inline text: \(plain(text))")
            check(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "bold run")
            check(text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true }, "italic run")
            check(text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }, "code run")
            check(text.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true }, "strikethrough run")
            check(text.runs.contains { $0.link?.absoluteString == "https://example.com" }, "link run")
        } else {
            check(false, "inline paragraph missing")
        }

        // Korean and English mixed
        let mixed = MarkdownParser.parse("# 동기화 설계 Sync design\n\n한국어와 English를 **섞어** 쓴 문장입니다. `토큰` 두 글자.\n\n- 항목 one\n- [x] 완료 two\n\n| 이름 | name |\n|---|---|\n| 결제 | payment |")
        d = describe(mixed.blocks)
        check(d.count == 5, "mixed block count \(d.count): \(d)")
        check(d.first == "h1:동기화 설계 Sync design", "mixed heading: \(d.first ?? "")")
        check(d.contains("p:한국어와 English를 섞어 쓴 문장입니다. 토큰 두 글자."), "mixed paragraph: \(d)")
        check(d.contains("li0:[x]:완료 two"), "mixed task: \(d)")

        // Unknown syntax and hostile input never crash or lose text
        let odd = ["|", "| a |", "```", "~~~~", "#", "-", ">", "1.", "- [", "***", "<div>x</div>", "[ref]: http://x", "![img](a.png)", "\t\t- tab", "\u{0}", "---\n---", "| a |\n|---|", "> > > > > > deep", "- ", "1) a\n2) b"]
        for text in odd {
            let doc = MarkdownParser.parse(text)
            check(doc.hiddenBlocks == 0, "odd input hidden blocks: \(text.debugDescription)")
        }
        d = describe(MarkdownParser.parse("<div>x</div>").blocks)
        check(d == ["p:<div>x</div>"], "html falls back to text: \(d)")
        d = describe(MarkdownParser.parse("1) a\n2) b").blocks)
        check(d == ["li0:1.:a", "li0:2.:b"], "paren numbering: \(d)")
        d = describe(MarkdownParser.parse("> > > > > > deep").blocks)
        check(!d.isEmpty && d.joined().contains("deep"), "deep quote kept: \(d)")
        check(MarkdownParser.parse("").blocks.isEmpty, "empty source")
        check(MarkdownParser.parse("\n\n   \n").blocks.isEmpty, "blank source")
        check(describe(MarkdownParser.parse("a\r\nb\r\n\r\nc").blocks) == ["p:a\nb", "p:c"], "CRLF")

        // Large bodies
        var big = ""
        var number = 0
        while big.count < 100_000 {
            number += 1
            big += "## Section \(number)\n\nParagraph with **bold** and `code` and a [link](https://example.com/\(number)).\n\n- one\n- [ ] two\n  - nested\n\n"
        }
        var started = Date()
        let bigDocument = MarkdownParser.parse(big)
        let bigSeconds = Date().timeIntervalSince(started)
        check(bigDocument.blocks.count == MarkdownParser.maxBlocks, "big document is capped: \(bigDocument.blocks.count)")
        check(bigDocument.hiddenBlocks > 0, "big document reports hidden blocks")
        check(bigSeconds < 3, "big document parse took \(bigSeconds)s")

        let oneLine = String(repeating: "word ", count: 20_000)  // 100,000 characters, no newline
        started = Date()
        let longDocument = MarkdownParser.parse(oneLine)
        check(longDocument.blocks.count > 1, "a 100,000 character line is split")
        let kept = longDocument.blocks.reduce(0) { total, block in
            if case .paragraph(let text) = block { return total + plain(text).count }
            return total
        }
        check(kept > 99_000, "split paragraphs keep their text: \(kept)")
        check(Date().timeIntervalSince(started) < 3, "long line parse too slow")

        let longCode = "```\n" + (1...30_000).map { "line \($0)" }.joined(separator: "\n") + "\n```"
        let codeDocument = MarkdownParser.parse(longCode)
        check(codeDocument.blocks.count + codeDocument.hiddenBlocks == 30_000 / MarkdownParser.codeChunkLines, "long code is chunked: \(codeDocument.blocks.count)")
    }
}
