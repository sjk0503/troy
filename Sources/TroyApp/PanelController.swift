import AppKit
import SwiftUI
import TroyUI

/// A borderless panel that does not activate the app but can take keystrokes, so the search field works.
final class TroyPanel: NSPanel {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// Shows the panel under the status item and closes it again on Escape, an outside click or lost focus.
final class PanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let state = PanelState()
    private let panel: TroyPanel
    private let anchor: () -> NSRect?
    private var outsideClickMonitor: Any?
    private var isCounted = false
    /// When the panel last closed because it lost focus. The click on the status item that
    /// caused it must not open the panel again.
    private var lastResignClose = Date.distantPast

    var isVisible: Bool { panel.isVisible }

    init(model: AppModel, actions: AppActions, openSettings: @escaping @MainActor @Sendable (SettingsTab) -> Void, anchor: @escaping () -> NSRect?) {
        self.model = model
        self.anchor = anchor
        panel = TroyPanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: Theme.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }

        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = PanelMetrics.cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true

        let host = NSHostingView(rootView: PanelRoot(model: model, state: state, actions: actions, openSettings: openSettings))
        host.sizingOptions = []
        host.frame = material.bounds
        host.autoresizingMask = [.width, .height]
        material.addSubview(host)
        panel.contentView = material
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else if Date().timeIntervalSince(lastResignClose) > 0.25 {
            show()
        }
    }

    func show() {
        guard !panel.isVisible else { return }
        position()
        state.reset()
        panel.makeKeyAndOrderFront(nil)
        // The search field can take focus only once the panel is key.
        DispatchQueue.main.async { [state] in state.focusRequest += 1 }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        if !isCounted {
            isCounted = true
            model.viewAppeared()
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if isCounted {
            isCounted = false
            model.viewDisappeared()
        }
        state.query = ""
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        lastResignClose = Date()
        hide()
    }

    /// Centers the panel under the status item and keeps it inside the visible part of the screen.
    private func position() {
        let margin: CGFloat = 8
        let anchorFrame = anchor()
        let screen = anchorFrame.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(Theme.panelWidth, visible.width - margin * 2)
        let height = min(Theme.panelHeight, visible.height - margin * 2)
        var x = visible.maxX - width - margin
        var top = visible.maxY - 4
        if let anchorFrame {
            x = anchorFrame.midX - width / 2
            top = min(anchorFrame.minY - 4, visible.maxY - 4)
        }
        x = min(max(x, visible.minX + margin), visible.maxX - width - margin)
        let y = max(top - height, visible.minY + margin)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    }
}
