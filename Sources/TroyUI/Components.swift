import SwiftUI
import TroyCore

// Small views shared by the panel, the main window and settings. A record must look the
// same wherever it appears, so every list uses `RecordRow` and every badge comes from here.

/// The colored tile that says what kind a record is.
public struct KindIcon: View {
    private let kind: RecordKind
    private let size: CGFloat

    public init(_ kind: RecordKind, size: CGFloat = 24) {
        self.kind = kind
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.color(kind).opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: Theme.symbol(kind))
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Theme.color(kind))
            }
            .accessibilityLabel(Theme.name(kind))
    }
}

/// Status as a symbol and a word. A superseded record shows that instead of its status.
public struct StatusBadge: View {
    private let status: RecordStatus
    private let isSuperseded: Bool
    private let showsName: Bool

    public init(_ status: RecordStatus, isSuperseded: Bool = false, showsName: Bool = true) {
        self.status = status
        self.isSuperseded = isSuperseded
        self.showsName = showsName
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isSuperseded ? "arrow.uturn.backward.circle" : Theme.symbol(status))
            if showsName { Text(isSuperseded ? Theme.supersededName : Theme.name(status)) }
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(isSuperseded ? Color.secondary : Theme.color(status))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSuperseded ? Theme.supersededName : Theme.name(status))
    }
}

public struct TagChip: View {
    private let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// One record in a list: kind, title, and a line of what matters about it right now.
public struct RecordRow: View {
    private let record: RecordSummary
    private let projectName: String?
    private let subtitle: String?

    /// - Parameters:
    ///   - projectName: shown when the list mixes projects.
    ///   - subtitle: replaces the preview line, for example a search snippet or "waits on #12".
    ///     An empty string shows no second line at all.
    public init(_ record: RecordSummary, projectName: String? = nil, subtitle: String? = nil) {
        self.record = record
        self.projectName = projectName
        self.subtitle = subtitle
    }

    private var isQuiet: Bool { record.status.isFinished || record.isSuperseded }

    public var body: some View {
        HStack(alignment: .top, spacing: Theme.rowSpacing) {
            KindIcon(record.kind)
                .opacity(isQuiet ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(record.title)
                        .font(.body.weight(isQuiet ? .regular : .semibold))
                        .lineLimit(2)
                        .strikethrough(record.status == .dropped)
                        .foregroundStyle(isQuiet ? .secondary : .primary)
                    Spacer(minLength: 4)
                    Text(Theme.age(record.updatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                        .help(Theme.timestamp(record.updatedAt))
                }
                if let line = subtitle ?? (record.preview.isEmpty ? nil : record.preview), !line.isEmpty {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(isQuiet ? .tertiary : .secondary)
                        .lineLimit(1)
                }
                meta
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var showsStatus: Bool { record.kind == .task || record.status != .open || record.isSuperseded }

    /// The reference, state and links. Always shown, because the id is how records are cited.
    private var meta: some View {
        HStack(spacing: 8) {
            Text("#\(record.id)")
                .font(Theme.referenceFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            if showsStatus { StatusBadge(record.status, isSuperseded: record.isSuperseded) }
            if record.status == .doing, let assignee = record.assignee {
                Text(assignee)
                    .font(.caption)
                    .foregroundStyle(Theme.isStale(claimedAt: record.claimedAt) ? Color.secondary : Theme.attention)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            if let projectName {
                Label(projectName, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-2)
                    .help(projectName)
            }
            if record.linkCount > 0 {
                Label("\(record.linkCount)", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityLabel(L("\(record.linkCount) links", ko: "연결 \(record.linkCount)개"))
            }
            tagSummary
            Spacer(minLength: 0)
        }
    }

    /// One whole tag plus a count, or nothing when the row is too narrow; never a clipped chip.
    @ViewBuilder private var tagSummary: some View {
        if let first = record.tags.first {
            let rest = record.tags.count - 1
            let all = record.tags.joined(separator: ", ")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    TagChip(first)
                    if rest > 0 {
                        Text("+\(rest)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .fixedSize()
                Label("\(record.tags.count)", systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            .layoutPriority(-3)
            .help(all)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Tags: \(all)", ko: "태그: \(all)"))
        }
    }
}

/// One advisory as a warning line.
public struct AdvisoryRow: View {
    private let advisory: Advisory

    public init(_ advisory: Advisory) { self.advisory = advisory }

    public var body: some View {
        Label {
            Text(Theme.text(advisory))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: advisory.kind == .unfinishedDependency ? "hourglass" : "exclamationmark.triangle.fill")
                .foregroundStyle(advisory.kind == .conflict ? Theme.danger : Theme.attention)
        }
    }
}

/// A small uppercase heading with an optional count, for sections inside a scrolling pane.
public struct SectionHeading: View {
    private let title: String
    private let count: Int?

    public init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.workspaceInk)
                .lineLimit(1)
                .truncationMode(.tail)
            if let count {
                Text("\(count)")
                    .font(Theme.referenceFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// What to show when a list or pane has nothing in it.
public struct EmptyState<Actions: View>: View {
    private let symbol: String
    private let title: String
    private let message: String
    private let actions: Actions

    public init(symbol: String, title: String, message: String, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(24)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    public init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// Things the views ask the app shell to do. The shell fills these in; views read them from the environment.
nonisolated public struct AppActions: Sendable {
    /// Brings the main window forward. A record id also selects that record.
    public var showMainWindow: @MainActor @Sendable (_ recordID: Int64?) -> Void = { _ in }
    /// Brings the main window forward in graph mode for the current project, whatever mode it was in.
    public var openProjectGraph: @MainActor @Sendable () -> Void = {}
    public var showSettings: @MainActor @Sendable () -> Void = {}
    public var hidePanel: @MainActor @Sendable () -> Void = {}
    public var quit: @MainActor @Sendable () -> Void = {}
    public var showConnections: @MainActor @Sendable () -> Void = {}
    public var openGuide: @MainActor @Sendable () -> Void = {}

    public init() {}
}

extension EnvironmentValues {
    @Entry public var appActions = AppActions()
}
