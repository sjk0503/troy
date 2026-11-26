import AppKit
import SwiftUI

/// Receives scroll-wheel and pinch events that happen over its frame. It never takes mouse
/// clicks (its `hitTest` returns nil), so SwiftUI gestures above it keep working; the events
/// are picked up through a local monitor and swallowed only while the pointer is over the view.
struct ScrollEventView: NSViewRepresentable {
    var onScroll: (CGPoint, CGFloat, Bool) -> Void
    var onMagnify: (CGPoint, CGFloat) -> Void

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(_ view: EventView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
    }

    static func dismantleNSView(_ view: EventView, coordinator: ()) {
        view.removeMonitor()
    }

    final class EventView: NSView {
        var onScroll: (CGPoint, CGFloat, Bool) -> Void = { _, _, _ in }
        var onMagnify: (CGPoint, CGFloat) -> Void = { _, _ in }
        nonisolated(unsafe) private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self else { return event }
                nonisolated(unsafe) let unsafeEvent = event
                let consumed = MainActor.assumeIsolated { self.handle(unsafeEvent) }
                return consumed ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
            let p = convert(event.locationInWindow, from: nil)
            guard bounds.contains(p) else { return false }
            switch event.type {
            case .scrollWheel:
                onScroll(p, event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
            case .magnify:
                onMagnify(p, event.magnification)
            default:
                return false
            }
            return true
        }
    }
}
