import AppKit
import SwiftUI

/// Draws a view into a PNG without showing it, so a screen can be checked from the command line
/// (`TroyApp --render …`) and screenshots for the README can be regenerated.
///
/// The view is hosted in a real, off-screen window, which is what makes AppKit-backed controls
/// (lists, text fields, split views) draw; `ImageRenderer` alone leaves them blank.
/// Translucent materials have nothing behind them off screen, so they come out as the window's
/// background color.
public enum SnapshotRenderer {
    /// - Parameters:
    ///   - settle: how long to let the view load data and lay out before the picture is taken.
    public static func png<Content: View>(
        of view: Content, size: CGSize, dark: Bool, scale: CGFloat = 2, settle: TimeInterval = 0.8
    ) -> Data? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let frame = NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        // Let tasks started by the view finish and SwiftUI commit its layout.
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()

        let pixels = NSSize(width: size.width * scale, height: size.height * scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        bitmap.size = size
        var data: Data?
        appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            data = bitmap.representation(using: .png, properties: [:])
        }
        return data
    }

    /// Renders and writes the file. Returns false when rendering or writing failed.
    @discardableResult
    public static func write<Content: View>(
        _ view: Content, to path: String, size: CGSize, dark: Bool, scale: CGFloat = 2, settle: TimeInterval = 0.8
    ) -> Bool {
        guard let data = png(of: view, size: size, dark: dark, scale: scale, settle: settle) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
