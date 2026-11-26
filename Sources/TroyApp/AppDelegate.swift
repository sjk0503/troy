import AppKit
import TroyCore
import TroyUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let databasePath: String
    private let preferences = Preferences()
    private var client: StoreClient?
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var panel: PanelController?
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private let hotKey = HotKey()
    private var pendingURLs: [URL] = []

    private let showAtLaunch: String?
    private let selectAtLaunch: Int64?

    init(databasePath: String, show: String? = nil, select: Int64? = nil) {
        self.databasePath = databasePath
        showAtLaunch = show
        selectAtLaunch = select
        super.init()
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let client: StoreClient
        do {
            client = try StoreClient(path: databasePath)
        } catch {
            failToOpen(error)
            return
        }
        self.client = client
        let model = AppModel(client: client)
        self.model = model

        let actions = makeActions()
        let openSettings: @MainActor @Sendable (SettingsTab) -> Void = { [weak self] tab in self?.showSettings(tab: tab) }
        panel = PanelController(model: model, actions: actions, openSettings: openSettings) { [weak self] in self?.statusItem?.anchorFrame }
        mainWindow = MainWindowController(
            model: model, actions: actions,
            onModeChange: { [weak self] mode in self?.persistBrowserMode(mode) },
            onVisibilityChange: { [weak self] in self?.windowsChanged() })
        settingsWindow = SettingsWindowController(model: model, preferences: preferences) { [weak self] in self?.windowsChanged() }
        statusItem = StatusItemController(handlers: .init(
            togglePanel: { [weak self] in self?.panel?.toggle() },
            hidePanel: { [weak self] in self?.panel?.hide() },
            openMain: { [weak self] in self?.showMainWindow(recordID: nil) },
            newRecord: { [weak self] in self?.startNewRecord() },
            openSettings: { [weak self] in self?.showSettings(tab: .general) },
            quit: { NSApp.terminate(nil) }))

        hotKey.onPress = { [weak self] in self?.panel?.toggle() }
        applyHotkeyPreference()
        trackPreferences()
        installMainMenu()
        model.start()

        let urls = pendingURLs
        pendingURLs = []
        urls.forEach(handle)
        if let showAtLaunch { openForInspection(showAtLaunch) }
    }

    /// `--show main|overview|graph|local-graph|panel|settings|settings-general|settings-data|new-record|new-project` opens
    /// that window at launch and prints the window numbers,
    /// so a development run can be looked at, or captured with `screencapture -l`, without clicking.
    private func openForInspection(_ what: String) {
        switch what {
        case "panel": panel?.show()
        case "settings": showSettings(tab: .connections)
        case "settings-general": showSettings(tab: .general)
        case "settings-data": showSettings(tab: .data)
        case "new-record": startNewRecord()
        case "new-project":
            model?.intent = .newProject
            showMainWindow(recordID: nil)
        case "local-graph":
            model?.browserMode = .graph
            if let id = selectAtLaunch, let model {
                showMainWindow(recordID: nil)
                // Only a record that really exists opens its local graph; otherwise the ordinary graph stays.
                Task {
                    guard let record = await model.record(id) else {
                        model.errorMessage = L("Record #\(id) no longer exists.", ko: "\(Josa.attach("기록 #\(id)", "이", "가")) 더 이상 없습니다.")
                        return
                    }
                    model.intent = .localGraph(record.summary)
                }
            } else {
                showMainWindow(recordID: nil)
            }
        default:
            // `main` stays the plain list scene scripts have always captured; `overview` and `graph` are opt-in.
            let mode: BrowserMode = what == "graph" ? .graph : what == "overview" ? .overview : .list
            model?.browserMode = mode
            showMainWindow(recordID: selectAtLaunch)
        }
        reportWindows(attempt: 0)
    }

    private func reportWindows(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let shown = NSApp.windows.filter { $0.isVisible && $0.frame.width > 100 }
            if shown.isEmpty && attempt < 8 {
                self?.reportWindows(attempt: attempt + 1)
                return
            }
            for window in shown {
                print("WINDOW \(window.windowNumber) \(Int(window.frame.width))x\(Int(window.frame.height))")
            }
            if shown.isEmpty {
                let all = NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))" }
                print("NO WINDOW; windows: \(all)")
            }
            fflush(stdout)
        }
    }

    private func failToOpen(_ error: Error) {
        activateApp()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("Troy cannot open its database", ko: "Troy가 데이터베이스를 열 수 없습니다")
        let detail = (error as? TroyError)?.message ?? error.localizedDescription
        alert.informativeText = "\(databasePath)\n\n\(detail)"
        alert.addButton(withTitle: L("Quit", ko: "종료"))
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.unregister()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again from Finder or the Dock shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model != nil { showMainWindow(recordID: nil) }
        return false
    }

    // MARK: URL scheme

    func application(_ application: NSApplication, open urls: [URL]) {
        guard model != nil else {
            pendingURLs += urls
            return
        }
        urls.forEach(handle)
    }

    /// `troy://record/<id>`, `troy://project/<id>`, `troy://open`.
    private func handle(_ url: URL) {
        guard url.scheme == "troy", let model else { return }
        let id = Int64(url.pathComponents.dropFirst().first ?? "")
        switch url.host {
        case "record":
            showMainWindow(recordID: id)
        case "project":
            if let id { model.selectedProjectID = id }
            showMainWindow(recordID: nil)
        default:
            showMainWindow(recordID: nil)
        }
    }

    // MARK: Actions the views ask for

    private func makeActions() -> AppActions {
        var actions = AppActions()
        actions.showMainWindow = { [weak self] id in self?.showMainWindow(recordID: id) }
        actions.openProjectGraph = { [weak self] in self?.openProjectGraph() }
        actions.showSettings = { [weak self] in self?.showSettings(tab: .general) }
        actions.hidePanel = { [weak self] in self?.panel?.hide() }
        actions.quit = { NSApp.terminate(nil) }
        actions.showConnections = { [weak self] in self?.showSettings(tab: .connections) }
        actions.openGuide = { [weak self] in self?.openGuide() }
        return actions
    }

    private static let browserModeKey = "TroyMainBrowserMode"
    private var restoredBrowserMode = false
    private var knownBrowserMode: BrowserMode?

    private var isInspecting: Bool { showAtLaunch != nil }

    /// The first main window of a normal launch opens the overview unless a view was chosen before.
    private func restoreBrowserModeOnce(_ model: AppModel) {
        guard !restoredBrowserMode, !isInspecting else { return }
        restoredBrowserMode = true
        let saved = UserDefaults.standard.string(forKey: Self.browserModeKey).flatMap(BrowserMode.init(rawValue:))
        let mode = saved ?? .overview
        knownBrowserMode = mode
        if model.browserMode != mode { model.browserMode = mode }
    }

    private func persistBrowserMode(_ mode: BrowserMode) {
        guard !isInspecting, restoredBrowserMode, mode != knownBrowserMode else { return }
        knownBrowserMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.browserModeKey)
    }

    private func openGuide() {
        let name = "Troy-Guide-ko"
        var url = Bundle.main.url(forResource: name, withExtension: "pdf")
        #if DEBUG
        if url == nil {
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("docs/\(name).pdf")
            if FileManager.default.fileExists(atPath: repository.path) { url = repository }
        }
        #endif
        guard let url, NSWorkspace.shared.open(url) else {
            activateApp()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Cannot open the user guide", ko: "사용 가이드를 열 수 없습니다")
            alert.informativeText = L(
                "The Korean PDF guide is missing from the app or no application can open it.",
                ko: "한국어 PDF 가이드가 앱에 없거나 이를 열 수 있는 앱이 없습니다.")
            alert.addButton(withTitle: L("OK", ko: "확인"))
            alert.runModal()
            return
        }
    }

    /// The panel's "그래프 열기": the first-open restore runs first, so it cannot overwrite the graph afterwards.
    private func openProjectGraph() {
        if let model {
            restoreBrowserModeOnce(model)
            if model.browserMode != .graph { model.browserMode = .graph }
            // The window clears a record's local graph; it owns that state.
            model.intent = .fullGraph
        }
        showMainWindow(recordID: nil)
    }

    /// Shows the main window. A record asked for by the panel, a URL or a script lands selected in the
    /// list, unless the window is showing the graph: then it is selected there.
    func showMainWindow(recordID: Int64?) {
        panel?.hide()
        guard let model, let mainWindow else { return }
        restoreBrowserModeOnce(model)
        if let recordID {
            Task {
                // Switch to the record's project first, or the main window would drop the selection.
                guard let record = await model.record(recordID) else {
                    model.errorMessage = L("Record #\(recordID) no longer exists.", ko: "\(Josa.attach("기록 #\(recordID)", "이", "가")) 더 이상 없습니다.")
                    return
                }
                if model.browserMode == .graph {
                    if model.selectedProjectID != nil, model.selectedProjectID != record.projectID {
                        model.selectedProjectID = record.projectID
                    }
                    model.selectedRecordID = recordID
                } else {
                    model.revealInList(record.summary)
                }
            }
        }
        enterRegularMode()
        mainWindow.show()
        activateApp()
    }

    private func showSettings(tab: SettingsTab) {
        panel?.hide()
        guard let settingsWindow else { return }
        enterRegularMode()
        settingsWindow.show(tab: tab)
        activateApp()
    }

    private func startNewRecord() {
        model?.intent = .newRecord
        showMainWindow(recordID: nil)
    }

    // MARK: Activation policy

    private func enterRegularMode() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            installMainMenu()
        }
    }

    /// Back to a menu bar app once the last window is closed.
    private func windowsChanged() {
        let open = (mainWindow?.isVisible ?? false) || (settingsWindow?.isVisible ?? false)
        if !open, NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }

    /// An accessory app is never frontmost on its own. `activate(ignoringOtherApps:)` is deprecated
    /// in macOS 14, but the cooperative `activate()` does not bring a menu bar app forward, so it stays here, once.
    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Preferences

    private func applyHotkeyPreference() {
        if preferences.hotkeyEnabled {
            preferences.hotkeyRegistered = hotKey.register()
        } else {
            hotKey.unregister()
            preferences.hotkeyRegistered = true
        }
    }

    private func trackPreferences() {
        withObservationTracking {
            _ = preferences.hotkeyEnabled
            _ = preferences.showsCount
            _ = model?.projects
            _ = model?.selectedProjectID
            _ = model?.languageRevision
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.preferencesChanged()
                self?.trackPreferences()
            }
        }
        updateCount()
    }

    private var appliedHotkey: Bool?

    private func preferencesChanged() {
        if appliedHotkey != preferences.hotkeyEnabled { applyHotkeyPreference() }
        if NSApp.activationPolicy() == .regular { installMainMenu() }
        updateCount()
    }

    private func updateCount() {
        appliedHotkey = preferences.hotkeyEnabled
        guard preferences.showsCount, let model else {
            statusItem?.setCount(nil)
            return
        }
        let active = model.projects.filter { $0.project.status == .active }
        let doing = model.selectedProjectID == nil
            ? active.reduce(0) { $0 + $1.stats.doing }
            : model.projects.first { $0.id == model.selectedProjectID }?.stats.doing ?? 0
        statusItem?.setCount(doing)
    }

    // MARK: Main menu

    /// Only visible while a window is open, but it carries the shortcuts text fields need (copy, paste, undo).
    private func installMainMenu() {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: L("About Troy", ko: "Troy 정보"), action: #selector(showAbout), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: L("Settings…", ko: "설정…"), action: #selector(showSettingsFromMenu), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: L("Hide Troy", ko: "Troy 가리기"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: L("Quit Troy", ko: "Troy 종료"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app)

        let edit = NSMenu(title: L("Edit", ko: "편집"))
        edit.addItem(withTitle: L("Undo", ko: "실행 취소"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo", ko: "다시 실행"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut", ko: "잘라내기"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy", ko: "복사"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste", ko: "붙여넣기"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All", ko: "전체 선택"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: L("Edit", ko: "편집"))

        let windowMenu = NSMenu(title: L("Window", ko: "윈도우"))
        windowMenu.addItem(withTitle: L("Minimize", ko: "최소화"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("Close", ko: "닫기"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: windowMenu, title: L("Window", ko: "윈도우"))

        let helpMenu = NSMenu(title: L("Help", ko: "도움말"))
        helpMenu.addItem(withTitle: L("Troy User Guide (Korean PDF)", ko: "Troy 사용 가이드 (PDF)"), action: #selector(openGuideFromMenu), keyEquivalent: "").target = self
        main.addItem(submenu: helpMenu, title: L("Help", ko: "도움말"))

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    @objc private func openGuideFromMenu() { openGuide() }

    @objc private func showAbout() { showSettings(tab: .about) }
    @objc private func showSettingsFromMenu() { showSettings(tab: .general) }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String = "") {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
