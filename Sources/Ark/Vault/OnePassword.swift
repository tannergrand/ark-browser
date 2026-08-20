import Foundation

/// Integration with 1Password through its official CLI, `op`.
///
/// Why the CLI and not the browser extension or the native helper:
/// WebKit has no extension system, and 1Password's browser helper verifies the
/// calling browser's code signature on purpose. `op` is the supported surface
/// for exactly this — auth is handled by the 1Password app (Touch ID), and no
/// secret is ever passed on a command line.
enum OnePassword {
    // MARK: - Discovery

    /// Common install locations, plus whatever is on PATH.
    private static let candidatePaths = [
        "/opt/homebrew/bin/op",
        "/usr/local/bin/op",
        "/opt/homebrew/opt/1password-cli/bin/op"
    ]

    static var binaryPath: String? {
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to PATH lookup without a shell.
        guard let pathVar = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathVar.split(separator: ":") {
            let candidate = "\(dir)/op"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static var isInstalled: Bool { binaryPath != nil }

    enum OPError: LocalizedError {
        case notInstalled
        case notSignedIn(String)
        case cli(String)
        case noMatch(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "1Password CLI not found. Install it with: brew install 1password-cli"
            case .notSignedIn(let detail):
                return "1Password CLI isn't authorized. Enable 1Password ▸ Settings ▸ Developer ▸ "
                     + "\"Integrate with 1Password CLI\", then try again. (\(detail))"
            case .cli(let detail):
                return "op failed: \(detail)"
            case .noMatch(let host):
                return "No 1Password login found for \(host)."
            }
        }
    }

    // MARK: - Models

    struct Item: Identifiable, Hashable {
        let id: String
        let title: String
        let vault: String
        /// Hostnames pulled from the item's saved URLs.
        let hosts: [String]
        /// `additional_information` from `op item list` — the username for Login
        /// items. Lets the autofill menu show who it will sign in as without
        /// fetching (and therefore prompting for) the secret.
        let usernameHint: String?
    }

    struct Login {
        let username: String
        let password: String
        let totp: String?
    }

    // MARK: - Process plumbing

    /// Runs `op` and returns stdout. Never logs stdout, since it may hold secrets.
    ///
    /// The timeout matters: if 1Password is locked, `op` can sit waiting for
    /// authorization, and without a bound the calling Task would hang forever.
    private static func run(_ args: [String], timeout: TimeInterval = 25) throws -> Data {
        guard let binary = binaryPath else { throw OPError.notInstalled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        // Ask the desktop app to authorize, rather than prompting for a token.
        env["OP_BIOMETRIC_UNLOCK_ENABLED"] = "true"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Drain both pipes concurrently so a large payload can't deadlock.
        var errData = Data()
        let errQueue = DispatchQueue(label: "drift.op.stderr")
        let group = DispatchGroup()
        group.enter()
        errQueue.async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        // Kill the process if it outlives its budget, so a locked vault can't
        // wedge us. The read below then returns whatever arrived.
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer.cancel()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
            if message.localizedCaseInsensitiveContains("sign in")
                || message.localizedCaseInsensitiveContains("not signed in")
                || message.localizedCaseInsensitiveContains("authoriz")
                || message.localizedCaseInsensitiveContains("no account") {
                throw OPError.notSignedIn(message)
            }
            throw OPError.cli(message)
        }
        return outData
    }

    private static func runAsync(_ args: [String], timeout: TimeInterval = 25) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try run(args, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - Public API

    /// Whether the 1Password app will currently authorize us.
    ///
    /// `op whoami` is NOT the right probe — it reports *token* sessions and
    /// fails with "account is not signed in" even when desktop app integration
    /// is working perfectly. Measured on this machine. `op vault list` needs the
    /// same authorization as a real read but returns only metadata, so it is
    /// the honest cheap check.
    static func isAuthorized() async -> Bool {
        guard isInstalled else { return false }
        do {
            let data = try await runAsync(["vault", "list", "--format", "json"], timeout: 8)
            guard let vaults = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return false
            }
            return !vaults.isEmpty
        } catch {
            return false
        }
    }

    /// Confirms the CLI is authorized, without touching any secret.
    static func checkAccess() async throws -> String {
        let data = try await runAsync(["account", "list", "--format", "json"])
        let accounts = parseAccounts(data)
        guard !accounts.isEmpty else { throw OPError.notSignedIn("no accounts returned") }
        return accounts.joined(separator: ", ")
    }

    /// All Login items, with the hostnames they apply to. No secrets fetched.
    static func loginItems() async throws -> [Item] {
        let data = try await runAsync(["item", "list", "--categories", "Login", "--format", "json"],
                                      timeout: 30)
        return parseItems(data)
    }

    /// Fetches one item's username and password. 1Password handles the Touch ID
    /// prompt. This is the only call that returns a secret.
    static func login(itemID: String) async throws -> Login {
        let data = try await runAsync(["item", "get", itemID, "--format", "json", "--reveal"])
        guard let login = parseLogin(data) else {
            throw OPError.cli("could not read username/password from that item")
        }
        return login
    }

    // MARK: - Parsing (pure, unit-tested in SelfTest)

    static func parseAccounts(_ data: Data) -> [String] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { $0["email"] as? String ?? $0["url"] as? String }
    }

    static func parseItems(_ data: Data) -> [Item] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { raw in
            guard let id = raw["id"] as? String else { return nil }
            let title = raw["title"] as? String ?? id
            let vault = (raw["vault"] as? [String: Any])?["name"] as? String ?? ""
            var hosts: [String] = []
            if let urls = raw["urls"] as? [[String: Any]] {
                for entry in urls {
                    guard let href = entry["href"] as? String else { continue }
                    if let host = hostFromLooseURL(href) { hosts.append(host) }
                }
            }
            // Some op versions omit urls in list output; the title often carries
            // the domain, so keep it as a weaker matching signal.
            if hosts.isEmpty, let host = hostFromLooseURL(title) { hosts.append(host) }
            var hint = raw["additional_information"] as? String
            if let h = hint, h.isEmpty || h == "—" { hint = nil }
            return Item(id: id, title: title, vault: vault, hosts: hosts, usernameHint: hint)
        }
    }

    static func parseLogin(_ data: Data) -> Login? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = raw["fields"] as? [[String: Any]] else { return nil }

        var username: String?
        var password: String?
        var totp: String?
        for field in fields {
            let purpose = field["purpose"] as? String
            let label = (field["label"] as? String)?.lowercased()
            let type = field["type"] as? String
            let value = field["value"] as? String

            // OTP fields carry the current code in `totp` and often omit
            // `value` entirely, so check them before requiring a value.
            if type == "OTP" || label == "one-time password" {
                if let code = field["totp"] as? String ?? value, !code.isEmpty { totp = code }
                continue
            }
            guard let value, !value.isEmpty else { continue }

            if purpose == "USERNAME" || (username == nil && label == "username") {
                username = value
            } else if purpose == "PASSWORD" || (password == nil && label == "password") {
                password = value
            }
        }
        guard let password else { return nil }
        return Login(username: username ?? "", password: password, totp: totp)
    }

    /// Accepts "example.com", "https://example.com/x", or "Example (example.com)".
    static func hostFromLooseURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), let host = url.host { return host.lowercased() }
        if let url = URL(string: "https://\(trimmed)"), let host = url.host,
           host.contains(".") { return host.lowercased() }
        // Pull a bare domain out of surrounding text.
        let pattern = #"([a-z0-9-]+\.)+[a-z]{2,}"#
        if let range = trimmed.lowercased().range(of: pattern, options: .regularExpression) {
            return String(trimmed.lowercased()[range])
        }
        return nil
    }

    /// Every item registered for a host, for the autofill menu.
    static func matches(for host: String, in items: [Item]) -> [Item] {
        let target = Keychain.normalize(host: host)
        return items.filter { item in
            item.hosts.contains { Keychain.normalize(host: $0) == target }
        }
    }

    /// Best item for a host, preferring an exact registrable-domain match.
    static func bestMatch(for host: String, in items: [Item]) -> Item? {
        let target = Keychain.normalize(host: host)
        let exact = items.filter { item in
            item.hosts.contains { Keychain.normalize(host: $0) == target }
        }
        if exact.count <= 1 { return exact.first }
        // Prefer the one whose host matches the full hostname, not just the domain.
        return exact.first { $0.hosts.contains(host.lowercased()) } ?? exact.first
    }
}
