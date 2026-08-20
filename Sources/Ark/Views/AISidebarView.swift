import SwiftUI

struct ChatTurn: Identifiable {
    let id = UUID()
    let role: String
    var text: String
}

/// Right-hand panel that asks about whatever page is in the focused pane.
///
/// Runs on Apple Intelligence by default, so the page text never leaves the Mac.
/// Claude is the fallback when Apple Intelligence is unavailable, or when it's
/// picked explicitly — worth it for a long page, since the on-device context
/// window is a fraction of the API's.
struct AISidebarView: View {
    @Environment(BrowserState.self) private var state
    @State private var turns: [ChatTurn] = []
    @State private var draft: String = ""
    @State private var busy = false
    @State private var error: String?
    @State private var contextTabID: UUID?

    private var tab: BrowserTab? { state.focusedTab }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            transcript
            Divider().opacity(0.4)
            composer
        }
        .onChange(of: tab?.id) { _, new in
            // A different page means a different conversation.
            if contextTabID != nil && contextTabID != new { turns = []; error = nil }
            contextTabID = new
        }
        .onAppear { contextTabID = tab?.id }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 0, height: 26)
            Image(systemName: "sparkles").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("Ask this page").font(.system(size: 12, weight: .semibold))
                Text(state.chatUsesOnDevice
                     ? "On-device · sees the first \(OnDeviceChat.contextBudget / 1000)k characters"
                     : "Claude · sends page text to the API")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !turns.isEmpty {
                Button("Clear") { turns = []; error = nil }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { state.showAISidebar = false } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if turns.isEmpty && error == nil { quickActions }

                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(turn.role == "user"
                                 ? "You"
                                 : (state.chatUsesOnDevice ? "Apple Intelligence" : "Claude"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(turn.role == "user"
                                                 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                            Text(turn.text)
                                .font(.system(size: 12.5))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(turn.id)
                    }

                    if busy && turns.last?.role != "assistant" {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reading the page…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }

                    if let error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: turns.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo("bottom") }
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(["Summarize this page in five bullets",
                     "What's the main claim, and what backs it up?",
                     "Pull out every number with its source",
                     "What is this page not telling me?"], id: \.self) { prompt in
                Button {
                    draft = prompt
                    ask()
                } label: {
                    Text(prompt)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 6) {
            TextField("Ask about this page…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...5)
                .onSubmit(ask)
            Button(action: ask) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .disabled(busy || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }

    private func ask() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy, let tab else { return }
        draft = ""
        error = nil
        turns.append(ChatTurn(role: "user", text: question))
        busy = true

        let history = turns.map { ClaudeClient.Message(role: $0.role, content: $0.text) }

        Task {
            let text = await tab.pageText()
            let title = tab.displayTitle
            let url = tab.urlString
            var streamed = ""
            var started = false

            do {
                for try await delta in state.chatStream(question: question, history: history,
                                                        pageTitle: title, pageURL: url,
                                                        pageText: text) {
                    streamed += delta
                    await MainActor.run {
                        if started {
                            turns[turns.count - 1].text = streamed
                        } else {
                            turns.append(ChatTurn(role: "assistant", text: streamed))
                            started = true
                        }
                    }
                }
                await MainActor.run { busy = false }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    busy = false
                }
            }
        }
    }
}
