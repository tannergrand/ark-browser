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

    Reply with at most 2 lines and nothing else. Each line is exactly:
    label|url

    The label is 2-5 words. The url must be a real, well-known site you are
    confident exists, or a search URL. Never invent a domain. No numbering, no
    bullets, no explanation, no blank lines.
    """

    #if canImport(FoundationModels)
    /// One session, reused. Building a `LanguageModelSession` per keystroke pays
    /// setup every time; the bench measures what that costs.
    @available(macOS 26.0, *)
    @MainActor
    private static var shared: LanguageModelSession?

    @available(macOS 26.0, *)
    @MainActor
    private static func session() -> LanguageModelSession {
        if let shared { return shared }
        let made = LanguageModelSession(instructions: instructions)
        shared = made
        return made
    }
    #endif

    /// Loads the model before the first keystroke, so the first suggestion isn't
    /// the one that pays for setup. Call it when the command bar opens.
    static func prewarm() {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return }
        Task { @MainActor in session().prewarm() }
        #endif
    }

    /// Results already produced, keyed by query. Typing "githu" then deleting
    /// back to "gith" should not re-ask a model that takes seconds to answer.
    @MainActor
    private static var cache: [String: [BrowserState.Suggestion]] = [:]
    @MainActor private static var cacheOrder: [String] = []

    @MainActor
    private static func remember(_ rows: [BrowserState.Suggestion], for key: String) {
        cache[key] = rows
        cacheOrder.append(key)
        if cacheOrder.count > 40, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    /// How long a suggestion is worth waiting for.
    ///
    /// Measured, not guessed: a single completion in a headless run did not come
    /// back inside three minutes. Whatever the model is doing, a suggestion that
    /// lands after you have already pressed Return is worse than no suggestion —
    /// it rewrites the list under a decision you have made. So the request is
    /// bounded and simply dropped if it misses.
    static let budget: Duration = .milliseconds(2500)

    /// `fast` asks for one line and caps the response harder. **Measured slower,
    /// not faster** — 400 ms against 340 ms for the normal path — so it is left
    /// off. Kept only because `--bench-suggest` reports it, and a number that
    /// contradicts the intuition is worth being able to reproduce.
    ///
    /// What did help, measured on this Mac:
    ///   • first call in a process ≈ 840 ms, later calls ≈ 310 ms — that gap is
    ///     session setup, which `prewarm()` moves off the first keystroke
    ///   • reusing the session: 489 ms → 340 ms mean
    ///   • a repeat of an answered query: 1 ms, via the cache
    ///   • the debounce was a flat 400 ms on top of all of it
    static func suggest(query: String, searchBase: String,
                        reuseSession: Bool = true,
                        fast: Bool = false) async -> [BrowserState.Suggestion] {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }

        if let hit = await MainActor.run { cache[trimmed] } { return hit }

        do {
            let active = reuseSession
                ? await MainActor.run { session() }
                : LanguageModelSession(instructions: instructions)
            let prompt = fast
                ? "Partial query: \(trimmed)\nSearch URL prefix: \(searchBase)?q=\nReply with ONE line only."
                : "Partial query: \(trimmed)\nSearch URL prefix: \(searchBase)?q="
            let options = GenerationOptions(sampling: .greedy,
                                            temperature: 0,
                                            maximumResponseTokens: fast ? 40 : 64)
            // Race the model against the budget. Whichever finishes first wins;
            // the loser is cancelled.
            let reply: String? = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    try await active.respond(to: prompt, options: options).content
                }
                group.addTask {
                    try await Task.sleep(for: budget)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let reply else {
                TintLog.say("suggestions: timed out after \(budget)")
                return []
            }
            let rows = parse(reply)
            if !rows.isEmpty { await MainActor.run { remember(rows, for: trimmed) } }
            return rows
        } catch {
            // A reused session can be left in a bad state by a cancelled or
            // failed turn; drop it so the next keystroke starts clean rather
            // than inheriting the failure.
            if reuseSession, #available(macOS 26.0, *) {
                await MainActor.run { shared = nil }
            }
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
