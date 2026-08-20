import SwiftUI

/// Peek, in the shape Arc and Zen use: the linked page slides in from the right
/// over the current one, which stays visible down the left edge so you keep your
/// place. Escape (or clicking the exposed edge) closes it; ⌘⏎ promotes it to a
/// real tab.
struct PeekOverlay: View {
    @Environment(BrowserState.self) private var state
    let tab: BrowserTab
    @State private var shown = false

    /// How much of the parent page stays visible on the left.
    private let exposedEdge: CGFloat = 84

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                // Dim the parent, and let a click on it dismiss.
                Rectangle()
                    .fill(.black.opacity(shown ? 0.28 : 0))
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                VStack(spacing: 0) {
                    bar
                    Divider().opacity(0.4)
                    ZStack {
                        Color(nsColor: .textBackgroundColor)
                        WebContainer(tab: tab)
                        if tab.isLoading {
                            VStack {
                                ProgressView(value: tab.progress)
                                    .progressViewStyle(.linear)
                                    .frame(height: 2)
                                Spacer()
                            }
                        }
                    }
                }
                .frame(width: max(520, geo.size.width - exposedEdge))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .glassRim(cornerRadius: 14, lineWidth: 1.5, enabled: state.glassChrome, intensity: state.glassIntensity)
                .shadow(color: .black.opacity(0.45), radius: 34, x: -10, y: 8)
                .padding(.vertical, 10)
                .padding(.trailing, 10)
                .offset(x: shown ? 0 : geo.size.width)
            }
        }
        .onAppear {
            withAnimation(Motion.pop) { shown = true }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(tab.webView.url?.host ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button { tab.goBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!tab.canGoBack)
            .foregroundStyle(tab.canGoBack ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))

            Button { state.promotePeek() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Open as Tab")
                    Text("⌘⏎").foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)

            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close peek (esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassSurface(.chrome, in: Rectangle(), enabled: state.glassChrome, intensity: state.glassIntensity)
    }

    private func close() {
        withAnimation(Motion.exit) { shown = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            state.dismissPeek()
        }
    }
}
