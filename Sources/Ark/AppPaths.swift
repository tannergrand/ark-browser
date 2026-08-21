import Foundation

/// Where this build keeps its data, and which channel it is.
///
/// Staging and production have to be **completely separate installs** — separate
/// bundle identifier, separate support folder, separate website data — or testing
/// isn't testing: a staging build sharing production's `state.json` can lose your
/// real tabs to a bug you were trying to find, and sharing the WebKit store means
/// a staging crash takes your logged-in sessions with it.
///
/// Everything derives from the bundle, so there is one source of truth and no
/// path can drift out of step with the identifier.
enum AppPaths {
    enum Channel: String {
        case production
        case staging

        var label: String {
            switch self {
            case .production: return "Production"
            case .staging: return "Staging"
            }
        }
    }

    /// Read from `ARKChannel` in Info.plist, which `build.sh --staging` sets.
    /// Defaults to production: an unmarked build is the real one.
    static var channel: Channel {
        let raw = Bundle.main.infoDictionary?["ARKChannel"] as? String ?? ""
        return Channel(rawValue: raw) ?? .production
    }

    static var isStaging: Bool { channel == .staging }

    /// "Ark" or "Ark Staging" — the folder name, taken from the bundle so it can
    /// never disagree with the identifier.
    static var folderName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Ark"
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    static func supportFile(_ name: String) -> URL {
        supportDirectory.appendingPathComponent(name)
    }

    /// Ensures the directory exists. Cheap, and callers otherwise each have to
    /// remember.
    static func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(at: supportDirectory,
                                                 withIntermediateDirectories: true)
    }
}
