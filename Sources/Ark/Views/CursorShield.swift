import AppKit
import SwiftUI

/// Claims the mouse cursor for the area it covers, without taking clicks.
///
/// The bug it fixes: hovering the floating sidebar shows the *page's* cursor, so
/// a link underneath turns the pointer into a hand. AppKit resolves the cursor by
/// hit-testing real `NSView`s, and SwiftUI's drawn content isn't one — so the
/// search falls straight through the sidebar to the `WKWebView` behind it, which
/// happily reports whatever its own hit-test found.
///
/// Two overrides carry the fix, and they cover different paths:
///   • `resetCursorRects` registers an arrow rect with the window. Cursor rects
///     are resolved by geometry and front-to-back view order, so this one wins
///     over the web view's.
///   • `cursorUpdate` handles the tracking-area path, which WebKit also uses.
///
/// `hitTest` returns nil deliberately. A real `NSView` in a SwiftUI stack sits
/// above the drawn content and would otherwise swallow clicks on the tab rows —
/// the exact hazard that made an earlier attempt at this not worth shipping.
/// Returning nil keeps the view invisible to mouse *events* while it stays
/// visible to cursor resolution.
struct CursorShield: NSViewRepresentable {
    /// The cursor to show. Arrow for chrome; a caret or hand would be wrong here.
    var cursor: NSCursor = .arrow

    func makeNSView(context: Context) -> Shield {
        let view = Shield()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ view: Shield, context: Context) {
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }

    final class Shield: NSView {
        var cursor: NSCursor = .arrow

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func cursorUpdate(with event: NSEvent) {
            cursor.set()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            trackingAreas.forEach(removeTrackingArea)
            // .inVisibleRect keeps the area correct as the panel resizes; without
            // it the rect goes stale the first time the sidebar width changes.
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
            window?.invalidateCursorRects(for: self)
        }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }

        /// Cursor only. Clicks belong to whatever is drawn above.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
