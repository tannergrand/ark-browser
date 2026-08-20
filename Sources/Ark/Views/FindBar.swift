import SwiftUI

/// ⌘F find-in-page, backed by WKWebView's native find.
struct FindBar: View {
    @Environment(BrowserState.self) private var state
    @FocusState private var focused: Bool
    @State private var noMatch = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Find on page", text: Binding(
                get: { state.findQuery },
                set: { state.findQuery = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .frame(width: 180)
            .focused($focused)
            .onSubmit { search(forward: true) }
            .onKeyPress(.escape) {
                close()
                return .handled
            }
            .onChange(of: state.findQuery) { _, _ in search(forward: true) }

            if noMatch {
                Text("Not found").font(.system(size: 11)).foregroundStyle(.red)
            }

            Button { search(forward: false) } label: {
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)

            Button { search(forward: true) } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)

            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassSurface(.floating, in: RoundedRectangle(cornerRadius: 9, style: .continuous),
                      enabled: state.glassChrome, intensity: state.glassIntensity)
        .glassRim(cornerRadius: 9, enabled: state.glassChrome, intensity: state.glassIntensity)
        .shadow(radius: 12, y: 4)
        .onAppear { focused = true }
    }

    private func search(forward: Bool) {
        let query = state.findQuery
        guard !query.isEmpty, let tab = state.focusedTab else {
            noMatch = false
            return
        }
        Task {
            let found = await tab.find(query, forward: forward)
            await MainActor.run { noMatch = !found }
        }
    }

    private func close() {
        state.showFindBar = false
        state.findQuery = ""
        noMatch = false
    }
}
