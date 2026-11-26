import AppKit
import SwiftUI
import TroyCore
import TroyUI

/// The content of the main window: projects and filters, the record list or graph, and the inspector.
public struct MainWindowView: View {
    @Bindable private var model: AppModel
    @State private var ui: BrowserUI
    @State private var columns = NavigationSplitViewVisibility.all

    /// `showsLocalGraph` only sets where the graph starts, so a preview can show a record's local graph.
    public init(model: AppModel, showsLocalGraph: Bool = false) {
        self.model = model
        _ui = State(initialValue: BrowserUI(model: model, showsLocalGraph: showsLocalGraph))
    }

    public var body: some View {
        @Bindable var ui = ui
        Group {
            switch model.browserMode {
            case .overview: wideSplitView(withInspector: false)
            case .graph: wideSplitView(withInspector: true)
            case .list: listSplitView
            }
        }
        .environment(ui)
        .frame(minWidth: 860, minHeight: 540)
        .sheet(item: $ui.sheet) { sheet in
            sheetContent(sheet)
        }
        .onAppear {
            model.start()
            model.viewAppeared()
            performIntent()
        }
        .onDisappear { model.viewDisappeared() }
        .onChange(of: model.intent) { performIntent() }
        .onChange(of: model.isLoaded) { performIntent() }
        // The local graph belongs to the graph view; it must not come back the next time the graph opens.
        .onChange(of: model.browserMode) { if model.browserMode != .graph { ui.showsLocalGraph = false } }
        .id(model.languageRevision)
    }

    /// Projects, record list, inspector.
    private var listSplitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 210, max: 280)
        } content: {
            ContentColumn(model: model)
                .navigationSplitViewColumnWidth(min: 340, ideal: 440)
        } detail: {
            InspectorView(model: model)
        }
    }

    /// Projects and one wide detail area. The graph takes all of it, and a selected record's
    /// inspector docks at a fixed width beside it, so the map stays the main thing on screen.
    /// The local graph is full width unless the user asked for the record detail beside it
    /// (`showsLocalInspector`). The overview has the same shape without an inspector.
    private func wideSplitView(withInspector: Bool) -> some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 260)
        } detail: {
            GeometryReader { proxy in
                let inspectorWidth = min(338, max(300, proxy.size.width * 0.34))
                HStack(spacing: 0) {
                    ContentColumn(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if withInspector && model.selectedRecordID != nil
                        && (!ui.showsLocalGraph || ui.showsLocalInspector) {
                        Divider()
                        InspectorView(model: model, minWidth: 300, compact: true)
                            .frame(width: inspectorWidth)
                    }
                }
            }
            .frame(minWidth: 560)
            .clipped()
        }
        // A neutral opaque backing behind the whole split, so the translucent native
        // sidebar material (and the gutter beside it) sits over the window color, not over black.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Does what another window asked for, once the data is there to act on.
    private func performIntent() {
        guard model.isLoaded, let intent = model.intent else { return }
        model.intent = nil
        switch intent {
        case .newRecord: ui.newRecord()
        case .newProject: ui.newProject()
        case .fullGraph: ui.showsLocalGraph = false
        case .localGraph(let summary): ui.openLocalGraph(for: summary)
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: BrowserSheet) -> some View {
        switch sheet {
        case .newRecord(let projectID):
            RecordEditorSheet(model: model, editing: nil, projectID: projectID) { id in
                ui.sheet = nil
                if let id { Task { await ui.select(created: id) } }
            }
        case .editRecord(let record):
            RecordEditorSheet(model: model, editing: record, projectID: record.projectID) { _ in
                ui.sheet = nil
            }
        case .newProject:
            ProjectEditorSheet(model: model, editing: nil) { _ in ui.sheet = nil }
        case .editProject(let project):
            ProjectEditorSheet(model: model, editing: project) { _ in ui.sheet = nil }
        case .addLink(let record):
            LinkEditorSheet(model: model, record: record) { ui.sheet = nil }
        }
    }
}
