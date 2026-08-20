import AppKit
import SwiftUI

/// A strip that behaves like a title bar: drag to move the window, double-click
/// to zoom.
///
/// Ark uses `.hiddenTitleBar`, so there is no system title bar to receive
/// either gesture — they have to be implemented. Note this does *not* use
/// `mouseDownCanMoveWindow`: with that set, the window server takes over the
/// drag and the view stops receiving `mouseUp`, which is exactly where the
/// double-click has to be detected. Calling `performDrag` from `mouseDragged`
/// keeps both working.
struct WindowChromeArea: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeStrip { ChromeStrip() }
    func updateNSView(_ view: ChromeStrip, context: Context) {}

    final class ChromeStrip: NSView {
        override func mouseDown(with event: NSEvent) {
            // Swallowed deliberately; the work happens on drag or on mouse-up.
        }

        override func mouseDragged(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            guard event.clickCount >= 2 else {
                super.mouseUp(with: event)
                return
            }
            performDoubleClickAction()
        }

        /// Honours System Settings ▸ Desktop & Dock ▸ "Double-click a window's
        /// title bar to". Unset means Maximize, which is the macOS default.
        private func performDoubleClickAction() {
            guard let window else { return }
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            switch action {
            case "Minimize":
                window.performMiniaturize(nil)
            case "None":
                break
            default:
                window.zoom(nil)
            }
        }

        /// Let clicks through to anything layered on top of this strip.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? self : hit
        }
    }
}


/// Configures the hosting window: mouse tracking plus true edge-to-edge content.
///
/// Two things, both of which need AppKit:
///
/// 1. `acceptsMouseMovedEvents` — without it macOS never generates `mouseMoved`,
///    so the left-edge sidebar reveal could not fire. A local event monitor is
///    used rather than SwiftUI `.onHover` on a thin strip, because the WKWebView
///    sits on top and swallows hover.
/// 2. `fullSizeContentView` + a transparent titlebar. `.hiddenTitleBar` hides the
///    bar but still lets the content view start *below* it, which showed up as a
///    band of empty white across the top of the window. With these set, content
///    reaches y=0 and the traffic lights float over it.
struct WindowMouseTracking: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowConfigurator() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class WindowConfigurator: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            // A toolbar would re-reserve the height we just reclaimed.
            window.toolbar = nil
            // Drag is handled by WindowChromeArea, so the whole background
            // must not be draggable — that would swallow clicks on pages.
            window.isMovableByWindowBackground = false
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
