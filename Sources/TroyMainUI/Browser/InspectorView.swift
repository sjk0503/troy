import SwiftUI
import TroyCore
import TroyUI

/// The right column: everything about the selected record, with its links as the main section.
struct InspectorView: View {
    @Bindable var model: AppModel
    /// The list layout keeps a wide inspector; the graph layout docks a narrow one beside the map.
    var minWidth: CGFloat = 360
    var compact = false
    @Environment(BrowserUI.self) private var ui

    var body: some View {
        Group {
            if let detail = model.detail, detail.record.id == model.selectedRecordID {
                RecordInspector(model: model, detail: detail, versions: model.versions, compact: compact)
                    .id(detail.record.id)
            } else if model.selectedRecordID != nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(
                    symbol: "doc.text.magnifyingglass",
                    title: L("No record selected", ko: "선택한 기록이 없습니다"),
                    message: L("Pick a record to read it and see what it is linked to.",
                               ko: "기록을 고르면 내용과 연결된 기록을 볼 수 있습니다."))
            }
        }
        .frame(minWidth: minWidth)
        .background(Color(nsColor: .textBackgroundColor))
        .confirmationDialog(
            L("Remove this link?", ko: "이 연결을 끊을까요?"),
            isPresented: Binding(get: { ui.linkToRemove != nil }, set: { if !$0 { ui.linkToRemove = nil } }),
            titleVisibility: .visible, presenting: ui.linkToRemove
        ) { pending in
            Button(L("Remove link", ko: "연결 끊기"), role: .destructive) {
                Task { await model.unlink(pending.link.link) }
            }
            Button(L("Cancel", ko: "취소"), role: .cancel) {}
        } message: { pending in
            let other = pending.link.other
            Text(L(
                "“#\(pending.from.id) \(pending.from.title)” \(pending.link.phrase) “#\(other.id) \(other.title)”. Only the link is removed; both records stay.",
                ko: "“#\(pending.from.id) \(pending.from.title)”와(과) “#\(other.id) \(other.title)”의 연결(\(Theme.name(pending.link.link.relation, outgoing: pending.link.isOutgoing)))만 끊습니다. 두 기록은 그대로 남습니다."))
        }
    }
}

private struct RecordInspector: View {
    @Bindable var model: AppModel
    let detail: RecordDetail
    let versions: [RecordVersion]
    var compact = false
    @Environment(BrowserUI.self) private var ui

    private var record: Record { detail.record }
    private var summary: RecordSummary { record.summary }

    var body: some View {
        ScrollView {
            // Reading order: the record itself, then how it connects, then the lookup material.
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if summary.isSuperseded { supersededBanner }
                    if !detail.advisories.isEmpty { advisories }
                }
                if !record.body.isEmpty { MarkdownText(record.body) }
                links
                if !summary.tags.isEmpty { tags }
                if !summary.paths.isEmpty { paths }
                if !versions.isEmpty { history }
                footer
            }
            .padding(.horizontal, compact ? 16 : 22)
            .padding(.vertical, compact ? 16 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Start at the very top. Under the window's transparent title bar the scroll view otherwise
        // opens one title-bar height down, with the header row hidden above the window.
        .defaultScrollAnchor(.top)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(Theme.name(summary.kind), systemImage: Theme.symbol(summary.kind))
                    .font(.callout)
                    .foregroundStyle(Theme.color(summary.kind))
                    .lineLimit(1)
                    .fixedSize()
                Text("#\(summary.id)")
                    .font(Theme.referenceFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .accessibilityLabel(L("Record \(summary.id)", ko: "기록 \(summary.id)"))
                if !compact { projectLabel }
                Spacer(minLength: 4)
                actions
            }
            // In the narrow dock the project name gets its own line instead of squeezing the actions.
            if compact { projectLabel }
            Text(summary.title)
                .font(.system(size: compact ? 21 : 26, weight: .bold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            statusLine
        }
    }

    @ViewBuilder private var projectLabel: some View {
        if model.selectedProjectID == nil, let name = ui.projectName(summary.projectID) {
            Label(name, systemImage: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { ui.edit(recordID: summary.id) } label: {
                Text(L("Edit", ko: "편집"))
            }
            .controlSize(.small)
            .keyboardShortcut("e", modifiers: .command)
            .help(L("Edit this record (⌘E)", ko: "이 기록 편집 (⌘E)"))

            Menu {
                Button(L("Copy “#\(summary.id)”", ko: "“#\(summary.id)” 복사")) { ui.copy("#\(summary.id)") }
                Button(L("Copy as Markdown", ko: "Markdown으로 복사")) { ui.copy(ui.markdown(detail)) }
                Divider()
                Button(L("Delete…", ko: "삭제…"), role: .destructive) { ui.recordToDelete = summary }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("More actions", ko: "더 보기"))
            .accessibilityLabel(L("More actions", ko: "더 보기"))
        }
    }

    private var statusLine: some View {
        // Status and claim share a line when the claim fits on one line; otherwise the claim sits
        // under the status and wraps (up to two lines, then truncates) within the column.
        Group {
            if summary.status == .doing, let who = summary.assignee {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        statusMenu
                        claim(who, wraps: false)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        statusMenu
                        claim(who, wraps: true)
                    }
                }
            } else {
                statusMenu
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusMenu: some View {
        Menu {
            Picker(L("Status", ko: "상태"), selection: Binding(
                get: { summary.status },
                set: { new in if new != summary.status { ui.setStatus(summary.id, new) } }
            )) {
                ForEach(RecordStatus.allCases, id: \.self) { status in
                    Label(Theme.name(status), systemImage: Theme.symbol(status)).tag(status)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: Theme.symbol(summary.status))
                Text(Theme.name(summary.status))
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Theme.color(summary.status))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Change the status. Choosing “In progress” claims the record for this app.",
                ko: "상태 바꾸기. “진행 중”을 고르면 이 앱이 기록을 맡습니다."))
    }

    private func claim(_ who: String, wraps: Bool) -> some View {
        let stale = Theme.isStale(claimedAt: summary.claimedAt)
        let age = summary.claimedAt.map { Theme.age($0) }
        let text = age.map { L("\(who) is on it · \($0)", ko: "\(who) 작업 중 · \($0)") } ?? who
        let explanation = stale
            ? L("Claimed more than \(Limits.staleClaimHours) hours ago. It may have been abandoned.",
                ko: "\(Limits.staleClaimHours)시간 넘게 지난 작업입니다. 중단됐을 수 있습니다.")
            : L("Claimed by another session or the app", ko: "다른 세션이나 앱이 맡고 있습니다")
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "person.fill")
            if wraps {
                // Wraps to two lines at the column width, then truncates; the tooltip has it all.
                Text(text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Only chosen by ViewThatFits when the whole claim fits on one line.
                Text(text).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            if stale {
                Text(L("stale", ko: "오래됨"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .fixedSize()
            }
        }
        .font(.callout)
        .foregroundStyle(stale ? Color.secondary : Theme.attention)
        .help("\(text)\n\(explanation)")
    }

    // MARK: Banners

    private var supersededBanner: some View {
        let replacements = detail.links.filter { $0.link.relation == .supersedes && !$0.isOutgoing }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Replaced by", ko: "이 기록을 대체한 기록"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(replacements) { item in
                    Button { ui.open(item.other) } label: {
                        Text("#\(item.other.id) \(item.other.title)")
                            .font(.callout.weight(.medium))
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private var advisories: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(detail.advisories.enumerated()), id: \.offset) { _, advisory in
                Button { ui.open(advisory.other) } label: {
                    AdvisoryRow(advisory)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Go to #\(advisory.other.id)", ko: "#\(advisory.other.id)(으)로 이동"))
            }
        }
        .background(Theme.attention.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    // MARK: Tags and paths

    private var tags: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(L("Tags", ko: "태그"), count: summary.tags.count)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(summary.tags, id: \.self) { tag in
                    Button { model.filter.tag = tag } label: { TagChip(tag) }
                        .buttonStyle(.plain)
                        .help(L("Show only records tagged “\(tag)”", ko: "“\(tag)” 태그가 붙은 기록만 보기"))
                }
            }
        }
    }

    private var paths: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeading(L("Files", ko: "관련 파일"), count: summary.paths.count)
            ForEach(summary.paths, id: \.self) { path in
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Links

    private struct LinkGroup: Identifiable {
        let relation: Relation
        /// `nil` for symmetric relations, which have no direction.
        let outgoing: Bool?
        let items: [LinkedRecord]
        var id: String { "\(relation.rawValue)-\(outgoing.map { $0 ? "out" : "in" } ?? "both")" }
        var title: String { Theme.name(relation, outgoing: outgoing ?? true) }
    }

    private var linkGroups: [LinkGroup] {
        var groups: [LinkGroup] = []
        for relation in Relation.allCases {
            let ofRelation = detail.links.filter { $0.link.relation == relation }
            if relation.isSymmetric {
                if !ofRelation.isEmpty { groups.append(LinkGroup(relation: relation, outgoing: nil, items: ofRelation)) }
            } else {
                for outgoing in [true, false] {
                    let items = ofRelation.filter { $0.isOutgoing == outgoing }
                    if !items.isEmpty { groups.append(LinkGroup(relation: relation, outgoing: outgoing, items: items)) }
                }
            }
        }
        return groups
    }

    /// A text button that falls back to its symbol when the dock is narrow.
    private func linkButton(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                Label(title, systemImage: symbol).lineLimit(1)
                Label(title, systemImage: symbol).labelStyle(.iconOnly)
            }
            .font(.callout)
        }
        .buttonStyle(.borderless)
        .tint(Theme.workspaceInk)
        .help(help)
        .accessibilityLabel(title)
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SectionHeading(L("Links", ko: "연결"), count: detail.links.count)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if !(ui.showsLocalGraph && model.browserMode == .graph) {
                    linkButton(
                        L("Open local graph", ko: "로컬 그래프 열기"), symbol: "point.3.connected.trianglepath.dotted",
                        help: L("Show only this record's direct links as a graph", ko: "이 기록의 직접 연결만 그래프로 봅니다")
                    ) { ui.openLocalGraph(for: summary) }
                }
                linkButton(
                    L("Add link…", ko: "연결 추가"), symbol: "plus",
                    help: L("Link this record to another one", ko: "이 기록을 다른 기록과 연결합니다")
                ) { ui.addLink(to: summary) }
            }
            if detail.links.isEmpty {
                Text(L("Not linked to anything yet. Links show how this record fits with the others.",
                       ko: "아직 연결된 기록이 없습니다. 연결하면 다른 기록과의 관계를 볼 수 있습니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(linkGroups) { group in
                let color = Paint.relations[group.relation] ?? .secondary
                VStack(alignment: .leading, spacing: 0) {
                    // The arrow gives the direction without relying on color: it points from the
                    // record that holds the link to the one it names.
                    HStack(spacing: 8) {
                        Image(systemName: group.outgoing.map { $0 ? "arrow.right" : "arrow.left" } ?? "arrow.left.arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(color)
                            .frame(width: 10)
                            .accessibilityHidden(true)
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                        Text("\(group.items.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 3)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(group.title), \(group.items.count)")
                    .accessibilityAddTraits(.isHeader)
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        LinkRow(item: item, from: summary, color: color,
                                isLast: index == group.items.count - 1,
                                showsProject: item.other.projectID != summary.projectID)
                    }
                }
            }
        }
    }

    // MARK: History and footer

    private var history: some View {
        DisclosureGroup {
            HistoryList(versions: versions, current: record)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                SectionHeading(L("History", ko: "변경 이력"), count: versions.count)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Created by \(summary.source.isEmpty ? "—" : summary.source) · \(Theme.timestamp(summary.createdAt))",
                   ko: "\(summary.source.isEmpty ? "—" : summary.source)이(가) \(Theme.timestamp(summary.createdAt))에 만듦"))
            Text(L("Updated \(Theme.timestamp(summary.updatedAt))", ko: "\(Theme.timestamp(summary.updatedAt))에 수정"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}

/// One linked record: kind, title, status and the link's note. Click to go there.
private struct LinkRow: View {
    let item: LinkedRecord
    let from: RecordSummary
    let color: Color
    let isLast: Bool
    let showsProject: Bool
    @Environment(BrowserUI.self) private var ui
    @State private var hovering = false

    private static let gutter: CGFloat = 18
    /// Vertical center of the title's first line, where the branch meets the row.
    private static let nodeY: CGFloat = 13

    @ViewBuilder private var actions: some View {
        Button(L("Open", ko: "열기")) { ui.open(item.other) }
        Button(L("Copy “#\(item.other.id)”", ko: "“#\(item.other.id)” 복사")) { ui.copy("#\(item.other.id)") }
        Divider()
        Button(L("Remove link…", ko: "연결 끊기…"), role: .destructive) {
            ui.linkToRemove = PendingLinkRemoval(link: item, from: from)
        }
    }

    var body: some View {
        let other = item.other
        let quiet = other.status.isFinished || other.isSuperseded
        let statusName = other.isSuperseded ? Theme.supersededName : Theme.name(other.status)
        HStack(alignment: .top, spacing: 2) {
            Button { ui.open(other) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(other.title)
                        .font(.body)
                        .foregroundStyle(quiet ? .secondary : .primary)
                        .strikethrough(other.status == .dropped)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Image(systemName: Theme.symbol(other.kind))
                            .foregroundStyle(Theme.color(other.kind))
                            .opacity(quiet ? 0.6 : 1)
                        Text("#\(other.id)")
                            .font(Theme.referenceFont)
                            .foregroundStyle(.secondary)
                        StatusBadge(other.status, isSuperseded: other.isSuperseded)
                        if showsProject, let name = ui.projectName(other.projectID) {
                            Label(name, systemImage: "folder").lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    if !item.link.note.isEmpty {
                        Text(item.link.note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Theme.name(item.link.relation, outgoing: item.isOutgoing)), #\(other.id) \(other.title), \(Theme.name(other.kind)), \(statusName)"
                                + (item.link.note.isEmpty ? "" : ", \(item.link.note)"))
            .accessibilityHint(L("Opens this record", ko: "이 기록을 엽니다"))

            Menu { actions } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.top, 2)
            .help(L("More actions", ko: "더 보기"))
            .accessibilityLabel(L("Actions for link to #\(other.id)", ko: "#\(other.id) 연결 작업"))
        }
        .contextMenu { actions }
        .padding(.leading, Self.gutter)
        .background(alignment: .leading) {
            // A trunk down the group with a short branch and node at each linked record.
            Canvas { context, size in
                let x: CGFloat = 5
                var trunk = Path()
                trunk.move(to: CGPoint(x: x, y: 0))
                trunk.addLine(to: CGPoint(x: x, y: isLast ? Self.nodeY : size.height))
                trunk.move(to: CGPoint(x: x, y: Self.nodeY))
                trunk.addLine(to: CGPoint(x: Self.gutter - 6, y: Self.nodeY))
                context.stroke(trunk, with: .color(color.opacity(0.5)), lineWidth: 1)
                context.fill(Path(ellipseIn: CGRect(x: Self.gutter - 9, y: Self.nodeY - 3, width: 6, height: 6)),
                             with: .color(color))
            }
            .frame(width: Self.gutter)
            .accessibilityHidden(true)
        }
    }
}
