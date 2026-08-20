import AppKit
import Foundation
import Observation
import SwiftUI
import WebKit

/// Where a tab lives in the sidebar. Drives peek behavior and archiving.
enum TabTier: String, Codable {
    case favorite   // global icon row, never archived
    case pinned     // permanent list, ⌘W resets instead of closing
    case today      // ephemeral, auto-archived
}

/// One tab. Owns its WKWebView for the life of the tab so switching tabs
/// never reloads the page — the view is swapped, not rebuilt.
@Observable
final class BrowserTab: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id: UUID

    var title: String = "New Tab"
    var urlString: String = ""
    var isLoading: Bool = false
    var progress: Double = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var faviconHost: String? = nil
    /// Approximate count of resources the blocker prevented from loading.
    var blockedCount: Int = 0

    var tier: TabTier = .today
    /// The URL a pinned tab snaps back to on ⌘W or "Reset".
    var pinnedURL: String?
    var lastAccessed: Date = Date()
    /// Renaming a tab keeps the custom label even as the page title changes.
    var customTitle: String?
    /// An emoji shown in place of the favicon, Arc/Zen style. Nil uses the site
    /// icon — which is the right default; this is for the handful of tabs you
    /// want to find without reading.
    var emoji: String?

    /// Set while this tab is being shown as a peek overlay.
    var isPeek: Bool = false

    /// Dominant colour of the page, used to tint the sidebar.
    ///
    /// Sourced from `WKWebView.themeColor` (the page's `<meta name="theme-color">`)
    /// which is free — no pixel sampling — and falls back to the computed body
    /// background when a site doesn't declare one. Near-white, near-black and
    /// grey results are discarded, since tinting by those muddies the chrome.
    var themeTint: Color?
    /// The raw winner behind `themeTint`, kept so a later candidate on the same
    /// page can only replace it by being *more* saturated.
    @ObservationIgnored private var tintSource: TintCandidate?

    /// Snoozed: the page has been torn down to reclaim memory, and the tab is a
    /// placeholder until you click it.
    ///
    /// WebKit gives every tab its own WebContent process, and the page's DOM and
    /// JS heap are the bulk of it — so pointing an idle tab at `about:blank`
    /// returns most of that memory without losing the tab. Position in history
    /// and scroll offset survive via `interactionState`, which is exactly what it
    /// is for; the URL alone would reload the page at the top with no back stack.
    var isSnoozed: Bool = false
    @ObservationIgnored private var sleepingState: Any?
    @ObservationIgnored private var sleepingURL: URL?

    /// Frees the page. Returns false when the tab isn't a candidate — nothing
    /// loaded, already asleep, or playing media, which is the one case where a
    /// background tab is doing something you'd notice.
    @MainActor
    func snooze() async -> Bool {
        guard !isSnoozed, let url = webView.url, url.scheme?.hasPrefix("http") == true
        else { return false }
        if await isPlayingMedia() { return false }

        sleepingURL = url
        if #available(macOS 14.0, *) { sleepingState = webView.interactionState }
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        isSnoozed = true
        return true
    }

    /// Restores the page. Called when the tab is shown again.
    @MainActor
    func wake() {
        guard isSnoozed else { return }
        isSnoozed = false
        if #available(macOS 14.0, *), let state = sleepingState {
            webView.interactionState = state
            sleepingState = nil
            // interactionState restores the back/forward list and scroll, but a
            // restore does not always kick off a load — reload if nothing came
            // back within a beat.
            let target = sleepingURL
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.webView.url == nil || self.webView.url?.scheme == "about"
                else { return }
                if let target { self.webView.load(URLRequest(url: target)) }
            }
        } else if let target = sleepingURL {
            webView.load(URLRequest(url: target))
        }
        sleepingURL = nil
        lastAccessed = Date()
    }

    /// Media playback, so a snooze sweep can't silence something.
    @MainActor
    private func isPlayingMedia() async -> Bool {
        await withCheckedContinuation { continuation in
            webView.requestMediaPlaybackState { state in
                continuation.resume(returning: state == .playing)
            }
        }
    }

    /// When the page last reported a right-click inside a fillable text field.
    /// Time-boxed because the context menu can outlive the click that opened it,
    /// and a stale flag would put "Fill Login" on menus that aren't in a field.
    @ObservationIgnored var contextFieldAt: Date?
    var contextFieldFresh: Bool {
        guard let contextFieldAt else { return false }
        return Date().timeIntervalSince(contextFieldAt) < 2
    }

    /// Viewport rect (CSS px) of the login field the page has focused, and
    /// whether it's the username or password box. Drives the autofill menu.
    var autofillAnchor: CGRect?
    var autofillKind: String?

    var displayTitle: String { customTitle ?? title }

    @ObservationIgnored let webView: ArkWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored weak var state: BrowserState?

    init(id: UUID = UUID(), url: URL? = nil, state: BrowserState? = nil,
         tier: TabTier = .today, dataStore: WKWebsiteDataStore = .default()) {
        self.id = id
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.isElementFullscreenEnabled = true
        self.webView = ArkWebView(frame: .zero, configuration: config)
        self.state = state
        self.tier = tier
        super.init()

        webView.tab = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = BrowserTab.userAgent
        // Painted in any area exposed before the page has re-laid out. Without
        // this, resizing a split pane flashes white on every frame.
        webView.underPageBackgroundColor = .textBackgroundColor

        installBlockCounter()
        installPasswordBridge()
        installNavBridge()
        observe()

        if let url {
            load(url)
            if tier != .today { pinnedURL = url.absoluteString }
        }
    }

    deinit { observations.forEach { $0.invalidate() } }

    // MARK: - Navigation

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Treats input as a URL when it looks like one, otherwise searches.
    func navigate(to input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        load(BrowserTab.resolve(text))
    }

    static func resolve(_ text: String) -> URL {
        if let url = URL(string: text), let scheme = url.scheme,
           ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        let looksLikeHost = !text.contains(" ")
            && text.contains(".")
            && !text.hasPrefix(".")
            && !text.hasSuffix(".")
        if looksLikeHost, let url = URL(string: "https://\(text)") {
            return url
        }
        return SearchEngine.current.url(for: text)
    }

    // MARK: - Zoom

    private static let zoomSteps: [Double] = [0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    func zoomIn() { stepZoom(1) }
    func zoomOut() { stepZoom(-1) }
    func resetZoom() { webView.pageZoom = 1.0 }

    private func stepZoom(_ direction: Int) {
        let current = webView.pageZoom
        let steps = Self.zoomSteps
        let nearest = steps.enumerated().min {
            abs($0.element - current) < abs($1.element - current)
        }?.offset ?? 4
        let next = max(0, min(steps.count - 1, nearest + direction))
        webView.pageZoom = steps[next]
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reloadFromOrigin() }
    func stop() { webView.stopLoading() }

    /// Returns a pinned tab to its pinned URL and drops its back/forward stack.
    func resetToPinned() {
        guard let str = pinnedURL, let url = URL(string: str) else { return }
        load(url)
    }

    var host: String? { webView.url?.host }

    // MARK: - Page tint

    /// Keeps a colour only if it's saturated enough to be worth tinting with.
    @MainActor
    private func adoptTint(_ color: NSColor?) {
        guard let color else { return }
        consider([color])
    }

    /// Merges new candidate colours into the running best for this page.
    ///
    /// "Best" means highest-scoring, not first found. Runtime tracing showed why:
    /// the sites in actual use hand back `#f4f2ee` (LinkedIn), `#454545`
    /// (Atlassian), `#0d1117` (GitHub) and plain white. A first-match rule
    /// therefore locked onto a neutral and the sidebar never coloured, which
    /// read as the feature being broken.
    @MainActor
    private func consider(_ colors: [NSColor]) {
        for color in colors {
            guard let candidate = BrowserTab.tintCandidate(color) else {
                TintLog.say("reject \(BrowserTab.describe(color)) on \(webView.url?.host ?? "-")")
                continue
            }
            if candidate.score > (tintSource?.score ?? 0) {
                tintSource = candidate
                themeTint = BrowserTab.presentable(candidate)
                TintLog.say("accept \(BrowserTab.describe(color)) sat=\(String(format: "%.2f", candidate.saturation)) score=\(String(format: "%.2f", candidate.score)) on \(webView.url?.host ?? "-")")
            }
        }
    }

    /// A colour that survived the gate, with the score that ranked it.
    struct TintCandidate {
        let color: NSColor
        let saturation: Double
        let score: Double
    }

    /// Accepts anything with a *hue worth using*, whatever its lightness.
    ///
    /// The old gate demanded mid brightness and saturation ≥ 0.12, which threw
    /// away GitHub's near-black navy and every off-white. Lightness is no longer
    /// a reason to reject, because `presentable(_:)` normalises it afterwards —
    /// only a genuinely monochrome colour (no hue to borrow) is rejected.
    static func tintCandidate(_ color: NSColor?) -> TintCandidate? {
        guard let converted = color?.usingColorSpace(.sRGB) else { return nil }
        guard converted.alphaComponent > 0.5 else { return nil }
        let saturation = Double(converted.saturationComponent)
        guard saturation > 0.045 else { return nil }
        // Saturation alone is the wrong ranking: in HSB a near-black navy scores
        // higher than a vivid purple, which is how Stripe's #061B31 (sat 0.88)
        // beat its own #533AFD (sat 0.77). Dark colours are discounted, because
        // `presentable(_:)` has to invent most of their lightness — the hue is
        // there but thin. Light-but-vivid colours are not penalised: they keep a
        // hue worth borrowing.
        let brightness = Double(converted.brightnessComponent)
        let weight = min(max((brightness - 0.10) / 0.35, 0.25), 1)
        let score = saturation * weight
        return TintCandidate(color: converted, saturation: saturation, score: score)
    }

    /// Normalises a page colour into something that actually reads as a tint.
    ///
    /// Sites hand over extremes — a near-black navy or a barely-off white. Used
    /// literally, both wash out to nothing behind a translucent panel. The hue
    /// is the part worth keeping, so saturation is lifted to a floor and
    /// lightness pulled into a usable band while the hue is left untouched.
    static func presentable(_ candidate: TintCandidate) -> Color {
        let source = candidate.color
        let hue = Double(source.hueComponent)
        let saturation = max(Double(source.saturationComponent), 0.42)
        let brightness = min(max(Double(source.brightnessComponent), 0.52), 0.86)
        return Color(nsColor: NSColor(hue: hue, saturation: saturation,
                                     brightness: brightness, alpha: 1))
    }

    static func describe(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "?" }
        return String(format: "#%02X%02X%02X",
                      Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }

    /// Asks the page for every colour worth considering, not just the first one.
    ///
    /// Brand colour usually lives in a link, a primary button or `accent-color`
    /// rather than in the page background — which is why background-only
    /// probing produced grey after grey.
    @MainActor
    private func inferTintFromPage() {
        webView.evaluateJavaScript(BrowserTab.tintProbeScript) { [weak self] value, error in
            guard let text = value as? String, !text.isEmpty else {
                TintLog.say("probe empty: err=\(String(describing: error))")
                return
            }
            TintLog.say("probe returned \(text)")
            let colors = text.split(separator: "|").compactMap {
                BrowserTab.parseCSSColor(String($0))
            }
            Task { @MainActor in self?.consider(colors) }
        }
    }

    static let tintProbeScript = """
    (() => {
      const out = [];
      const push = (c) => {
        if (!c) return;
        if (c === 'transparent' || c.indexOf('rgba(0, 0, 0, 0)') === 0) return;
        out.push(c);
      };
      const meta = document.querySelector('meta[name="theme-color"]');
      if (meta) push(meta.getAttribute('content'));

      // Backgrounds: the page's own surfaces.
      for (const sel of ['header', 'nav', '[role=banner]', 'body', 'html']) {
        const el = document.querySelector(sel);
        if (el) push(getComputedStyle(el).backgroundColor);
      }

      // Brand colour: usually a link, a primary button, or accent-color.
      const root = getComputedStyle(document.documentElement);
      push(root.accentColor);
      const inked = [];
      for (const el of document.querySelectorAll('a, button, [type=submit]')) {
        const style = getComputedStyle(el);
        const box = el.getBoundingClientRect();
        if (box.width < 8 || box.height < 8) continue;
        inked.push(style.backgroundColor, style.color, style.borderTopColor);
        if (inked.length > 90) break;
      }
      inked.forEach(push);
      return out.join('|');
    })()
    """

    /// Parses `#rgb`, `#rrggbb`, `rgb(...)` and `rgba(...)`.
    static func parseCSSColor(_ text: String) -> NSColor? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            var hex = String(trimmed.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
            return NSColor(srgbRed: Double((value >> 16) & 0xFF) / 255,
                           green: Double((value >> 8) & 0xFF) / 255,
                           blue: Double(value & 0xFF) / 255, alpha: 1)
        }
        guard let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")") else {
            return nil
        }
        let parts = trimmed[trimmed.index(after: open)..<close]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        if parts.count >= 4, parts[3] < 0.5 { return nil }
        return NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255,
                       blue: parts[2] / 255, alpha: 1)
    }

    // MARK: - Find in page

    func find(_ query: String, forward: Bool = true) async -> Bool {
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.wraps = true
        config.caseSensitive = false
        return await withCheckedContinuation { cont in
            webView.find(query, configuration: config) { result in
                cont.resume(returning: result.matchFound)
            }
        }
    }

    /// Pulls the readable text of the page for the AI sidebar.
    func pageText() async -> String {
        let js = """
        (() => {
          const el = document.querySelector('article, main') || document.body;
          if (!el) return '';
          return el.innerText.replace(/\\n{3,}/g, '\\n\\n').slice(0, 60000);
        })()
        """
        return await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { value, _ in
                cont.resume(returning: value as? String ?? "")
            }
        }
    }

    // MARK: - KVO

    private func observe() {
        observations = [
            // Title, URL and favicon are frozen while snoozed. Loading
            // about:blank fires both of these, which renamed every snoozed tab
            // to "New Tab" and blanked its URL — losing exactly the identity the
            // placeholder row needs to keep.
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in
                    guard let self, !self.isSnoozed else { return }
                    let t = wv.title ?? ""
                    self.title = t.isEmpty ? (wv.url?.host ?? "New Tab") : t
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in
                    guard let self, !self.isSnoozed else { return }
                    self.urlString = wv.url?.absoluteString ?? ""
                    self.faviconHost = wv.url?.host
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in
                    guard let self else { return }
                    // A snoozed tab is not "loading"; showing a spinner on the
                    // row would be a lie about what it's doing.
                    self.isLoading = self.isSnoozed ? false : wv.isLoading
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.themeColor, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.adoptTint(wv.themeColor) }
            }
        ]
    }

    // MARK: - Block counting (approximate)

    /// WKContentRuleList gives no block callbacks, so we listen for resource
    /// load failures instead. Close, but not authoritative — the UI says so.
    private func installBlockCounter() {
        let script = WKUserScript(source: """
        (() => {
          let n = 0;
          window.addEventListener('error', (e) => {
            const t = e.target;
            if (!t || !t.tagName) return;
            if (!['IMG','SCRIPT','IFRAME','LINK','VIDEO'].includes(t.tagName)) return;
            n++;
            window.webkit.messageHandlers.arkBlocked.postMessage(n);
          }, true);
        })()
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        webView.configuration.userContentController.addUserScript(script)
        webView.configuration.userContentController.add(BlockCounterProxy(tab: self), name: "arkBlocked")
    }

    /// Shift-click (peek) and cmd/middle-click (background tab) are caught in
    /// the page rather than in `decidePolicyFor`, because WebKit does not
    /// reliably surface modifier flags on `.linkActivated` — which is why
    /// shift-click peek silently did nothing.
    private func installNavBridge() {
        let script = WKUserScript(source: BrowserTab.navBridgeScript,
                                  injectionTime: .atDocumentStart, forMainFrameOnly: false)
        webView.configuration.userContentController.addUserScript(script)
        webView.configuration.userContentController.add(NavBridge(tab: self), name: "arkNav")
    }

    static let navBridgeScript = """
    (() => {
      const post = (type, href) => {
        try {
          window.webkit.messageHandlers.arkNav.postMessage({ type: type, href: href });
        } catch (e) {}
      };
      const linkFrom = (target) => {
        if (!target) return null;
        if (target.closest) return target.closest('a[href]');
        return null;
      };
      const usable = (a) => {
        if (!a) return null;
        const href = a.href;
        if (!href) return null;
        if (href.indexOf('javascript:') === 0) return null;
        if (href.indexOf('#') === 0) return null;
        return href;
      };

      document.addEventListener('click', (e) => {
        const href = usable(linkFrom(e.target));
        if (!href) return;
        if (e.shiftKey) {
          e.preventDefault();
          e.stopImmediatePropagation();
          post('peek', href);
        } else if (e.metaKey) {
          e.preventDefault();
          e.stopImmediatePropagation();
          post('newTab', href);
        }
      }, true);

      document.addEventListener('auxclick', (e) => {
        if (e.button !== 1) return;
        const href = usable(linkFrom(e.target));
        if (!href) return;
        e.preventDefault();
        post('newTab', href);
      }, true);
    })();
    """

    /// Login-form detection, fill, and save-prompt plumbing.
    private func installPasswordBridge() {
        let script = WKUserScript(source: PasswordManager.bridgeScript,
                                  injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(script)
        webView.configuration.userContentController.add(PasswordBridge(tab: self), name: "arkPasswords")
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    // MARK: - WKNavigationDelegate

    /// Routes link clicks: ⇧ peeks, ⌘ opens a background tab, and links that
    /// leave a pinned tab's site peek rather than navigating it away.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated,
              let url = action.request.url,
              url.scheme?.hasPrefix("http") == true else {
            decisionHandler(.allow)
            return
        }

        let mods = action.modifierFlags
        if mods.contains(.shift) {
            decisionHandler(.cancel)
            Task { @MainActor in state?.peek(url) }
            return
        }
        if mods.contains(.command) {
            decisionHandler(.cancel)
            Task { @MainActor in state?.openInNewTab(url, activate: false) }
            return
        }
        // A pinned tab is a fixed destination; offsite links peek instead.
        if tier != .today, !isPeek, let home = pinnedURL,
           let homeHost = URL(string: home)?.host, url.host != homeHost {
            decisionHandler(.cancel)
            Task { @MainActor in state?.peek(url) }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            blockedCount = 0
            // Clear the old tint so the sidebar fades between pages rather than
            // jumping straight from one site's colour to the next.
            themeTint = nil
            tintSource = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, url.scheme?.hasPrefix("http") == true else { return }
        let title = webView.title ?? url.host ?? url.absoluteString
        Task { @MainActor in
            state?.recordVisit(url: url, title: title)
            inferTintFromPage()
        }
    }

    // Downloads: hand both link-initiated and response-initiated ones to the
    // manager, which picks a unique destination in ~/Downloads.
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        state?.downloads.register(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        state?.downloads.register(download)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open land in a new tab, not a popup window.
        if let url = navigationAction.request.url {
            Task { @MainActor in state?.openInNewTab(url) }
        }
        return nil
    }
}

/// Routes shift/cmd/middle link clicks from the page.
private final class NavBridge: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    init(tab: BrowserTab) { self.tab = tab }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let href = body["href"] as? String,
              let url = URL(string: href) else { return }
        Task { @MainActor in
            guard let state = self.tab?.state else { return }
            switch type {
            case "peek": state.peek(url)
            case "newTab": state.openInNewTab(url, activate: false)
            default: break
            }
        }
    }
}

/// Separate object so the tab isn't retained by the user content controller.
private final class BlockCounterProxy: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    init(tab: BrowserTab) { self.tab = tab }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let n = message.body as? Int else { return }
        Task { @MainActor in self.tab?.blockedCount = n }
    }
}
