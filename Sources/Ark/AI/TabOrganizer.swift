import Foundation

/// Chrome-style "organize my tabs", via Claude.
///
/// Deliberately proposal-first: it never rearranges anything on its own. Tabs
/// are the user's working set, and silently reshuffling them would be hostile,
/// so this returns a plan that has to be approved.
///
/// Privacy: tab **titles and hostnames** are sent to the API — never page
/// content, cookies, or form data. Pinned tabs and favourites are excluded, so
/// only the ephemeral Today set is ever described.
enum TabOrganizer {
    /// Grouping benefits from real judgment, and this runs on an explicit user
    /// action rather than per keystroke, so it uses the larger model.
    static let model = ClaudeClient.model

    struct ProposedGroup: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var tabIDs: [UUID]
        /// Rows start checked; unchecking one leaves those tabs where they are.
        var accepted: Bool = true
    }

    struct Proposal {
        var groups: [ProposedGroup]
        /// Tabs the model deliberately left alone.
        var ungrouped: [UUID]
    }

    struct OrganizerError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    private static let systemPrompt = """
    You organize browser tabs into named groups, like Chrome's tab groups.

    You receive a numbered list of open tabs with their titles and hostnames.
    Return groups that reflect what the person is actually working on — a
    project, a topic, a task in progress. Prefer a few meaningful groups over
    many tiny ones.

    Rules:
    - Group names: 1–3 words, Title Case, specific. "Rock Tickets", not "Work".
    - Only group tabs that genuinely belong together. Leave a tab out rather
      than forcing it somewhere.
    - A tab may appear in at most one group.
    - Never invent tabs or indices that were not given to you.
    - Skip any group that would contain fewer than 2 tabs.

    Reply with ONLY a JSON object, no prose and no code fences:
    {"groups":[{"name":"Group Name","tabs":[0,3,4]}]}
    """

    static func propose(tabs: [(id: UUID, title: String, host: String)]) async throws -> Proposal {
        guard tabs.count >= 2 else {
            throw OrganizerError(detail: "Need at least two tabs to organize.")
        }
        let key = try ClaudeClient.apiKey()

        let listing = tabs.enumerated().map { index, tab in
            "\(index). \(tab.title.prefix(120))  —  \(tab.host)"
        }.joined(separator: "\n")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1200,
            "system": systemPrompt,
            "messages": [["role": "user", "content": "Open tabs:\n\(listing)"]]
        ]

        var request = URLRequest(url: ClaudeClient.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OrganizerError(detail: "No response from api.anthropic.com")
        }
        guard http.statusCode == 200 else {
            var detail = "HTTP \(http.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                detail = message
            }
            throw OrganizerError(detail: detail)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw OrganizerError(detail: "Unexpected response shape")
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        let proposal = parse(text, tabs: tabs.map(\.id))
        guard !proposal.groups.isEmpty else {
            throw OrganizerError(detail: "Claude didn't find a useful grouping for these tabs.")
        }
        return proposal
    }

    /// Validates model output against the real tab list. Both engines funnel
    /// through here, because an out-of-range or duplicated index is a risk in
    /// either and must be rejected in exactly one place.
    static func assemble(rawGroups: [(name: String, indices: [Int])], tabs: [UUID]) -> Proposal {
        var used = Set<UUID>()
        var groups: [ProposedGroup] = []

        for entry in rawGroups {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            var ids: [UUID] = []
            for index in entry.indices {
                guard tabs.indices.contains(index) else { continue }
                let id = tabs[index]
                guard used.insert(id).inserted else { continue }
                ids.append(id)
            }
            guard ids.count >= 2 else {
                ids.forEach { used.remove($0) }
                continue
            }
            groups.append(ProposedGroup(name: String(name.prefix(40)), tabIDs: ids))
        }
        return Proposal(groups: groups, ungrouped: tabs.filter { !used.contains($0) })
    }

    /// Tolerates code fences and prose, and validates every index against the
    /// real tab list so a hallucinated index can never move the wrong tab.
    static func parse(_ raw: String, tabs: [UUID]) -> Proposal {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end else {
            return Proposal(groups: [], ungrouped: tabs)
        }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawGroups = object["groups"] as? [[String: Any]] else {
            return Proposal(groups: [], ungrouped: tabs)
        }

        let mapped: [(name: String, indices: [Int])] = rawGroups.compactMap { entry in
            guard let name = entry["name"] as? String,
                  let raw = entry["tabs"] as? [Any] else { return nil }
            let indices: [Int] = raw.compactMap { value in
                switch value {
                case let n as Int: return n
                case let d as Double: return Int(d)
                case let s as String: return Int(s)
                default: return nil
                }
            }
            return (name, indices)
        }
        return assemble(rawGroups: mapped, tabs: tabs)
    }

    /// Shared instructions, so both engines get the same grouping behaviour.
    static let instructions = systemPrompt

    /// Compact listing. The on-device model has a small context window, so
    /// titles are truncated and the set is capped.
    static func listing(for tabs: [(id: UUID, title: String, host: String)]) -> String {
        tabs.enumerated().map { index, tab in
            "\(index). \(tab.title.prefix(70)) — \(tab.host)"
        }.joined(separator: "\n")
    }

    static let onDeviceTabCap = 40
}
