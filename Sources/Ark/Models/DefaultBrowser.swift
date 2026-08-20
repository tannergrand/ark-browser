import AppKit
import Foundation

/// Making Ark the system's default web browser.
///
/// macOS needs two things: the bundle must declare `CFBundleURLTypes` for http
/// and https (see build.sh), and the app must ask via NSWorkspace, which shows
/// the system's own confirmation dialog. There is no way to switch the default
/// silently, by design.
enum DefaultBrowser {
    /// The app currently handling https, e.g. "Safari".
    static var current: String? {
        guard let probe = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    static var currentBundleID: String? {
        guard let probe = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundle = Bundle(url: appURL) else { return nil }
        return bundle.bundleIdentifier
    }

    static var isDrift: Bool {
        currentBundleID == Bundle.main.bundleIdentifier
    }

    /// Asks macOS to make Ark the default for http and https.
    /// The user still has to confirm in the system dialog.
    static func requestDefault() async -> String {
        let bundleURL = Bundle.main.bundleURL
        var failures: [String] = []

        for scheme in ["http", "https"] {
            let error: Error? = await withCheckedContinuation { continuation in
                NSWorkspace.shared.setDefaultApplication(
                    at: bundleURL, toOpenURLsWithScheme: scheme
                ) { error in
                    continuation.resume(returning: error)
                }
            }
            if let error { failures.append("\(scheme): \(error.localizedDescription)") }
        }

        if failures.isEmpty {
            return isDrift
                ? "Ark is now your default browser."
                : "Request sent — confirm it in the system dialog, or set it in "
                  + "System Settings ▸ Desktop & Dock ▸ Default web browser."
        }
        return failures.joined(separator: "\n")
    }

    /// Ark lives in a project folder, which Launch Services tolerates but
    /// which churns its registration on every rebuild. /Applications is steadier.
    static var isInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }
}
