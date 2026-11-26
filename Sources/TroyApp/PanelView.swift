import SwiftUI
import TroyCore
import TroyUI

/// What the panel remembers while it is open. Closing the panel clears it.
@Observable
final class PanelState {
    var query = ""
    /// Increases to ask the search field for focus.
    var focusRequest = 0
    var showsAllDecisions = false

    func reset() {
        query = ""
        showsAllDecisions = false
        focusRequest += 1
    }
}

extension EnvironmentValues {
    /// Opens the settings window on a given tab.
    @Entry var openSettingsTab: @MainActor @Sendable (SettingsTab) -> Void = { _ in }
}

/// The panel as the shell shows it: the content plus a hairline edge. The material behind it
/// belongs to the window, so this view stays transparent.
struct PanelRoot: View {
    let model: AppModel
    let state: PanelState
    let actions: AppActions
    let openSettings: @MainActor @Sendable (SettingsTab) -> Void

    var body: some View {
        PanelView(model: model, state: state)
            .id(model.languageRevision)
            .environment(\.appActions, actions)
            .environment(\.openSettingsTab, openSettings)
            .overlay {
                RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

enum PanelMetrics {
    static let cornerRadius: CGFloat = 12
}

struct PanelView: View {
    let model: AppModel
    @Bindable var state: PanelState

    @Environment(\.appActions) private var actions
    @Environment(\.openSettingsTab) private var openSettingsTab
    @FocusState private var searchFocused: Bool
    @State private var hits: [SearchHit] = []
    @State private var hitsQuery = ""
    @State private var highlighted = 0

    private var trimmed: String { state.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmed.isEmpty }
    private var activeProjects: [ProjectSummary] { model.projects.filter { $0.project.status == .active } }

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage { errorBanner(message) }
            headerSurface
            Divider().padding(.top, 10)
            content
            Divider()
            footer
        }
        .task(id: SearchKey(text: trimmed, projectID: model.selectedProjectID)) { await runSearch() }
        .onChange(of: state.focusRequest) { searchFocused = true }
        .onAppear { searchFocused = true }
        .onExitCommand { if isSearching { state.query = "" } else { actions.hidePanel() } }
    }

    // MARK: Header

    private var projectTitle: String {
        if activeProjects.isEmpty { return "Troy" }
        return model.selectedProject?.name ?? L("All projects", ko: "모든 프로젝트")
    }

    /// Project scope and search as one surface; the focus outline belongs to the search row alone.
    private var headerSurface: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6).padding(.horizontal, 10)
            searchField
        }
        .background(Theme.workspaceSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            // Quiet, constant outer stroke: keyboard focus is shown on the search row only.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(activeProjects) { summary in
                    Button {
                        model.selectedProjectID = summary.id
                    } label: {
                        if summary.id == model.selectedProjectID {
                            Label(summary.project.name, systemImage: "checkmark")
                        } else {
                            Text(summary.project.name)
                        }
                    }
                }
                if !activeProjects.isEmpty {
                    Divider()
                    Button {
                        model.selectedProjectID = nil
                    } label: {
                        if model.selectedProjectID == nil {
                            Label(L("All projects", ko: "모든 프로젝트"), systemImage: "checkmark")
                        } else {
                            Text(L("All projects", ko: "모든 프로젝트"))
                        }
                    }
                    Divider()
                }
                Button(L("New project…", ko: "새 프로젝트…")) { startNewProject() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.workspaceInk)
                        .frame(width: 24, height: 24)
                        .background(Theme.workspaceInk.opacity(0.14), in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                        .accessibilityHidden(true)
                    Text(projectTitle)
                        .font(.system(.headline, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(L("Project: \(projectTitle)", ko: "프로젝트: \(projectTitle)"))
            .help(L("Switch project", ko: "프로젝트 전환"))

            Group {
                if !activeProjects.isEmpty {
                    PanelLabelButton(
                        symbol: "point.3.connected.trianglepath.dotted", title: L("Open graph", ko: "그래프 열기"),
                        help: L("Open the project graph in the Troy window", ko: "Troy 창에서 프로젝트 그래프 열기")
                    ) { actions.openProjectGraph() }
                }
                PanelIconButton(symbol: "gearshape", label: L("Settings", ko: "설정")) { openSettingsTab(.general) }
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(searchFocused ? Theme.workspaceInk : .secondary)
                .accessibilityHidden(true)
            TextField(L("Search records", ko: "기록 검색"), text: $state.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(openHighlighted)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
            if state.query.isEmpty {
                Text("⌘K")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                    }
                    .accessibilityHidden(true)
            } else {
                Button { state.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Clear search", ko: "검색어 지우기"))
                .accessibilityLabel(L("Clear search", ko: "검색어 지우기"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            Color.primary.opacity(searchFocused ? 0.05 : 0.03),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            // The one border of the search row: a faint outline at rest, a clear ink outline on focus.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    searchFocused ? Theme.workspaceInk.opacity(0.85) : Color.primary.opacity(0.16),
                    lineWidth: searchFocused ? 1.5 : 0.5)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if isSearching {
            searchResults
        } else if !model.isLoaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if activeProjects.isEmpty {
            noProjects
        } else if model.selectedProjectID == nil {
            projectList
        } else if let overview = model.overview {
            if overview.stats.records == 0 { noRecords } else { overviewList(overview) }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var noProjects: some View {
        EmptyState(
            symbol: "point.3.connected.trianglepath.dotted",
            title: L("No projects yet", ko: "아직 프로젝트가 없습니다"),
            message: L(
                "After connecting, open a project folder in your AI client and ask it to save your first task or decision to Troy. The project then appears here.",
                ko: "연결한 뒤 AI 클라이언트에서 프로젝트 폴더를 열고 첫 할 일이나 결정을 Troy에 저장해 달라고 요청하세요. 그러면 프로젝트가 여기에 나타납니다.")
        ) {
            HStack(spacing: 8) {
                Button(L("Connect an AI client", ko: "AI 클라이언트 연결")) { actions.showConnections() }
                    .buttonStyle(.borderedProminent)
                Button(L("New project", ko: "새 프로젝트")) { startNewProject() }
            }
            .padding(.top, 4)
        }
    }

    private var noRecords: some View {
        EmptyState(
            symbol: "tray",
            title: L("No records yet", ko: "아직 기록이 없습니다"),
            message: L(
                "Decisions, tasks and notes that agents save to this project will show up here.",
                ko: "에이전트가 이 프로젝트에 남기는 결정, 할 일, 메모가 여기에 나타납니다.")
        ) {
            Button(L("New record", ko: "새 기록")) { startNewRecord() }.padding(.top, 4)
        }
    }

    private func overviewList(_ overview: ProjectOverview) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                if !overview.doing.isEmpty {
                    section(L("In progress", ko: "진행 중"), count: overview.doing.count) {
                        ForEach(overview.doing) { record in recordButton(record, subtitle: claimLine(record)) }
                    }
                }
                if !overview.collisions.isEmpty {
                    section(L("Watch out", ko: "주의"), count: overview.collisions.count) {
                        ForEach(Array(overview.collisions.enumerated()), id: \.offset) { _, collision in
                            CollisionCard(collision: collision) { actions.showMainWindow($0) }
                        }
                    }
                }
                if !overview.ready.isEmpty {
                    section(L("Ready", ko: "시작 가능"), count: overview.ready.count) {
                        ForEach(overview.ready) { recordButton($0) }
                    }
                }
                if !overview.blocked.isEmpty {
                    section(L("Blocked", ko: "막힘"), count: overview.blocked.count) {
                        ForEach(overview.blocked, id: \.record.id) { blocked in
                            recordButton(blocked.record, subtitle: waitLine(blocked))
                        }
                    }
                }
                if !overview.decisions.isEmpty {
                    decisionsSection(overview.decisions)
                }
                if !overview.recent.isEmpty {
                    section(L("Recent", ko: "최근"), count: nil) {
                        ForEach(overview.recent) { recordButton($0) }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
        }
    }

    private func decisionsSection(_ decisions: [RecordSummary]) -> some View {
        let limit = 3
        let shown = state.showsAllDecisions ? decisions : Array(decisions.prefix(limit))
        return section(L("Decisions in effect", ko: "적용 중인 결정"), count: decisions.count) {
            ForEach(shown) { recordButton($0) }
            if decisions.count > limit {
                Button {
                    state.showsAllDecisions.toggle()
                } label: {
                    Text(state.showsAllDecisions
                         ? L("Show fewer", ko: "접기")
                         : L("Show all \(decisions.count)", ko: "\(decisions.count)개 모두 보기"))
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                SectionHeading(L("Projects", ko: "프로젝트"), count: activeProjects.count)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                ForEach(activeProjects) { summary in
                    PanelRowButton { model.selectedProjectID = summary.id } content: {
                        ProjectRow(summary: summary)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
        }
    }

    // MARK: Search

    private struct SearchKey: Equatable {
        var text: String
        var projectID: Int64?
    }

    private func runSearch() async {
        let text = trimmed
        guard !text.isEmpty else {
            hits = []
            hitsQuery = ""
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let found = await model.search(text, projectID: model.selectedProjectID, limit: 20)
        guard !Task.isCancelled else { return }
        hits = found
        hitsQuery = text
        highlighted = 0
    }

    @ViewBuilder private var searchResults: some View {
        if hitsQuery != trimmed {
            Color.clear.frame(maxHeight: .infinity)
        } else if hits.isEmpty {
            EmptyState(
                symbol: "magnifyingglass",
                title: L("No matches", ko: "검색 결과가 없습니다"),
                message: L("Nothing matches “\(trimmed)”. Try fewer or shorter words.", ko: "\(Josa.attach("“\(trimmed)”", "과", "와")) 일치하는 기록이 없습니다. 더 짧은 단어로 검색해 보세요."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            PanelRowButton(highlighted: index == highlighted) {
                                actions.showMainWindow(hit.record.id)
                            } content: {
                                RecordRow(
                                    hit.record,
                                    projectName: model.selectedProjectID == nil ? projectName(hit.record.projectID) : nil,
                                    subtitle: hit.snippet.isEmpty ? nil : hit.snippet)
                            }
                            .id(hit.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 10)
                }
                .onChange(of: highlighted) {
                    if hits.indices.contains(highlighted) { proxy.scrollTo(hits[highlighted].id) }
                }
            }
        }
    }

    /// True when the results on hand answer what is typed now, not an earlier query still being replaced.
    private var hitsAreCurrent: Bool { hitsQuery == trimmed }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard isSearching, hitsAreCurrent, !hits.isEmpty else { return .ignored }
        highlighted = min(max(highlighted + delta, 0), hits.count - 1)
        return .handled
    }

    private func openHighlighted() {
        // Return pressed before the new results arrive must not open a record found for the old query.
        guard isSearching, hitsAreCurrent, hits.indices.contains(highlighted) else { return }
        actions.showMainWindow(hits[highlighted].record.id)
    }

    private func projectName(_ id: Int64) -> String? {
        model.projects.first { $0.id == id }?.project.name
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button {
                startNewRecord()
            } label: {
                Label {
                    Text(L("New record", ko: "새 기록"))
                } icon: {
                    Image(systemName: "plus").foregroundStyle(Theme.workspaceInk)
                }
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(activeProjects.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var footerText: String {
        let stats: [ProjectStats]
        if let selected = model.selectedProjectID {
            stats = model.projects.filter { $0.id == selected }.map(\.stats)
        } else {
            stats = activeProjects.map(\.stats)
        }
        let records = stats.reduce(0) { $0 + $1.records }
        let doing = stats.reduce(0) { $0 + $1.doing }
        let recordsText = L(records == 1 ? "1 record" : "\(records) records", ko: "기록 \(records)개")
        guard doing > 0 else { return recordsText }
        return recordsText + " · " + L("\(doing) in progress", ko: "진행 중 \(doing)개")
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, count: Int?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeading(title, count: count)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
            content()
        }
    }

    /// The panel lists many records, so its rows are one line shorter than `RecordRow`: no body preview.
    private func recordButton(_ record: RecordSummary, subtitle: String? = nil) -> some View {
        PanelRowButton { actions.showMainWindow(record.id) } content: {
            CompactRecordRow(record: record, subtitle: subtitle)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { model.errorMessage = nil } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Dismiss", ko: "닫기"))
            .accessibilityLabel(L("Dismiss", ko: "닫기"))
        }
        .padding(10)
        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private func startNewRecord() {
        model.intent = .newRecord
        actions.showMainWindow(nil)
    }

    private func startNewProject() {
        model.intent = .newProject
        actions.showMainWindow(nil)
    }

    // MARK: Text

    private func claimLine(_ record: RecordSummary) -> String? {
        guard let claimedAt = record.claimedAt else { return nil }
        let seconds = Date().timeIntervalSince(claimedAt)
        let since: String
        if seconds < 60 {
            since = L("just now", ko: "방금")
        } else if seconds > 86_400 * 60 {
            since = Theme.day(claimedAt)
        } else {
            since = L("\(Theme.age(claimedAt)) ago", ko: "\(Theme.age(claimedAt)) 전")
        }
        if Theme.isStale(claimedAt: claimedAt) {
            return L("Stale: started \(since), may be abandoned", ko: "멈춘 듯함: \(since)에 시작")
        }
        return L("Started \(since)", ko: "\(since) 시작")
    }

    private func waitLine(_ blocked: BlockedRecord) -> String {
        let names = blocked.waitingOn.prefix(2).map { "#\($0.id) \($0.title)" }.joined(separator: ", ")
        let extra = blocked.waitingOn.count - 2
        let list = extra > 0 ? names + " +\(extra)" : names
        return L("Waits on \(list)", ko: "선행 작업: \(list)")
    }
}

// MARK: - Rows

/// A full-width row button with a hover and keyboard highlight.
private struct PanelRowButton<Content: View>: View {
    var highlighted = false
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(highlighted ? Theme.workspaceInk.opacity(0.16) : Color.primary.opacity(hovering ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

/// `RecordRow` without the preview line, built from the same pieces, so about ten records fit in the panel.
/// `RecordRow` always draws a preview line, even for an empty subtitle.
private struct CompactRecordRow: View {
    let record: RecordSummary
    var subtitle: String?

    private var isQuiet: Bool { record.status.isFinished || record.isSuperseded }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.rowSpacing) {
            KindIcon(record.kind)
                .opacity(isQuiet ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(record.title)
                        .fontWeight(isQuiet ? .regular : .medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .strikethrough(record.status == .dropped)
                        .foregroundStyle(isQuiet ? .secondary : .primary)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    Text(Theme.age(record.updatedAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .fixedSize()
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                meta
            }
        }
        .padding(.vertical, 4)
        .help(record.title)
    }

    /// Tags are the least important part of the line: when they do not fit they are dropped one by one
    /// rather than clipping the ID, status or assignee.
    private var meta: some View {
        ViewThatFits(in: .horizontal) {
            metaLine(tags: 2)
            metaLine(tags: 1)
            metaLine(tags: 0)
        }
    }

    private func metaLine(tags count: Int) -> some View {
        let showsStatus = record.kind == .task || record.status != .open || record.isSuperseded
        return HStack(spacing: 8) {
            Text("#\(record.id)")
                .font(Theme.referenceFont)
                .foregroundStyle(.secondary)
                .fixedSize()
            if showsStatus { StatusBadge(record.status, isSuperseded: record.isSuperseded) }
            if record.status == .doing, let assignee = record.assignee {
                Text(assignee)
                    .font(.caption)
                    .foregroundStyle(Theme.isStale(claimedAt: record.claimedAt) ? Color.secondary : Theme.attention)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            ForEach(record.tags.prefix(count), id: \.self) { TagChip($0) }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

private struct ProjectRow: View {
    let summary: ProjectSummary

    var body: some View {
        HStack(alignment: .top, spacing: Theme.rowSpacing) {
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .fill(Theme.workspaceInk.opacity(0.14))
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.workspaceInk)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(summary.project.name).lineLimit(1)
                    Spacer(minLength: 4)
                    if let last = summary.stats.lastActivity {
                        Text(Theme.age(last)).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                if !summary.project.summary.isEmpty {
                    Text(summary.project.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(L(summary.stats.records == 1 ? "1 record" : "\(summary.stats.records) records", ko: "기록 \(summary.stats.records)개"))
                        .foregroundStyle(.secondary)
                    if summary.stats.doing > 0 {
                        Label(L("\(summary.stats.doing) in progress", ko: "진행 중 \(summary.stats.doing)개"), systemImage: "circle.lefthalf.filled")
                            .foregroundStyle(Theme.attention)
                    }
                    if summary.stats.openTasks > 0 {
                        Text(L("\(summary.stats.openTasks) open", ko: "대기 \(summary.stats.openTasks)개"))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CollisionCard: View {
    let collision: Collision
    let open: (Int64) -> Void

    private var isConflict: Bool { collision.kind == .conflict }
    private var tint: Color { isConflict ? Theme.danger : Theme.attention }
    private var title: String {
        switch collision.kind {
        case .conflict: L("Conflict", ko: "충돌")
        case .pathOverlap: L("Same files", ko: "같은 파일 작업 중")
        case .unfinishedDependency: L("Waiting", ko: "선행 작업 대기")
        }
    }

    private var symbol: String {
        switch collision.kind {
        case .conflict: "exclamationmark.triangle.fill"
        case .pathOverlap: "doc.on.doc.fill"
        case .unfinishedDependency: "hourglass"
        }
    }

    /// What actually collides: the shared paths, or the note on the conflict link.
    private var reason: String? {
        let detail = collision.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        switch collision.kind {
        case .pathOverlap:
            return detail.isEmpty ? nil : L("Both change \(detail)", ko: "둘 다 수정: \(detail)")
        case .conflict:
            return detail.isEmpty ? L("Linked as conflicting", ko: "충돌로 연결됨") : detail
        case .unfinishedDependency:
            return detail.isEmpty ? nil : detail
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                CollisionLine(record: collision.first, open: open)
                CollisionLine(record: collision.second, open: open)
                if let reason {
                    Text(reason)
                        .font(isConflict ? .caption : Theme.referenceFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
    }
}

/// One side of a collision: opens its record, with a hover highlight like the list rows.
private struct CollisionLine: View {
    let record: RecordSummary
    let open: (Int64) -> Void
    @State private var hovering = false

    var body: some View {
        Button { open(record.id) } label: {
            HStack(spacing: 6) {
                KindIcon(record.kind, size: 16)
                Text("#\(record.id)")
                    .font(Theme.referenceFont)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(record.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if let assignee = record.assignee {
                    Text(assignee)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(Color.primary.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -4)
        .help(record.title)
    }
}

/// Icon plus word, so the one action that leads out of the panel is legible without hovering.
private struct PanelLabelButton: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.workspaceInk)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.workspaceInk.opacity(hovering ? 0.2 : 0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(title)
    }
}

private struct PanelIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
