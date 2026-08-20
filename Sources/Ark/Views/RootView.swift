import SwiftUI

/// The gap between the web content and the window edges.
///
/// One constant, used by the content pane *and* the command-bar overlay, because
/// they were drifting apart: top was 0, bottom and trailing 4, and leading came
/// from the 8pt resize handle. Matching the handle's width means the left gap
/// needs no padding of its own while the sidebar is pinned.
enum Layout {
    static let contentInset: CGFloat = 8
}

struct RootView: View {
    @Environment(BrowserState.self) private var state

    private var rimHighlight: Double {
        GlassRamp.active(state.glassChrome, state.glassIntensity)
            ? GlassRamp.rimHighlight(state.glassIntensity)
            : 0.08
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if state.sidebarPinned {
                    SidebarView()
                        .frame(width: state.sidebarWidth)
                        // Order is load-bearing: `.background` inserts behind
                        // whatever it is attached to, so the tint has to be
                        // applied *before* the glass to land in front of it.
                        // Reversed, the glass surface covered the tint entirely
                        // and the sidebar never coloured at all.
                        .background(ChromeTint(tint: state.chromeTint,
                                               strength: state.chromeTintStrength))
                        .glassSurface(.chrome,
                                      in: RoundedRectangle(cornerRadius: 0, style: .continuous),
                                      enabled: state.glassChrome,
                                      intensity: state.glassIntensity)
                    ResizeHandle(
                        width: Binding(get: { state.sidebarWidth },
                                       set: { state.sidebarWidth = $0 }),
                        edge: .leading,
                        range: 180...460,
                        onCommit: state.save)
                }

                VStack(spacing: 0) {
                    // Without a pinned sidebar the traffic lights need somewhere
                    // to sit. This strip is that space, and doubles as the
                    // drag/double-click-to-zoom target.
                    if !state.sidebarPinned {
                        // No surface of its own: it's a hole in the layout that
                        // the window's tinted gutter shows through, so the
                        // traffic lights float on the same colour as every other
                        // edge. Given a glass fill and a hairline, it read as a
                        // stray toolbar bolted above the page.
                        // Nothing but space for the traffic lights. The chatbot
                        // toggle used to live here so hiding the sidebar didn't
                        // hide the feature, but a lone floating icon over the
                        // page looked like a stray control — ⌘⇧A does the job.
                        WindowChromeArea()
                            .frame(height: 26)
                            .frame(maxWidth: .infinity)
                    }
                    SplitContainer()
                }
                .padding(.top, Layout.contentInset)
                .padding(.bottom, Layout.contentInset)
                .padding(.trailing, Layout.contentInset)
                // The resize handle is exactly `contentInset` wide, so it
                // already supplies the left gap while the sidebar is pinned.
                .padding(.leading, state.sidebarPinned ? 0 : Layout.contentInset)

                if state.showAISidebar {
                    ResizeHandle(
                        width: Binding(get: { state.aiWidth },
                                       set: { state.aiWidth = $0 }),
                        edge: .trailing,
                        range: 260...620,
                        onCommit: state.save)
                    AISidebarView()
                        .frame(width: state.aiWidth)
                        .glassSurface(.chrome,
                                      in: RoundedRectangle(cornerRadius: 0, style: .continuous),
                                      enabled: state.glassChrome,
                                      intensity: state.glassIntensity)
                }
            }

            // Auto-hidden sidebar: floats above the content on left-edge hover.
            if state.sidebarFloating {
                HStack(spacing: 0) {
                    SidebarView()
                        .frame(width: state.sidebarWidth)
                        .background(ChromeTint(tint: state.chromeTint,
                                               strength: state.chromeTintStrength))
                        .glassSurface(.chrome,
                                      in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                      enabled: state.glassChrome, intensity: state.glassIntensity)
                        .glassRim(cornerRadius: 14, enabled: state.glassChrome,
                                  intensity: state.glassIntensity)
                        .shadow(color: .black.opacity(0.35), radius: 26, x: 8)
                        .padding(.top, 38)
                        .padding(.bottom, 8)
                        .padding(.leading, 8)
                        // Keep it open while the pointer is inside it, even if the
                        // edge monitor thinks we've moved past the reveal strip.
                        .onHover { inside in
                            if inside { state.revealSidebar() }
                            else { state.scheduleSidebarHide() }
                        }
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
                .zIndex(5)
            }

            if state.showFindBar {
                VStack {
                    HStack {
                        Spacer()
                        FindBar().padding(.top, 12).padding(.trailing, 16).jellyAppear()
                    }
                    Spacer()
                }
            }

            // Fill-login chip, bottom-left of the content area.
            if let tab = state.focusedTab,
               state.passwords.offerFillFor == tab.id,
               state.passwords.savePrompt == nil {
                VStack {
                    Spacer()
                    HStack {
                        FillLoginChip(tab: tab)
                            .padding(.leading, state.sidebarPinned ? 16 : 20)
                            .padding(.bottom, 16)
                            .jellyAppear()
                        Spacer()
                    }
                }
            }

            if let prompt = state.passwords.savePrompt {
                VStack {
                    SavePasswordBanner(prompt: prompt).padding(.top, 14).jellyAppear()
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if state.showDownloads {
                VStack {
                    Spacer()
                    HStack {
                        DownloadsPanel()
                            .padding(.leading, state.sidebarPinned ? 12 : 20)
                            .padding(.bottom, 44)
                            .jellyAppear()
                        Spacer()
                    }
                }
                .transition(.opacity)
            }

            // Ghost of the dragged tab. Rendered at the root so it is visible
            // over the sidebar and the page alike, and never hit-tested.
            if state.drag.isDragging {
                GeometryReader { geo in
                    HStack(spacing: 6) {
                        Favicon(host: state.drag.ghostHost).frame(width: 13, height: 13)
                        Text(state.drag.ghostTitle)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .shadow(radius: 10, y: 3)
                    .fixedSize()
                    .position(
                        x: state.drag.pointerLocation.x - geo.frame(in: .global).minX + 62,
                        y: state.drag.pointerLocation.y - geo.frame(in: .global).minY - 14)
                }
                .allowsHitTesting(false)
                .zIndex(50)
            }

            // The resize guide — the only thing that moves during a drag.
            if let preview = state.resizePreview {
                GeometryReader { geo in
                    let x = preview.leadingEdge
                        ? preview.width
                        : geo.size.width - preview.width
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2)
                            .shadow(color: .accentColor.opacity(0.7), radius: 4)
                        Text("\(Int(preview.width))")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                            .offset(y: 44)
                    }
                    .frame(height: geo.size.height)
                    .position(x: x, y: geo.size.height / 2)
                }
                .allowsHitTesting(false)
                .zIndex(60)
            }

            if let peek = state.peekTab {
                PeekOverlay(tab: peek)
            }

            if state.commandBarMode != nil {
                // Inset to the content area. The new-tab colour field is opaque,
                // so covering the whole window read as the sidebar vanishing
                // every time you opened a tab.
                HStack(spacing: 0) {
                    if state.sidebarPinned {
                        Color.clear.frame(width: state.sidebarWidth + Layout.contentInset)
                    }
                    ZStack {
                        // A new tab gets a colour field; editing an existing URL
                        // keeps a plain dim, so the page you're reading stays legible.
                        Group {
                            if state.commandBarMode == .newTab {
                                LiquidBackdrop(seed: state.newTabSeed, dimming: 0.30)
                                    .clipShape(RoundedRectangle(cornerRadius: 8,
                                                                style: .continuous))
                                    .transition(.opacity)
                            } else {
                                Color.black.opacity(0.18)
                            }
                        }
                        .onTapGesture { state.closeCommandBar(committed: false) }
                        VStack {
                            CommandBar().padding(.top, 120).jellyAppear()
                            Spacer()
                        }
                    }
                    .padding(.top, Layout.contentInset)
                    .padding(.bottom, Layout.contentInset)
                    .padding(.trailing, Layout.contentInset)
                    .padding(.leading, state.sidebarPinned ? 0 : Layout.contentInset)
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        // .hiddenTitleBar hides the bar and fullSizeContentView extends the
        // content view, but SwiftUI still reserves a titlebar-sized safe area —
        // which showed up as a white band across the top. This is the piece
        // that actually removes it.
        .ignoresSafeArea(.container, edges: .top)
        // The gutter around the page, and the rim on it, are the same surface as
        // the sidebar — so they take the same colour. Left neutral, the 8pt frame
        // read as a grey border drawn between two tinted things.
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                ChromeTint(tint: state.chromeTint,
                           strength: state.chromeTintStrength * 0.85)
            }
            .ignoresSafeArea()
        }
        // Links handed to Ark by other apps (Mail, Slack, Finder) when it is
        // the default browser. Front the window so the tab is actually visible.
        .sheet(isPresented: Binding(
            get: { state.organizeProposal != nil },
            set: { if !$0 { state.dismissOrganizeProposal() } }
        )) {
            if let proposal = state.organizeProposal {
                OrganizeTabsSheet(proposal: proposal).environment(state)
            }
        }
        .alert("Couldn't organize tabs",
               isPresented: Binding(
                get: { state.organizeError != nil },
                set: { if !$0 { state.organizeError = nil } })) {
            Button("OK") { state.organizeError = nil }
        } message: {
            Text(state.organizeError ?? "")
        }
        .onOpenURL { url in
            NSApp.activate(ignoringOtherApps: true)
            state.openInNewTab(url)
        }
        .animation(Motion.settle, value: state.showSidebar)
        .animation(Motion.settle, value: state.sidebarFloating)
    }
}

/// Draggable edge between the sidebar and the content.
struct ResizeHandle: View {
    @Environment(BrowserState.self) private var state
    @Binding var width: Double
    let edge: HorizontalEdge
    let range: ClosedRange<Double>
    let onCommit: () -> Void

    @State private var hovering = false
    @State private var dragging = false
    @State private var start: Double?
    /// Tracked so hover push/pop stays balanced — an unbalanced stack leaves the
    /// resize cursor stuck over the page.
    @State private var pushedCursor = false

    var body: some View {
        Rectangle()
            .fill(hovering || dragging
                  ? AnyShapeStyle(Color.accentColor.opacity(0.55))
                  : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.18),
                                                          .black.opacity(0.10)],
                                                 startPoint: .top, endPoint: .bottom)))
            .frame(width: (hovering || dragging) ? 3 : 1)
            // Matches Layout.contentInset so the gap to the left of the page is
            // the same as the gap on every other side.
            .frame(width: Layout.contentInset)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                setCursor(inside || dragging)
            }
            // Only the handle's own hover state animates; never a width.
            .animation(Motion.squish, value: hovering)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if start == nil {
                            start = width
                            dragging = true
                            setCursor(true)
                        }
                        let delta = edge == .leading
                            ? value.translation.width
                            : -value.translation.width
                        let raw = ((start ?? width) + delta).rounded()
                        let clamped = Swift.min(Swift.max(raw, range.lowerBound),
                                                range.upperBound)
                        // Only the guide moves. No layout, so nothing to stutter.
                        state.resizePreview = BrowserState.ResizePreview(
                            leadingEdge: edge == .leading, width: clamped)
                    }
                    .onEnded { _ in
                        // Exactly one layout pass, at the end of the drag.
                        if let preview = state.resizePreview { width = preview.width }
                        state.resizePreview = nil
                        start = nil
                        dragging = false
                        setCursor(hovering)
                        onCommit()
                    }
            )
            .onDisappear {
                setCursor(false)
                state.resizePreview = nil
            }
    }

    private func setCursor(_ wanted: Bool) {
        guard wanted != pushedCursor else { return }
        pushedCursor = wanted
        if wanted { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
}


/// The page's dominant colour, washed across the sidebar.
///
/// Kept deliberately weak — a vertical falloff at low opacity, so it reads as a
/// hint of the site rather than a coloured panel. Cross-fades on change, which
/// is why the tint is cleared at navigation start: the sidebar eases back to
/// neutral and then into the new colour, instead of snapping between two sites.
private struct ChromeTint: View {
    let tint: Color?
    /// 0…1 from Settings. Maps onto the two wash opacities below; at 0 the view
    /// renders nothing at all rather than a transparent layer.
    var strength: Double = 0.55

    var body: some View {
        // A flat wash under the whole sidebar plus a stronger pool at the top,
        // rather than a gradient that faded to nothing halfway down — at the old
        // strength the bottom half of the sidebar showed no colour at all.
        let live = tint != nil && strength > 0.01
        let base = live ? 0.55 * strength : 0
        let pool = live ? 0.62 * strength : 0
        ZStack {
            (tint ?? .clear).opacity(base)
            LinearGradient(
                colors: [(tint ?? .clear).opacity(pool),
                         (tint ?? .clear).opacity(pool * 0.35),
                         .clear],
                startPoint: .top,
                endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.55), value: tint)
        .animation(Motion.settle, value: strength)
        .allowsHitTesting(false)
    }
}
