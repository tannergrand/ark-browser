import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import WebKit

/// Detects login forms, fills saved credentials, and offers to save new ones.
/// Storage is the iCloud-synced keychain in `Keychain`; this type is only the
/// page-side plumbing plus the Touch ID gate.
@Observable
final class PasswordManager {
    /// A pending "save this login?" prompt, shown as a banner.
    struct SavePrompt: Identifiable {
        let id = UUID()
        var host: String
        var username: String
        var password: String
        var isUpdate: Bool
    }

    /// Where Ark looks for logins.
    enum Source: String, CaseIterable, Identifiable, Codable {
        case builtin, onePassword
        var id: String { rawValue }
        var label: String {
            switch self {
            case .builtin: return "Ark vault (keychain)"
            case .onePassword: return "1Password, then Ark vault"
            }
        }
    }

    var source: Source = .builtin
    /// Cached Login items from `op`, refreshed on demand. Titles/URLs only.
    @ObservationIgnored private var opItems: [OnePassword.Item] = []
    var opStatus: String?
    /// nil = not checked yet. Mirrors whether 1Password will authorize us.
    var opUnlocked: Bool?
    /// When on, cached secrets live as long as 1Password stays unlocked instead
    /// of expiring on a timer — and are dropped the moment it locks.
    var mirrorOnePasswordLock: Bool = true
    @ObservationIgnored private var lastLockCheck: Date = .distantPast
    @ObservationIgnored private var loadingOPItems = false
    var opAccounts: String?

    var savePrompt: SavePrompt?
    /// Set when a page has a password field and we hold a matching credential.
    var offerFillFor: UUID?
    var lastError: String?

    /// Touch ID unlock, remembered for this long so filling isn't a chore.
    private var unlockedUntil: Date = .distantPast
    var unlockMinutes: Double = 15
    var requireBiometrics: Bool = true

    var isUnlocked: Bool { !requireBiometrics || unlockedUntil > Date() }

    // MARK: - Biometrics

    static var biometricsAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Returns true when the vault is usable. Falls back to the login password
    /// if Touch ID isn't available on this Mac.
    func unlock(reason: String = "unlock your saved passwords") async -> Bool {
        if isUnlocked { return true }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        let policy: LAPolicy = Self.biometricsAvailable
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        do {
            let ok = try await context.evaluatePolicy(policy, localizedReason: reason)
            if ok {
                unlockedUntil = Date().addingTimeInterval(unlockMinutes * 60)
            }
            return ok
        } catch {
            await MainActor.run { lastError = error.localizedDescription }
            return false
        }
    }

    func lock() {
        unlockedUntil = .distantPast
        clearCachedSecrets()
    }

    // MARK: - Fill

    /// Fills the first matching credential into the page's login form.
    ///
    /// This is the only path that reads a password, and it's behind an explicit
    /// user action plus Touch ID — so at most one consent prompt, when asked for.
    @MainActor
    @discardableResult
    func fill(into tab: BrowserTab) async -> Bool {
        guard let host = tab.webView.url?.host else { return false }

        // 1Password first when enabled — it handles its own Touch ID prompt, so
        // Ark's biometric gate is skipped to avoid asking twice.
        if source == .onePassword, OnePassword.isInstalled {
            if await fillFromOnePassword(host: host, into: tab) { return true }
        }

        guard let summary = Keychain.summaries(for: host).first else { return false }
        let cacheKey = "drift-" + summary.id
        if let hit = cached(cacheKey) {
            await fill(hit, into: tab)
            return true
        }
        guard await unlock(reason: "fill your login for \(Keychain.normalize(host: host))") else { return false }
        guard let credential = Keychain.credential(domain: summary.domain,
                                                   username: summary.username) else { return false }
        remember(credential, for: cacheKey)
        await fill(credential, into: tab)
        return true
    }

    /// Returns false (quietly) when 1Password has nothing for this host, so the
    /// caller can fall through to the built-in vault.
    @MainActor
    private func fillFromOnePassword(host: String, into tab: BrowserTab) async -> Bool {
        do {
            try await ensureItems()
            guard let match = OnePassword.bestMatch(for: host, in: opItems) else { return false }
            let login = try await OnePassword.login(itemID: match.id)
            let credential = Keychain.Credential(domain: host,
                                                 username: login.username,
                                                 password: login.password)
            await fill(credential, into: tab)
            opStatus = "Filled from 1Password — \(match.title)"
            return true
        } catch {
            opStatus = error.localizedDescription
            lastError = error.localizedDescription
            return false
        }
    }

    /// Marks the cached item list stale without shelling out.
    ///
    /// This used to run `op vault list` on every activation, which is a separate
    /// 1Password authorization — combined with the launch-time item list, that
    /// was two prompts every time Ark opened. Nothing here talks to `op`; the
    /// next real need refreshes, and the outcome of *that* call tells us whether
    /// 1Password is unlocked.
    @MainActor
    func markOnePasswordStale() {
        guard source == .onePassword else { return }
        itemsStale = true
    }

    /// Loads the item list at most once per TTL, and only when something
    /// actually needs it. Success implies 1Password authorized us.
    @MainActor
    private func ensureItems() async throws {
        let fresh = Date().timeIntervalSince(lastItemLoad) < itemTTL
        if !opItems.isEmpty, fresh, !itemsStale { return }
        opItems = try await OnePassword.loginItems()
        lastItemLoad = Date()
        itemsStale = false
        opUnlocked = true
    }

    @ObservationIgnored private var lastItemLoad: Date = .distantPast
    @ObservationIgnored private var itemsStale = false
    /// Ten minutes: long enough that normal browsing never re-prompts.
    @ObservationIgnored private let itemTTL: TimeInterval = 600

    /// Explicit refresh, used by Settings and after enabling the integration.
    @MainActor
    func refreshOnePassword() async {
        guard OnePassword.isInstalled else {
            opStatus = OnePassword.OPError.notInstalled.localizedDescription
            opAccounts = nil
            return
        }
        do {
            opAccounts = try await OnePassword.checkAccess()
            opItems = try await OnePassword.loginItems()
            opUnlocked = true
            lastLockCheck = Date()
            opStatus = "\(opItems.count) login items available"
        } catch {
            opAccounts = nil
            opUnlocked = false
            opStatus = error.localizedDescription
        }
    }

    /// Does 1Password have a login for this host? Uses the cached list only, so
    /// it never shells out during page rendering.
    @MainActor
    func onePasswordHasMatch(for host: String) -> Bool {
        guard source == .onePassword, !opItems.isEmpty else { return false }
        return OnePassword.bestMatch(for: host, in: opItems) != nil
    }

    @MainActor
    func fill(_ credential: Keychain.Credential, into tab: BrowserTab,
              atContextTarget: Bool = false) async {
        rememberFingerprint(domain: Keychain.normalize(host: credential.domain),
                            username: credential.username, password: credential.password)
        let user = Self.escape(credential.username)
        let pass = Self.escape(credential.password)
        let call = atContextTarget ? "__arkFillTarget" : "__arkFill"
        _ = try? await tab.webView.evaluateJavaScript("window.\(call)('\(user)','\(pass)')")
    }

    /// Silent existence check — attribute-only, so no consent prompt.
    /// Cached per host because the page bridge can ask repeatedly.
    @MainActor
    func hasCredentials(for tab: BrowserTab?) -> Bool {
        guard let host = tab?.webView.url?.host else { return false }
        if onePasswordHasMatch(for: host) { return true }
        let domain = Keychain.normalize(host: host)
        if let cached = hostHasCredentials[domain] { return cached }
        let result = Keychain.hasCredentials(for: domain)
        hostHasCredentials[domain] = result
        return result
    }

    /// Invalidated whenever the vault changes.
    @ObservationIgnored private var hostHasCredentials: [String: Bool] = [:]

    func invalidateHostCache() { hostHasCredentials.removeAll() }

    // MARK: - Autofill menu

    /// One row in the inline dropdown.
    struct Candidate: Identifiable, Hashable {
        enum Origin: String { case drift, onePassword }
        let id: String
        let label: String       // username, or the item title when unknown
        let sublabel: String    // vault name or domain
        let origin: Origin
        let domain: String
        let username: String
        let opItemID: String?
    }

    /// Everything that could fill this host, from both sources. Attribute-only —
    /// no secret is read to build this list.
    @MainActor
    func candidates(for host: String) -> [Candidate] {
        guard !host.isEmpty else { return [] }
        // Load the item list the first time a login field is seen — but only
        // once, and never on a timer. Rendering the menu must not cost an `op`
        // authorization, or opening Ark prompts before you've asked for anything.
        if source == .onePassword, opItems.isEmpty, OnePassword.isInstalled, !loadingOPItems {
            loadingOPItems = true
            Task { @MainActor in
                do { try await ensureItems() }
                catch { opStatus = error.localizedDescription; opUnlocked = false }
                loadingOPItems = false
            }
        }
        var out: [Candidate] = []

        if source == .onePassword {
            for item in OnePassword.matches(for: host, in: opItems) {
                out.append(Candidate(
                    id: "op-" + item.id,
                    label: item.usernameHint ?? item.title,
                    sublabel: item.vault.isEmpty ? "1Password" : "1Password · " + item.vault,
                    origin: .onePassword,
                    domain: Keychain.normalize(host: host),
                    username: item.usernameHint ?? "",
                    opItemID: item.id))
            }
        }
        for summary in Keychain.summaries(for: host) {
            out.append(Candidate(
                id: "drift-" + summary.id,
                label: summary.username,
                sublabel: "Ark vault",
                origin: .drift,
                domain: summary.domain,
                username: summary.username,
                opItemID: nil))
        }
        return out
    }

    /// Fills a chosen row. This is the point a secret is read.
    @MainActor
    func fill(candidate: Candidate, into tab: BrowserTab,
              atContextTarget: Bool = false) async {
        do {
            let cacheKey = candidate.id
            let credential: Keychain.Credential
            if let hit = cached(cacheKey) {
                credential = hit
            } else if let opID = candidate.opItemID {
                let login = try await OnePassword.login(itemID: opID)
                credential = Keychain.Credential(domain: candidate.domain,
                                                 username: login.username,
                                                 password: login.password)
                remember(credential, for: cacheKey)
            } else {
                guard await unlock(reason: "fill your login for " + candidate.domain) else { return }
                guard let found = Keychain.credential(domain: candidate.domain,
                                                     username: candidate.username) else { return }
                credential = found
                remember(credential, for: cacheKey)
            }
            await fill(credential, into: tab, atContextTarget: atContextTarget)
            tab.autofillAnchor = nil
        } catch {
            lastError = error.localizedDescription
            opStatus = error.localizedDescription
        }
    }

    /// Secrets already unlocked once this session, so filling the same login
    /// again doesn't re-trigger the macOS consent dialog or 1Password auth.
    /// Memory only, never written to disk, and dropped when the vault is locked.
    @ObservationIgnored private var credentialCache: [String: (Keychain.Credential, Date)] = [:]
    var cacheMinutes: Double = 30

    private func cached(_ key: String) -> Keychain.Credential? {
        guard let (credential, stamp) = credentialCache[key] else { return nil }
        // With lock mirroring on, 1Password's own lock state is the expiry, so
        // there's no arbitrary timer to fight. Locking clears the cache.
        if mirrorOnePasswordLock, source == .onePassword, opUnlocked == true {
            return credential
        }
        guard Date().timeIntervalSince(stamp) < cacheMinutes * 60 else {
            credentialCache[key] = nil
            return nil
        }
        return credential
    }

    private func remember(_ credential: Keychain.Credential, for key: String) {
        credentialCache[key] = (credential, Date())
    }

    /// Clears cached secrets as well as the unlock window.
    func clearCachedSecrets() {
        credentialCache.removeAll()
    }

    /// The page blurs the field the instant the native menu is clicked, so
    /// dismissal is delayed and cancelled while the pointer is over the menu.
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    @MainActor
    func scheduleAutofillDismiss(for tab: BrowserTab) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            tab.autofillAnchor = nil
        }
    }

    @MainActor
    func cancelAutofillDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    // MARK: - Save

    /// Called from the page bridge when a login form is submitted.
    func offerToSave(host: String, username: String, password: String) {
        guard !username.isEmpty, !password.isEmpty else { return }
        let domain = Keychain.normalize(host: host)

        // Suppress the repeat prompt without reading the stored secret: compare
        // against fingerprints of what this session already saved or filled.
        // Reading the real password here would trigger a consent dialog on
        // every single login submit, which is exactly the bug this avoids.
        let fingerprint = Self.fingerprint(domain: domain, username: username, password: password)
        if knownFingerprints.contains(fingerprint) { return }

        let existing = Keychain.summaries(for: domain)
        savePrompt = SavePrompt(
            host: domain,
            username: username,
            password: password,
            isUpdate: existing.contains { $0.username == username }
        )
    }

    /// SHA-256 of host+user+password. Never stored on disk, session-only.
    @ObservationIgnored private var knownFingerprints: Set<String> = []

    private static func fingerprint(domain: String, username: String, password: String) -> String {
        let digest = SHA256.hash(data: Data("\(domain)|\(username)|\(password)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func rememberFingerprint(domain: String, username: String, password: String) {
        knownFingerprints.insert(Self.fingerprint(domain: domain, username: username, password: password))
    }

    func confirmSave() {
        guard let prompt = savePrompt else { return }
        let status = Keychain.save(Keychain.Credential(
            domain: prompt.host, username: prompt.username, password: prompt.password))
        if status != errSecSuccess {
            lastError = "Couldn't save to keychain: \(Keychain.describe(status))"
        } else {
            rememberFingerprint(domain: prompt.host, username: prompt.username, password: prompt.password)
            invalidateHostCache()
        }
        savePrompt = nil
    }

    /// "Not Now" also fingerprints, so the same submit doesn't re-ask on every
    /// keystroke or click the page bridge reports.
    func dismissSave() {
        if let prompt = savePrompt {
            rememberFingerprint(domain: prompt.host, username: prompt.username, password: prompt.password)
        }
        savePrompt = nil
    }

    // MARK: - CSV import

    /// Imports a CSV exported from the macOS Passwords app or Safari.
    /// Expected headers include Title/URL/Username/Password in some order.
    struct ImportResult {
        var imported = 0
        var skipped = 0
        var errors: [String] = []
    }

    func importCSV(at url: URL) -> ImportResult {
        var result = ImportResult()
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            result.errors.append("Couldn't read \(url.lastPathComponent)")
            return result
        }
        let rows = Self.parseCSV(raw)
        guard let header = rows.first else { return result }

        let lower = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func column(_ names: [String]) -> Int? {
            for name in names {
                if let idx = lower.firstIndex(of: name) { return idx }
            }
            return nil
        }
        guard let urlCol = column(["url", "website", "site"]),
              let userCol = column(["username", "user", "login", "email"]),
              let passCol = column(["password", "pass"]) else {
            result.errors.append("CSV needs URL, Username, and Password columns.")
            return result
        }

        for row in rows.dropFirst() {
            guard row.count > max(urlCol, max(userCol, passCol)) else { result.skipped += 1; continue }
            let rawHost = row[urlCol]
            let host = URL(string: rawHost)?.host
                ?? rawHost.replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                    .split(separator: "/").first.map(String.init)
                ?? rawHost
            let username = row[userCol]
            let password = row[passCol]
            guard !host.isEmpty, !username.isEmpty, !password.isEmpty else {
                result.skipped += 1
                continue
            }
            let status = Keychain.save(Keychain.Credential(
                domain: host, username: username, password: password))
            if status == errSecSuccess { result.imported += 1 }
            else {
                result.skipped += 1
                let message = Keychain.describe(status)
                if !result.errors.contains(message) { result.errors.append(message) }
            }
        }
        return result
    }

    /// Minimal RFC-4180 reader — handles quoted fields and embedded commas.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        while let ch = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []
                case "\r": break
                default: field.append(ch)
                }
            }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }

    // MARK: - Page bridge

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Injected into every page: reports login forms, exposes a fill function,
    /// and reports submitted credentials so we can offer to save them.
    static let bridgeScript = """
    (() => {
      const send = (msg) => {
        try { window.webkit.messageHandlers.arkPasswords.postMessage(msg); } catch (e) {}
      };

      // Visibility, properly. The old filter was `offsetParent !== null ||
      // el.type === 'password'`, and the second clause made it a no-op for every
      // password field — so hidden fields and honeypots counted, and the fill
      // could land in a trap field instead of the real one.
      const visible = (el) => {
        if (!el || el.disabled || el.readOnly) return false;
        if (el.getAttribute('aria-hidden') === 'true') return false;
        if (el.offsetParent === null && getComputedStyle(el).position !== 'fixed') return false;
        const r = el.getBoundingClientRect();
        if (r.width < 8 || r.height < 8) return false;
        const style = getComputedStyle(el);
        if (style.visibility === 'hidden' || style.display === 'none') return false;
        if (parseFloat(style.opacity || '1') < 0.1) return false;
        return true;
      };

      // Every root worth searching. Login forms live inside shadow DOM often
      // enough (design systems, web components) that ignoring it means missing
      // the field entirely.
      const roots = () => {
        const found = [document];
        const walk = (node) => {
          for (const el of node.querySelectorAll('*')) {
            if (el.shadowRoot) { found.push(el.shadowRoot); walk(el.shadowRoot); }
          }
        };
        try { walk(document); } catch (e) {}
        return found;
      };

      const queryAll = (selector) => {
        const out = [];
        for (const root of roots()) {
          try { out.push(...root.querySelectorAll(selector)); } catch (e) {}
        }
        return out;
      };

      const passwordFields = () => queryAll('input[type=password]').filter(visible);

      // What a field's own markup says it is. `autocomplete` is the one signal
      // the spec actually defines for this, so it outranks every guess below it.
      const autocompleteOf = (el) =>
        (el.getAttribute('autocomplete') || '').toLowerCase().split(' ').pop().trim();

      // Text a human would read as the field's label. Placeholder and
      // aria-label were previously ignored, which is why fields whose name and
      // id are opaque hashes went unrecognised.
      const labelText = (el) => {
        let text = (el.getAttribute('placeholder') || '') + ' ' +
                   (el.getAttribute('aria-label') || '') + ' ' +
                   (el.name || '') + ' ' + (el.id || '');
        if (el.id) {
          try {
            const tag = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
            if (tag) text += ' ' + tag.innerText;
          } catch (e) {}
        }
        const wrapping = el.closest('label');
        if (wrapping) text += ' ' + wrapping.innerText;
        return text.toLowerCase();
      };

      const userFieldFor = (pw) => {
        const scope = pw.form || pw.getRootNode();
        let candidates;
        try {
          candidates = Array.from(scope.querySelectorAll('input'));
        } catch (e) {
          candidates = [];
        }
        candidates = candidates.filter(el =>
          el !== pw && visible(el) &&
          !['password','hidden','submit','checkbox','radio','button','file','range'].includes(el.type));
        if (!candidates.length) return null;

        const scored = candidates.map(el => {
          const auto = autocompleteOf(el);
          const hay = labelText(el);
          let score = 0;
          // Decisive: the page declared it.
          if (auto === 'username' || auto === 'email') score += 10;
          if (auto === 'off' || auto === 'new-password') score -= 4;
          if (/user|login|email|account|e-mail|phone|mobile/.test(hay)) score += 3;
          if (el.type === 'email' || el.type === 'tel') score += 2;
          // Position beats keywords: the username sits just above the password.
          // Scored as proximity, not a flat bonus, so a search box further up
          // the page can't outrank the field directly above it.
          const before = el.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING;
          if (before) {
            score += 4;
            const gap = Math.abs(pw.getBoundingClientRect().top - el.getBoundingClientRect().top);
            if (gap < 200) score += 2;
            if (gap < 90) score += 1;
          }
          // Things that are never the username.
          if (/search|query|coupon|promo|zip|postal|card|cvv|otp|code/.test(hay)) score -= 8;
          if (el.getAttribute('role') === 'searchbox' || el.type === 'search') score -= 8;
          return { el, score };
        }).filter(entry => entry.score > 0)
          .sort((a, b) => b.score - a.score);

        return scored.length ? scored[0].el : null;
      };

      // A registration or change-password form, rather than a login. Two or more
      // password fields, or a field the page marks as new-password. Offering to
      // fill a saved password into "choose a new password" is wrong, so these
      // are reported but never auto-offered.
      const isNewPasswordForm = () => {
        const pws = passwordFields();
        if (pws.length >= 2) return true;
        return pws.some(pw => autocompleteOf(pw) === 'new-password');
      };

      const setValue = (el, value) => {
        if (!el) return;
        const proto = el instanceof HTMLTextAreaElement
          ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };

      // Right-click target. Remembered so "Fill Login" from the context menu
      // fills the field that was actually clicked — on multi-step logins the
      // page's first password field is often not the one in front of you.
      let contextTarget = null;
      const fillableField = (el) => {
        if (!el || el.tagName !== 'INPUT') return false;
        if (el.disabled || el.readOnly) return false;
        return ['text', 'email', 'tel', 'password', ''].includes((el.type || '').toLowerCase());
      };
      document.addEventListener('contextmenu', (e) => {
        contextTarget = fillableField(e.target) ? e.target : null;
        if (contextTarget) send({ type: 'contextField' });
      }, true);

      window.__arkFillTarget = (username, password) => {
        const el = contextTarget;
        if (!el) return window.__arkFill(username, password);
        if ((el.type || '').toLowerCase() === 'password') {
          setValue(el, password);
          const partner = userFieldFor(el);
          if (partner && !partner.value) setValue(partner, username);
        } else {
          setValue(el, username);
          // Nearest password field after the clicked one, so a two-field form
          // completes in one action.
          const scope = el.form || document;
          const pw = Array.from(scope.querySelectorAll('input[type=password]'))
            .find(p => visible(p));
          if (pw) setValue(pw, password);
        }
        el.focus();
        return true;
      };

      window.__arkFill = (username, password) => {
        const pws = passwordFields();
        if (!pws.length) return false;
        const pw = pws[0];
        setValue(userFieldFor(pw), username);
        setValue(pw, password);
        pw.focus();
        return true;
      };

      // Report a login form AT MOST ONCE per page. The previous version fired
      // on every DOM mutation, and each report triggered a keychain lookup —
      // which is what produced the storm of macOS consent prompts.
      let reported = false;
      const report = () => {
        if (reported) return;
        if (!passwordFields().length) return;
        reported = true;
        if (isNewPasswordForm()) return;   // signing up, not signing in
        send({ type: 'formFound' });
      };

      // SPA route changes replace the whole form without a page load, so the
      // one-shot detection above would never fire again. Re-arm on navigation.
      const rearm = () => {
        reported = false;
        setTimeout(report, 350);
      };
      for (const method of ['pushState', 'replaceState']) {
        const original = history[method];
        history[method] = function () {
          const result = original.apply(this, arguments);
          rearm();
          return result;
        };
      }
      window.addEventListener('popstate', rearm);

      // Capture on submit — and on click of likely submit buttons, since many
      // sites log in over fetch() without ever firing a submit event.
      let lastSent = '';
      const capture = () => {
        const pws = passwordFields();
        if (!pws.length) return;
        const pw = pws[0];
        const user = userFieldFor(pw);
        if (!pw.value) return;
        const username = user ? user.value : '';
        // Enter-key and click handlers both fire for one login; send once.
        const key = username + String.fromCharCode(31) + pw.value;
        if (key === lastSent) return;
        lastSent = key;
        send({ type: 'submit', username: username, password: pw.value });
      };

      // --- inline autofill menu: report which login field is focused, and where
      let watched = [];
      const computeWatched = () => {
        watched = [];
        const pws = passwordFields();
        if (!pws.length) return;
        const pw = pws[0];
        watched.push({ el: pw, kind: 'password' });
        const u = userFieldFor(pw);
        if (u) watched.push({ el: u, kind: 'username' });
      };
      const anchorFor = (el) => {
        const r = el.getBoundingClientRect();
        return { x: r.left, y: r.top, w: r.width, h: r.height };
      };
      const watchedEntry = (el) => watched.find((w) => w.el === el);

      const announce = (el) => {
        computeWatched();
        const hit = watchedEntry(el);
        if (!hit) return;
        send({ type: 'fieldFocus', kind: hit.kind, rect: anchorFor(el) });
      };
      document.addEventListener('focusin', (e) => announce(e.target), true);
      // Clicking a field that already has focus fires no focus event at all.
      document.addEventListener('click', (e) => announce(e.target), true);
      document.addEventListener('focusout', (e) => {
        if (watchedEntry(e.target)) send({ type: 'fieldBlur' });
      }, true);
      const dropAnchor = () => send({ type: 'fieldBlur' });
      window.addEventListener('scroll', dropAnchor, true);
      window.addEventListener('resize', dropAnchor, true);

      document.addEventListener('submit', capture, true);
      document.addEventListener('click', (e) => {
        const t = e.target.closest('button, input[type=submit], [role=button]');
        if (!t) return;
        const label = (t.innerText || t.value || '').toLowerCase();
        if (/log ?in|sign ?in|continue|submit|next/.test(label)) setTimeout(capture, 0);
      }, true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') setTimeout(capture, 0);
      }, true);

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', report);
      } else {
        report();
      }
      // Watch only until a form is found, debounced, then disconnect entirely.
      let timer = null;
      const observer = new MutationObserver(() => {
        if (reported) { observer.disconnect(); return; }
        if (timer) return;
        timer = setTimeout(() => {
          timer = null;
          report();
          if (reported) observer.disconnect();
        }, 400);
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
    })();
    """
}

/// Routes page messages to the manager without the page retaining a tab.
final class PasswordBridge: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    init(tab: BrowserTab) { self.tab = tab }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        Task { @MainActor in
            guard let tab = self.tab, let manager = tab.state?.passwords else { return }
            switch type {
            case "formFound":
                if manager.hasCredentials(for: tab) { manager.offerFillFor = tab.id }
            case "contextField":
                tab.contextFieldAt = Date()
            case "fieldFocus":
                guard let rect = body["rect"] as? [String: Any] else { return }
                let anchor = CGRect(x: rect["x"] as? Double ?? 0,
                                    y: rect["y"] as? Double ?? 0,
                                    width: rect["w"] as? Double ?? 0,
                                    height: rect["h"] as? Double ?? 0)
                manager.cancelAutofillDismiss()
                tab.autofillAnchor = anchor
                tab.autofillKind = body["kind"] as? String
            case "fieldBlur":
                manager.scheduleAutofillDismiss(for: tab)
            case "submit":
                guard let host = tab.webView.url?.host else { return }
                manager.offerToSave(host: host,
                                    username: body["username"] as? String ?? "",
                                    password: body["password"] as? String ?? "")
            default:
                break
            }
        }
    }
}
