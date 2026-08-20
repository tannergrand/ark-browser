import AppKit
import SwiftUI

/// Renders the live window to a PNG, on demand, from inside the app.
///
/// This exists because verification here has been blind all along:
/// `screencapture` fails without Screen Recording permission, and synthetic
/// mouse events need Accessibility. But a view can always draw *itself* —
/// `cacheDisplay(in:to:)` needs no permission at all, because nothing is being
/// captured off the screen.
///
/// Set `ARK_PROBE_PNG=/path/out.png` to have the window written there a few
/// seconds after launch, with the colour at a few named points logged. That
/// turns "the border still isn't tinted" from a guess into a measurement.
enum WindowProbe {
    static func armIfRequested(_ state: BrowserState) {
        guard let path = ProcessInfo.processInfo.environment["ARK_PROBE_PNG"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["ARK_PROBE_DELAY"] ?? "6") ?? 6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // State first: a colour reading is meaningless without knowing what
            // the app thought it was drawing.
            say("style=\(state.sidebarStyle.rawValue) strength=\(state.chromeTintStrength)")
            say("glass=\(state.glassChrome)")
            if let tint = state.chromeTint,
               let rgb = NSColor(tint).usingColorSpace(.sRGB) {
                say(String(format: "chromeTint=#%02X%02X%02X",
                           Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                           Int(rgb.blueComponent * 255)))
            } else {
                say("chromeTint=nil")
            }
            say("focused=\(state.focusedTab?.host ?? "-") themeTint=\(state.focusedTab?.themeTint != nil)")
            capture(to: path)
        }
    }

    static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView else {
            say("no visible window")
            return
        }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            say("no bitmap rep")
            return
        }
        view.cacheDisplay(in: bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            say("png encode failed")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        say("wrote \(Int(bounds.width))x\(Int(bounds.height)) to \(path)")

        // Colour readings at the points under discussion. Rep coordinates are
        // top-left origin, unlike the view's.
        let scale = Double(rep.pixelsWide) / Double(bounds.width)
        func read(_ label: String, _ x: Double, _ y: Double) {
            let px = Int(x * scale), py = Int(y * scale)
            guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
                  let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else {
                say("\(label): out of range")
                return
            }
            say(String(format: "%@ (%d,%d): #%02X%02X%02X", label, px, py,
                       Int(color.redComponent * 255), Int(color.greenComponent * 255),
                       Int(color.blueComponent * 255)))
        }
        let midY = bounds.height / 2
        read("sidebar interior", 100, midY)
        read("gutter left of page", 245, midY)
        read("gutter above page", bounds.width / 2, 4)
        read("gutter right of page", bounds.width - 4, midY)
        read("gutter below page", bounds.width / 2, bounds.height - 4)
        read("page interior", bounds.width / 2, midY)
    }

    private static func say(_ message: String) {
        FileHandle.standardError.write("[probe] \(message)\n".data(using: .utf8)!)
    }
}
