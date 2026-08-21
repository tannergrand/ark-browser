import SwiftUI

/// Up to four panes side by side, each with a draggable divider between them.
struct SplitContainer: View {
    @Environment(BrowserState.self) private var state

    /// Ratios captured when a drag begins, plus the ratios the drag *would*
    /// commit. Matching the sidebar: the divider drag moves a guide line and
    /// nothing relayouts until release, so a live web view is never resized
    /// mid-drag.
    @State private var dragStart: [Double]?
    @State private var previewRatios: [Double]?
    @State private var previewIndex: Int?

    private var resizing: Bool { previewRatios != nil }

    private static let dividerWidth: CGFloat = 6
    private static let minRatio: Double = 0.15

    private var tabs: [BrowserTab] { state.displayedTabs }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    PaneView(tab: tab,
                             width: width(for: index, total: geo.size.width),
                             paneCount: tabs.count)
                    if index < tabs.count - 1 {
                        PaneDivider(
                            active: previewIndex == index,
                            onStart: {
                                dragStart = normalizedRatios
                                previewIndex = index
                                previewRatios = normalizedRatios
                            },
                            onDrag: { translation in
                                previewRatios = prospective(at: index,
                                                            translation: translation,
                                                            total: geo.size.width)
                            },
                            onEnd: {
                                // One layout pass, at the end of the drag.
                                if let committed = previewRatios {
                                    state.paneRatios = committed
                                }
                                previewRatios = nil
                                previewIndex = nil
                                dragStart = nil
                                state.rememberCurrentSplit()
                                state.save()
                            })
                    }
                }
            }
            .background {
                GeometryReader { inner in
                    Color.clear
                        .onAppear { WindowProbe.report("splitContainer", inner.frame(in: .global)) }
                        .onChange(of: inner.frame(in: .global)) { _, new in
                            WindowProbe.report("splitContainer", new)
                        }
                }
                .allowsHitTesting(false)
            }
            // The guide — the only thing that moves while dragging a divider.
            .overlay(alignment: .topLeading) {
                if let ratios = previewRatios, let index = previewIndex {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                        .shadow(color: .accentColor.opacity(0.7), radius: 4)
                        .offset(x: dividerX(after: index, ratios: ratios,
                                            total: geo.size.width))
                        .allowsHitTesting(false)
                }
            }
            // A width change must never be animated: the spring would fight the
            // drag and the web view would re-layout to stale sizes, which is
            // what read as flashing.
            .transaction { transaction in
                if resizing { transaction.animation = nil }
            }
            .onChange(of: tabs.count) { _, count in
                if state.paneRatios.count != count {
                    state.paneRatios = state.normalized([], count: max(count, 1))
                }
            }
        }
    }

    private var normalizedRatios: [Double] {
        state.normalized(state.paneRatios, count: max(tabs.count, 1))
    }

    /// Whole points only. Fractional widths make WebKit re-layout on subpixel
    /// boundaries, which is both slower and visibly jittery.
    private func width(for index: Int, total: CGFloat) -> CGFloat {
        let dividers = CGFloat(max(0, tabs.count - 1)) * Self.dividerWidth
        let usable = max(0, total - dividers)
        let ratios = normalizedRatios
        guard index < ratios.count else { return usable }

        if index == ratios.count - 1 {
            // Last pane absorbs the rounding remainder so the row always fills.
            let assigned = ratios.dropLast().reduce(0.0) { $0 + (usable * $1).rounded() }
            return max(0, usable - assigned)
        }
        return (usable * ratios[index]).rounded()
    }

    /// Absolute: start ratios + total translation. No accumulation, no drift.
    /// Returns the ratios a release would commit, clamped so the guide stops
    /// where the panes actually would.
    private func prospective(at index: Int, translation: CGFloat,
                             total: CGFloat) -> [Double]? {
        guard let start = dragStart, start.count > index + 1, total > 0 else { return nil }
        let dividers = CGFloat(max(0, tabs.count - 1)) * Self.dividerWidth
        let usable = max(1, total - dividers)
        let delta = Double(translation / usable)

        let headroom = start[index + 1] - Self.minRatio
        let backroom = start[index] - Self.minRatio
        let bounded = Swift.min(Swift.max(delta, -backroom), headroom)

        var next = start
        next[index] = start[index] + bounded
        next[index + 1] = start[index + 1] - bounded
        return next
    }

    /// Left edge of the divider that follows `index`, for the guide.
    private func dividerX(after index: Int, ratios: [Double], total: CGFloat) -> CGFloat {
        let dividers = CGFloat(max(0, tabs.count - 1)) * Self.dividerWidth
        let usable = max(0, total - dividers)
        var x: CGFloat = 0
        for slot in 0...index {
            x += (usable * (ratios[safe: slot] ?? 0)).rounded()
            if slot < index { x += Self.dividerWidth }
        }
        return x + Self.dividerWidth / 2 - 1
    }
}

/// One pane of the split, and a drop target: dragging a tab from the sidebar
/// onto the content area adds it as another pane.
private struct PaneView: View {
    @Environment(BrowserState.self) private var state
    let tab: BrowserTab
    let width: CGFloat
    let paneCount: Int

    private var isFocused: Bool { state.focusedTabID == tab.id && paneCount > 1 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // A tab with nothing loaded shows a colour field rather than a
            // blank white pane. Seeded from the tab id, so it stays put.
            if tab.urlString.isEmpty {
                LiquidBackdrop(seed: tab.id.hashValue, dimming: 0.10)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
            WebContainer(tab: tab)

            // Autofill menu, placed under the page's focused login field. The
            // rect arrives in CSS px relative to the viewport, so it scales with
            // pageZoom to land in view points.
            if let anchor = tab.autofillAnchor, state.focusedTabID == tab.id {
                let rows = state.passwords.candidates(for: tab.host ?? "")
                if !rows.isEmpty {
                    let zoom = tab.webView.pageZoom
                    AutofillPopover(tab: tab, candidates: rows)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .offset(x: min(anchor.minX * zoom, max(0, width - 330)),
                                y: anchor.maxY * zoom + 4)
                        .transition(.opacity)
                }
            }

            if paneCount > 1 {
                Button { state.removeFromSplit(tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .padding(5)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Close this pane")
            }

            if let left = state.drag.splitSide(for: tab.id) {
                splitHint(left: left)
            }
        }
        .frame(width: width)
        .reportsFrame(state.drag, as: .pane(tab.id))
        // Rounded clipping and a glass rim are both per-frame costs on a live
        // web view. During a drag they are dropped and restored on release,
        // which is the difference between smooth and stuttering.
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .glassRim(cornerRadius: 8, lineWidth: 1,
                  enabled: state.glassChrome, intensity: state.glassIntensity,
                  tint: state.chromeTint)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.55 : 0), lineWidth: 2)
        }
        .animation(Motion.settle, value: isFocused)
        .contentShape(Rectangle())
        // Clicking anywhere in a pane focuses it, without stealing the click.
        .onTapGesture { state.focusedTabID = tab.id }
        // Only *between* panes. A uniform inset here added 2pt to the outer
        // edges on top of the window's own gutter, which is half of why the gaps
        // around the page measured 10 left and 6 right instead of 8 and 8.
        .padding(.horizontal, paneCount > 1 ? 2 : 0)
    }

    /// Shades the half the new pane will occupy, so the split is previewed
    /// before the drop rather than guessed at.
    private func splitHint(left: Bool) -> some View {
        let full = state.displayed.count >= 4
        return HStack(spacing: 0) {
            if left {
                zoneFill(full: full)
                Color.clear
            } else {
                Color.clear
                zoneFill(full: full)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func zoneFill(full: Bool) -> some View {
        ZStack {
            Rectangle().fill(full ? Color.orange.opacity(0.22) : Color.accentColor.opacity(0.28))
            VStack(spacing: 5) {
                Image(systemName: full ? "exclamationmark.triangle" : "rectangle.split.2x1")
                    .font(.system(size: 20))
                Text(full ? "Split is full (4 panes)" : "Drop here")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .shadow(radius: 3)
        }
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().strokeBorder(.white.opacity(0.5), lineWidth: 2))
    }
}

/// Thin draggable divider between panes.
private struct PaneDivider: View {
    let active: Bool
    let onStart: () -> Void
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    @State private var hovering = false
    @State private var dragging = false
    /// Tracked so hover push/pop stays balanced — an unbalanced stack leaves
    /// the resize cursor stuck over the page.
    @State private var pushedCursor = false

    var body: some View {
        Rectangle()
            .fill(hovering || dragging
                  ? Color.accentColor.opacity(0.45)
                  : Color.primary.opacity(0.06))
            .frame(width: 1)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                setCursor(inside || dragging)
            }
            .gesture(
                // minimumDistance 0 so the first pixel of movement counts and
                // the divider doesn't appear to "catch" before it starts.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            setCursor(true)
                            onStart()
                        }
                        onDrag(value.translation.width)
                    }
                    .onEnded { _ in
                        dragging = false
                        setCursor(hovering)
                        onEnd()
                    }
            )
            .onDisappear { setCursor(false) }
    }

    private func setCursor(_ wanted: Bool) {
        guard wanted != pushedCursor else { return }
        pushedCursor = wanted
        if wanted { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
}
