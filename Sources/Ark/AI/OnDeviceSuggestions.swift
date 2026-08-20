import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Command-bar completions on Apple Intelligence's on-device model.
///
/// Better suited than the API for this: what you type in an address bar is about
/// as sensitive as browsing gets, and on-device means **the query never leaves
/// the Mac**. It's also free and works offline.
///
/// Output is line-based (`label|url`) rather than JSON. A small model produces
/// short, well-formed lines far more reliably than nested JSON, and latency
/// matters more here than anywhere else in the app.
enum OnDeviceSuggestions {
    static var isAvailable: Bool { OnDeviceOrganizer.availability.isAvailable }

    private static let instructions = """
    You complete queries typed into a web browser's address bar.

    Reply with at most 3 lines and nothing else. Each line is exactly:
    label|url

    The label is 2-5 words. The url must be a real, well-known site you are
    confident exists, or a search URL. Never invent a domain. No numbering, no
    bullets, no explanation, no blank lines.
    """

    static func suggest(query: String, searchBase: String) async -> [BrowserState.Suggestion] {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }

        do {
            let session = LanguageModelSession(instructions: instructions)
            let reply = try await session.respond(
                to: "Partial query: \(trimmed)\nSearch URL prefix: \(searchBase)?q=")
            return parse(reply.content)
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    /// Tolerates numbering, stray bullets, and code fences, and drops anything
    /// without a resolvable host so a hallucinated domain can't be offered.
    static func parse(_ raw: String) -> [BrowserState.Suggestion] {
        var out: [BrowserState.Suggestion] = []
        var seen = Set<String>()

        for line in raw.split(separator: "\n") {
            var text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("```") else { continue }
            // Strip "1." / "-" / "*" prefixes.
            while let first = text.first, first.isNumber || first == "." || first == ")"
                    || first == "-" || first == "*" || first == " " {
                text.removeFirst()
                text = text.trimmingCharacters(in: .whitespaces)
                if text.isEmpty { break }
            }
            guard let separator = text.firstIndex(of: "|") else { continue }

            let label = String(text[text.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            var url = String(text[text.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !url.isEmpty else { continue }
            if !url.contains("://") { url = "https://" + url }
            guard let host = URL(string: url)?.host, host.contains(".") else { continue }
            guard seen.insert(url).inserted else { continue }

            out.append(BrowserState.Suggestion(kind: .ai, label: String(label.prefix(60)),
                                               detail: host, url: url))
            if out.count == 3 { break }
        }
        return out
    }
}
