import AppKit
import SwiftUI
import TroyCore

/// Colors, symbols and names for everything Troy shows. Views take these from here so a
/// record looks the same in the panel, the list, the inspector and the graph.
nonisolated public enum Theme {
    // MARK: Record kinds

    public static func color(_ kind: RecordKind) -> Color {
        switch kind {
        case .task: dynamic(light: 0x2F6FEB, dark: 0x5B9BFF)
        case .decision: dynamic(light: 0x7A4FE0, dark: 0xA78BFA)
        case .note: dynamic(light: 0x946205, dark: 0xF0B429)
        case .result: dynamic(light: 0x117451, dark: 0x34D399)
        case .prompt: dynamic(light: 0xAD3468, dark: 0xF472B6)
        }
    }

    public static func symbol(_ kind: RecordKind) -> String {
        switch kind {
        case .task: "checklist"
        case .decision: "signpost.right.fill"
        case .note: "note.text"
        case .result: "shippingbox.fill"
        case .prompt: "text.bubble.fill"
        }
    }

    public static func name(_ kind: RecordKind) -> String {
        switch kind {
        case .task: L("Task", ko: "할 일")
        case .decision: L("Decision", ko: "결정")
        case .note: L("Note", ko: "메모")
        case .result: L("Result", ko: "결과")
        case .prompt: L("Prompt", ko: "프롬프트")
        }
    }

    public static func pluralName(_ kind: RecordKind) -> String {
        switch kind {
        case .task: L("Tasks", ko: "할 일")
        case .decision: L("Decisions", ko: "결정")
        case .note: L("Notes", ko: "메모")
        case .result: L("Results", ko: "결과")
        case .prompt: L("Prompts", ko: "프롬프트")
        }
    }

    // MARK: Statuses

    public static func color(_ status: RecordStatus) -> Color {
        switch status {
        case .open: Color.secondary
        case .doing: attention
        case .done: dynamic(light: 0x117451, dark: 0x34D399)
        case .dropped: Color.secondary.opacity(0.8)
        }
    }

    public static func symbol(_ status: RecordStatus) -> String {
        switch status {
        case .open: "circle"
        case .doing: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        case .dropped: "xmark.circle"
        }
    }

    public static func name(_ status: RecordStatus) -> String {
        switch status {
        case .open: L("Open", ko: "대기")
        case .doing: L("In progress", ko: "진행 중")
        case .done: L("Done", ko: "완료")
        case .dropped: L("Dropped", ko: "중단")
        }
    }

    public static var supersededName: String { L("Superseded", ko: "대체됨") }

    // MARK: Relations

    /// The heading for a group of links, seen from one record.
    public static func name(_ relation: Relation, outgoing: Bool) -> String {
        switch (relation, outgoing) {
        case (.partOf, true): L("Part of", ko: "상위")
        case (.partOf, false): L("Contains", ko: "하위")
        case (.dependsOn, true): L("Depends on", ko: "선행 작업")
        case (.dependsOn, false): L("Blocks", ko: "후속 작업")
        case (.derivedFrom, true): L("Derived from", ko: "근거")
        case (.derivedFrom, false): L("Led to", ko: "파생")
        case (.supersedes, true): L("Supersedes", ko: "대체한 기록")
        case (.supersedes, false): L("Superseded by", ko: "대체됨")
        case (.relatesTo, _): L("Related", ko: "관련")
        case (.conflictsWith, _): L("Conflicts with", ko: "충돌")
        }
    }

    /// The relation's own name, for pickers and legends.
    public static func name(_ relation: Relation) -> String {
        switch relation {
        case .partOf: L("Part of", ko: "하위 작업")
        case .dependsOn: L("Depends on", ko: "선행 필요")
        case .derivedFrom: L("Derived from", ko: "근거")
        case .supersedes: L("Supersedes", ko: "대체")
        case .relatesTo: L("Related", ko: "관련")
        case .conflictsWith: L("Conflicts with", ko: "충돌")
        }
    }

    /// One sentence saying what the relation means, for the link editor.
    public static func explanation(_ relation: Relation) -> String {
        switch relation {
        case .partOf: L("This record is a sub-task or part of the other.", ko: "이 기록이 상대 기록의 하위 작업이거나 일부입니다.")
        case .dependsOn: L("This record cannot be finished before the other is done.", ko: "상대 기록이 끝나야 이 기록을 끝낼 수 있습니다.")
        case .derivedFrom: L("This record was produced from, or justified by, the other.", ko: "이 기록이 상대 기록에서 나왔거나 그것을 근거로 합니다.")
        case .supersedes: L("This record replaces the other.", ko: "이 기록이 상대 기록을 대체합니다.")
        case .relatesTo: L("Both records are about the same topic.", ko: "두 기록이 같은 주제를 다룹니다.")
        case .conflictsWith: L("The two contradict each other or overlap.", ko: "두 기록이 서로 모순되거나 작업이 겹칩니다.")
        }
    }

    public static func color(_ relation: Relation) -> Color {
        switch relation {
        case .partOf: dynamic(light: 0x5B6B82, dark: 0x9AA7BD)
        case .dependsOn: attention
        case .derivedFrom: dynamic(light: 0x0E8F9C, dark: 0x4FD1C5)
        case .supersedes: dynamic(light: 0x6B7280, dark: 0x8A8F98)
        case .relatesTo: dynamic(light: 0x7C838F, dark: 0x7D8491)
        case .conflictsWith: danger
        }
    }

    // MARK: Semantic colors

    /// In progress, waiting, needs a look.
    public static var attention: Color { dynamic(light: 0xB45309, dark: 0xFFA94D) }
    /// Conflicts and destructive actions.
    public static var danger: Color { dynamic(light: 0xC62828, dark: 0xFF6B6B) }

    // MARK: Project scope

    /// Quiet indigo ink for the project scope: the scope name, section headings, record references.
    public static var workspaceInk: Color { dynamic(light: 0x47398B, dark: 0xC9BCFF) }
    /// A cool mist surface for grouped headers. Flat, never a card.
    public static var workspaceSurface: Color { dynamic(light: 0xF3F2F9, dark: 0x252431) }
    /// Monospaced face for `#record` references.
    public static let referenceFont = Font.system(.caption, design: .monospaced)

    // MARK: Metrics

    public static let cornerRadius: CGFloat = 8
    public static let rowSpacing: CGFloat = 10
    public static let panelWidth: CGFloat = 420
    public static let panelHeight: CGFloat = 620

    // MARK: Time

    /// How long ago, in the shortest readable form: "now", "5m", "2h", "3d", "2w", then a date.
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return L("now", ko: "방금")
        case ..<3_600: return L("\(Int(seconds / 60))m", ko: "\(Int(seconds / 60))분")
        case ..<86_400: return L("\(Int(seconds / 3_600))h", ko: "\(Int(seconds / 3_600))시간")
        case ..<(86_400 * 14): return L("\(Int(seconds / 86_400))d", ko: "\(Int(seconds / 86_400))일")
        case ..<(86_400 * 60): return L("\(Int(seconds / (86_400 * 7)))w", ko: "\(Int(seconds / (86_400 * 7)))주")
        default: return day(date, now: now)
        }
    }

    /// A calendar date, with the year only when it is not this year.
    public static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let locale = Locale(identifier: Localization.usesKorean ? "ko_KR" : "en_US")
        let style = sameYear
            ? Date.FormatStyle.dateTime.month(.abbreviated).day()
            : Date.FormatStyle.dateTime.year().month(.abbreviated).day()
        return date.formatted(style.locale(locale))
    }

    /// A date and time for histories and tooltips.
    public static func timestamp(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(Locale(identifier: Localization.usesKorean ? "ko_KR" : "en_US")))
    }

    /// True when a claim is old enough to be treated as abandoned.
    public static func isStale(claimedAt: Date?, now: Date = Date()) -> Bool {
        guard let claimedAt else { return false }
        return now.timeIntervalSince(claimedAt) > Double(Limits.staleClaimHours) * 3_600
    }

    // MARK: Advisories

    public static func text(_ advisory: Advisory) -> String {
        let other = "#\(advisory.other.id) \(advisory.other.title)"
        switch advisory.kind {
        case .pathOverlap:
            let who = advisory.other.assignee ?? L("another session", ko: "다른 세션")
            return L("\(who) is working on \(other), which touches the same files: \(advisory.detail)",
                     ko: "\(Josa.attach(who, "이", "가")) 작업 중인 \(Josa.attach(other, "이", "가")) 같은 파일을 건드립니다: \(advisory.detail)")
        case .unfinishedDependency:
            return L("Waits on \(other), which is not finished.", ko: "\(Josa.attach(other, "이", "가")) 끝나야 진행할 수 있습니다.")
        case .conflict:
            let reason = advisory.detail.isEmpty ? "" : " — \(advisory.detail)"
            return L("Conflicts with \(other)\(reason)", ko: "\(Josa.attach(other, "과", "와")) 충돌합니다\(reason)")
        }
    }

    // MARK: Helpers

    public static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
