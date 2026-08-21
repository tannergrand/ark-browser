import Foundation

/// The "what changed" page shown on the first launch after an update.
///
/// Reads the CHANGELOG shipped inside the bundle, takes every section newer than
/// the version last seen, and renders it to a local HTML file that opens in a
/// tab. HTML rather than a native sheet for one reason worth stating: Ark already
/// has an excellent renderer for documents, and a modal panel you must dismiss
/// before using your browser is a worse greeting than a tab you can close.
///
/// Shown only when a *previous* version was recorded. A fresh install has
/// nothing to catch up on, and opening release notes at someone the first time
/// they launch an app is noise.
enum WhatsNew {
    /// Sections of the changelog strictly newer than `since`, in file order.
    ///
    /// Headings look like `## v0.26.1 — Title (date)`. Anything unparseable is
    /// skipped rather than guessed at — a mangled heading would either drop a
    /// real entry or invent one.
    static func sections(from markdown: String, since: String?, upTo current: String) -> [String] {
        var out: [String] = []
        var currentLines: [String] = []
        var keeping = false

        func flush() {
            if keeping, !currentLines.isEmpty { out.append(currentLines.joined(separator: "\n")) }
            currentLines = []
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                let version = parseVersion(from: line)
                keeping = version.map { candidate in
                    let notOlderThanCurrent = !Updater.isNewer(candidate, than: current)
                    let newerThanSeen = since.map { Updater.isNewer(candidate, than: $0) } ?? true
                    return notOlderThanCurrent && newerThanSeen
                } ?? false
                if keeping { currentLines.append(line) }
            } else if keeping {
                currentLines.append(line)
            }
        }
        flush()
        return out
    }

    /// `## v0.26.1 — Something (2026-08-20)` -> `0.26.1`
    static func parseVersion(from heading: String) -> String? {
        let body = heading.dropFirst(3).trimmingCharacters(in: .whitespaces)
        let token = body.split(separator: " ").first.map(String.init) ?? ""
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard let first = trimmed.first, first.isNumber else { return nil }
        return trimmed
    }

    /// Enough Markdown for a changelog: headings, bullets, bold, inline code,
    /// links, rules. Deliberately not a general renderer — anything it doesn't
    /// understand passes through as text rather than being mangled.
    static func html(from sections: [String], version: String) -> String {
        var body = ""
        for section in sections {
            body += "<section>"
            var inList = false
            for raw in section.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line == "---" { continue }

                let bullet = line.hasPrefix("- ")
                if bullet && !inList { body += "<ul>"; inList = true }
                if !bullet && inList { body += "</ul>"; inList = false }

                if line.hasPrefix("### ") {
                    body += "<h3>\(inline(String(line.dropFirst(4))))</h3>"
                } else if line.hasPrefix("## ") {
                    body += "<h2>\(inline(String(line.dropFirst(3))))</h2>"
                } else if bullet {
                    body += "<li>\(inline(String(line.dropFirst(2))))</li>"
                } else {
                    body += "<p>\(inline(line))</p>"
                }
            }
            if inList { body += "</ul>" }
            body += "</section>"
        }
        return page(body: body, version: version)
    }

    private static func inline(_ text: String) -> String {
        var out = escape(text)
        out = replacePairs(in: out, marker: "**", tag: "strong")
        out = replacePairs(in: out, marker: "`", tag: "code")
        // [label](url) — only http(s) become links. Any other scheme keeps its
        // label and loses the URL entirely: this page opens by itself after an
        // update, so a `javascript:` or `file://` target has no business
        // surviving even as visible text someone might copy.
        if let regex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\((https?://[^)\\s]+)\\)") {
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: "<a href=\"$2\">$1</a>")
        }
        if let regex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)\\s]+\\)") {
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: "$1")
        }
        return out
    }

    private static func replacePairs(in text: String, marker: String, tag: String) -> String {
        var parts = text.components(separatedBy: marker)
        guard parts.count > 2 else { return text }
        var out = parts.removeFirst()
        var opening = true
        for part in parts {
            out += opening ? "<\(tag)>" : "</\(tag)>"
            out += part
            opening.toggle()
        }
        // An unbalanced marker would leave a tag open; close it.
        if !opening { out += "</\(tag)>" }
        return out
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func page(body: String, version: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>What's new in Ark \(version)</title>
        <style>
          :root { color-scheme: dark light; }
          body {
            font: 15px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
            margin: 0; padding: 64px 24px 96px;
            background: #14161c; color: #e8eaf0;
          }
          main { max-width: 660px; margin: 0 auto; }
          .badge {
            display: inline-block; font-size: 12px; letter-spacing: .06em;
            text-transform: uppercase; color: #8b93a7; margin-bottom: 8px;
          }
          h1 { font-size: 34px; letter-spacing: -.02em; margin: 0 0 34px; }
          section { border-top: 1px solid #262a35; padding: 26px 0 4px; }
          section:first-of-type { border-top: 0; padding-top: 0; }
          h2 { font-size: 19px; margin: 0 0 14px; }
          h3 { font-size: 13px; text-transform: uppercase; letter-spacing: .07em;
               color: #8b93a7; margin: 22px 0 8px; }
          ul { padding-left: 20px; margin: 0 0 14px; }
          li { margin-bottom: 9px; }
          p { margin: 0 0 12px; }
          code { font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
                 background: #1e222b; padding: 2px 5px; border-radius: 4px; }
          strong { color: #fff; }
          a { color: #7aa2f7; }
          footer { margin-top: 42px; color: #6d748a; font-size: 13px; }
          @media (prefers-color-scheme: light) {
            body { background: #fbfbfd; color: #1d1f26; }
            section { border-color: #e6e8ef; }
            code { background: #eef0f5; }
            strong { color: #000; }
          }
        </style></head>
        <body><main>
          <div class="badge">Ark \(version)</div>
          <h1>What's new</h1>
          \(body)
          <footer>Full history in CHANGELOG.md · github.com/tannergrand/ark-browser</footer>
        </main></body></html>
        """
    }

    /// Writes the page and returns its URL, or nil when there is nothing to show.
    static func prepare(lastSeen: String?, current: String) -> URL? {
        guard lastSeen != current, lastSeen != nil else { return nil }
        guard let changelog = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let markdown = try? String(contentsOf: changelog, encoding: .utf8) else { return nil }
        let picked = sections(from: markdown, since: lastSeen, upTo: current)
        guard !picked.isEmpty else { return nil }

        AppPaths.ensureSupportDirectory()
        let target = AppPaths.supportFile("whats-new-\(current).html")
        do {
            try html(from: picked, version: current).write(to: target, atomically: true,
                                                           encoding: .utf8)
            return target
        } catch {
            return nil
        }
    }
}
