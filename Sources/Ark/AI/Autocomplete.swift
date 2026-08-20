import Foundation

/// AI completions for the command bar. Runs on Haiku for latency, returns
/// quickly or not at all — local suggestions are never gated on this.
enum Autocomplete {
    static let model = "claude-haiku-4-5-20251001"

    private static var systemPrompt: String { """
    You complete queries typed into a web browser's address bar. Given a partial \
    query, return up to 3 useful completions.

    Each completion is either a specific destination URL the user likely wants, \
    or a sharper search query than what they typed.

    Reply with ONLY a JSON array, no prose, no code fences:
    [{"label":"short description","url":"https://..."}]

    For search refinements use the user's search engine: \
    \(SearchEngine.current.base)?q=<url-encoded query>
    Prefer real, well-known URLs. Never invent domains you are not confident exist.
    """ }

    static func suggest(query: String) async -> [BrowserState.Suggestion] {
        guard let key = try? ClaudeClient.apiKey() else { return [] }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 400,
            "system": systemPrompt,
            "messages": [["role": "user", "content": query]]
        ]

        var req = URLRequest(url: ClaudeClient.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]] else { return [] }
            let text = content.compactMap { $0["text"] as? String }.joined()
            return parse(text)
        } catch {
            return []
        }
    }

    /// Tolerates code fences and leading prose around the JSON array.
    static func parse(_ raw: String) -> [BrowserState.Suggestion] {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"), start < end else { return [] }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            guard let label = item["label"] as? String,
                  let url = item["url"] as? String,
                  URL(string: url)?.host != nil else { return nil }
            return BrowserState.Suggestion(kind: .ai, label: label,
                                           detail: URL(string: url)?.host ?? url, url: url)
        }
    }
}
