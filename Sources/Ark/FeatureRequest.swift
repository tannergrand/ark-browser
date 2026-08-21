import AppKit
import Foundation

/// In-app feature requests.
///
/// Two destinations, deliberately, because they solve different halves:
///
/// 1. **Always** appended to `requests.jsonl` in Ark's support folder. Local,
///    instant, works offline, and cannot be lost to a failed network call.
/// 2. **Optionally** opened as a pre-filled GitHub issue, which is what makes a
///    friend's request reach Tanner rather than sitting on their own Mac.
///
/// What this deliberately does *not* do is post the issue itself. That needs a
/// token, and a token shipped inside a public app is a leaked credential — one
/// that could be used to write to the repo. The pre-filled URL costs the person
/// one click and asks them to authenticate as themselves, which is the correct
/// trade.
///
/// Nothing is attached beyond what's stated in the sheet: the app version and the
/// macOS version. No page, no URL, no history.
struct FeatureRequest: Codable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var appVersion: String
    var systemVersion: String
    var submittedAt: Date

    init(title: String, detail: String,
         appVersion: String = Updater.currentVersion,
         systemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
         id: String = UUID().uuidString,
         submittedAt: Date = Date()) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.submittedAt = submittedAt
    }

    var isValid: Bool { !title.isEmpty }

    static var storeURL: URL { AppPaths.supportFile("requests.jsonl") }

    /// One JSON object per line, appended. A single-line-per-record format
    /// survives a crash mid-write with at most one bad line, where a re-encoded
    /// JSON array would risk the whole file.
    static func append(_ request: FeatureRequest, to url: URL = storeURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(request)
        line.append(0x0A)

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    /// GitHub's issue form accepts `title` and `body` as query parameters.
    ///
    /// The body is capped: a URL that long enough to be rejected by the server
    /// would fail silently as a blank page, which is worse than a truncated
    /// description.
    func issueURL(repository: String = Updater.repository) -> URL? {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        let body = """
        \(detail)

        ---
        Ark \(appVersion) · \(systemVersion)
        """
        components?.queryItems = [
            URLQueryItem(name: "title", value: String(title.prefix(120))),
            URLQueryItem(name: "body", value: String(body.prefix(4000))),
            URLQueryItem(name: "labels", value: "feature-request")
        ]
        return components?.url
    }

    /// The plain-text form, for the clipboard.
    var asText: String {
        var out = title
        if !detail.isEmpty { out += "\n\n" + detail }
        out += "\n\nArk \(appVersion) · \(systemVersion)"
        return out
    }
}
