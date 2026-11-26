import SwiftUI
import TroyCore
import TroyUI

/// The middle column: an optional error banner, the toolbar, then the list, the graph or an empty state.
struct ContentColumn: View {
    @Bindable var model: AppModel
    @Environment(\.appActions) private var appActions
    @Environment(BrowserUI.self) private var ui

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.errorMessage = nil }
            }
            ContentHeader(model: model)
            Divider()
            content
        }
        .confirmationDialog(
            L("Delete this record?", ko: "이 기록을 삭제할까요?"),
            isPresented: Binding(get: { ui.recordToDelete != nil }, set: { if !$0 { ui.recordToDelete = nil } }),
            titleVisibility: .visible, presenting: ui.recordToDelete
        ) { record in
            Button(L("Delete", ko: "삭제"), role: .destructive) {
                Task { await model.deleteRecord(record.id) }
            }
            Button(L("Cancel", ko: "취소"), role: .cancel) {}
        } message: { record in
            Text(L(
                "“\(record.title)” (#\(record.id)) will be permanently deleted with its \(record.linkCount) links and its history. The records it links to are kept. This cannot be undone.",
                ko: "“\(record.title)” (#\(record.id)) 기록이 연결 \(record.linkCount)개와 변경 이력까지 영구 삭제됩니다. 연결돼 있던 다른 기록은 그대로 남습니다. 되돌릴 수 없습니다."))
        }
    }

    @ViewBuilder private var content: some View {
        if !model.isLoaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.projects.isEmpty {
            EmptyState(
                symbol: "tray",
                title: L("No projects yet", ko: "아직 프로젝트가 없습니다"),
                message: L(
                    "Your AI agents create projects and save records here once an AI client is connected to Troy. You can also start a project yourself.",
                    ko: "AI 클라이언트를 Troy에 연결하면 에이전트가 프로젝트를 만들고 기록을 남깁니다. 직접 프로젝트를 만들어 시작할 수도 있습니다.")
            ) {
                HStack {
                    Button(L("Connect an AI client", ko: "AI 클라이언트 연결")) { appActions.showConnections() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button(L("New project", ko: "새 프로젝트")) { ui.newProject() }
                }
                .padding(.top, 4)
            }
        } else {
            switch model.browserMode {
            case .overview: ProjectBriefView(model: model)
            case .graph: GraphScreen(model: model)
            case .list: RecordListView(model: model)
            }
        }
    }
}

/// A dismissible failure message.
struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(L("Dismiss", ko: "닫기"))
                .accessibilityLabel(L("Dismiss", ko: "닫기"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.danger.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// View switcher, status scope, filters, search and the New Record button.
struct ContentHeader: View {
    @Bindable var model: AppModel
    @Environment(BrowserUI.self) private var ui
    @FocusState private var searchFocused: Bool

    private var inList: Bool { model.browserMode == .list }

    var body: some View {
        VStack(spacing: 8) {
            topBar
            if inList {
                HStack(spacing: 8) {
                    scopeTitle
                        .layoutPriority(-1)
                    Spacer(minLength: 4)
                    Picker(L("Status", ko: "상태"), selection: $model.filter.scope) {
                        ForEach(StatusScope.allCases, id: \.self) { Text(Self.name($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .help(L("Which records to list", ko: "목록에 보일 기록"))

                    filterMenu
                }
                searchField
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.workspaceSurface)
        .background(shortcuts)
        .onChange(of: ui.searchFocusTick) { if inList { searchFocused = true } }
    }

    /// One row when it fits: switcher, the graph's scope, then the actions. Narrower, the actions
    /// lose their names; narrower still, the switcher gets its own row above them.
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            if model.browserMode == .graph { bar(showsScope: true, iconsOnly: false) }
            bar(showsScope: false, iconsOnly: false)
            bar(showsScope: false, iconsOnly: true)
            VStack(spacing: 6) {
                viewSwitcher(fixedWidth: false)
                HStack(spacing: 8) {
                    Spacer(minLength: 4)
                    UsageHelpButton()
                    newRecordButton(iconOnly: false)
                }
            }
        }
    }

    private func bar(showsScope: Bool, iconsOnly: Bool) -> some View {
        HStack(spacing: 8) {
            viewSwitcher(fixedWidth: true)
            if showsScope { scopeTitle.layoutPriority(-1) }
            Spacer(minLength: 4)
            if iconsOnly {
                UsageHelpButton().labelStyle(.iconOnly)
            } else {
                UsageHelpButton()
            }
            newRecordButton(iconOnly: iconsOnly)
        }
    }

    private func viewSwitcher(fixedWidth: Bool) -> some View {
        Picker(L("View", ko: "보기"), selection: $model.browserMode) {
            Text(L("Overview", ko: "작업 개요")).tag(BrowserMode.overview)
            Text(L("List", ko: "목록")).tag(BrowserMode.list)
            Text(L("Graph", ko: "그래프")).tag(BrowserMode.graph)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: fixedWidth ? 210 : nil)
        .frame(maxWidth: fixedWidth ? nil : .infinity)
        .help(L("Overview (⌘3), list (⌘1) or graph (⌘2)", ko: "작업 개요 (⌘3), 목록 (⌘1), 그래프 (⌘2)"))
        .accessibilityLabel(L("View", ko: "보기"))
    }

    static func name(_ scope: StatusScope) -> String {
        switch scope {
        case .active: L("Active", ko: "활성")
        case .all: L("All", ko: "전체")
        case .finished: L("Finished", ko: "끝난 기록")
        }
    }

    private var filtersActive: Bool {
        !model.filter.hideSuperseded || !model.filter.kinds.isEmpty || model.filter.tag != nil
    }

    private var filterMenu: some View {
        Menu {
            Toggle(L("Hide superseded", ko: "대체된 기록 숨기기"), isOn: $model.filter.hideSuperseded)
            if !model.filter.kinds.isEmpty || model.filter.tag != nil {
                Divider()
                Button(L("Clear kind and tag filters", ko: "종류·태그 필터 해제")) {
                    model.filter.kinds = []
                    model.filter.tag = nil
                }
            }
        } label: {
            Image(systemName: filtersActive
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Filters", ko: "필터"))
        .accessibilityLabel(L("Filters", ko: "필터"))
    }

    /// The project in view, or all of them. Names only what is selected; no counts.
    private var scopeTitle: some View {
        let name = model.selectedProject?.name ?? L("All projects", ko: "모든 프로젝트")
        let symbol = model.selectedProject == nil ? "point.3.connected.trianglepath.dotted" : "folder"
        return Label {
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: symbol)
                .font(.subheadline)
        }
        .foregroundStyle(Theme.workspaceInk)
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func newRecordButton(iconOnly: Bool) -> some View {
        Button { ui.newRecord() } label: {
            if iconOnly {
                Label(L("New record", ko: "새 기록"), systemImage: "plus").labelStyle(.iconOnly)
            } else {
                Label(L("New record", ko: "새 기록"), systemImage: "plus").lineLimit(1).fixedSize()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .keyboardShortcut("n", modifiers: .command)
        .help(L("New record (⌘N)", ko: "새 기록 (⌘N)"))
        .accessibilityLabel(L("New record", ko: "새 기록"))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Search records", ko: "기록 검색"), text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                // ⌘F from the overview or the graph: this field was just built; focus it once it is in place.
                .task {
                    guard ui.wantsSearchFocus else { return }
                    ui.wantsSearchFocus = false
                    await Task.yield()
                    if !Task.isCancelled { searchFocused = true }
                }
                .onExitCommand {
                    model.searchText = ""
                    searchFocused = false
                }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L("Clear search", ko: "검색어 지우기"))
                .accessibilityLabel(L("Clear search", ko: "검색어 지우기"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            if searchFocused {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.workspaceInk.opacity(0.6), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .help(L("Search (⌘F)", ko: "검색 (⌘F)"))
    }

    /// The overview has no search, so ⌘F goes to the list; the new list's header takes the focus.
    private func find() {
        if model.browserMode == .overview {
            ui.wantsSearchFocus = true
            model.browserMode = .list
        } else {
            ui.searchFocusTick += 1
        }
    }

    /// Invisible buttons that carry the window's keyboard shortcuts.
    private var shortcuts: some View {
        Group {
            Button("") { model.browserMode = .list }.keyboardShortcut("1", modifiers: .command)
            Button("") { model.browserMode = .graph }.keyboardShortcut("2", modifiers: .command)
            Button("") { model.browserMode = .overview }.keyboardShortcut("3", modifiers: .command)
            Button("") { find() }.keyboardShortcut("f", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
