import AppKit
import WebKit

/// The concrete web view type for every tab.
///
/// Also the host for the page context menu. On macOS there is no `WKUIDelegate`
/// hook for this — the iOS `contextMenuConfiguration` API has no counterpart —
/// so the only supported route is overriding `willOpenMenu` on a subclass.
final class ArkWebView: WKWebView {
    /// Set by the owning tab, so the menu can reach the vault.
    weak var tab: BrowserTab?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let tab, let state = tab.state else { return }
        // The page tells us whether the click landed in a fillable field; that
        // message arrives just before the menu opens, hence the freshness check.
        guard tab.contextFieldFresh else { return }
        let candidates = state.passwords.candidates(for: tab.host ?? "")
        guard !candidates.isEmpty else { return }

        let item = NSMenuItem(title: candidates.count == 1
                              ? "Fill Login — \(candidates[0].label)"
                              : "Fill Login", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)

        if candidates.count == 1 {
            item.action = #selector(fillFromMenu(_:))
            item.target = self
            item.representedObject = candidates[0].id
        } else {
            let submenu = NSMenu()
            for candidate in candidates {
                let row = NSMenuItem(title: candidate.label.isEmpty
                                     ? candidate.sublabel
                                     : "\(candidate.label) — \(candidate.sublabel)",
                                     action: #selector(fillFromMenu(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = candidate.id
                submenu.addItem(row)
            }
            item.submenu = submenu
        }

        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func fillFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let tab, let state = tab.state else { return }
        Task { @MainActor in
            let candidates = state.passwords.candidates(for: tab.host ?? "")
            guard let candidate = candidates.first(where: { $0.id == id }) else { return }
            // Fills the field that was right-clicked, not just the first login
            // field on the page — the two are often different on multi-step and
            // multi-account forms.
            await state.passwords.fill(candidate: candidate, into: tab, atContextTarget: true)
        }
    }
}
