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
    /// Frames published by the views themselves, so measurements come from the
    /// layout rather than from counting pixels in a screenshot.
    @MainActor static var reportedFrames: [String: CGRect] = [:]

    static func report(_ label: String, _ frame: CGRect) {
        Task { @MainActor in reportedFrames[label] = frame }
    }

    static func armIfRequested(_ state: BrowserState) {
        guard let path = ProcessInfo.processInfo.environment["ARK_PROBE_PNG"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["ARK_PROBE_DELAY"] ?? "6") ?? 6
        // Optionally open Settings first, so the probe can look at a panel the
        // shell can't click on.
        if ProcessInfo.processInfo.environment["ARK_PROBE_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, delay - 3)) {
                NSApp.activate(ignoringOtherApps: true)
                // Both spellings: the selector was renamed in macOS 13, and
                // sendAction silently does nothing for the one that doesn't
                // exist — which is why the first attempt captured no panel.
                for name in ["showSettingsWindow:", "showPreferencesWindow:"] {
                    NSApp.sendAction(Selector((name)), to: nil, from: nil)
                }
            }
        }
        // Revealing three seconds early let the edge monitor hide the panel again
        // before the report ran — the real pointer sits over the page, which is
        // exactly the "move away" gesture. Reveal, let it lay out, then look.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if ProcessInfo.processInfo.environment["ARK_PROBE_REVEAL_SIDEBAR"] == "1" {
                state.sidebarAutoHide = true
                state.sidebarRevealed = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.6) {
            reportCursorShields()
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
            reportContentInsets(state)
            capture(to: path)
        }
    }

    /// What the cursor shields are doing, since the cursor itself can't be
    /// observed from a script. Reports presence, geometry, and — the part that
    /// matters — that they stay invisible to hit testing, so clicks still reach
    /// the rows drawn above them.
    static func reportCursorShields() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let root = window.contentView else { return }
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if view is CursorShield.Shield { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        say("cursor shields: \(found.count)")
        for shield in found {
            let frame = shield.convert(shield.bounds, to: root)
            let centre = NSPoint(x: frame.midX, y: frame.midY)
            let hit = root.hitTest(centre)
            say(String(format: "  frame %.0f,%.0f %.0fx%.0f  hitTest→%@",
                       frame.minX, frame.minY, frame.width, frame.height,
                       hit.map { String(describing: type(of: $0)) } ?? "nil"))
            say("  cursor rect registered: \(!shield.trackingAreas.isEmpty)")
        }

        // The monitor's actual question, asked at two points: one inside the
        // panel, one out over the page. Cursor rects were the first attempt and
        // silently lost to WebKit; this is the check that matters now.
        if let shield = found.first {
            let frame = shield.convert(shield.bounds, to: nil)
            let inside = NSPoint(x: frame.midX, y: frame.midY)
            let outside = NSPoint(x: frame.maxX + 200, y: frame.midY)
            say("  covers point inside panel: \(CursorShield.coversPointer(inside, in: window))")
            say("  covers point over page:   \(CursorShield.coversPointer(outside, in: window))")
        }
    }

    /// The gap between the web content and each window edge, measured from the
    /// pane's own registered frame. "Looks uneven" is worth a number.
    private static func shieldFrame(in root: NSView) -> CGRect? {
        var found: NSView?
        func walk(_ view: NSView) {
            if view is CursorShield.Shield, found == nil { found = view }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.map { $0.convert($0.bounds, to: root) }
    }

    @MainActor
    static func reportContentInsets(_ state: BrowserState) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let root = window.contentView else { return }
        let panes = state.drag.registeredFrames.filter {
            if case .pane = $0.key { return true }
            return false
        }
        for (label, frame) in reportedFrames.sorted(by: { $0.key < $1.key }) {
            say(String(format: "%@  %.0f,%.0f %.0fx%.0f", label,
                       frame.minX, frame.minY, frame.width, frame.height))
        }
        guard let pane = panes.values.first else {
            say("insets: no pane frame registered")
            return
        }
        // Registered frames are in SwiftUI global space, which for this window
        // matches the content view's flipped coordinates.
        let bounds = root.bounds
        say(String(format: "window %.0fx%.0f  pane %.0f,%.0f %.0fx%.0f",
                   bounds.width, bounds.height, pane.minX, pane.minY,
                   pane.width, pane.height))
        say(String(format: "insets  left %.1f  right %.1f  top %.1f  bottom %.1f",
                   pane.minX, bounds.width - pane.maxX,
                   pane.minY, bounds.height - pane.maxY))
    }

    static func capture(to path: String) {
        // Every visible window, not just the first: a settings panel is a second
        // window, and it is exactly the thing worth looking at.
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        guard !windows.isEmpty else {
            say("no visible window")
            return
        }
        for (index, window) in windows.enumerated() where index > 0 {
            let extra = (path as NSString).deletingPathExtension + "-\(index).png"
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: extra))
                    say("window \(index) \"\(window.title)\" \(Int(view.bounds.width))x\(Int(view.bounds.height)) -> \(extra)")
                }
            }
        }
        guard let window = windows.first, let view = window.contentView else { return }
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
        // Corners of the floating panel, if one is up: a square backing shows as
        // the corner pixel matching the panel's fill instead of what's behind it.
        if let shield = shieldFrame(in: view) {
            // The view's origin is bottom-left; the bitmap's is top-left.
            let topY = bounds.height - shield.maxY
            read("panel corner (2,2 in)", shield.minX + 2, topY + 2)
            read("panel inset (14,14 in)", shield.minX + 14, topY + 14)
            read("just outside panel", shield.minX - 4, topY - 4)
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
