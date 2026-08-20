import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A verse suggested for what you have been reading lately.
///
/// The verse of the day was the original ask. It isn't cleanly reachable:
/// YouVersion has no open verse-of-the-day endpoint (the documented Platform API
/// needs an app key), and bible.com's page is HTML behind bot protection — one in
/// three fetches came back as a "Client Challenge" during testing. So this does
/// something better suited to a browser anyway: it reads the themes in your own
/// recent history and suggests a verse against them.
///
/// **The model never writes scripture.** It returns only a reference, which is
/// then validated against the 66-book canon and looked up from a real text
/// source. A small on-device model asked for verse text will produce
/// plausible-sounding paraphrase, and shipping invented scripture is not a
/// tradeoff worth making for a nicer new-tab page. If the lookup fails, the card
/// shows the reference alone and links out.
enum VerseSuggestion {

    struct Verse: Codable, Equatable {
        /// "Philippians 4:6" — canonical, from the text source where possible.
        var reference: String
        /// Empty when the lookup failed; the card then shows a link instead.
        var text: String
        /// e.g. "World English Bible" — shown, because translation matters.
        var translation: String
        /// One line from the model on why this verse, for what you've been doing.
        var connection: String
        var fetchedAt: Date

        var bibleComURL: URL? {
            let query = reference.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) ?? ""
            return URL(string: "https://www.bible.com/search/bible?query=\(query)")
        }
    }

    static var isAvailable: Bool { OnDeviceOrganizer.availability.isAvailable }

    /// Set by the `--verse` probe. The failure modes here — a guardrail refusal,
    /// a differently-shaped reply, a rejected reference — are indistinguishable
    /// from the outside, and the card just doesn't appear.
    static var debugLog: ((String) -> Void)?

    private static let instructions = """
    You suggest one Bible verse that speaks to what someone has been reading and
    working on today.

    Reply with exactly one line and nothing else:
    Book Chapter:Verse|one short sentence on why this verse fits

    Rules:
    - Use a full English book name, e.g. "Philippians 4:6" or "1 Peter 5:7".
    - One verse, not a range. No translation name.
    - Never quote or paraphrase the verse itself. Only the reference.
    - The sentence is at most 15 words, plain and warm, not preachy.
    """

    /// Themes come from page titles only — never URLs, query strings, or page
    /// content, since those carry far more than the topic.
    static func themes(from history: [HistoryEntry], limit: Int = 18) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in history {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count > 3 else { continue }
            let key = title.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(String(title.prefix(90)))
            if out.count >= limit { break }
        }
        return out
    }

    /// On-device only, deliberately. This prompt contains a summary of recent
    /// browsing, which is not something to hand to a remote API for a decoration
    /// on the new-tab page.
    static func suggest(history: [HistoryEntry], translation: String = "web") async -> Verse? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return nil }
        let titles = themes(from: history)
        guard titles.count >= 3 else { return nil }

        do {
            let session = LanguageModelSession(instructions: instructions)
            let reply = try await session.respond(to: """
            Recent page titles:
            \(titles.map { "- \($0)" }.joined(separator: "\n"))
            """)
            debugLog?("raw reply: \(reply.content)")
            guard let parsed = parse(reply.content) else {
                debugLog?("parse rejected the reply")
                return nil
            }
            return await resolve(reference: parsed.reference, connection: parsed.connection,
                                 translation: translation)
        } catch {
            debugLog?("model error: \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Pulls a reference and a one-line reason out of whatever the model said.
    ///
    /// The strict `reference|reason` format is tried first, then a tolerant scan.
    /// Tolerance is not optional here: asked for the strict form, the on-device
    /// model reliably answers `Philippians 4:6 - "Do not be anxious…"` followed
    /// by a paragraph. Rejecting that meant the card never appeared at all.
    ///
    /// The model's own quotation is always discarded — the text is looked up.
    static func parse(_ raw: String) -> (reference: String, connection: String)? {
        // 1. The format we asked for.
        for line in raw.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`*-•"))
                .trimmingCharacters(in: .whitespaces)
            guard let bar = text.firstIndex(of: "|") else { continue }
            let reference = String(text[text.startIndex..<bar])
            let connection = String(text[text.index(after: bar)...])
                .trimmingCharacters(in: .whitespaces)
            if let canonical = canonicalReference(reference), !connection.isEmpty {
                return (canonical, String(connection.prefix(140)))
            }
        }

        // 2. Anything containing a real reference.
        guard let reference = findReference(in: raw) else { return nil }
        return (reference, connectionText(in: raw) ?? "")
    }

    /// First `Book Chapter:Verse` in the text that names a real book.
    static func findReference(in text: String) -> String? {
        let pattern = "((?:[1-3]\\s*)?[A-Z][A-Za-z]+(?:\\s+of\\s+[A-Z][A-Za-z]+)?)\\.?\\s*(\\d+)\\s*[:.]\\s*(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let full = Range(match.range, in: text) else { continue }
            let candidate = String(text[full])
            if let canonical = canonicalReference(candidate) { return canonical }
        }
        return nil
    }

    /// The model's explanation, minus any scripture it quoted.
    ///
    /// Prefers a line with no quotation marks and no reference in it — which is
    /// exactly the trailing "This verse speaks to…" paragraph.
    static func connectionText(in raw: String) -> String? {
        let lines = raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let clean = lines.filter {
            !$0.contains("\"") && !$0.contains("\u{201C}") && findReference(in: $0) == nil
        }
        guard let best = clean.max(by: { $0.count < $1.count }) else { return nil }
        return String(best.prefix(140))
    }

    /// Returns the reference in canonical form, or nil if it isn't one.
    ///
    /// Parsed from the end rather than by splitting on ":", so "Philippians 4.6"
    /// and "Philippians 4:6" both work — models mix the two freely.
    static func canonicalReference(_ raw: String) -> String? {
        var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
        // Trailing junk the model sometimes adds ("Philippians 4:6.").
        while let last = rest.last, !last.isNumber { rest = rest.dropLast() }

        func trailingNumber() -> Int? {
            var digits = ""
            while let last = rest.last, last.isNumber {
                digits.insert(last, at: digits.startIndex)
                rest = rest.dropLast()
            }
            return digits.isEmpty ? nil : Int(digits)
        }

        guard let verse = trailingNumber(), verse > 0 else { return nil }
        // Exactly one separator between chapter and verse. A range ("4:6-7")
        // leaves a "-" here and is rejected: showing one verse of a two-verse
        // claim is a different claim.
        guard let separator = rest.last, separator == ":" || separator == "." else { return nil }
        rest = rest.dropLast()

        guard let chapter = trailingNumber(), chapter > 0 else { return nil }
        let book = rest.trimmingCharacters(in: CharacterSet(charactersIn: " .,:"))
        guard !book.isEmpty else { return nil }
        guard let matched = books.first(where: { $0.caseInsensitiveCompare(book) == .orderedSame })
        else { return nil }
        return "\(matched) \(chapter):\(verse)"
    }

    /// Looks up the actual text. Public-domain translation on purpose: the WEB is
    /// free to display, where NIV and ESV text are licensed and would need an
    /// agreement to ship. Swapping in the YouVersion Platform API later would be
    /// the way to show a licensed translation.
    /// Translations the text source actually serves, verified one request at a
    /// time against a New Testament *and* an Old Testament reference.
    ///
    /// English only, deliberately: the non-English editions the source carries
    /// (Vulgate, Synodal, Almeida, Chinese Union, Bible kralická) index their
    /// books under localised names, so an English reference returns "not found".
    /// Supporting them means a per-language book table, which is a bigger job
    /// than it looks and buys nothing here.
    ///
    /// All public domain — that is *why* they're queryable without a key. NIV,
    /// ESV, NLT and NASB are licensed and no open API serves them at any length;
    /// ESV is reachable with your own free api.esv.org key if you want it.
    struct Translation: Identifiable, Hashable {
        let id: String
        let label: String
        /// Shown under the picker when the edition is partial.
        var caveat: String?
    }

    static let translations: [Translation] = [
        Translation(id: "web", label: "World English Bible"),
        Translation(id: "webbe", label: "World English Bible, British"),
        Translation(id: "kjv", label: "King James Version"),
        Translation(id: "asv", label: "American Standard Version (1901)"),
        Translation(id: "darby", label: "Darby Bible"),
        Translation(id: "dra", label: "Douay-Rheims (1899)"),
        Translation(id: "oeb-us", label: "Open English Bible, US"),
        Translation(id: "oeb-cw", label: "Open English Bible, Commonwealth"),
        Translation(id: "bbe", label: "Bible in Basic English"),
        Translation(id: "ylt", label: "Young's Literal Translation",
                    caveat: "New Testament only — Old Testament references fall back to the World English Bible.")
    ]

    static func translation(id: String) -> Translation? {
        translations.first { $0.id == id }
    }

    /// The order to try. A partial edition (YLT has no Old Testament) and a
    /// throttled response look identical from here — an empty result — so the
    /// fallback covers both. The card always shows the translation that actually
    /// answered, so falling back never misattributes the text.
    static func lookupOrder(for translation: String) -> [String] {
        translation == "web" ? ["web"] : [translation, "web"]
    }

    static func resolve(reference: String, connection: String,
                        translation: String = "web") async -> Verse {
        var result = Verse(reference: reference, text: "", translation: "",
                           connection: connection, fetchedAt: Date())
        for candidate in lookupOrder(for: translation) {
            // One retry per edition: bible-api throttles bursts, and a throttled
            // request is indistinguishable from a missing verse.
            for attempt in 0..<2 {
                if attempt == 1 { try? await Task.sleep(for: .milliseconds(700)) }
                if let fetched = await fetch(reference: reference, translation: candidate) {
                    result.reference = fetched.reference
                    result.text = fetched.text
                    result.translation = fetched.translation_name
                    return result
                }
            }
        }
        return result
    }

    private static func fetch(reference: String, translation: String) async -> APIVerse? {
        let slug = reference.replacingOccurrences(of: " ", with: "+")
        guard let url = URL(string: "https://bible-api.com/\(slug)?translation=\(translation)")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? JSONDecoder().decode(APIVerse.self, from: data)
            else { return nil }
            let text = payload.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return APIVerse(reference: payload.reference, text: text,
                            translation_name: payload.translation_name)
        } catch {
            return nil
        }
    }

    private struct APIVerse: Decodable {
        let reference: String
        let text: String
        let translation_name: String
    }

    static let books = [
        "Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy", "Joshua",
        "Judges", "Ruth", "1 Samuel", "2 Samuel", "1 Kings", "2 Kings",
        "1 Chronicles", "2 Chronicles", "Ezra", "Nehemiah", "Esther", "Job",
        "Psalms", "Psalm", "Proverbs", "Ecclesiastes", "Song of Solomon",
        "Isaiah", "Jeremiah", "Lamentations", "Ezekiel", "Daniel", "Hosea",
        "Joel", "Amos", "Obadiah", "Jonah", "Micah", "Nahum", "Habakkuk",
        "Zephaniah", "Haggai", "Zechariah", "Malachi",
        "Matthew", "Mark", "Luke", "John", "Acts", "Romans", "1 Corinthians",
        "2 Corinthians", "Galatians", "Ephesians", "Philippians", "Colossians",
        "1 Thessalonians", "2 Thessalonians", "1 Timothy", "2 Timothy", "Titus",
        "Philemon", "Hebrews", "James", "1 Peter", "2 Peter", "1 John", "2 John",
        "3 John", "Jude", "Revelation"
    ]
}
