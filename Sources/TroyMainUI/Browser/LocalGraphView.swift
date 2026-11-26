import SwiftUI
import TroyCore
import TroyGraph
import TroyUI

/// One heading of the local map: a relation seen in one direction from the focus record.
struct LocalGraphGroup: Identifiable {
    let relation: Relation
    let outgoing: Bool
    let items: [LinkedRecord]
    var id: String { "\(relation)-\(outgoing)" }
}

/// Counts shown by the toolbar for a record's local map.
struct LocalGraphCounts {
    var links: Int
    var records: Int
    /// Distinct linked records that live in a project other than the focus record's.
    var otherProjectRecords: Int
}

enum LocalGraph {
    /// Groups by relation and direction as viewed from the focus record. Symmetric relations have one group.
    static func groups(_ links: [LinkedRecord]) -> [LocalGraphGroup] {
        var result: [LocalGraphGroup] = []
        for relation in Relation.allCases {
            for outgoing in [true, false] {
                if relation.isSymmetric && !outgoing { continue }
                let items = links
                    .filter { $0.link.relation == relation && (relation.isSymmetric || $0.isOutgoing == outgoing) }
                    .sorted { a, b in
                        let order = a.other.title.localizedStandardCompare(b.other.title)
                        return order == .orderedSame ? a.link.id < b.link.id : order == .orderedAscending
                    }
                if !items.isEmpty { result.append(LocalGraphGroup(relation: relation, outgoing: outgoing, items: items)) }
            }
        }
        return result
    }

    /// Outgoing directed groups belong left of the focus; incoming ones and the symmetric relations right.
    static func sides(_ groups: [LocalGraphGroup]) -> (left: [LocalGraphGroup], right: [LocalGraphGroup]) {
        (groups.filter { $0.outgoing && !$0.relation.isSymmetric },
         groups.filter { !$0.outgoing || $0.relation.isSymmetric })
    }

    enum Layout: Equatable { case balanced, side, stacked }

    /// The balanced two-sided diagram needs both sides populated, enough width, and the taller side to fit the
    /// height. Otherwise the top-oriented layouts keep the focus on the first screen.
    static func layout(_ groups: [LocalGraphGroup], width: CGFloat, height: CGFloat) -> Layout {
        guard width >= 640 else { return .stacked }
        let (left, right) = sides(groups)
        guard width >= 840, !left.isEmpty, !right.isEmpty else { return .side }
        func estimate(_ side: [LocalGraphGroup]) -> CGFloat {
            side.reduce(0) { $0 + 40 + CGFloat($1.items.count) * 64 }
        }
        return max(estimate(left), estimate(right)) <= height - 56 ? .balanced : .side
    }

    static func counts(_ detail: RecordDetail) -> LocalGraphCounts {
        let others = Set(detail.links.map(\.other.id))
        let foreign = Set(detail.links.filter { $0.other.projectID != detail.record.projectID }.map(\.other.id))
        return LocalGraphCounts(links: detail.links.count, records: others.count, otherProjectRecords: foreign.count)
    }
}

/// Structure is drawn in a restrained ink; only the nodes and relation names carry color.
private let ink = Color(white: 0.38)
private let inkLine: CGFloat = 1.5

/// The one-hop map of a record. Wide with links on both sides: the focus in the middle, outgoing groups mirrored
/// on its left, incoming and symmetric ones on its right. Otherwise the focus on one side, every linked record on
/// the other. Connectors end exactly on each branch's node.
struct LocalGraphView: View {
    let detail: RecordDetail
    let projectName: (Int64) -> String?
    let onOpen: (RecordSummary) -> Void
    let onAddLink: () -> Void

    private let nodeSpace: CGFloat = 26
    private let wideGutter: CGFloat = 34
    private let balancedTrunkX: CGFloat = 36

    var body: some View {
        let groups = LocalGraph.groups(detail.links)
        GeometryReader { geo in
            ScrollView(.vertical) {
                Group {
                    if groups.isEmpty {
                        emptyLayout
                    } else {
                        switch LocalGraph.layout(groups, width: geo.size.width, height: geo.size.height) {
                        case .balanced: balancedLayout(groups)
                        case .side: wideLayout(groups)
                        case .stacked: narrowLayout(groups)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            // Keyed by record so navigating starts at the top instead of keeping the previous scroll offset.
            .id(detail.record.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Links of \(detail.record.title)", ko: "\(detail.record.title)의 연결"))
    }

    // MARK: Layouts

    /// Focus centered, both columns centered on it, so the whole diagram sits in the vertical middle.
    private func balancedLayout(_ groups: [LocalGraphGroup]) -> some View {
        let sides = LocalGraph.sides(groups)
        let stub = balancedTrunkX + inkLine / 2
        return HStack(alignment: .center, spacing: 0) {
            branches(sides.left, trunkX: balancedTrunkX, join: .center, mirrored: true)
                .overlay(alignment: .trailing) { stubLine(width: stub) }
                .frame(maxWidth: .infinity, alignment: .trailing)
            focusCard.frame(width: 260)
            branches(sides.right, trunkX: balancedTrunkX, join: .center, mirrored: false)
                .overlay(alignment: .leading) { stubLine(width: stub) }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(28)
        .frame(maxWidth: 1240)
    }

    /// The horizontal join from the focus card into a trunk, at the diagram's vertical middle.
    private func stubLine(width: CGFloat) -> some View {
        Rectangle().fill(ink).frame(width: width, height: inkLine).accessibilityHidden(true)
    }

    private func wideLayout(_ groups: [LocalGraphGroup]) -> some View {
        // Both columns hang from the top, so the root never scrolls away from the first screen however tall
        // either column grows. The first header draws the connector from the card into the trunk, so the
        // join stays on the trunk whatever the heights are.
        HStack(alignment: .top, spacing: 0) {
            focusCard.frame(width: 280)
            branches(groups, trunkX: wideGutter + inkLine / 2, join: .side)
                .frame(maxWidth: 560 + wideGutter, alignment: .leading)
        }
        .padding(28)
        .frame(maxWidth: 1000)
    }

    private func narrowLayout(_ groups: [LocalGraphGroup]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            focusCard
            Rectangle().fill(ink).frame(width: inkLine, height: 14)
                .padding(.leading, 14 - inkLine / 2)
                .accessibilityHidden(true)
            branches(groups, trunkX: 14, join: .top)
        }
        .padding(16)
        .frame(maxWidth: 560)
    }

    private var emptyLayout: some View {
        VStack(spacing: 20) {
            focusCard.frame(maxWidth: 360)
            VStack(spacing: 10) {
                Text(L("This record has no links yet.", ko: "아직 연결된 기록이 없습니다."))
                    .font(.headline)
                Text(L("Link what it depends on, what it came from, or what it replaces so the map can show them.",
                       ko: "선행 작업, 근거, 대체한 기록을 연결하면 이곳에 지도로 나타납니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onAddLink) {
                    Label(L("Add link", ko: "연결 추가"), systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .frame(maxWidth: 360)
        }
        .padding(28)
    }

    // MARK: Focus

    private var focusCard: some View {
        let record = detail.record
        let color = Paint.kinds[record.kind] ?? .gray
        let finished = record.status.isFinished || record.summary.isSuperseded
        var meta = "\(Theme.name(record.kind)) · \(Theme.name(record.status))"
        if record.summary.isSuperseded { meta += " · \(Theme.supersededName)" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: Theme.symbol(record.kind))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(meta).lineLimit(1)
                Spacer(minLength: 4)
                Text("#\(record.id)").monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Text(record.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white.opacity(finished ? 0.7 : 1))
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let name = projectName(record.projectID) {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(color.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L("Focus", ko: "기준 기록")): \(record.title), \(meta), #\(record.id)")
    }

    // MARK: Branches

    private func branches(_ groups: [LocalGraphGroup], trunkX: CGFloat, join: Join, mirrored: Bool = false) -> some View {
        let trunk = Trunk(x: trunkX, width: trunkX + (join == .center ? 44 : nodeSpace), join: join, mirrored: mirrored)
        return VStack(alignment: mirrored ? .trailing : .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                header(group, trunk: trunk, isFirst: groupIndex == 0)
                ForEach(Array(group.items.enumerated()), id: \.element.id) { itemIndex, item in
                    BranchRow(
                        item: item, group: group, trunk: trunk,
                        isLast: groupIndex == groups.count - 1 && itemIndex == group.items.count - 1,
                        projectLabel: item.other.projectID != detail.record.projectID
                            ? (projectName(item.other.projectID) ?? L("Another project", ko: "다른 프로젝트")) : nil,
                        onOpen: onOpen)
                }
            }
        }
    }

    private func header(_ group: LocalGraphGroup, trunk: Trunk, isFirst: Bool) -> some View {
        let heading = Theme.name(group.relation, outgoing: group.outgoing)
        let mirrored = trunk.mirrored
        let label = Text(heading)
            .font((trunk.rich ? Font.subheadline : .caption).weight(.semibold))
            .foregroundStyle(Theme.color(group.relation))
        let count = Text("\(group.items.count)")
            .font(trunk.rich ? .caption : .caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        return HStack(spacing: 6) {
            if mirrored {
                Spacer(minLength: 0)
                count
                label
            } else {
                label
                count
                Spacer(minLength: 0)
            }
        }
        .padding(.top, isFirst ? 0 : 14)
        .padding(.bottom, 4)
        .padding(mirrored ? .trailing : .leading, trunk.width)
        .frame(minHeight: isFirst && trunk.join == .side ? 40 : 22)
        .background(alignment: mirrored ? .trailing : .leading) {
            TrunkShape(trunk: trunk, kind: .header, isFirst: isFirst, isLast: false, node: .clear, relation: nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(heading), \(group.items.count)")
    }
}

// MARK: - Trunk

private struct Trunk {
    /// Where the vertical line runs, measured from the cell's near edge (leading, or trailing when mirrored).
    var x: CGFloat
    /// The cell's width; the node sits at its far end.
    var width: CGFloat
    var join: Join
    /// The left half of the balanced diagram: trunk at the trailing edge, nodes at the leading end.
    var mirrored = false
    /// The balanced diagram draws larger titles and relation-styled connectors.
    var rich: Bool { join == .center }
}

/// How the first header meets the focus card: from its side (wide, a stub into the trunk), from above (narrow),
/// or `.center`: the balanced diagram, where a stub at the diagram's middle joins each trunk.
private enum Join { case side, top, center }

/// The vertical trunk plus, for a row, the tick that ends on the row's node dot.
private struct TrunkShape: View {
    enum Kind { case header, row }
    let trunk: Trunk
    let kind: Kind
    let isFirst: Bool
    let isLast: Bool
    let node: Color
    /// Set in the balanced diagram: the tick takes this relation's color, dash and arrow.
    let relation: Relation?

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let trunkX = trunk.mirrored ? size.width - trunk.x : trunk.x
            // Narrow: the trunk starts at the cell's top, flush with the connector from the card.
            // Otherwise it starts at the first header's middle.
            let top = (isFirst && trunk.join != .top) ? mid : 0
            let bottom = (isLast && kind == .row) ? mid : size.height
            var trunkLine = Path()
            trunkLine.move(to: CGPoint(x: trunkX, y: top))
            trunkLine.addLine(to: CGPoint(x: trunkX, y: bottom))
            context.stroke(trunkLine, with: .color(ink), lineWidth: inkLine)
            if kind == .header, isFirst, trunk.join == .side {
                var stub = Path()
                stub.move(to: CGPoint(x: 0, y: mid))
                stub.addLine(to: CGPoint(x: trunkX, y: mid))
                context.stroke(stub, with: .color(ink), lineWidth: inkLine)
            }
            guard kind == .row else { return }
            let center = CGPoint(x: trunk.mirrored ? 7 : size.width - 7, y: mid)
            let dir: CGFloat = center.x >= trunkX ? 1 : -1
            var tick = Path()
            tick.move(to: CGPoint(x: trunkX, y: mid))
            tick.addLine(to: center)
            if let relation {
                let style = RelationStyle.of(relation)
                let color = (Paint.relations[relation] ?? .gray).opacity(0.9)
                let dash: [CGFloat] = switch style.stroke {
                case .solid: []
                case .dashed: [5, 4]
                case .dotted: [1.2, 4]
                }
                context.stroke(tick, with: .color(color),
                               style: StrokeStyle(lineWidth: min(style.width, 2.6), lineCap: .round, dash: dash))
                if style.hasArrow {
                    // Left half: the link leaves the focus and ends at the node. Right half: it comes in to the trunk.
                    let atNode = trunk.mirrored
                    let tip = atNode ? center.x - dir * 6 : trunkX + dir * 2
                    let heading: CGFloat = atNode ? dir : -dir
                    var head = Path()
                    head.move(to: CGPoint(x: tip, y: mid))
                    head.addLine(to: CGPoint(x: tip - heading * 7, y: mid - 4))
                    head.addLine(to: CGPoint(x: tip - heading * 7, y: mid + 4))
                    head.closeSubpath()
                    context.fill(head, with: .color(color))
                }
            } else {
                context.stroke(tick, with: .color(ink), lineWidth: inkLine)
            }
            let dot = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: dot), with: .color(node))
            context.stroke(Path(ellipseIn: dot), with: .color(.black), lineWidth: 1.5)
        }
        .frame(width: trunk.width)
        .accessibilityHidden(true)
    }
}

// MARK: - Branch row

private struct BranchRow: View {
    let item: LinkedRecord
    let group: LocalGraphGroup
    let trunk: Trunk
    let isLast: Bool
    let projectLabel: String?
    let onOpen: (RecordSummary) -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let other = item.other
        let color = Paint.kinds[other.kind] ?? .gray
        let finished = other.status.isFinished || other.isSuperseded
        var meta = "\(Theme.name(other.kind)) · \(Theme.name(other.status))"
        if other.isSuperseded { meta += " · \(Theme.supersededName)" }
        meta += " · #\(other.id)"
        if let projectLabel { meta += " · \(projectLabel)" }
        let heading = Theme.name(group.relation, outgoing: group.outgoing)
        let mirrored = trunk.mirrored
        let textAlign: TextAlignment = mirrored ? .trailing : .leading
        return Button { onOpen(other) } label: {
            VStack(alignment: mirrored ? .trailing : .leading, spacing: 2) {
                Text(other.title)
                    .font(trunk.rich ? Font.body.weight(.medium) : .callout)
                    .foregroundStyle(.white.opacity(finished ? 0.62 : 0.95))
                    .lineLimit(3)
                    .multilineTextAlignment(textAlign)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.link.note.isEmpty {
                    Text(item.link.note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .italic()
                        .lineLimit(2)
                        .multilineTextAlignment(textAlign)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: mirrored ? .trailing : .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovering || focused ? 0.09 : 0)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: focused ? 2 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .padding(mirrored ? .trailing : .leading, trunk.width)
        .padding(.vertical, 1)
        .background(alignment: mirrored ? .trailing : .leading) {
            TrunkShape(trunk: trunk, kind: .row, isFirst: false, isLast: isLast, node: color,
                       relation: trunk.rich ? group.relation : nil)
        }
        .help(L("Open \(other.title)", ko: "\(other.title) 열기"))
        .accessibilityLabel("\(heading): \(other.title), \(meta)")
        .accessibilityHint(L("Opens this record", ko: "이 기록을 엽니다"))
    }
}
