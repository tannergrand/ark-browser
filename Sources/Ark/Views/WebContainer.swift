import SwiftUI
import WebKit

/// Hosts the active tab's WKWebView. Swaps the subview on tab change so pages
/// keep their scroll position, media, and JS state.
struct WebContainer: NSViewRepresentable {
    let tab: BrowserTab?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let webView = tab?.webView else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard webView.superview !== container else { return }

        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }
}
