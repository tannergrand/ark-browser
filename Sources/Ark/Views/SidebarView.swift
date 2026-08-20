import SwiftUI

/// Arc-style sidebar: window controls and nav at the top, then a favorites icon
/// row, a permanent pinned section with groups, and an ephemeral Today section.
struct SidebarView: View {
    @Environment(BrowserState.self) private var state
    @State private var renamingID: UUID?
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pinnedGroupsSection
                    todaySection
                    newTabRow
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            // Leaves room for the traffic lights, which float over the sidebar,
            // and doubles as the title-bar substitute: drag to move the window,
            // double-click to zoom.
            // Traffic lights float over the left of this strip; the chatbot
            // toggle takes the right, so it reads as a window-level control
            // rather than a tab-list entry.
            WindowChromeArea()
                .frame(height: 26)
                .overlay(alignment: .trailing) { askPageButton }

            HStack(spacing: 2) {
                navButton("chevron.left", enabled: state.focusedTab?.canGoBack ?? false,
                          help: "Back (⌘[)") {
                    state.focusedTab?.goBack()
                }
                navButton("chevron.right", enabled: state.focusedTab?.canGoForward ?? false,
                          help: "Forward (⌘])") {
                    state.focusedTab?.goForward()
                }
                navButton(state.focusedTab?.isLoading == true ? "xmark" : "arrow.clockwise",
                          enabled: state.focusedTab != nil,
                          help: state.focusedTab?.isLoading == true
                                ? "Stop loading this page"
                                : "Reload this page (⌘R)") {
                    if state.focusedTab?.isLoading == true { state.focusedTab?.stop() }
                    else { state.focusedTab?.reload() }
                }
                Spacer()
                shieldButton
                navButton(state.focusedTabIsBookmarked ? "bookmark.fill" : "bookmark",
                          enabled: state.focusedTab != nil,
                          help: state.focusedTabIsBookmarked
                                ? "Remove this page from bookmarks (⌘D)"
                                : "Bookmark this page (⌘D)") {
                    state.toggleBookmark()
                }
                navButton(state.sidebarAutoHide ? "sidebar.leading" : "sidebar.left",
                          enabled: true, active: state.sidebarAutoHide,
                          help: state.sidebarAutoHide
                                ? "Sidebar auto-hides — click to keep it pinned open"
                                : "Auto-hide the sidebar, revealing it on hover at the left edge") {
                    state.sidebarAutoHide.toggle()
                    state.save()
                }
            }

            urlPill

            // Pinned tabs and favourites are fixed here rather than scrolling
            // with the Today list: the point of pinning something is that it is
            // always in the same place.
            favoritesRow
            pinnedIconStrip
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    /// Top-level pinned tabs as icons in their own container, Arc/Zen style.
    ///
    /// The tiles size themselves to the sidebar, so widening it makes them
    /// bigger rather than just spreading them out, and a single pinned tab sits
    /// centred instead of hugging the left edge.
    private var pinnedIconStrip: some View {
        let tabs = state.pinned.filter { !$0.isGroup }.compactMap { $0.tab }
        // Arc and Zen both use a fixed four-across grid whose tiles divide the
        // available width, so the row always reaches both edges and the tiles
        // grow with the sidebar. 20 is the sidebar's own horizontal padding.
        let inner = max(60, state.sidebarWidth - 20)
        let spacing: CGFloat = 6
        let columns = 4
        let tile = max(24, (inner - spacing * CGFloat(columns - 1)) / CGFloat(columns))

        return Group {
            if !tabs.isEmpty {
                VStack(spacing: spacing) {
                    ForEach(Array(rows(tabs, perRow: columns).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: spacing) {
                            // Centred, with the tile size still coming from the
                            // four-across grid — so a short row sits in the
                            // middle at the same size rather than stretching or
                            // hugging the leading edge.
                            Spacer(minLength: 0)
                            ForEach(row) { tab in
                                PinnedIcon(tab: tab, size: tile,
                                           renamingID: $renamingID, draft: $draft)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                // No container box. Arc and Zen let the tiles sit directly on the
                // sidebar; a bordered panel around them reads as a widget.
                .padding(.top, 6)
                .padding(.bottom, 2)
            }
        }
    }

    private func rows(_ tabs: [BrowserTab], perRow: Int) -> [[BrowserTab]] {
        guard perRow > 0 else { return [tabs] }
        return stride(from: 0, to: tabs.count, by: perRow).map {
            Array(tabs[$0..<min($0 + perRow, tabs.count)])
        }
    }

    /// Clicking the pill opens the command bar in edit mode — Arc's pattern.
    private var urlPill: some View {
        Button {
            state.commandBarMode = .editURL
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.focusedTab?.webView.url?.scheme == "https"
                      ? "lock.fill" : "globe")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(prettyURL)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .glassRim(cornerRadius: 7, enabled: state.glassChrome, intensity: state.glassIntensity)
            .contentShape(Rectangle())
        }
        .buttonStyle(JellyPress(scale: 0.985))
        .help("Edit address (⌘L)")
        .overlay(alignment: .bottom) {
            if let tab = state.focusedTab, tab.isLoading {
                ProgressView(value: tab.progress)
                    .progressViewStyle(.linear)
                    .tint(state.chromeTint ?? .accentColor)
                    .frame(height: 1.5)
                    .offset(y: 3)
            }
        }
    }

    private var prettyURL: String {
        guard let url = state.focusedTab?.webView.url, let host = url.host else {
            return "Search or enter address"
        }
        var shown = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if url.path != "/" && !url.path.isEmpty { shown += url.path }
        return shown
    }

    // MARK: - Favorites

    private var favoritesRow: some View {
        Group {
            if !state.favorites.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5),
                          spacing: 4) {
                    ForEach(state.favorites) { tab in
                        Button { state.show(tab) } label: {
                            TabIcon(tab: tab, size: 30)
                                .frame(width: 30, height: 30)
                                .background {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(state.displayed.contains(tab.id)
                                              ? Color.accentColor.opacity(0.22)
                                              : Color.primary.opacity(0.06))
                                }
                        }
                        .buttonStyle(JellyPress(scale: 0.90))
                        .help(tab.displayTitle)
                        .contextMenu { tabMenu(tab) }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Pinned

    private var pinnedGroupsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(state.pinned.filter(\.isGroup)) { item in
                NodeRow(item: item, depth: 0, renamingID: $renamingID, draft: $draft)
                    .transition(Motion.appear)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - AI

    /// The chatbot toggle, parked in the title-bar strip.
    private var askPageButton: some View {
        Button {
            state.showAISidebar.toggle()
        } label: {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(state.showAISidebar ? Color.accentColor.opacity(0.20) : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(JellyPress(scale: 0.9))
        .foregroundStyle(state.showAISidebar
                         ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        .help("Ask this page (⌘⇧A)")
    }

    /// AI tab grouping, as an icon beside the Today label — it acts on the tabs
    /// listed under that divider, so it belongs on the divider itself.
    ///
    /// Sized to the 14pt header row, which is height-locked so the divider can't
    /// shift when a button appears or disappears.
    private var organizeButton: some View {
        Button {
            Task { await state.organizeTabs() }
        } label: {
            Group {
                if state.organizing {
                    ProgressView().controlSize(.small).scaleEffect(0.42)
                } else {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 9.5))
                }
            }
            .frame(width: 13, height: 13)
            .foregroundStyle(.tertiary)
            .padding(2)
            .contentShape(Rectangle())
        }
        .buttonStyle(JellyPress(scale: 0.8))
        .disabled(state.organizing || state.organizableTabs.count < 2)
        .help(state.organizing
              ? "Grouping tabs…"
              : "Group these \(state.organizableTabs.count) tabs by topic with AI")
    }

    // MARK: - Today

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("Today")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                if state.organizableTabs.count >= 2 || state.organizing {
                    organizeButton
                }
                Rectangle().fill(.quaternary).frame(height: 1)
                if state.clearableTodayCount > 0 {
                    Button {
                        state.closeAllTodayTabs()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(JellyPress(scale: 0.8))
                    .help("Clear tabs — closes \(state.clearableTodayCount) Today tab\(state.clearableTodayCount == 1 ? "" : "s"), keeps the one you're on. ⌘⇧T reopens.")
                }
            }
            // Fixed height so the divider can't shift when the button appears.
            .frame(height: 14)
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())


            // A tree, so groups can live in Today without being pinned.
            // The id list drives the reorder animation.
            ForEach(state.visibleTodayItems) { item in
                NodeRow(item: item, depth: 0, renamingID: $renamingID, draft: $draft)
                    .transition(Motion.appear)
            }
            if state.draggedTabGroupSection == .today {
                RootDropStrip(placement: .today, label: "Drop here to leave the group")
            }
        }

    }

    // MARK: - New tab (inline, under the last tab)

    private var newTabRow: some View {
        Button { state.beginNewTab() } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 14)
                Text("New Tab")
                    .font(.system(size: 13.5))
                Spacer(minLength: 0)
                Text("⌘T")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(JellySquashButton())
        .foregroundStyle(.secondary)
        .help("Open a new tab (⌘T)")
        .padding(.top, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Spacer()

            Button {
                state.showDownloads.toggle()
                state.downloads.hasUnseen = false
            } label: {
                Image(systemName: state.downloads.active > 0
                      ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(state.downloads.hasUnseen
                                     ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Downloads (⌘⌥L)")

            Button { state.newGroup() } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New group")
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Bits

    private var shieldButton: some View {
        let active = state.blockingActive(for: state.focusedTab)
        let count = state.focusedTab?.blockedCount ?? 0
        return Button {
            if let tab = state.focusedTab { state.toggleBlocking(forHostOf: tab) }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: active ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 11))
                if active && count > 0 {
                    Text("\(count)").font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .frame(height: 20)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active
              ? "Blocking on — \(count) blocked (approximate). Click to allow this site."
              : "Blocking off for this site. Click to re-enable.")
    }

    private func navButton(_ symbol: String, enabled: Bool, active: Bool = false,
                           help: String = "",
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 20)
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor)
                                        : AnyShapeStyle(enabled ? .secondary : .tertiary))
                .contentShape(Rectangle())
        }
        .buttonStyle(JellyPress(scale: 0.88))
        .disabled(!enabled)
        .help(help)
    }

    @ViewBuilder
    private func tabMenu(_ tab: BrowserTab) -> some View {
        TabContextMenu(tab: tab, renamingID: $renamingID, draft: $draft)
    }
}

// MARK: - Nodes

/// A pinned-section row: either a group (with children) or a tab.
private struct NodeRow: View {
    @Environment(BrowserState.self) private var state
    let item: SidebarItem
    let depth: Int
    @Binding var renamingID: UUID?
    @Binding var draft: String

    var body: some View {
        if let tab = item.tab {
            TabRow(tab: tab, depth: depth, renamingID: $renamingID, draft: $draft)
        } else {
            folderRow
            if item.isExpanded {
                ForEach(item.children) { child in
                    NodeRow(item: child, depth: depth + 1, renamingID: $renamingID, draft: $draft)
                        .transition(Motion.appear)
                }

            }
        }
    }

    /// Split out because inlining the ternaries made the type-checker time out.
    private func commitGroupRename() {
        let trimmed: String = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { item.groupName = trimmed }
        renamingID = nil
        state.save()
    }

    @ViewBuilder
    private func groupPlacementButton(_ item: SidebarItem) -> some View {
        let isToday: Bool = state.placement(of: item) == .today
        let title: String = isToday ? "Pin Group" : "Unpin Group"
        let target: BrowserState.GroupPlacement = isToday ? .pinned : .today
        Button(title) { state.moveGroup(item, to: target) }
    }

    private var folderRow: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(Motion.settle) { item.isExpanded.toggle() }
                state.save()
            } label: {
                Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
            .buttonStyle(.plain)
            .help(item.isExpanded
                  ? "Collapse this group"
                  : "Expand this group (\(item.children.count) tab\(item.children.count == 1 ? "" : "s"))")

            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if renamingID == item.id {
                TextField("Group", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
                    .onSubmit { commitGroupRename() }
            } else {
                Text(item.groupName ?? "Group")
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(item.tabCount)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 6)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(state.drag.isGroupTargeted(item.id)
                      ? Color.accentColor.opacity(0.22) : .clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor
                            .opacity(state.drag.isGroupTargeted(item.id) ? 0.7 : 0),
                                      lineWidth: 1.5)
                }
        }
        .contentShape(Rectangle())
        // Anywhere on the row toggles the group. The chevron still works, but
        // hitting a 10pt target to open a folder is a needless bit of precision.
        .onTapGesture {
            guard renamingID != item.id else { return }
            withAnimation(Motion.settle) { item.isExpanded.toggle() }
            state.save()
        }
        // Groups deliberately have no drag source: mixing a system drag with
        // the pointer-tracked one is what broke tab dragging six times over.
        // Move a group with the Pin/Unpin Group menu item instead.
        .reportsFrame(state.drag, as: .group(item.id))
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { value in
                    if state.drag.draggingID == nil {
                        state.drag.begin(group: item, at: value.location)
                    }
                    state.drag.update(to: value.location)
                }
                .onEnded { _ in
                    withAnimation(Motion.settle) { state.commitDrag() }
                }
        )
        .opacity(state.drag.draggingID == item.id ? 0.4 : 1)
        .contextMenu {
            Button("Rename…") { draft = item.groupName ?? ""; renamingID = item.id }
            Button("New Tab in Group") {
                let tab = state.newTab(activate: true)
                state.move(tab, into: item)
                state.commandBarMode = .newTab
            }
            groupPlacementButton(item)
            Divider()
            Button("Delete Group", role: .destructive) { state.deleteGroup(item) }
        }
    }
}

private struct TabRow: View {
    @Environment(BrowserState.self) private var state
    let tab: BrowserTab
    let depth: Int
    @Binding var renamingID: UUID?
    @Binding var draft: String
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var pressing = false
    @State private var pressAnchor: UnitPoint = .center
    @State private var rowWidth: CGFloat = 1

    /// One squash-and-release. Not tied to mouse-down state: tracking that needs
    /// a gesture, and a gesture here is what broke dragging.
    private func squash() {
        pressing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(110))
            pressing = false
        }
    }

    private var isDisplayed: Bool { state.displayed.contains(tab.id) }
    private var isFocused: Bool { state.focusedTabID == tab.id }
    private var isDragging: Bool { state.drag.draggingTabID == tab.id }

    var body: some View {
        HStack(spacing: 7) {
            if tab.isLoading {
                // Same colour that's tinting the sidebar, so a loading tab reads
                // as part of the chrome rather than a stray system accent.
                ProgressView().controlSize(.small).scaleEffect(0.55)
                    .tint(state.chromeTint ?? .accentColor)
                    .frame(width: 14, height: 14)
            } else if let emoji = tab.emoji {
                Text(emoji)
                    .font(.system(size: 13))
                    .frame(width: 15, height: 15)
                    .opacity(tab.isSnoozed ? 0.45 : 1)
            } else {
                Favicon(host: tab.faviconHost)
                    .frame(width: 15, height: 15)
                    // Dimmed, with a moon badge: the tab is still here, its page
                    // just isn't in memory.
                    .opacity(tab.isSnoozed ? 0.45 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if tab.isSnoozed {
                            Image(systemName: "moon.zzz.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.secondary)
                                .padding(1)
                                .background(.background, in: Circle())
                                .offset(x: 3, y: 3)
                        }
                    }
                    .help(tab.isSnoozed
                          ? "Snoozed to save memory — click to reload it"
                          : "")
            }

            if renamingID == tab.id {
                TextField("Title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .onSubmit {
                        tab.customTitle = draft.isEmpty ? nil : draft
                        renamingID = nil
                        state.save()
                    }
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                // Every trailing control is always laid out and only cross-faded.
                // Inserting a view on hover changed the row's height, which is
                // what nudged the Today divider whenever a pinned tab was hovered.
                // The slot width is fixed per tier for the same reason.
                HStack(spacing: 2) {
                    if tab.tier == .pinned {
                        // On hover only. A pin on every pinned row, permanently,
                        // is just restating which section you're looking at.
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 14)
                            .opacity(hovering ? 1 : 0)
                            .help("Pinned — stays across restarts")
                    }
                    Button { state.close(tab) } label: {
                        Image(systemName: tab.tier == .today ? "xmark" : "arrow.counterclockwise")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(JellyPress(scale: 0.8))
                    .foregroundStyle(.secondary)
                    .help(tab.tier == .today
                          ? "Close tab (⌘W)"
                          : "Reset this pinned tab back to its pinned page")
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                }
                .frame(width: tab.tier == .pinned ? 30 : 14, height: 14)
                .animation(Motion.squish, value: hovering)
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isDisplayed ? Color.accentColor.opacity(isFocused ? 0.22 : 0.12)
                                  : (hovering ? Color.primary.opacity(0.06) : Color.clear))
                .overlay { InsertBar(edge: state.drag.insertEdge(for: tab.id)) }
        }

        .frame(height: 29)
        .contentShape(Rectangle())
        .jellyRow(pressed: pressing, hovering: hovering,
                  dragging: isDragging, selected: isDisplayed, anchor: pressAnchor)
        .onHover { hovering = $0 }
        // Shift-click peeks the tab in an overlay instead of switching to it,
        // matching shift-click on a link.
        .highPriorityGesture(
            TapGesture().modifiers(.shift).onEnded {
                if let url = tab.webView.url ?? URL(string: tab.urlString) {
                    state.peek(url)
                }
            }
        )
        // SpatialTapGesture rather than onTapGesture: it reports where the click
        // landed, which is what anchors the squash. A second DragGesture would
        // have given the same information and did — along with breaking
        // reordering and selection outright, because two drag gestures on one
        // row fight over the same events.
        .gesture(
            SpatialTapGesture(coordinateSpace: .local)
                .onEnded { value in
                    pressAnchor = UnitPoint(
                        x: min(max(value.location.x / max(rowWidth, 1), 0), 1), y: 0.5)
                    squash()
                    state.show(tab)
                }
        )
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { rowWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in rowWidth = new }
            }
            .allowsHitTesting(false)
        }
        .reportsFrame(state.drag, as: .row(tab.id))
        // minimumDistance keeps a plain click a click; only real movement starts
        // a drag. Restored to 8 after a 0 here broke reordering.
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { value in
                    if state.drag.draggingTabID == nil {
                        state.drag.begin(tab: tab, at: value.location)
                    }
                    state.drag.update(to: value.location)
                }
                .onEnded { _ in
                    withAnimation(Motion.settle) { state.commitDrag() }
                }
        )
        .opacity(isDragging ? 0.4 : 1)

        .contextMenu {
            TabContextMenu(tab: tab, renamingID: $renamingID, draft: $draft)
        }
    }
}

private struct TabContextMenu: View {
    @Environment(BrowserState.self) private var state
    let tab: BrowserTab
    @Binding var renamingID: UUID?
    @Binding var draft: String

    /// A short, deliberately opinionated set. A full emoji picker in a context
    /// menu is worse than a dozen good defaults plus the system picker via
    /// Rename — and these are the ones people actually label tabs with.
    private static let icons = ["📥", "📅", "💬", "🎵", "📝", "🧭", "🛠", "📊",
                                "🙏", "❤️", "⭐️", "🔥", "🧪", "📚", "🏠", "💡"]

    var body: some View {
        Button("Rename…") { draft = tab.displayTitle; renamingID = tab.id }
        Menu("Tab Icon") {
            ForEach(Self.icons, id: \.self) { icon in
                Button(icon) { tab.emoji = icon; state.save() }
            }
            if tab.emoji != nil {
                Divider()
                Button("Use Site Icon") { tab.emoji = nil; state.save() }
            }
        }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.urlString, forType: .string)
        }
        Divider()

        if state.displayed.count < 4 && !state.displayed.contains(tab.id) {
            Button("Add to Split View") { state.addToSplit(tab) }
        }
        if state.displayed.contains(tab.id) && state.displayed.count > 1 {
            Button("Remove from Split") { state.removeFromSplit(tab) }
        }
        Divider()

        if tab.tier != .favorite {
            Button("Add to Favorites") { state.addToFavorites(tab) }
        }
        if tab.tier == .today {
            Button("Pin Tab") { state.pin(tab) }
        } else {
            Button("Unpin Tab") { state.unpin(tab) }
            Button("Reset to Pinned Page") { tab.resetToPinned() }
        }

        if state.groupContaining(tab.id) != nil {
            Button("Remove from Group") {
                withAnimation(Motion.settle) { state.ungroup(tab) }
            }
        }
        if !state.allGroups.isEmpty {
            Menu("Move to Group") {
                ForEach(state.allGroups) { folder in
                    Button(folder.groupName ?? "Group") { state.move(tab, into: folder) }
                }
            }
        }
        Button("New Group with Tab") {
            let folder = state.newGroup(containing: tab)
            draft = "New Group"
            renamingID = folder.id
        }

        Divider()
        Button(tab.tier == .today ? "Close Tab" : "Reset Tab", role: .destructive) {
            state.close(tab)
        }
    }
}

/// Drop target that lifts a tab to the top level of a section — how a tab gets
/// back out of a group by dragging.
private struct RootDropStrip: View {
    @Environment(BrowserState.self) private var state
    let placement: BrowserState.GroupPlacement
    let label: String

    private var targeted: Bool {
        state.drag.isRootTargeted(pinned: placement == .pinned)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.16) : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(targeted ? Color.accentColor
                                                  : Color.secondary.opacity(0.35))
                }
        }
        .padding(.top, 4)
        .reportsFrame(state.drag, as: .rootStrip(pinned: placement == .pinned))
        .transition(Motion.appear)
    }
}

/// Favicons, cached in memory by host.
///
/// This used to be a bare `AsyncImage`, which re-enters the image pipeline
/// whenever the view is re-created — and during a sidebar resize that is every
/// row, every frame. A tiny host-keyed cache makes a repeat render free, which
/// is a real part of why resizing stuttered.
///
/// Fetched straight from each site's /favicon.ico: no third-party favicon
/// service, so nothing about browsing leaves the machine.
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()

    private var images: [String: NSImage] = [:]
    private var misses: Set<String> = []
    private var inFlight: Set<String> = []

    func image(for host: String) -> NSImage? { images[host] }
    func hasFailed(_ host: String) -> Bool { misses.contains(host) }

    func load(_ host: String, onLoad: @escaping (NSImage) -> Void) {
        guard images[host] == nil, !misses.contains(host),
              !inFlight.contains(host),
              let url = URL(string: "https://\(host)/favicon.ico") else { return }
        inFlight.insert(host)

        Task { [weak self] in
            defer { Task { @MainActor in self?.inFlight.remove(host) } }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            // Let the URL cache serve repeats; a favicon rarely changes.
            request.cachePolicy = .returnCacheDataElseLoad
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let image = NSImage(data: data), image.size.width > 0 else {
                await MainActor.run { self?.misses.insert(host) }
                return
            }
            await MainActor.run {
                self?.images[host] = image
                onLoad(image)
            }
        }
    }
}

struct Favicon: View {
    let host: String?
    @State private var loaded: NSImage?

    var body: some View {
        Group {
            if let image = resolved {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                placeholder
            }
        }
        .onAppear(perform: fetch)
        .onChange(of: host) { _, _ in
            loaded = nil
            fetch()
        }
    }

    private var resolved: NSImage? {
        guard let host else { return nil }
        return loaded ?? FaviconCache.shared.image(for: host)
    }

    private func fetch() {
        guard let host, FaviconCache.shared.image(for: host) == nil else { return }
        FaviconCache.shared.load(host) { image in
            if self.host == host { loaded = image }
        }
    }

    private var placeholder: some View {
        Image(systemName: "globe")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
    }
}

/// The accent bar showing which edge a dragged tab will land on.
private struct InsertBar: View {
    let edge: VerticalEdge?

    var body: some View {
        if let edge {
            VStack(spacing: 0) {
                if edge == .bottom { Spacer(minLength: 0) }
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .shadow(color: .accentColor.opacity(0.6), radius: 3)
                    .padding(.horizontal, 3)
                if edge == .top { Spacer(minLength: 0) }
            }
            .allowsHitTesting(false)
        }
    }
}


/// A tab's icon: its emoji if one is set, otherwise the site favicon.
struct TabIcon: View {
    let tab: BrowserTab
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let emoji = tab.emoji {
                Text(emoji).font(.system(size: size * 0.55))
            } else {
                Favicon(host: tab.faviconHost)
            }
        }
        .frame(width: size, height: size)
    }
}


/// A pinned tab as a single icon: favicon or emoji, no title.
///
/// Registers the same drag region as a row, so reordering and dropping into a
/// group keep working — the drag coordinator is pointer-based and only cares
/// about the frame, not the layout that produced it.
private struct PinnedIcon: View {
    @Environment(BrowserState.self) private var state
    let tab: BrowserTab
    var size: CGFloat = 32
    @Binding var renamingID: UUID?
    @Binding var draft: String
    @State private var hovering = false
    @State private var pressing = false

    private var isDisplayed: Bool { state.displayed.contains(tab.id) }
    private var isFocused: Bool { state.focusedTabID == tab.id }
    private var isDragging: Bool { state.drag.draggingTabID == tab.id }

    var body: some View {
        ZStack {
            if tab.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.5)
                    .tint(state.chromeTint ?? .accentColor)
            } else {
                TabIcon(tab: tab, size: size * 0.62)
                    .opacity(tab.isSnoozed ? 0.45 : 1)
            }
            if tab.isSnoozed {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: max(6, size * 0.22)))
                    .foregroundStyle(.secondary)
                    .padding(1)
                    .background(.background, in: Circle())
                    .frame(width: size * 0.8, height: size * 0.8, alignment: .bottomTrailing)
            }
        }
        .frame(width: size, height: size)
        .background {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(isDisplayed
                      ? Color.accentColor.opacity(isFocused ? 0.28 : 0.16)
                      : (hovering ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05)))
                .overlay { InsertBar(edge: state.drag.insertEdge(for: tab.id)) }
        }
        .contentShape(Rectangle())
        .jellyRow(pressed: pressing, hovering: hovering,
                  dragging: isDragging, selected: isDisplayed)
        .onHover { hovering = $0 }
        .help(tab.isSnoozed
              ? "\(tab.displayTitle) — snoozed to save memory"
              : tab.displayTitle)
        .highPriorityGesture(
            TapGesture().modifiers(.shift).onEnded {
                if let url = tab.webView.url ?? URL(string: tab.urlString) { state.peek(url) }
            }
        )
        .onTapGesture {
            pressing = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(110))
                pressing = false
            }
            state.show(tab)
        }
        .reportsFrame(state.drag, as: .row(tab.id))
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { value in
                    if state.drag.draggingTabID == nil {
                        state.drag.begin(tab: tab, at: value.location)
                    }
                    state.drag.update(to: value.location)
                }
                .onEnded { _ in
                    withAnimation(Motion.settle) { state.commitDrag() }
                }
        )
        .opacity(isDragging ? 0.4 : 1)
        .contextMenu {
            TabContextMenu(tab: tab, renamingID: $renamingID, draft: $draft)
        }
    }
}
