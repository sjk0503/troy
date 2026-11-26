import AppKit
import SwiftUI
import TroyCore
import TroyMainUI
import TroyUI

/// `TroyApp --render <scene> --out <file.png> [--db path] [--demo en|ko] [--dark] [--lang en|ko] [--size WxH]`
/// draws one scene off screen and exits. It is how a change to a screen is checked without clicking
/// through the app, and how the screenshots in the README are made. It never starts the menu bar app, never writes to the real
/// database and never runs another program.
enum RenderMode {
    static let scenes = [
        "panel", "panel-search", "panel-empty",
        "main", "main-overview", "main-graph", "main-local-graph", "main-search",
        "editor-record", "editor-link", "editor-project",
        "settings-general", "settings-connections", "settings-data", "settings-about",
    ]

    static func run(_ options: LaunchOptions) -> Int32 {
        guard let scene = options.render, scenes.contains(scene), let out = options.out else {
            FileHandle.standardError.write(Data("usage: TroyApp --render <\(scenes.joined(separator: "|"))> --out <file.png> [--db path] [--demo en|ko] [--dark] [--lang en|ko] [--size WxH]\n".utf8))
            return 2
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        // The model and `Localization` keep their choices in UserDefaults. Put them back afterwards.
        let defaults = UserDefaults.standard
        let keys = [Localization.defaultsKey, "selectedProjectID"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.removeObject(forKey: "selectedProjectID")
        Localization.language = options.language ?? .english

        // `panel-empty` is the first-run state, so it ignores any demo or database.
        let wantsEmpty = scene == "panel-empty"
        let path: String
        var selectedProject: Int64?
        // With demo data: a record to show in the inspector, and one to link it to.
        var focus: RecordSummary?
        var other: RecordSummary?
        do {
            if options.db != nil && !wantsEmpty && options.demo == nil {
                path = options.db ?? ""
            } else {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("troy-render-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                path = folder.appendingPathComponent("troy.db").path
                let store = try Store(path: path, agent: "render")
                if let demo = options.demo, !wantsEmpty {
                    let project = try DemoData.seed(into: store, language: demo)
                    selectedProject = project.id
                    let all = try store.list(RecordQuery(projectID: project.id))
                    focus = all.first { $0.status == .doing && $0.linkCount > 3 } ?? all.first { $0.status == .doing }
                    other = all.first { $0.status == .done && $0.kind == .task }
                } else if options.emptyProject {
                    selectedProject = try store.createProject(name: "Empty project", summary: "").id
                }
                store.close()
            }
        } catch {
            FileHandle.standardError.write(Data("render: cannot prepare the database: \(error)\n".utf8))
            return 1
        }

        let client: StoreClient
        do { client = try StoreClient(path: path, agent: "render") } catch {
            FileHandle.standardError.write(Data("render: cannot open the database: \(error)\n".utf8))
            return 1
        }
        let model = AppModel(client: client)
        if let selectedProject { model.selectedProjectID = selectedProject }
        model.start()
        // Wait for what the scene shows, so a slow machine does not produce a picture of a spinner.
        func wait(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, !condition() {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        wait { model.isLoaded && (model.selectedProjectID == nil || model.overview != nil) }
        let korean = Localization.usesKorean
        if scene.hasPrefix("main"), let focus {
            model.selectedRecordID = focus.id
            wait { model.detail?.record.id == focus.id }
        }
        let windowBackground = Color(nsColor: .windowBackgroundColor)

        let actions = AppActions()
        let size: CGSize
        let view: AnyView
        var settle = 1.6
        switch scene {
        case "panel", "panel-empty":
            size = options.size ?? CGSize(width: Theme.panelWidth, height: Theme.panelHeight)
            view = AnyView(RenderPanel(model: model, state: PanelState(), actions: actions))
        case "panel-search":
            size = options.size ?? CGSize(width: Theme.panelWidth, height: Theme.panelHeight)
            let state = PanelState()
            state.query = options.query ?? (Localization.usesKorean ? "오프라인" : "offline")
            view = AnyView(RenderPanel(model: model, state: state, actions: actions))
            settle = 2.2
        case "main", "main-graph", "main-local-graph", "main-overview", "main-search":
            // The model starts in the overview; `main` and `main-search` are the list scenes.
            switch scene {
            case "main-graph", "main-local-graph":
                model.browserMode = .graph
                wait { model.isGraphLoaded }
            case "main-overview":
                model.browserMode = .overview
            case "main-search":
                model.browserMode = .list
                model.searchText = options.query ?? (korean ? "동기화" : "sync")
                wait { model.searchHits != nil }
            default:
                model.browserMode = .list
            }
            size = options.size ?? CGSize(width: 1180, height: 740)
            view = AnyView(
                MainRoot(model: model, actions: actions, showsLocalGraph: scene == "main-local-graph")
                    .background(windowBackground))
            settle = scene.hasSuffix("graph") ? 4.0 : 2.5
        case "editor-record":
            // A new record whose title resembles an existing one, so the similar-records hint shows.
            size = options.size ?? CGSize(width: 640, height: 620)
            view = AnyView(RecordEditorSheet(
                model: model, editing: nil, projectID: selectedProject,
                initialTitle: korean ? "로컬 우선 동기화 엔진 개선" : "Local first sync engine", showsPreview: false, onDone: { _ in }
            ).background(windowBackground))
            settle = 2.2
        case "editor-link":
            guard let focus else {
                FileHandle.standardError.write(Data("render: editor-link needs --demo\n".utf8))
                return 2
            }
            size = options.size ?? CGSize(width: 600, height: 700)
            view = AnyView(LinkEditorSheet(
                model: model, record: focus, relation: .dependsOn, query: korean ? "데이터베이스" : "database", selected: other, onDone: {}
            ).background(windowBackground))
            settle = 2.0
        case "editor-project":
            size = options.size ?? CGSize(width: 540, height: 520)
            view = AnyView(ProjectEditorSheet(model: model, editing: nil, onDone: { _ in }).background(windowBackground))
        default:
            let tab = SettingsTab(rawValue: String(scene.dropFirst("settings-".count))) ?? .general
            size = options.size ?? CGSize(width: SettingsTab.width, height: tab.height)
            let state = SettingsState()
            state.tab = tab
            let root = SettingsRoot(
                model: model, state: state, preferences: Preferences(), launch: LaunchAtLogin(),
                connections: ConnectionsModel(fileOnly: true))
            view = AnyView(root.background(windowBackground))
        }

        try? FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let ok = SnapshotRenderer.write(view, to: out, size: size, dark: options.dark, settle: settle)
        if ok { print(out); return 0 }
        FileHandle.standardError.write(Data("render: could not write \(out)\n".utf8))
        return 1
    }
}

/// The panel with the window background an off-screen render needs, since a material has nothing behind it there.
private struct RenderPanel: View {
    let model: AppModel
    let state: PanelState
    let actions: AppActions

    var body: some View {
        PanelRoot(model: model, state: state, actions: actions, openSettings: { _ in })
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
    }
}
