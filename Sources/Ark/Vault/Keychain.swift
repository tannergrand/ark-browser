import Foundation
import Security

/// Keychain access for two separate things:
///
/// 1. Ark's own API key — a generic password, local to this Mac.
/// 2. Website credentials — internet passwords written with
///    `kSecAttrSynchronizable`, which is what puts them in the **iCloud
///    Keychain** and syncs them to the user's other Macs.
///
/// Important limitation, stated plainly: this can read and write *Ark's own*
/// items. macOS gives no third-party app a way to read Safari's or the Passwords
/// app's saved website passwords — that data sits behind private Apple
/// entitlements. No third-party browser on macOS can do it.
enum Keychain {
    /// Deliberately still the old identifier after the rename to Ark. This is
    /// the lookup key for every credential already in the keychain — renaming it
    /// would orphan them all, silently, with the items still on disk. Same for
    /// the security domain below. These are opaque keys, not branding.
    static let service = "com.tannergrandstaff.drift"
    private static let apiKeyAccount = "anthropic-api-key"

    // MARK: - API key (local only, deliberately not synced)

    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: apiKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Attribute-only existence check — silent, no consent prompt.
    static func hasAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: apiKeyAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    @discardableResult
    static func writeAPIKey(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: apiKeyAccount
        ]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return true }
        var attrs = base
        attrs[kSecValueData as String] = Data(key.utf8)
        attrs[kSecAttrLabel as String] = "Ark — Anthropic API key"
        attrs[kSecAttrAccessible as String] = nil
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func deleteAPIKey() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: apiKeyAccount
        ] as CFDictionary)
    }

    // MARK: - Website credentials (synced through iCloud Keychain)

    struct Credential: Identifiable, Hashable {
        var id: String { "\(domain)|\(username)" }
        var domain: String
        var username: String
        var password: String
        var modified: Date?
    }

    /// Whether this build can write iCloud-synced keychain items.
    ///
    /// `kSecAttrSynchronizable: true` is the flag that makes an item an iCloud
    /// Keychain item instead of a local login-keychain one — but writing those
    /// requires an application-identifier entitlement, which in turn requires
    /// signing with a real Apple Developer team identity. An ad-hoc signature
    /// gets `errSecMissingEntitlement` (-34018). Verified on this machine.
    ///
    /// So: probe once, then write synced items if we can and local ones if we
    /// can't. Reads always match both.
    /// Cached across launches — the answer only changes when the app is re-signed,
    /// so probing on every launch is wasted work.
    private(set) static var syncAvailable: Bool = {
        let key = "drift.syncAvailable"
        let signature = "\(Bundle.main.bundleIdentifier ?? "?")|\(teamIdentifier ?? "adhoc")"
        let stampKey = "drift.syncProbeIdentity"
        if UserDefaults.standard.string(forKey: stampKey) == signature {
            return UserDefaults.standard.bool(forKey: key)
        }
        let result = probeSync()
        UserDefaults.standard.set(result, forKey: key)
        UserDefaults.standard.set(signature, forKey: stampKey)
        return result
    }()

    /// Team identifier from our own code signature, nil when ad-hoc signed.
    static var teamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict["teamid"] as? String
    }

    private static func probeSync() -> Bool {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrServer as String: "drift-capability-probe.invalid",
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data("probe".utf8)
        ]
        SecItemDelete(probe as CFDictionary)
        let status = SecItemAdd(probe as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        return status == errSecSuccess
    }

    private static func credentialQuery(domain: String? = nil, username: String? = nil,
                                        forWrite: Bool = false) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            // Scopes every query to Ark's own items, so the vault list never
            // shows unrelated login-keychain entries from other apps.
            kSecAttrSecurityDomain as String: "drift"
        ]
        // Writes must pick one keychain; reads should see both.
        q[kSecAttrSynchronizable as String] = forWrite
            ? (syncAvailable ? kCFBooleanTrue! : kCFBooleanFalse!)
            : kSecAttrSynchronizableAny
        if let domain { q[kSecAttrServer as String] = domain }
        if let username { q[kSecAttrAccount as String] = username }
        return q
    }

    /// Normalizes to a registrable-ish domain so login.example.com and
    /// www.example.com share one credential.
    static func normalize(host: String) -> String {
        var parts = host.lowercased().split(separator: ".").map(String.init)
        // Keep the last two labels, or three for two-part public suffixes.
        let twoPartSuffixes: Set<String> = ["co.uk", "com.au", "co.nz", "co.jp", "com.br", "org.uk"]
        if parts.count > 2 {
            let lastTwo = parts.suffix(2).joined(separator: ".")
            let keep = twoPartSuffixes.contains(lastTwo) ? 3 : 2
            parts = Array(parts.suffix(keep))
        }
        return parts.joined(separator: ".")
    }

    /// Lists matching items by attribute only.
    ///
    /// Asking for `kSecReturnData` together with `kSecMatchLimitAll` fails with
    /// `errSecParam` (-50) — verified on macOS 26. So listing and reading the
    /// secret are two separate calls: attributes in bulk, then one fetch per
    /// item with `kSecMatchLimitOne`.
    private static func list(domain: String?) -> [(server: String, account: String, modified: Date?)] {
        var q = credentialQuery(domain: domain)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            let server = item[kSecAttrServer as String] as? String ?? domain ?? ""
            guard !server.isEmpty else { return nil }
            return (server, account, item[kSecAttrModificationDate as String] as? Date)
        }
    }

    private static func password(domain: String, account: String) -> String? {
        var q = credentialQuery(domain: domain, username: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Domain + username with **no password fetched**.
    ///
    /// This distinction is the whole ballgame for UX: asking for
    /// `kSecReturnData` is what makes macOS show the "wants to use your
    /// confidential information" consent dialog. Attribute-only reads are
    /// silent. So anything that merely needs to know *whether* a login exists
    /// must use a summary, and only an explicit user action may fetch a secret.
    struct Summary: Identifiable, Hashable {
        var id: String { "\(domain)|\(username)" }
        var domain: String
        var username: String
        var modified: Date?
    }

    static func summaries(for host: String) -> [Summary] {
        let domain = normalize(host: host)
        return list(domain: domain).map {
            Summary(domain: domain, username: $0.account, modified: $0.modified)
        }
    }

    static func allSummaries() -> [Summary] {
        list(domain: nil)
            .map { Summary(domain: $0.server, username: $0.account, modified: $0.modified) }
            .sorted { ($0.domain, $0.username) < ($1.domain, $1.username) }
    }

    /// Silent — no consent prompt.
    static func hasCredentials(for host: String) -> Bool {
        !list(domain: normalize(host: host)).isEmpty
    }

    /// Fetches one secret. **Prompts** for consent unless this exact code
    /// identity already has an ACL entry, so call it only from an explicit
    /// user action (fill, or reveal), never from page or UI polling.
    static func credential(domain: String, username: String) -> Credential? {
        let normalized = normalize(host: domain)
        guard let pw = password(domain: normalized, account: username) else { return nil }
        return Credential(domain: normalized, username: username, password: pw)
    }

    /// First stored credential for a host, secret included. Prompts.
    static func firstCredential(for host: String) -> Credential? {
        guard let summary = summaries(for: host).first else { return nil }
        return credential(domain: summary.domain, username: summary.username)
    }

    @discardableResult
    static func save(_ credential: Credential) -> OSStatus {
        let domain = normalize(host: credential.domain)
        let query = credentialQuery(domain: domain, username: credential.username)

        let update: [String: Any] = [
            kSecValueData as String: Data(credential.password.utf8)
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return updateStatus }

        var attrs = credentialQuery(domain: domain, username: credential.username, forWrite: true)
        attrs[kSecValueData as String] = Data(credential.password.utf8)
        attrs[kSecAttrLabel as String] = "\(domain) (Ark)"
        let status = SecItemAdd(attrs as CFDictionary, nil)
        // If the entitlement probe was optimistic, retry locally.
        if status == errSecMissingEntitlement, syncAvailable {
            syncAvailable = false
            var local = credentialQuery(domain: domain, username: credential.username, forWrite: true)
            local[kSecValueData as String] = Data(credential.password.utf8)
            local[kSecAttrLabel as String] = "\(domain) (Ark)"
            return SecItemAdd(local as CFDictionary, nil)
        }
        return status
    }

    @discardableResult
    static func deleteSummary(_ summary: Summary) -> OSStatus {
        SecItemDelete(credentialQuery(domain: normalize(host: summary.domain),
                                      username: summary.username) as CFDictionary)
    }

    @discardableResult
    static func delete(_ credential: Credential) -> OSStatus {
        SecItemDelete(credentialQuery(domain: normalize(host: credential.domain),
                                      username: credential.username) as CFDictionary)
    }

    static func describe(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}
