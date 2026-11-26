import SwiftUI
import TroyUI

/// Shows a record body: Markdown blocks (headings, lists, task lists, quotes, code, tables) laid out natively.
///
/// The text is parsed off the main actor. Until the parse arrives the plain text is shown, so a very
/// long body never blocks the window.
public struct MarkdownText: View {
    private let source: String
    @State private var document: MarkdownDocument?
    @State private var parsedSource: String?

    public init(_ source: String) {
        self.source = source
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                // Only web and mail links leave the app; anything else is ignored.
                guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
                    return .discarded
                }
                return .systemAction
            })
            .task(id: source) {
                let text = source
                let parsed = await Task.detached(priority: .userInitiated) { MarkdownParser.parse(text) }.value
                guard !Task.isCancelled else { return }
                document = parsed
                parsedSource = text
            }
    }

    @ViewBuilder private var content: some View {
        if let document, parsedSource == source {
            MarkdownBlocksView(blocks: document.blocks, hiddenBlocks: document.hiddenBlocks)
        } else {
            // Parse not finished: the raw text, capped so it is cheap to lay out.
            Text(String(source.prefix(4_000)))
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Blocks

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var hiddenBlocks = 0

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block)
                    .padding(.top, index == 0 ? 0 : gap(before: block, after: blocks[index - 1]))
            }
            if hiddenBlocks > 0 {
                Text(L("\(hiddenBlocks) more blocks are not shown.", ko: "나머지 \(hiddenBlocks)개 블록은 표시하지 않았습니다."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
            }
        }
    }

    /// Space between two blocks: list items sit close together, headings pull away from what precedes them.
    private func gap(before block: MarkdownBlock, after previous: MarkdownBlock) -> CGFloat {
        switch (previous, block) {
        case (.listItem, .listItem): return 4
        case (_, .heading(let level, _)): return level <= 2 ? 18 : 14
        case (.heading, _): return 6
        case (.rule, _), (_, .rule): return 12
        default: return 10
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(Self.headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(text)
                .font(.body)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let depth, let marker, let text):
            MarkdownListItem(depth: depth, marker: marker, text: text)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                MarkdownBlocksView(blocks: inner)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text, let continued, let indent):
            MarkdownCodeBlock(language: continued ? nil : language, text: text)
                .padding(.leading, CGFloat(min(indent, 12)) * 7)
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Divider()
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 18, weight: .semibold)
        case 2: .system(size: 16, weight: .semibold)
        case 3: .system(size: 14, weight: .semibold)
        default: .system(size: 13, weight: .semibold)
        }
    }
}

struct MarkdownListItem: View {
    let depth: Int
    let marker: MarkdownListMarker
    let text: AttributedString

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            markerView
                .frame(minWidth: 18, alignment: .trailing)
            Text(text)
                .font(.body)
                .lineSpacing(2)
                .foregroundStyle(isDone ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(depth) * 20)
    }

    private var isDone: Bool {
        if case .task(let done) = marker { return done }
        return false
    }

    @ViewBuilder private var markerView: some View {
        switch marker {
        case .bullet:
            Text(["•", "◦", "▪"][depth % 3])
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .number(let number):
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .foregroundStyle(done ? Color.accentColor : Color.secondary)
                .accessibilityLabel(done ? L("Done", ko: "완료") : L("Not done", ko: "미완료"))
        }
    }
}

struct MarkdownCodeBlock: View {
    let language: String?
    let text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(text.isEmpty ? " " : text)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, language == nil ? 10 : 20)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let language {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 5)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column, isHeader: true)
                            .gridColumnAlignment(Self.alignment(table.alignments[column]))
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellView(cell, column: column, isHeader: false)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        }
        .scrollIndicators(.automatic)
    }

    private func cellView(_ cell: AttributedString, column: Int, isHeader: Bool) -> some View {
        Text(cell)
            .font(isHeader ? .callout.weight(.semibold) : .callout)
            .frame(maxWidth: 360, alignment: Self.frameAlignment(table.alignments[column]))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isHeader ? Color.primary.opacity(0.05) : Color.clear)
    }

    private static func alignment(_ value: MarkdownAlignment) -> HorizontalAlignment {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private static func frameAlignment(_ value: MarkdownAlignment) -> Alignment {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
