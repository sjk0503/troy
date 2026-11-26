import SwiftUI
import TroyCore
import TroyUI

/// A record's earlier versions, newest first: who changed what, with the previous values on demand.
///
/// Each `RecordVersion` holds the values a change replaced. The value a field changed to is the same
/// field in the nearest newer version that has it, or else the current record.
public struct HistoryList: View {
    private let versions: [RecordVersion]
    private let current: Record

    public init(versions: [RecordVersion], current: Record) {
        self.versions = versions
        self.current = current
    }

    public var body: some View {
        let entries = HistoryEntry.entries(versions: versions, current: current)
        if entries.isEmpty {
            Text(L("No earlier versions.", ko: "이전 버전이 없습니다."))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.vertical, 10) }
                    HistoryRow(entry: entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Model

/// One change, with the old and new value of each field that differed.
struct HistoryEntry: Identifiable {
    enum Change: Identifiable {
        case title(old: String, new: String)
        case kind(old: RecordKind, new: RecordKind)
        case status(old: RecordStatus, new: RecordStatus)
        case tags(added: [String], removed: [String])
        case paths(added: [String], removed: [String])
        case body(previous: String, delta: Int)
        case project(old: Int64, new: Int64)
        case holder(previous: String)

        var id: String {
            switch self {
            case .title: "title"
            case .kind: "kind"
            case .status: "status"
            case .tags: "tags"
            case .paths: "paths"
            case .body: "body"
            case .project: "project"
            case .holder: "holder"
            }
        }
    }

    let id: Int64
    let actor: String
    let date: Date
    let changes: [Change]

    /// Newest first. A version that changed nothing visible is left out.
    static func entries(versions: [RecordVersion], current: Record) -> [HistoryEntry] {
        let ordered = versions.sorted { ($0.rev, $0.id) > ($1.rev, $1.id) }
        var result: [HistoryEntry] = []
        for (index, version) in ordered.enumerated() {
            let newer = ordered[..<index]
            func next<T>(_ field: KeyPath<RecordVersion, T?>, fallback: T) -> T {
                for candidate in newer.reversed() {
                    if let value = candidate[keyPath: field] { return value }
                }
                return fallback
            }
            var changes: [Change] = []
            if let old = version.title {
                let new = next(\.title, fallback: current.title)
                if old != new { changes.append(.title(old: old, new: new)) }
            }
            if let old = version.kind {
                let new = next(\.kind, fallback: current.kind)
                if old != new { changes.append(.kind(old: old, new: new)) }
            }
            if let old = version.status {
                let new = next(\.status, fallback: current.status)
                if old != new { changes.append(.status(old: old, new: new)) }
            }
            if let old = version.tags {
                let new = next(\.tags, fallback: current.tags)
                if old != new {
                    let oldSet = Set(old), newSet = Set(new)
                    changes.append(.tags(
                        added: new.filter { !oldSet.contains($0) }, removed: old.filter { !newSet.contains($0) }))
                }
            }
            if let old = version.paths {
                let new = next(\.paths, fallback: current.paths)
                if old != new {
                    let oldSet = Set(old), newSet = Set(new)
                    changes.append(.paths(
                        added: new.filter { !oldSet.contains($0) }, removed: old.filter { !newSet.contains($0) }))
                }
            }
            if let old = version.body {
                let new = next(\.body, fallback: current.body)
                if old != new { changes.append(.body(previous: old, delta: new.count - old.count)) }
            }
            if let old = version.projectID {
                let new = next(\.projectID, fallback: current.projectID)
                if old != new { changes.append(.project(old: old, new: new)) }
            }
            // A release is already told by the status line; a takeover has no other trace.
            if let previous = version.assignee, version.status == nil { changes.append(.holder(previous: previous)) }
            guard !changes.isEmpty else { continue }
            result.append(HistoryEntry(id: version.id, actor: version.actor, date: version.changedAt, changes: changes))
        }
        return result
    }
}

// MARK: - Views

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.actor)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Theme.timestamp(entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ForEach(entry.changes) { change in
                ChangeLine(change: change)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ChangeLine: View {
    let change: HistoryEntry.Change

    var body: some View {
        switch change {
        case .title(let old, let new):
            line(L("Title", ko: "제목")) {
                Text(old).strikethrough().foregroundStyle(.secondary)
                    + Text("  →  ").foregroundStyle(.tertiary)
                    + Text(new)
            }
        case .kind(let old, let new):
            line(L("Kind", ko: "종류")) {
                Text(Theme.name(old)).foregroundStyle(.secondary)
                    + Text("  →  ").foregroundStyle(.tertiary)
                    + Text(Theme.name(new))
            }
        case .status(let old, let new):
            line(L("Status", ko: "상태")) {
                Text(Theme.name(old)).foregroundStyle(.secondary)
                    + Text("  →  ").foregroundStyle(.tertiary)
                    + Text(Theme.name(new)).foregroundStyle(new == .open ? Color.primary : Theme.color(new))
            }
        case .tags(let added, let removed):
            line(L("Tags", ko: "태그")) { diffText(added: added, removed: removed, reordered: L("reordered", ko: "순서 변경")) }
        case .paths(let added, let removed):
            line(L("Paths", ko: "경로")) { diffText(added: added, removed: removed, reordered: L("reordered", ko: "순서 변경")) }
        case .holder(let previous):
            line(L("Taken over", ko: "넘겨받음")) {
                Text(L("from \(previous)", ko: "\(previous)에게서")).foregroundStyle(.secondary)
            }
        case .project(let old, let new):
            line(L("Project", ko: "프로젝트")) {
                Text("#\(old)").foregroundStyle(.secondary) + Text("  →  ").foregroundStyle(.tertiary) + Text("#\(new)")
            }
        case .body(let previous, let delta):
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Previous body", ko: "이전 본문"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    ScrollView {
                        if previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(L("(empty)", ko: "(비어 있음)")).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            MarkdownText(previous)
                        }
                    }
                    .frame(maxHeight: 240)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 4)
            } label: {
                (Text(L("Body changed", ko: "본문 변경"))
                    + Text(delta == 0 ? "" : "  " + (delta > 0
                        ? L("+\(delta) characters", ko: "+\(delta)자")
                        : L("−\(-delta) characters", ko: "−\(-delta)자"))).foregroundStyle(.secondary))
                    .font(.callout)
            }
        }
    }

    private func line(_ label: String, _ value: () -> Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            value()
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func diffText(added: [String], removed: [String], reordered: String) -> Text {
        var parts: [Text] = []
        for tag in added { parts.append(Text("+\(tag)").foregroundStyle(Theme.color(RecordStatus.done))) }
        for tag in removed { parts.append(Text("−\(tag)").foregroundStyle(Theme.danger)) }
        guard var result = parts.first else { return Text(reordered).foregroundStyle(.secondary) }
        for part in parts.dropFirst() { result = result + Text("  ") + part }
        return result
    }
}
