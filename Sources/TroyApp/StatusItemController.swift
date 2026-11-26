import AppKit
import TroyUI

/// The icon in the menu bar. A click toggles the panel; a right click or control-click opens a small menu.
final class StatusItemController: NSObject {
    struct Handlers {
        var togglePanel: () -> Void
        var hidePanel: () -> Void
        var openMain: () -> Void
        var newRecord: () -> Void
        var openSettings: () -> Void
        var quit: () -> Void
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let handlers: Handlers

    /// The status item's button in screen coordinates, for anchoring the panel.
    var anchorFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    init(handlers: Handlers) {
        self.handlers = handlers
        super.init()
        guard let button = item.button else { return }
        button.image = Self.icon()
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Troy"
        button.setAccessibilityLabel("Troy")
    }

    /// Shows the number of records in progress beside the icon; `nil` or 0 shows the icon alone.
    func setCount(_ count: Int?) {
        guard let button = item.button else { return }
        if let count, count > 0 {
            button.title = " \(count)"
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.setAccessibilityLabel(L("Troy, \(count) in progress", ko: "Troy, 진행 중 \(count)개"))
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Troy")
        }
    }

    private static func icon() -> NSImage? {
        let names = ["point.3.connected.trianglepath.dotted", "point.3.filled.connected.trianglepath.dotted", "circle.hexagongrid", "network"]
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Troy") {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            handlers.hidePanel()
            showMenu()
        } else {
            handlers.togglePanel()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(entry(L("Open Troy", ko: "Troy 열기"), #selector(openMain)))
        menu.addItem(entry(L("New Record…", ko: "새 기록…"), #selector(newRecord)))
        menu.addItem(.separator())
        menu.addItem(entry(L("Settings…", ko: "설정…"), #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(entry(L("Quit Troy", ko: "Troy 종료"), #selector(quit)))
        // Attach the menu only for this click, so a plain click keeps reaching the action above.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func entry(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func openMain() { handlers.openMain() }
    @objc private func newRecord() { handlers.newRecord() }
    @objc private func openSettings() { handlers.openSettings() }
    @objc private func quit() { handlers.quit() }
}
