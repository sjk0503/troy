import SwiftUI
import TroyCore
import TroyGraph
import TroyUI

/// Pure black: the toolbar, the loading and empty surfaces, and the canvas behind the points all
/// share it, so the records read as points on one continuous black screen.
private let graphBackground = Color.black

/// A quiet neutral charcoal tint for the thin boundary under the header bars.
private let graphBoundary = Color(white: 0.16)

/// The graph of the selected project: records as nodes, links as lines you can tell apart by style.
/// A native toolbar above the canvas finds a record or explains the legend, each in a transient popover.
struct GraphScreen: View {
    @Bindable var model: AppModel
    @Environment(BrowserUI.self) private var ui
    /// The window's real scheme. The graph forces dark, but popovers keep the system look.
    @Environment(\.colorScheme) private var systemScheme
    @State private var saved: [Int64: CGPoint] = [:]
    @State private var showsFind = false
    @State private var showsLegend = false
    @State private var revealRequest = 0
    @State private var toolbarWidth: CGFloat = 1000
    /// Records visited through the local map, oldest first, for the back button.
    @State private var history: [RecordSummary] = []
    @State private var lastLoaded: RecordSummary?
    @State private var isGoingBack = false
    /// The lookup behind a Back press; only one runs at a time.
    @State private var backTask: Task<Void, Never>?
    /// A ⌘F pressed in the local map, waiting for the whole map to be shown and loaded.
    @State private var pendingFind = false

    private struct FindReadiness: Equatable {
        var pending: Bool
        var local: Bool
        var loaded: Bool
    }

    private var filtersActive: Bool {
        !model.filter.kinds.isEmpty || model.filter.tag != nil || ui.graphHidesFinished
            || !ui.graphHiddenRelations.isEmpty
    }

    /// The local map is shown only while a record is selected; otherwise the whole graph is.
    private var showsLocal: Bool { ui.showsLocalGraph && model.selectedRecordID != nil }

    /// The selected record's detail once it has loaded (not the previous record's).
    private var loadedDetail: RecordDetail? {
        guard let id = model.selectedRecordID, let detail = model.detail, detail.record.id == id else { return nil }
        return detail
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsLocal { localContent } else { globalContent }
        }
        .background(graphBackground, ignoresSafeAreaEdges: [])
        .clipped()
        .environment(\.colorScheme, .dark)
        .onChange(of: model.selectedProjectID, initial: true) {
            saved = model.layoutCache.load(projectID: model.selectedProjectID)
            showsFind = false
            showsLegend = false
            pendingFind = false
        }
        .onChange(of: ui.searchFocusTick) {
            // From the local map, return to the whole map first; the finder opens once that is shown and loaded.
            pendingFind = true
            if ui.showsLocalGraph { ui.showsLocalGraph = false }
        }
        .onChange(of: FindReadiness(pending: pendingFind, local: showsLocal, loaded: model.isGraphLoaded), initial: true) {
            guard pendingFind, !showsLocal, model.isGraphLoaded else { return }
            pendingFind = false
            // Everything filtered out: the whole map's empty state (with its filter reset) is shown instead.
            guard !visibleRecords().isEmpty else { return }
            showsLegend = false
            showsFind = true
        }
        .onDisappear {
            pendingFind = false
            backTask?.cancel()
            backTask = nil
        }
        .onChange(of: model.selectedRecordID, initial: true) { old, new in
            // The callback can arrive after a newer selection. Judge by the current selection, and only
            // leave the local map on a real deselection (a record was selected before), never on the initial call.
            if new == nil {
                if old != nil, model.selectedRecordID == nil, ui.showsLocalGraph { ui.showsLocalGraph = false }
                history = []
                lastLoaded = nil
                isGoingBack = false
                return
            }
            if showsLocal, !isGoingBack, let old, old != new, let previous = lastLoaded, previous.id == old {
                history.append(previous)
                if history.count > 30 { history.removeFirst() }
            }
            isGoingBack = false
        }
        .onChange(of: loadedDetail?.record.summary, initial: true) {
            if let summary = loadedDetail?.record.summary { lastLoaded = summary }
        }
        .onChange(of: showsLocal) {
            if !showsLocal { history = []; isGoingBack = false; backTask?.cancel() }
        }
    }

    // MARK: Local

    @ViewBuilder private var localContent: some View {
        let detail = loadedDetail
        localToolbar(detail)
        ZStack {
            if let detail {
                LocalGraphView(
                    detail: detail, projectName: { ui.projectName($0) },
                    onOpen: { ui.open($0) },
                    onAddLink: { ui.addLink(to: detail.record.summary) })
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func goBack() {
        guard backTask == nil, !history.isEmpty, let originID = model.selectedRecordID else { return }
        let originProject = model.selectedProjectID
        backTask = Task { @MainActor in
            defer { backTask = nil }
            var remaining = history
            while let candidate = remaining.popLast() {
                // Read the record fresh: it may have been deleted, or moved to another project, since it was visited.
                let fresh = await model.record(candidate.id)
                // The user may have left the map or picked another record while the lookup ran.
                guard !Task.isCancelled, model.browserMode == .graph, showsLocal, model.selectedRecordID == originID,
                      model.selectedProjectID == originProject else { return }
                guard let fresh, fresh.id != originID else { continue }
                history = remaining
                isGoingBack = true
                ui.open(fresh.summary)
                return
            }
            history = []
        }
    }

    private func localToolbar(_ detail: RecordDetail?) -> some View {
        // Four labeled controls plus the switch need more room than the global toolbar's three.
        let compact = toolbarWidth < 560
        let counts = detail.map { LocalGraph.counts($0) }
        var text = ""
        if let counts {
            text = L("\(counts.links) links · \(counts.records) records", ko: "연결 \(counts.links)개 · 기록 \(counts.records)개")
            if counts.otherProjectRecords > 0 {
                text += L(" · \(counts.otherProjectRecords) records in other projects",
                          ko: " · 다른 프로젝트의 기록 \(counts.otherProjectRecords)개")
            }
        }
        let scope = L("Every link of this record, across projects. Graph filters and the record limit do not apply.",
                      ko: "이 기록의 모든 연결을 프로젝트와 관계없이 표시합니다. 그래프 필터와 표시 한도는 적용되지 않습니다.")
        return HStack(spacing: 8) {
            scopeSwitch(compact: compact)
            Button(action: goBack) {
                ToolbarLabel(title: L("Back", ko: "뒤로"), symbol: "chevron.backward", compact: compact)
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(history.isEmpty || backTask != nil)
            .help(history.last.map { L("Back to \($0.title) (⌘[)", ko: "\($0.title)(으)로 돌아가기 (⌘[)") }
                  ?? L("No earlier record in this map", ko: "이 지도에서 이전에 본 기록이 없습니다"))
            Button { if let detail { ui.addLink(to: detail.record.summary) } } label: {
                ToolbarLabel(title: L("Add link", ko: "연결 추가"), symbol: "link.badge.plus", compact: compact)
            }
            .disabled(detail == nil)
            .help(L("Link this record to another", ko: "이 기록을 다른 기록과 연결"))
            Toggle(isOn: Binding(get: { ui.showsLocalInspector }, set: { ui.showsLocalInspector = $0 })) {
                ToolbarLabel(title: L("Record details", ko: "기록 상세"), symbol: "sidebar.right", compact: compact)
            }
            .toggleStyle(.button)
            .disabled(detail == nil)
            .help(ui.showsLocalInspector
                  ? L("Hide record details", ko: "기록 상세 숨기기")
                  : L("Show record details beside the map", ko: "지도 옆에 기록 상세 보기"))
            .accessibilityAddTraits(ui.showsLocalInspector ? .isSelected : [])
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                Text(text).fixedSize(horizontal: true, vertical: false)
                Color.clear.frame(width: 0, height: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .help(scope)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(graphBackground, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Rectangle().fill(graphBoundary).frame(height: 1) }
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.width, initial: true) { toolbarWidth = proxy.size.width }
        })
    }

    /// Whole graph or the selected record's links. Visible in both; the local side needs a selection.
    private func scopeSwitch(compact: Bool) -> some View {
        let local = showsLocal
        return HStack(spacing: 0) {
            scopeButton(L("Whole graph", ko: "전체 그래프"), symbol: "point.3.connected.trianglepath.dotted",
                        isOn: !local, enabled: true, compact: compact) { ui.showsLocalGraph = false }
            scopeButton(L("Local graph", ko: "로컬 그래프"), symbol: "scope",
                        isOn: local, enabled: model.selectedRecordID != nil, compact: compact) { ui.showsLocalGraph = true }
        }
        .padding(2)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Graph view", ko: "그래프 보기"))
    }

    private func scopeButton(_ title: String, symbol: String, isOn: Bool, enabled: Bool, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ToolbarLabel(title: title, symbol: symbol, compact: compact)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .background(isOn ? Color(white: 0.28) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(enabled ? title : L("Select a record to see its links", ko: "기록을 선택하면 연결을 볼 수 있습니다"))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: Global

    @ViewBuilder private var globalContent: some View {
        let records = visibleRecords()
        let nodes = makeNodes(records)
        let ids = Set(records.map(\.id))
        let edges = visibleEdges(among: ids)
        // Links between the visible records, per relation, counted before any relation is hidden.
        let relationCounts = Dictionary(
            grouping: model.graph.links.filter { ids.contains($0.sourceID) && ids.contains($0.targetID) },
            by: \.relation
        ).mapValues(\.count)
        let hiddenSelection: Int64? = {
            guard model.isGraphLoaded, let id = model.selectedRecordID,
                  model.graph.records.contains(where: { $0.id == id }), !ids.contains(id) else { return nil }
            return id
        }()
        VStack(spacing: 0) {
            toolbar(records: records, linkCount: edges.count, relationCounts: relationCounts)
            if let hiddenSelection {
                hiddenSelectionBar(hiddenSelection)
            }
            ZStack(alignment: .topLeading) {
                if !model.isGraphLoaded {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if nodes.isEmpty {
                    empty
                } else {
                    GraphCanvas(
                        nodes: nodes, edges: edges, selection: $model.selectedRecordID, savedPositions: saved,
                        labels: .init(
                            graph: L("Graph", ko: "그래프"), zoomIn: L("Zoom in", ko: "확대"),
                            zoomOut: L("Zoom out", ko: "축소"), fit: L("Fit to view", ko: "전체 보기")),
                        revealRequest: revealRequest,
                        onOpen: { ui.edit(recordID: $0) },
                        onPositionsSettled: { positions in
                            let known = Set(model.graph.records.map(\.id))
                            let kept = positions.filter { known.contains($0.key) }
                            guard !kept.isEmpty else { return }
                            model.layoutCache.save(kept, projectID: model.selectedProjectID)
                        })
                }
                if model.graph.truncated {
                    truncatedNote
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(10)
                }
            }
        }
    }

    // MARK: Data

    private func visibleRecords() -> [RecordSummary] {
        let filter = model.filter
        return model.graph.records.filter { record in
            if !filter.kinds.isEmpty, !filter.kinds.contains(record.kind) { return false }
            if let tag = filter.tag, !record.tags.contains(tag) { return false }
            if ui.graphHidesFinished, record.status.isFinished { return false }
            return true
        }
    }

    private func makeNodes(_ records: [RecordSummary]) -> [GraphNode] {
        let allProjects = model.selectedProjectID == nil
        return records.map { record in
            GraphNode(
                id: record.id, title: record.title, color: Paint.kinds[record.kind] ?? .gray,
                symbol: Theme.symbol(record.kind), weight: Double(record.linkCount),
                isDimmed: record.status.isFinished || record.isSuperseded, isRinged: record.status == .doing,
                group: allProjects ? Int(truncatingIfNeeded: record.projectID) : nil)
        }
    }

    private func visibleEdges(among ids: Set<Int64>) -> [GraphEdge] {
        model.graph.links.compactMap { link in
            guard !ui.graphHiddenRelations.contains(link.relation),
                  ids.contains(link.sourceID), ids.contains(link.targetID) else { return nil }
            let style = RelationStyle.of(link.relation)
            return GraphEdge(
                id: link.id, source: link.sourceID, target: link.targetID,
                color: Paint.relations[link.relation] ?? .gray, stroke: style.stroke, width: style.width,
                hasArrow: style.hasArrow, label: Theme.name(link.relation), strength: style.strength)
        }
    }

    private func resetFilters() {
        model.filter.kinds = []
        model.filter.tag = nil
        ui.graphHidesFinished = false
        ui.graphHiddenRelations = []
    }

    // MARK: Pieces

    private func hiddenSelectionBar(_ id: Int64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash").accessibilityHidden(true)
            Text(L("Selected record #\(id) is hidden by the current filters.",
                   ko: "선택한 기록 #\(id)은 현재 필터에서 숨겨져 있습니다."))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(L("Reset filters", ko: "필터 초기화")) { resetFilters() }
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.14))
        .overlay(alignment: .bottom) { Rectangle().fill(graphBoundary).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    private func toolbar(records: [RecordSummary], linkCount: Int, relationCounts: [Relation: Int]) -> some View {
        let counts = L("\(records.count) records · \(linkCount) links",
                       ko: "기록 \(records.count)개 · 연결 \(linkCount)개")
        let hint = L("Select a point to read the record", ko: "점을 선택해 기록을 읽으세요")
        let compact = toolbarWidth < 520
        return HStack(spacing: 8) {
            scopeSwitch(compact: compact)
            Button { showsFind.toggle() } label: {
                ToolbarLabel(title: L("Find records", ko: "기록 검색"), symbol: "magnifyingglass", compact: compact)
            }
            .help(L("Find records (⌘F)", ko: "기록 검색 (⌘F)"))
            .disabled(!model.isGraphLoaded || records.isEmpty)
            .popover(isPresented: $showsFind, arrowEdge: .bottom) {
                GraphFindList(records: records, projectName: { ui.projectName($0) }, showsProject: model.selectedProjectID == nil) { id in
                    model.selectedRecordID = id
                    revealRequest &+= 1
                    showsFind = false
                }
                .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
                .environment(\.colorScheme, systemScheme)
            }

            Button { showsLegend.toggle() } label: {
                ToolbarLabel(title: L("Legend", ko: "범례"), symbol: "list.bullet.below.rectangle", compact: compact)
                    .overlay(alignment: .topTrailing) {
                        if filtersActive {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                                .offset(x: 5, y: -3)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .help(L("Colors, line styles and filters", ko: "색, 선 모양, 필터"))
            .accessibilityValue(filtersActive ? L("Filters on", ko: "필터 적용 중") : "")
            .popover(isPresented: $showsLegend, arrowEdge: .bottom) {
                GraphLegend(model: model, filtersActive: filtersActive, reset: resetFilters, relationCounts: relationCounts)
                    .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
                    .environment(\.colorScheme, systemScheme)
            }

            Spacer(minLength: 8)

            if model.isGraphLoaded {
                ViewThatFits(in: .horizontal) {
                    if !records.isEmpty {
                        Text("\(hint) · \(counts)").fixedSize(horizontal: true, vertical: false)
                    }
                    Text(counts).fixedSize(horizontal: true, vertical: false)
                    Color.clear.frame(width: 0, height: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(graphBackground, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Rectangle().fill(graphBoundary).frame(height: 1) }
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.width, initial: true) { toolbarWidth = proxy.size.width }
        })
    }

    @ViewBuilder private var empty: some View {
        let hidden = !model.graph.records.isEmpty
        EmptyState(
            symbol: "point.3.connected.trianglepath.dotted",
            title: L("Nothing to draw", ko: "그릴 기록이 없습니다"),
            message: hidden
                ? L("The kind, tag or finished-record filters hide every record.", ko: "종류, 태그, 끝난 기록 필터가 모든 기록을 가리고 있습니다.")
                : L("Records and the links between them appear here as soon as the project has some.",
                    ko: "프로젝트에 기록이 생기면 기록과 연결이 여기에 그려집니다.")
        ) {
            if hidden {
                Button(L("Reset filters", ko: "필터 초기화")) { resetFilters() }
                    .disabled(!filtersActive)
            }
        }
    }

    private var truncatedNote: some View {
        Label(L("Showing the first \(Limits.graphRecords) records", ko: "처음 \(Limits.graphRecords)개 기록만 표시합니다"),
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A toolbar label that collapses to its icon when the bar is narrow. The title stays as the accessibility label.
private struct ToolbarLabel: View {
    let title: String
    let symbol: String
    let compact: Bool

    var body: some View {
        if compact {
            Image(systemName: symbol).accessibilityLabel(title)
        } else {
            Label(title, systemImage: symbol)
        }
    }
}

// MARK: - Find records

/// A searchable list of the records the graph is drawing. Choosing one selects it; nothing else changes.
private struct GraphFindList: View {
    let records: [RecordSummary]
    let projectName: (Int64) -> String?
    let showsProject: Bool
    let onSelect: (Int64) -> Void

    @State private var query = ""
    @State private var highlighted: Int64?
    @FocusState private var fieldFocused: Bool

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private func matches() -> [RecordSummary] {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsID = text.hasPrefix("#")
        if wantsID { text.removeFirst() }
        let found: [RecordSummary]
        if text.isEmpty {
            found = records
        } else {
            // "#12" (or a bare number) also finds the record with that id.
            let idQuery = wantsID || Int(text) != nil
            found = records.filter { record in
                if !wantsID, record.title.range(of: text, options: Self.options) != nil { return true }
                return idQuery && String(record.id).hasPrefix(text)
            }
        }
        return found.sorted { a, b in
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    var body: some View {
        let results = matches()
        let current = results.contains { $0.id == highlighted } ? highlighted : results.first?.id
        VStack(spacing: 0) {
            TextField(L("Search titles or #id", ko: "제목 또는 #번호 검색"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { if let current { onSelect(current) } }
                .onKeyPress(.downArrow) { move(1, in: results, from: current); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: results, from: current); return .handled }
                .accessibilityLabel(L("Find records", ko: "기록 검색"))
                .padding(10)

            Divider()

            if results.isEmpty {
                Text(L("No matching records", ko: "일치하는 기록이 없습니다"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { record in
                                row(record, isCurrent: record.id == current)
                                    .id(record.id)
                            }
                        }
                        .padding(4)
                    }
                    .frame(height: min(320, CGFloat(results.count) * 48))
                    .onChange(of: current) { if let current { proxy.scrollTo(current) } }
                }
            }
        }
        .frame(width: 320)
        .task { fieldFocused = true }
    }

    private func move(_ step: Int, in results: [RecordSummary], from current: Int64?) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == current } ?? 0
        highlighted = results[min(max(index + step, 0), results.count - 1)].id
    }

    private func row(_ record: RecordSummary, isCurrent: Bool) -> some View {
        let color = Paint.kinds[record.kind] ?? .gray
        var detail = "\(Theme.name(record.kind)) · \(Theme.name(record.status))"
        if record.isSuperseded { detail += " · \(Theme.supersededName)" }
        detail += " · #\(record.id)"
        if showsProject, let name = projectName(record.projectID) { detail += " · \(name)" }
        return Button { onSelect(record.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Theme.symbol(record.kind))
                    .font(.caption)
                    .foregroundStyle(color)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { highlighted = record.id } }
        .accessibilityLabel("\(record.title), \(detail)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

// MARK: - Legend

/// Draws a relation's line the way the graph does, for the legend.
struct RelationSample: View {
    let relation: Relation

    var body: some View {
        let style = RelationStyle.of(relation)
        let color = Paint.relations[relation] ?? .gray
        Canvas { context, size in
            let y = size.height / 2
            let end = style.hasArrow ? size.width - 4 : size.width
            var line = Path()
            line.move(to: CGPoint(x: 1, y: y))
            line.addLine(to: CGPoint(x: end, y: y))
            let dash: [CGFloat] = switch style.stroke {
            case .solid: []
            case .dashed: [4, 3]
            case .dotted: [1.2, 3]
            }
            let width = min(style.width, 2.6)
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
            if style.hasArrow {
                var head = Path()
                head.move(to: CGPoint(x: size.width, y: y))
                head.addLine(to: CGPoint(x: size.width - 6, y: y - 3.5))
                head.addLine(to: CGPoint(x: size.width - 6, y: y + 3.5))
                head.closeSubpath()
                context.fill(head, with: .color(color))
            }
        }
        .frame(width: 32, height: 10)
        .accessibilityHidden(true)
    }
}

/// Kinds by color, relations by line style, and the graph's local filters. Shown in a popover.
struct GraphLegend: View {
    @Bindable var model: AppModel
    let filtersActive: Bool
    let reset: () -> Void
    /// Links per relation among the records currently drawn, counted even when the relation is hidden.
    let relationCounts: [Relation: Int]
    @Environment(BrowserUI.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        let counts = relationCounts
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 10, lineSpacing: 3) {
                ForEach(RecordKind.allCases, id: \.self) { kind in
                    HStack(spacing: 4) {
                        Circle().fill(Paint.kinds[kind] ?? .gray).frame(width: 8, height: 8)
                        Text(Theme.name(kind)).font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text(L("Ring: in progress · Faded: finished or replaced", ko: "테두리: 진행 중 · 흐림: 끝남·대체됨"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 1) {
                ForEach(Relation.allCases, id: \.self) { relation in
                    relationRow(relation, count: counts[relation] ?? 0)
                }
            }

            Divider()

            Toggle(isOn: $ui.graphHidesFinished) {
                Text(L("Hide finished", ko: "끝난 기록 숨기기")).font(.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Button(L("Reset filters", ko: "필터 초기화"), action: reset)
                .controlSize(.small)
                .disabled(!filtersActive)
        }
        .padding(12)
        .frame(width: 236, alignment: .leading)
    }

    private func relationRow(_ relation: Relation, count: Int) -> some View {
        let hidden = ui.graphHiddenRelations.contains(relation)
        return Button {
            if hidden { ui.graphHiddenRelations.remove(relation) } else { ui.graphHiddenRelations.insert(relation) }
        } label: {
            HStack(spacing: 8) {
                RelationSample(relation: relation)
                Text(Theme.name(relation))
                    .font(.caption)
                    .strikethrough(hidden)
                Spacer(minLength: 2)
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .opacity(hidden ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .help(hidden
              ? L("Click to show these links", ko: "눌러서 이 연결 보이기")
              : L("Click to hide these links", ko: "눌러서 이 연결 숨기기"))
        .accessibilityValue(hidden ? L("Hidden", ko: "숨김") : L("Shown", ko: "표시 중"))
    }
}
