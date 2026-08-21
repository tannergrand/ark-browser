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
/// **Cursor rects alone do not fix this**, which is what the first version got
/// wrong. WebKit doesn't rely on cursor rects: it calls `[cursor set]` directly
/// while handling `mouseMoved`, and it receives those events through its own
/// tracking area — which is geometric and doesn't care what is drawn on top. So
/// the page kept re-asserting its cursor a moment after AppKit resolved ours.
///
/// The fix that works is to stop the event reaching the web view at all: a local
/// event monitor swallows `mouseMoved` while the pointer is inside a registered
/// shield, and sets the arrow itself. SwiftUI's `.onHover` uses
/// `mouseEntered`/`mouseExited` tracking areas rather than `mouseMoved`, so row
/// highlighting is unaffected.
///
/// This view's job is therefore twofold: register its frame so the monitor knows
/// where the panel is, and keep the cursor-rect and `cursorUpdate` paths covered
/// for the cases the monitor doesn't see.
///
/// `hitTest` returns nil deliberately. A real `NSView` in a SwiftUI stack sits
/// above the drawn content and would otherwise swallow clicks on the tab rows —
/// the exact hazard that made an earlier attempt at this not worth shipping.
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

    /// Live shields, so the event monitor can ask where they are. Weak, so a
    /// dismissed panel's shield doesn't keep claiming the cursor.
    private static let registry = Registry()

    final class Registry {
        private var shields: [Weak] = []
        struct Weak { weak var view: Shield? }

        func add(_ shield: Shield) {
            shields.removeAll { $0.view == nil }
            guard !shields.contains(where: { $0.view === shield }) else { return }
            shields.append(Weak(view: shield))
        }

        /// True when a point in window coordinates falls inside a visible shield.
        func contains(windowPoint point: NSPoint, in window: NSWindow) -> Bool {
            shields.removeAll { $0.view == nil }
            for entry in shields {
                guard let view = entry.view, view.window === window,
                      view.superview != nil, !view.isHiddenOrHasHiddenAncestor
                else { continue }
                let frame = view.convert(view.bounds, to: nil)
                if frame.contains(point) { return true }
            }
            return false
        }
    }

    /// Whether the pointer is over chrome that should own the cursor.
    static func coversPointer(_ point: NSPoint, in window: NSWindow) -> Bool {
        registry.contains(windowPoint: point, in: window)
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
            CursorShield.registry.add(self)
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
