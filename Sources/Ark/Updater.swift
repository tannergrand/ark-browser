import AppKit
import CryptoKit
import Foundation

/// Checks GitHub Releases for a newer Ark and installs it on request.
///
/// Deliberately not Sparkle. Sparkle is the right answer for a signed, notarised
/// app with a hosted appcast; Ark is a self-signed build shared with friends, and
/// Sparkle's EdDSA + appcast machinery would be ceremony around a trust anchor
/// that doesn't exist yet. This does the same job in one file: read the release
/// feed, compare versions, download the asset, verify it, swap the bundle.
///
/// What is and isn't guaranteed, plainly:
///   • Transport is HTTPS to a pinned host, and the download URL must live on
///     GitHub — a release body can't redirect the download somewhere else.
///   • If the release notes contain a `sha256: <hex>` line, the download must
///     match it or the update is refused. Publish one (the release script does)
///     and a tampered asset is caught.
///   • Nothing installs itself. The check is silent; installing needs a click.
///   • This is *not* a substitute for notarisation. An unsigned app that can
///     replace itself is a real trust decision, which is why it is opt-in and
///     never automatic.
@MainActor
@Observable
final class Updater {
    nonisolated struct Release: Equatable {
        let version: String
        let notes: String
        let downloadURL: URL
        let sha256: String?
        let publishedAt: String
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case readyToRelaunch
        case failed(String)
    }

    /// Where releases are published. Set once the repo exists.
    nonisolated static let repository = "tannergrand/ark-browser"

    var phase: Phase = .idle
    var automaticallyChecks: Bool = true
    var lastChecked: Date?

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Compares dotted numeric versions. "0.26" < "0.26.1" < "1.0".
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// Pulls `sha256: <64 hex>` out of release notes, case-insensitively.
    nonisolated static func checksum(in notes: String) -> String? {
        let pattern = "sha256[: ]+([0-9a-fA-F]{64})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: notes,
                                           range: NSRange(notes.startIndex..., in: notes)),
              let range = Range(match.range(at: 1), in: notes) else { return nil }
        return String(notes[range]).lowercased()
    }

    /// Rejects anything not served by GitHub, so release notes can't point the
    /// installer at an arbitrary host.
    nonisolated static func isTrustedAssetURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
            || host == "objects.githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let assets = root["assets"] as? [[String: Any]] else { return nil }
        let notes = root["body"] as? String ?? ""
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
        guard let urlString = zip?["browser_download_url"] as? String,
              let url = URL(string: urlString), isTrustedAssetURL(url) else { return nil }
        return Release(version: tag, notes: notes, downloadURL: url,
                       sha256: checksum(in: notes),
                       publishedAt: root["published_at"] as? String ?? "")
    }

    func check(userInitiated: Bool = false) async {
        if case .downloading = phase { return }
        phase = .checking
        defer { lastChecked = Date() }

        let endpoint = "https://api.github.com/repos/\(Self.repository)/releases/latest"
        guard let url = URL(string: endpoint) else {
            phase = .failed("Bad release URL")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 {
                phase = userInitiated ? .failed("No releases published yet") : .idle
                return
            }
            guard code == 200, let release = Self.parse(data) else {
                phase = .failed("Couldn't read the release feed (HTTP \(code))")
                return
            }
            phase = Self.isNewer(release.version, than: Self.currentVersion)
                ? .available(release)
                : .upToDate
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func install(_ release: Release) async {
        phase = .downloading(0)
        do {
            let (temp, response) = try await URLSession.shared.download(from: release.downloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                phase = .failed("Download failed")
                return
            }
            let data = try Data(contentsOf: temp)

            if let expected = release.sha256 {
                let actual = Self.sha256Hex(data)
                guard actual == expected else {
                    // Refuse rather than warn. A mismatch is either corruption or
                    // tampering, and neither should be one click from installed.
                    phase = .failed("Checksum mismatch — refusing to install")
                    return
                }
            }

            phase = .downloading(0.7)
            try Self.swapBundle(zipAt: temp)
            phase = .readyToRelaunch
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Unzips beside the running bundle and swaps it in.
    ///
    /// The old bundle is moved aside rather than deleted, then removed only after
    /// the new one is in place — a failure mid-swap leaves a working app.
    private static func swapBundle(zipAt archive: URL) throws {
        let fm = FileManager.default
        let installed = Bundle.main.bundleURL
        let staging = fm.temporaryDirectory
            .appendingPathComponent("ark-update-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw NSError(domain: "Ark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't expand the archive"])
        }

        guard let payload = try fm.contentsOfDirectory(at: staging,
                                                       includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "Ark", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No app bundle in the archive"])
        }

        let backup = installed.appendingPathExtension("old")
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: installed, to: backup)
        do {
            try fm.moveItem(at: payload, to: installed)
        } catch {
            try? fm.moveItem(at: backup, to: installed)   // put it back
            throw error
        }
        try? fm.removeItem(at: backup)
        try? fm.removeItem(at: staging)
    }

    /// Launches the freshly installed copy and exits this one.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
