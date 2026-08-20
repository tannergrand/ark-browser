import SwiftUI

/// Arc's floating command bar: one field for search, URLs, open tabs, history,
/// and bookmarks. Replaces the persistent address bar entirely.
struct CommandBar: View {
    @Environment(BrowserState.self) private var state
    @State private var text = ""
    @State private var selection = 0
    @State private var aiRows: [BrowserState.Suggestion] = []
    @State private var aiTask: Task<Void, Never>?
    /// Drives the travelling ripple. Keyed on keystrokes, not on the text, so
    /// repeating a character still sends a wave.
    @State private var wave = JellyWaveDriver()
    @FocusState private var focused: Bool

    /// Local history/bookmark/open-tab matches are capped at three.
    ///
    /// Uncapped, eight history rows filled the list and pushed the AI
    /// completions off the bottom — so the bar only ever showed you places you
    /// had already been.
    private static let localRowLimit = 3

    private var rows: [BrowserState.Suggestion] {
        state.localSuggestions(for: text, limit: Self.localRowLimit) + aiRows
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if !text.isEmpty {
                Divider().opacity(0.5)
                list
            }
        }
        .frame(width: 620)
        // The ripple is the bar's own surface, so the glass and the rim both
        // follow the wave rather than a static outline sitting over a moving one.
        .glassSurface(.floating, in: rippleShape,
                      enabled: state.glassChrome, intensity: state.glassIntensity)
        .overlay {
            rippleShape.stroke(
                LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear {
            if state.commandBarMode == .editURL {
                text = state.focusedTab?.urlString ?? ""
            }
            // Focus has to be set after this view is in the window's responder
            // chain; doing it synchronously in onAppear silently no-ops, which
            // is why a new tab used to open with the field unfocused.
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                focused = true
                if state.commandBarMode == .editURL {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
        }
        .onChange(of: text) { _, new in
            selection = 0
            scheduleAISuggestions(for: new)
            wave.strike(caret: caretFraction, reduced: Motion.reduced)
        }
        .onDisappear { aiTask?.cancel() }
    }

    private var rippleShape: JellyWave {
        JellyWave(travel: wave.travel, origin: wave.origin,
                  amplitude: wave.amplitude, cornerRadius: 14)
    }

    /// Where the caret is, as a fraction of the bar — estimated from the text
    /// length, since a SwiftUI `TextField` doesn't expose its cursor position.
    /// The field starts ~46pt in and a character is ~7pt at this size.
    private var caretFraction: Double {
        let x = 46 + Double(text.count) * 7.0
        return min(max(x / 620, 0.04), 0.96)
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(state.commandBarMode == .editURL
                      ? "Edit address" : "Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .focused($focused)
                .onSubmit(commit)
                .onKeyPress(.downArrow) {
                    selection = min(selection + 1, max(0, rows.count + searchRowOffset))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = max(selection - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    state.closeCommandBar(committed: false)
                    return .handled
                }

            if aiTask != nil && !text.isEmpty {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Results

    private var list: some View {
        ScrollView {
            VStack(spacing: 1) {
                // Row 0 is the primary action. Sites win over searches: a typed
                // URL first, then the best known site for what you typed, and
                // only then a web search.
                row(index: 0,
                    icon: primaryIcon,
                    label: primaryLabel,
                    detail: primaryDetail,
                    accent: .secondary) {
                    commitPrimary()
                }

                // Search stays one row away rather than being the default.
                if !looksLikeURL && !text.isEmpty {
                    row(index: 1,
                        icon: "magnifyingglass",
                        label: "Search for \u{201C}\(text)\u{201D}",
                        detail: SearchEngine.current.label,
                        accent: .secondary) {
                        commitSearch()
                    }
                }

                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, suggestion in
                    row(index: idx + searchRowOffset + 1,
                        icon: icon(for: suggestion.kind),
                        label: suggestion.label,
                        detail: suggestion.detail,
                        accent: suggestion.kind == .ai ? .purple : .secondary) {
                        state.open(suggestion)
                    }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 340)
    }

    private func row(index: Int, icon: String, label: String, detail: String,
                     accent: Color, action: @escaping () -> Void) -> some View {
        let selected = index == selection
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Text("\u{21A9}").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .jellyPress(scale: 0.985)
    }

    private func icon(for kind: BrowserState.Suggestion.Kind) -> String {
        switch kind {
        case .openTab: return "square.on.square"
        case .bookmark: return "bookmark.fill"
        case .history: return "clock"
        case .search: return "magnifyingglass"
        case .ai: return "sparkles"
        }
    }

    // MARK: - Actions

    /// Anything with a dot, a scheme, a port, or localhost is a destination.
    private var looksLikeURL: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" ") else { return false }
        if t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("file://") { return true }
        if t == "localhost" || t.hasPrefix("localhost:") || t.hasPrefix("localhost/") { return true }
        if t.contains("."), !t.hasPrefix("."), !t.hasSuffix(".") { return true }
        return false
    }

    /// A known site for a bare word, so "gith" goes to github.com.
    private var siteMatch: BrowserState.Suggestion? {
        looksLikeURL ? nil : state.bestSiteMatch(for: text)
    }

    private var searchRowOffset: Int { (!looksLikeURL && !text.isEmpty) ? 1 : 0 }

    private var primaryIcon: String {
        if looksLikeURL { return "arrow.up.right" }
        if siteMatch != nil { return "globe" }
        return "magnifyingglass"
    }

    private var primaryLabel: String {
        if looksLikeURL { return text }
        if let siteMatch { return siteMatch.label.isEmpty ? siteMatch.url : siteMatch.label }
        return "Search for \u{201C}\(text)\u{201D}"
    }

    private var primaryDetail: String {
        if looksLikeURL { return "Open site" }
        if let siteMatch { return URL(string: siteMatch.url)?.host ?? siteMatch.url }
        return SearchEngine.current.label
    }

    private func commitPrimary() {
        if looksLikeURL { commitTyped() }
        else if let siteMatch { state.open(siteMatch) }
        else { commitSearch() }
    }

    private func commitSearch() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = SearchEngine.current.url(for: trimmed)
        if state.commandBarMode == .editURL, let tab = state.focusedTab { tab.load(url) }
        else { state.openFromCommandBar(url) }
        state.closeCommandBar(committed: true)
    }

    private func commit() {
        if selection == 0 {
            commitPrimary()
        } else if searchRowOffset == 1 && selection == 1 {
            commitSearch()
        } else if let suggestion = rows[safe: selection - 1 - searchRowOffset] {
            state.open(suggestion)
        }
    }

    private func commitTyped() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = BrowserTab.resolve(trimmed)
        if state.commandBarMode == .editURL, let tab = state.focusedTab {
            tab.load(url)
        } else {
            state.openFromCommandBar(url)
        }
        state.closeCommandBar(committed: true)
    }

    /// Debounced, cancellable AI completions. Local rows never wait on these.
    private func scheduleAISuggestions(for query: String) {
        aiTask?.cancel()
        aiRows = []
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard state.aiSuggestionsEnabled, trimmed.count >= 4, !looksLikeURL else {
            aiTask = nil
            return
        }
        aiTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let results = await state.suggestions(forQuery: trimmed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                aiRows = results
                aiTask = nil
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
