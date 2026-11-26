import AppKit
import SwiftUI
import TroyMainUI
import TroyUI

/// The main window's content with the app actions filled in and the language applied.
struct MainRoot: View {
    let model: AppModel
    let actions: AppActions
    var onModeChange: (@MainActor (BrowserMode) -> Void)?
    /// Only for previews: start the graph on the selected record's local graph.
    var showsLocalGraph = false

    var body: some View {
        MainWindowView(model: model, showsLocalGraph: showsLocalGraph)
            .id(model.languageRevision)
            .environment(\.appActions, actions)
            .onChange(of: model.browserMode) { _, mode in onModeChange?(mode) }
    }
}

/// Owns the one main window. Opening and closing it is reported so the app can switch its activation policy.
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let onVisibilityChange: () -> Void
    private var isCounted = false
    private(set) lazy var window: NSWindow = makeWindow()
    private let actions: AppActions
    private let onModeChange: (@MainActor (BrowserMode) -> Void)?

    init(model: AppModel, actions: AppActions, onModeChange: (@MainActor (BrowserMode) -> Void)? = nil, onVisibilityChange: @escaping () -> Void) {
        self.model = model
        self.actions = actions
        self.onModeChange = onModeChange
        self.onVisibilityChange = onVisibilityChange
        super.init()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.title = "Troy"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 540)
        window.delegate = self
        let controller = NSHostingController(rootView: MainRoot(model: model, actions: actions, onModeChange: onModeChange))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1180, height: 740))
        window.center()
        // Restores the last frame when there is one.
        window.setFrameAutosaveName("TroyMainWindow")
        return window
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        window.makeKeyAndOrderFront(nil)
        if !isCounted {
            isCounted = true
            model.viewAppeared()
        }
        onVisibilityChange()
    }

    func windowWillClose(_ notification: Notification) {
        if isCounted {
            isCounted = false
            model.viewDisappeared()
        }
        DispatchQueue.main.async { [onVisibilityChange] in onVisibilityChange() }
    }
}

/// The settings window: a fixed-width window with a toolbar tab bar, one SwiftUI view inside.
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let model: AppModel
    private let state = SettingsState()
    private let preferences: Preferences
    private let launch = LaunchAtLogin()
    private let connections = ConnectionsModel()
    private let onVisibilityChange: () -> Void
    private var isCounted = false
    private(set) lazy var window: NSWindow = makeWindow()

    init(model: AppModel, preferences: Preferences, onVisibilityChange: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.onVisibilityChange = onVisibilityChange
        super.init()
    }

    var isVisible: Bool { window.isVisible }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsTab.width, height: SettingsTab.general.height),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = SettingsRoot(model: model, state: state, preferences: preferences, launch: launch, connections: connections)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        window.contentViewController = controller
        let toolbar = NSToolbar(identifier: "TroySettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(state.tab.rawValue)
        // The local window, not `self.window`: that property is still being initialized by this very call.
        resize(window, for: state.tab, animated: false)
        window.center()
        observeLanguage()
        return window
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { select(tab) }
        let window = window
        window.makeKeyAndOrderFront(nil)
        if !isCounted {
            isCounted = true
            model.viewAppeared()
        }
        onVisibilityChange()
    }

    private func select(_ tab: SettingsTab) {
        state.tab = tab
        let window = window
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
        resize(window, for: tab, animated: window.isVisible)
    }

    /// Changes the window's height to fit the tab, keeping its top edge where it is.
    private func resize(_ window: NSWindow, for tab: SettingsTab, animated: Bool) {
        window.title = tab.title
        let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: SettingsTab.width, height: tab.height))
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: animated)
    }

    /// Titles in the toolbar and the window follow the interface language.
    private func observeLanguage() {
        withObservationTracking {
            _ = model.languageRevision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                for item in self.window.toolbar?.items ?? [] {
                    if let tab = SettingsTab(rawValue: item.itemIdentifier.rawValue) { item.label = tab.title }
                }
                self.window.title = self.state.tab.title
                self.observeLanguage()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if isCounted {
            isCounted = false
            model.viewDisappeared()
        }
        DispatchQueue.main.async { [onVisibilityChange] in onVisibilityChange() }
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsTab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(tabClicked(_:))
        return item
    }

    @objc private func tabClicked(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(tab)
    }
}
