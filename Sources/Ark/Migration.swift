import Foundation

/// Carries a Drift install forward to Ark.
///
/// The rename changes two paths that hold real user data, and neither moves on
/// its own:
///
/// 1. `Application Support/Drift` — tabs, groups, history, settings.
/// 2. `~/Library/WebKit/<bundle-id>` — cookies, localStorage, and every logged-in
///    session. This one is keyed on the bundle identifier, so changing the
///    identifier silently signs you out of everything.
///
/// Copies rather than moves, so a failed launch on the new build leaves the old
/// install intact and usable. Runs once: if the destination exists, it's a no-op.
///
/// The keychain needs no migration — `Keychain.service` intentionally kept its
/// original identifier for exactly this reason.
enum Migration {
    static func runIfNeeded() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        copyOnce(from: support.appendingPathComponent("Drift"),
                 to: support.appendingPathComponent("Ark"),
                 label: "app state")

        let webkit = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit")
        copyOnce(from: webkit.appendingPathComponent("com.tannergrandstaff.drift"),
                 to: webkit.appendingPathComponent("com.tannergrandstaff.ark"),
                 label: "website data")
    }

    private static func copyOnce(from source: URL, to destination: URL, label: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path),
              !fm.fileExists(atPath: destination.path) else { return }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
            NSLog("Ark: migrated %@ from Drift", label)
        } catch {
            NSLog("Ark: could not migrate %@ — %@", label, error.localizedDescription)
        }
    }
}
