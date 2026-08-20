import Foundation
import Observation
import SwiftUI

/// Which model runs Ark's AI — grouping, command-bar completions, and the page
/// assistant all follow this one setting.
///
/// On-device is the default for all three. Everything these features touch is
/// sensitive: what you're reading, what you type into the address bar, which
/// tabs you have open. Apple Intelligence keeps all of it on the Mac, costs
/// nothing, and works offline. Claude is better on a long page, so it stays
/// available — as a choice, not a default.
///
/// `automatic` is kept only so old settings files still decode; it now resolves
/// exactly like `appleIntelligence`.
enum GroupingEngine: String, CaseIterable, Identifiable, Codable {
    case automatic, appleIntelligence, claude
    var id: String { rawValue }
    /// `automatic` is legacy — decodable, but never offered.
    static var selectable: [GroupingEngine] { [.appleIntelligence, .claude] }
    var label: String {
        switch self {
        case .automatic: return "On-device (Apple Intelligence)"
        case .appleIntelligence: return "On-device (Apple Intelligence)"
        case .claude: return "Claude (sends data to the API)"
        }
    }
}

/// A remembered split: which tabs were side by side, and at what widths.
struct SplitGroup: Codable, Hashable {
    var tabs: [UUID]
    var ratios: [Double]
}

struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: String
}

struct HistoryEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var visitedAt: Date
}

/// What the command bar is doing when it's open.
enum CommandBarMode {
    case newTab       // ⌘T — blank, opens a new tab
    case editURL      // ⌘L — prefilled with the current tab's URL
}

@Observable
final class BrowserState {
    // MARK: - Tabs

    /// Global icon row, never archived.
    var favorites: [BrowserTab] = []
    /// Permanent section, holds tabs and nestable groups.
    var pinned: [SidebarItem] = []
    /// Ephemeral section. A tree, not a flat list, so groups can live here too —
    /// a group is a way to organize open tabs, not a commitment to pin them.
    var todayItems: [SidebarItem] = []

    /// Flat view of the Today section, for the many places that only want tabs.
    var todayTabs: [BrowserTab] { todayItems.allTabs }

    /// The tabs currently on screen, left to right. 1–4 panes.
    var displayed: [UUID] = []
    /// Relative widths of the current panes, summing to 1. Lives here rather
    /// than in the view so it survives relaunch and split restoration.
    var paneRatios: [Double] = [1]
    /// Remembered split groupings. Clicking any member restores the whole split
    /// instead of collapsing to one pane.
    var splitGroups: [SplitGroup] = []
    /// Which pane has keyboard focus.
    var focusedTabID: UUID?

    /// Link peeked over the top of the current pane.
    var peekTab: BrowserTab?

    // MARK: - Chrome

    var showSidebar: Bool = true
    /// Arc-style: the sidebar stays hidden and slides in on a left-edge hover.
    var sidebarAutoHide: Bool = false {
        didSet { if !sidebarAutoHide { sidebarRevealed = false } }
    }
    /// Transient — whether the auto-hidden sidebar is currently shown.
    var sidebarRevealed: Bool = false
    var showAISidebar: Bool = false
    var sidebarWidth: Double = 240
    var aiWidth: Double = 340

    /// A resize in progress, as a *preview* rather than a live width.
    ///
    /// Rebuilt after three failed attempts at live resizing. The lesson: any
    /// layout change during the drag stutters, because a live web view plus the
    /// sidebar plus glass exceeds a frame's budget — and trimming that work
    /// (rounded widths, no implicit animation, no glass, a frozen page snapshot,
    /// a clipped sidebar) never got it under. So nothing relayouts at all now:
    /// the drag moves a guide line, and the width is applied exactly once on
    /// release.
    struct ResizePreview: Equatable {
        var leadingEdge: Bool
        /// The width that will be committed when the drag ends.
        var width: Double
    }

    var resizePreview: ResizePreview?

    /// True while a guide is on screen. No layout depends on this — it exists so
    /// the handle can draw itself as active.
    var isResizingChrome: Bool { resizePreview != nil }

    var commandBarMode: CommandBarMode? {
        didSet {
            // New seed per opening, so each new tab gets its own colour field.
            if commandBarMode == .newTab, oldValue != .newTab {
                newTabSeed = Int.random(in: 1...1_000_000)
            }
        }
    }
    /// Seeds the new-tab colour field. Stable while the bar is open so it can't
    /// shimmer as you type.
    var newTabSeed: Int = Int.random(in: 1...1_000_000)
    var findQuery: String = ""
    var showFindBar: Bool = false

    // MARK: - Settings

    var bookmarks: [Bookmark] = []
    var history: [HistoryEntry] = []
    var blockerAllowlist: Set<String> = []
    var blockingEnabled: Bool = true
    var aiSuggestionsEnabled: Bool = true
    /// Liquid Glass chrome. Off falls back to plain materials.
    var glassChrome: Bool = true
    /// 0…1. Scales rim highlight, tint strength, and whether small controls get
    /// the interactive (pointer-tracking) variant.
    var glassIntensity: Double = 0.6
    /// Tint the sidebar with the active page's dominant colour, Arc-style.
    /// What the sidebar's surface is made of. One slider drives whichever is
    /// picked, so intensity always means "more of the thing you chose".
    var sidebarStyle: SidebarStyle = .pageTint
    /// The fixed colour used by `.custom`, stored as sRGB components so it
    /// round-trips through JSON without needing a Color codable shim.
    var sidebarColorRGB: [Double] = [0.24, 0.36, 0.72]

    enum SidebarStyle: String, CaseIterable, Identifiable {
        case glass      // liquid glass only, no colour
        case pageTint   // glass plus the page's own colour
        case custom     // glass plus one colour you picked

        var id: String { rawValue }
        var label: String {
            switch self {
            case .glass: return "Liquid Glass"
            case .pageTint: return "Webpage"
            case .custom: return "Tinted"
            }
        }
    }

    var sidebarColor: Color {
        get {
            let c = sidebarColorRGB
            guard c.count >= 3 else { return .blue }
            return Color(red: c[0], green: c[1], blue: c[2])
        }
        set {
            let resolved = NSColor(newValue).usingColorSpace(.sRGB) ?? .systemBlue
            sidebarColorRGB = [Double(resolved.redComponent),
                               Double(resolved.greenComponent),
                               Double(resolved.blueComponent)]
        }
    }

    /// The single knob. Glass reads it as rim/refraction strength; the tint and
    /// custom modes read it as colour strength.
    var sidebarIntensity: Double {
        get { sidebarStyle == .glass ? glassIntensity : chromeTintStrength }
        set {
            if sidebarStyle == .glass { glassIntensity = newValue }
            else { chromeTintStrength = newValue }
        }
    }
    /// 0…1. How strongly the page colour shows in the sidebar.
    var chromeTintStrength: Double = 0.55
    /// The colour the sidebar should be tinted with right now.
    var chromeTint: Color? {
        switch sidebarStyle {
        case .glass: return nil
        case .custom: return sidebarColor
        case .pageTint: break
        }
        // `tintChromeFromPage` used to gate this. The style picker replaced that
        // toggle, so the flag became unreachable in the UI — and anyone whose
        // saved state had it off got no tint, ever, with no way to turn it back
        // on. Measured on a live window: style=pageTint, themeTint present,
        // chromeTint=nil. The style is the switch now.
        // A blank tab has no page to sample, but it does have a colour field —
        // so the sidebar picks up that palette instead of falling to neutral.
        if commandBarMode == .newTab { return LiquidBackdrop.signature(seed: newTabSeed) }
        guard let tab = focusedTab else { return nil }
        if let tint = tab.themeTint { return tint }
        if tab.urlString.isEmpty { return LiquidBackdrop.signature(seed: tab.id.hashValue) }
        return nil
    }

    /// The version whose release notes have already been shown.
    var lastSeenVersion: String?

    /// 0 disables auto-archiving.
    var archiveHours: Double = 12
    /// Minutes of idleness before a background tab's page is freed. 0 is off.
    var snoozeMinutes: Double = 20
    var snoozedCount: Int { allTabs.filter(\.isSnoozed).count }

    /// Which tabs are eligible right now. Pure, so the policy is testable — the
    /// sweep itself can't be, since it needs live web views.
    ///
    /// Displayed tabs are exempt (they're on screen), and so is the focused tab
    /// even when it isn't in the split, because it's the one you'd return to
    /// first. Tier is deliberately *not* a factor: a pinned tab you haven't
    /// touched since this morning is the best candidate in the window.
    static func snoozeCandidates(_ tabs: [BrowserTab], displayed: [UUID],
                                 focused: UUID?, idleMinutes: Double,
                                 exempt: Set<UUID> = [],
                                 now: Date = Date()) -> [BrowserTab] {
        guard idleMinutes > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-idleMinutes * 60)
        return tabs.filter { tab in
            !tab.isSnoozed
            && !displayed.contains(tab.id)
            && tab.id != focused
            && !exempt.contains(tab.id)
            && tab.lastAccessed < cutoff
            && !tab.urlString.isEmpty
        }
    }

    /// Top-level pinned tabs — the ones sitting loose in the pinned section
    /// rather than inside a group. These are the handful you keep one click
    /// away, so they stay resident; a pinned tab inside a group is more like
    /// filed-away reading and is fair game.
    var snoozeExempt: Set<UUID> {
        Set(pinned.filter { !$0.isGroup }.compactMap { $0.tab?.id })
    }

    /// Test hook: `ARK_SNOOZE_MINUTES=0.05` makes the sweep fire in seconds.
    /// Verifying this feature means measuring real WebContent memory, and
    /// waiting 20 minutes per measurement isn't verification.
    private var effectiveSnoozeMinutes: Double {
        if let raw = ProcessInfo.processInfo.environment["ARK_SNOOZE_MINUTES"],
           let value = Double(raw) { return value }
        return snoozeMinutes
    }

    @MainActor
    func sweepSnooze() async {
        let candidates = Self.snoozeCandidates(allTabs, displayed: displayed,
                                               focused: focusedTabID,
                                               idleMinutes: effectiveSnoozeMinutes,
                                               exempt: snoozeExempt)
        for tab in candidates { _ = await tab.snooze() }
    }

    /// Free everything not on screen, regardless of idle time. Wired to the
    /// system memory-pressure signal, and to a menu item.
    @MainActor
    func snoozeAllBackgroundTabs() async {
        let exempt = snoozeExempt
        for tab in allTabs where !displayed.contains(tab.id)
            && tab.id != focusedTabID && !exempt.contains(tab.id) {
            _ = await tab.snooze()
        }
    }

    /// GitHub-Releases updater. Checks once per launch when enabled; never
    /// installs anything without a click.
    @ObservationIgnored private var updaterStorage: Updater?
    @MainActor var updater: Updater {
        if let updaterStorage { return updaterStorage }
        let made = Updater()
        updaterStorage = made
        return made
    }

    /// Vault: keychain-backed website credentials plus autofill.
    let passwords = PasswordManager()
    let downloads = DownloadManager()
    var showDownloads: Bool = false
    /// AI tab grouping: a pending proposal awaiting approval.
    var organizeProposal: TabOrganizer.Proposal?
    var organizing: Bool = false
    var organizeError: String?
    /// Which model does the grouping.
    var groupingEngine: GroupingEngine = .appleIntelligence
    /// ⌘-clicked tabs, for acting on several at once.
    ///
    /// Kept separate from `displayed`: those are the tabs on screen in a split,
    /// this is a set you've marked to operate on. Conflating them would mean
    /// selecting five tabs opened five panes.
    var selectedTabIDs: Set<UUID> = []

    var selectionCount: Int { selectedTabIDs.count }

    func isSelected(_ id: UUID) -> Bool { selectedTabIDs.contains(id) }

    /// ⌘-click. The clicked tab joins or leaves the set; nothing is shown or
    /// hidden, because a multi-select click is not a navigation.
    func toggleSelection(_ id: UUID) {
        if selectedTabIDs.contains(id) { selectedTabIDs.remove(id) }
        else { selectedTabIDs.insert(id) }
    }

    func clearSelection() {
        guard !selectedTabIDs.isEmpty else { return }
        selectedTabIDs = []
    }

    /// Selected tabs in sidebar order, so bulk actions preserve what you see
    /// rather than the arbitrary order of a Set.
    var selectedTabsInOrder: [BrowserTab] {
        orderedTabs.filter { selectedTabIDs.contains($0.id) }
    }

    /// Drops ids that no longer exist. A closed tab left in the set would make
    /// the count lie.
    func pruneSelection() {
        let live = Set(allTabs.map(\.id))
        selectedTabIDs = selectedTabIDs.intersection(live)
    }

    // MARK: - Bulk actions

    @MainActor
    func closeSelected() {
        let doomed = selectedTabsInOrder
        clearSelection()
        for tab in doomed { close(tab) }
    }

    /// One new group holding everything selected, in sidebar order.
    @MainActor
    @discardableResult
    func groupSelected(named name: String = "New Group") -> SidebarItem? {
        let tabs = selectedTabsInOrder
        guard tabs.count > 1, let first = tabs.first else { return nil }
        let group = newGroup(named: name, containing: first)
        for tab in tabs.dropFirst() { move(tab, into: group) }
        group.isExpanded = true
        clearSelection()
        save()
        return group
    }

    @MainActor
    func pinSelected() {
        for tab in selectedTabsInOrder where tab.tier == .today { pin(tab) }
        clearSelection()
    }

    @MainActor
    func moveSelected(into group: SidebarItem) {
        for tab in selectedTabsInOrder { move(tab, into: group) }
        group.isExpanded = true
        clearSelection()
        save()
    }

    /// True while a sidebar tab is being dragged. Pane drop layers are only
    /// live during a drag so they never intercept ordinary clicks.
    /// Sidebar/pane drag tracking. Pointer-based, no drag-and-drop API.
    let drag = TabDragCoordinator()
    /// The tab currently being dragged, so its row can dim while in flight.
    var draggingTabID: UUID?
    var tabDragActive: Bool = false {
        didSet {
            guard tabDragActive else { return }
            // A cancelled drag reports no drop, so bound how long the layer can
            // stay live — otherwise it would keep swallowing clicks on the page.
            dragWatchdog?.cancel()
            dragWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                self?.tabDragActive = false
                self?.draggingTabID = nil
            }
        }
    }

    @ObservationIgnored private var dragWatchdog: Task<Void, Never>?
    @ObservationIgnored private var sidebarHideTask: Task<Void, Never>?

    /// Recently closed tabs, most recent first, for ⌘⇧T.
    @ObservationIgnored private var closedStack: [(url: URL, title: String)] = []

    @ObservationIgnored private var archiveTimer: Timer?
    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?

    // MARK: - Derived

    var allTabs: [BrowserTab] { favorites + pinned.allTabs + todayItems.allTabs }

    var focusedTab: BrowserTab? {
        allTabs.first { $0.id == focusedTabID } ?? displayedTabs.first
    }

    var displayedTabs: [BrowserTab] {
        displayed.compactMap { id in allTabs.first { $0.id == id } }
    }

    /// Sidebar order, used for ⌘⇧[ / ⌘⇧] cycling.
    var orderedTabs: [BrowserTab] {
        favorites + pinned.visibleTabsInOrder() + todayItems.visibleTabsInOrder()
    }

    // MARK: - Lifecycle

    init() {
        load()
        if allTabs.isEmpty {
            newTab(url: URL(string: "https://duckduckgo.com")!)
        }
        if displayed.isEmpty, let first = allTabs.first {
            displayed = [first.id]
            focusedTabID = first.id
        }
        startArchiveTimer()
    }

    // MARK: - Opening tabs

    /// Opens a real blank tab and puts the command bar over *it*, not over the
    /// page you were reading.
    ///
    /// The sidebar's New Tab row used to just set `commandBarMode`, leaving the
    /// previous page live underneath — and WebKit kept setting the cursor from
    /// that page, so hovering a link through an opaque overlay produced a
    /// pointing hand. The overlay announced itself.
    ///
    /// Dismissing without typing anything reverts: the blank tab is closed and
    /// the previous tab comes back, so an accidental ⌘T costs nothing.
    @MainActor
    @discardableResult
    func beginNewTab() -> BrowserTab {
        pendingNewTab = PendingNewTab(previousDisplayed: displayed,
                                      previousFocused: focusedTabID)
        let tab = newTab()
        pendingNewTab?.tabID = tab.id
        // One seed for the overlay's field, the blank pane's field, and the
        // sidebar tint. They were drawing from two different palettes, so the
        // sidebar could be tinted from a field you weren't looking at.
        newTabSeed = tab.id.hashValue
        return tab
    }

    struct PendingNewTab {
        var tabID: UUID?
        let previousDisplayed: [UUID]
        let previousFocused: UUID?
    }

    /// The blank tab awaiting a destination, if any.
    var pendingNewTab: PendingNewTab?

    /// Today's rows, minus a blank tab that is still waiting for a destination.
    ///
    /// The tab has to exist — it's what the command bar sits on top of, and
    /// having a real blank pane there is what stopped the previous page from
    /// setting the cursor. But listing it in the sidebar before it goes anywhere
    /// shows a "New Tab" row for something that may never become a tab.
    var visibleTodayItems: [SidebarItem] {
        guard let id = pendingNewTab?.tabID,
              let tab = tab(withID: id), tab.urlString.isEmpty else { return todayItems }
        return todayItems.filter { $0.id != id }
    }

    /// Called when the command bar closes. Keeps the tab if it went somewhere,
    /// otherwise undoes the whole thing.
    @MainActor
    func resolvePendingNewTab(committed: Bool) {
        guard let pending = pendingNewTab else { return }
        pendingNewTab = nil
        guard !committed, let id = pending.tabID, let tab = tab(withID: id),
              tab.urlString.isEmpty else { return }

        _ = todayItems.removeNode(id: id)
        splitGroups.removeAll { $0.tabs.contains(id) }
        let live = Set(allTabs.map(\.id))
        let restored = pending.previousDisplayed.filter(live.contains)
        if !restored.isEmpty {
            displayed = restored
            focusedTabID = pending.previousFocused ?? restored.first
        } else if let first = orderedTabs.first {
            show(first)
        } else {
            displayed = []
            focusedTabID = nil
        }
        save()
    }

    /// The one exit from the command bar. `committed` false means the user
    /// backed out, which is what reverts a blank tab.
    @MainActor
    func closeCommandBar(committed: Bool) {
        commandBarMode = nil
        resolvePendingNewTab(committed: committed)
    }

    /// Repoints a pinned tab's home. `nil` input clears it back to whatever the
    /// tab is showing now.
    ///
    /// The pinned URL is what ⌘W and Reset snap back to, so a tab pinned months
    /// ago at a URL that has since moved was stuck returning to the wrong page
    /// with no way to correct it short of unpinning and repinning.
    @MainActor
    func setPinnedURL(_ raw: String?, for tab: BrowserTab) {
        guard let resolved = Self.resolvePinnedURL(raw, fallback: tab.urlString) else { return }
        tab.pinnedURL = resolved
        save()
    }

    /// Accepts what someone would actually type — a bare host, a full URL, or
    /// nothing at all, which means "use the page I'm on".
    ///
    /// Returns nil only when there is genuinely nothing to point at, so a typo
    /// can't silently blank a pinned tab's home.
    static func resolvePinnedURL(_ raw: String?, fallback: String) -> String? {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            let current = fallback.trimmingCharacters(in: .whitespaces)
            return current.isEmpty ? nil : current
        }
        let url = BrowserTab.resolve(text)
        // `resolve` falls back to a search URL for anything unparseable, and a
        // search results page is a poor thing to pin someone to by accident —
        // but it is still a valid destination, so it is allowed rather than
        // rejected. Only an empty result is refused.
        let absolute = url.absoluteString
        return absolute.isEmpty ? nil : absolute
    }

    /// Where a command-bar navigation should land: the pending blank tab if one
    /// is waiting, otherwise a fresh tab.
    @MainActor
    func openFromCommandBar(_ url: URL) {
        if let id = pendingNewTab?.tabID, let tab = tab(withID: id) {
            pendingNewTab = nil
            tab.load(url)
            show(tab)
            save()
            return
        }
        newTab(url: url)
    }

    @discardableResult
    func newTab(url: URL? = nil, activate: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: url, state: self, tier: .today)
        todayItems.append(SidebarItem(tab: tab))
        applyBlocking(to: tab)
        if activate { show(tab) }
        if url == nil { commandBarMode = .newTab }
        save()
        return tab
    }

    func openInNewTab(_ url: URL, activate: Bool = true) {
        newTab(url: url, activate: activate)
    }

    /// Shows a tab. If it belongs to a remembered split, the whole split comes
    /// back rather than collapsing to a single pane — so clicking away and
    /// clicking back doesn't quietly destroy the layout.
    func show(_ tab: BrowserTab) {
        focusedTabID = tab.id
        tab.lastAccessed = Date()
        // Waking touches the web view, which is main-actor bound. Every caller
        // is a UI action, so hop rather than making `show` itself isolated —
        // that would cascade through newTab and half the state API.
        Task { @MainActor in tab.wake() }

        if let group = splitGroup(containing: tab.id) {
            let live = Set(allTabs.map(\.id))
            let members = group.tabs.filter(live.contains)
            if members.count > 1 {
                displayed = members
                paneRatios = normalized(group.ratios, count: members.count)
                return
            }
            forgetSplit(containing: tab.id)
        }
        displayed = [tab.id]
        paneRatios = [1]
    }

    // MARK: - AI tab grouping

    /// Only Today tabs are described to the model — pinned tabs and favourites
    /// are someone's deliberate structure and are left alone.
    var organizableTabs: [BrowserTab] {
        todayTabs.filter { $0.webView.url?.host != nil }
    }

    @MainActor
    func organizeTabs() async {
        guard !organizing else { return }
        organizing = true
        organizeError = nil
        organizeProposal = nil

        let candidates = organizableTabs.map {
            (id: $0.id, title: $0.displayTitle, host: $0.webView.url?.host ?? "")
        }
        do {
            organizeProposal = try await Self.propose(candidates, using: groupingEngine)
        } catch {
            organizeError = error.localizedDescription
        }
        organizing = false
    }

    /// Automatic tries on-device first and only falls back to the API if Apple
    /// Intelligence is unavailable — the private, free option should win by
    /// default, not merely be offered.
    static func propose(_ tabs: [(id: UUID, title: String, host: String)],
                        using engine: GroupingEngine) async throws -> TabOrganizer.Proposal {
        switch engine {
        case .appleIntelligence:
            return try await OnDeviceOrganizer.propose(tabs: tabs)
        case .claude:
            return try await TabOrganizer.propose(tabs: tabs)
        case .automatic:
            if OnDeviceOrganizer.availability.isAvailable {
                do { return try await OnDeviceOrganizer.propose(tabs: tabs) }
                catch { /* fall through to the API */ }
            }
            return try await TabOrganizer.propose(tabs: tabs)
        }
    }

    /// Command-bar completions, on-device first. The address bar is about as
    /// sensitive as browsing gets, so the private option wins by default and the
    /// API is only a fallback.
    func suggestions(forQuery query: String) async -> [Suggestion] {
        if groupingEngine == .claude { return await Autocomplete.suggest(query: query) }
        if OnDeviceSuggestions.isAvailable {
            let local = await OnDeviceSuggestions.suggest(
                query: query, searchBase: SearchEngine.current.base)
            if !local.isEmpty { return local }
        }
        // Only reached when Apple Intelligence isn't available on this Mac. The
        // settings pane says so rather than pretending the choice took effect.
        return await Autocomplete.suggest(query: query)
    }

    /// Page-assistant replies, on-device first.
    func chatStream(question: String, history: [ClaudeClient.Message],
                    pageTitle: String, pageURL: String,
                    pageText: String) -> AsyncThrowingStream<String, Error> {
        let useOnDevice = groupingEngine != .claude && OnDeviceChat.isAvailable

        if useOnDevice {
            return OnDeviceChat.stream(question: question, history: history,
                                       pageTitle: pageTitle, pageURL: pageURL,
                                       pageText: pageText)
        }
        return ClaudeClient.stream(messages: history, pageTitle: pageTitle,
                                   pageURL: pageURL, pageText: pageText)
    }

    /// Which engine the chat will actually use, for the panel's label.
    var chatUsesOnDevice: Bool {
        groupingEngine != .claude && OnDeviceChat.isAvailable
    }

    /// Label for the UI, so it's obvious which engine will actually run.
    var effectiveGroupingEngine: GroupingEngine {
        if groupingEngine == .claude { return .claude }
        return OnDeviceOrganizer.availability.isAvailable ? .appleIntelligence : .claude
    }

    /// Creates a group per accepted row and moves its tabs in.
    @MainActor
    func applyOrganizeProposal() {
        guard let proposal = organizeProposal else { return }
        for group in proposal.groups where group.accepted {
            let tabs = group.tabIDs.compactMap { id in todayTabs.first { $0.id == id } }
            guard tabs.count >= 2 else { continue }
            let node = newGroup(named: group.name)
            for tab in tabs { move(tab, into: node) }
        }
        organizeProposal = nil
        save()
    }

    func dismissOrganizeProposal() {
        organizeProposal = nil
        organizeError = nil
    }

    // MARK: - Sidebar reveal

    /// Pointer reached the left edge.
    func revealSidebar() {
        sidebarHideTask?.cancel()
        sidebarHideTask = nil
        guard sidebarAutoHide, !sidebarRevealed else { return }
        sidebarRevealed = true
    }

    /// Pointer left the sidebar's area. Delayed so brushing past the edge on the
    /// way somewhere else doesn't make it flicker.
    func scheduleSidebarHide(after delay: Duration = .milliseconds(260)) {
        guard sidebarAutoHide, sidebarRevealed else { return }
        sidebarHideTask?.cancel()
        sidebarHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.sidebarRevealed = false
        }
    }

    /// Whether the sidebar occupies layout space (pinned) as opposed to floating.
    var sidebarPinned: Bool { showSidebar && !sidebarAutoHide }
    /// Whether the floating overlay should be on screen.
    var sidebarFloating: Bool { showSidebar && sidebarAutoHide && sidebarRevealed }

    // MARK: - Split memory

    func splitGroup(containing id: UUID) -> SplitGroup? {
        splitGroups.first { $0.tabs.contains(id) }
    }

    /// Records the current pane set so it can be restored later.
    func rememberCurrentSplit() {
        splitGroups = Self.remembering(displayed: displayed,
                                       ratios: Self.normalized(paneRatios, count: displayed.count),
                                       in: splitGroups)
    }

    func forgetSplit(containing id: UUID) {
        splitGroups = Self.forgetting(id, in: splitGroups)
    }

    func normalized(_ values: [Double], count: Int) -> [Double] {
        Self.normalized(values, count: count)
    }

    // MARK: - Pure split helpers (unit-tested directly)

    /// One group per tab: any existing group sharing a member is replaced, so a
    /// tab can never belong to two remembered splits at once.
    static func remembering(displayed: [UUID], ratios: [Double],
                            in groups: [SplitGroup]) -> [SplitGroup] {
        guard displayed.count > 1 else { return groups }
        var next = groups.filter { existing in
            existing.tabs.filter(displayed.contains).isEmpty
        }
        next.append(SplitGroup(tabs: displayed, ratios: ratios))
        if next.count > 12 { next.removeFirst(next.count - 12) }
        return next
    }

    static func forgetting(_ id: UUID, in groups: [SplitGroup]) -> [SplitGroup] {
        groups.filter { !$0.tabs.contains(id) }
    }

    static func normalized(_ values: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard values.count == count else {
            return Array(repeating: 1.0 / Double(count), count: count)
        }
        let total = values.reduce(0, +)
        guard total > 0.0001 else {
            return Array(repeating: 1.0 / Double(count), count: count)
        }
        return values.map { $0 / total }
    }

    // MARK: - Split view

    /// Adds a tab as another pane, up to four.
    func addToSplit(_ tab: BrowserTab) {
        guard !displayed.contains(tab.id), displayed.count < 4 else { return }
        displayed.append(tab.id)
        paneRatios = normalized([], count: displayed.count)
        focusedTabID = tab.id
        tab.lastAccessed = Date()
        rememberCurrentSplit()
        save()
    }

    /// Inserts a tab as a pane beside `neighbour`, on the given side.
    func addToSplit(_ tab: BrowserTab, beside neighbour: BrowserTab, on side: DropZone) {
        tabDragActive = false
        guard displayed.count < 4 else { return }
        guard tab.id != neighbour.id else { return }
        // Already on screen: move it rather than duplicating the pane.
        displayed.removeAll { $0 == tab.id }
        guard let anchor = displayed.firstIndex(of: neighbour.id) else {
            displayed.append(tab.id)
            focusedTabID = tab.id
            return
        }
        let index = side == .left ? anchor : anchor + 1
        displayed.insert(tab.id, at: min(index, displayed.count))
        paneRatios = normalized([], count: displayed.count)
        focusedTabID = tab.id
        tab.lastAccessed = Date()
        rememberCurrentSplit()
        save()
    }

    func removeFromSplit(_ tab: BrowserTab) {
        guard displayed.count > 1 else { return }
        displayed.removeAll { $0 == tab.id }
        paneRatios = normalized([], count: displayed.count)
        if focusedTabID == tab.id { focusedTabID = displayed.first }
        forgetSplit(containing: tab.id)
        if displayed.count > 1 { rememberCurrentSplit() }
        save()
    }

    /// ⌘⌥\ — splits with the next tab in sidebar order.
    func splitWithNextTab() {
        guard displayed.count < 4,
              let current = focusedTab,
              let idx = orderedTabs.firstIndex(where: { $0.id == current.id }) else { return }
        let candidates = orderedTabs.enumerated()
            .filter { $0.offset != idx && !displayed.contains($0.element.id) }
            .map(\.element)
        if let next = candidates.first {
            addToSplit(next)
        } else {
            addToSplit(newTab(activate: false))
        }
    }

    /// Explicitly forgets the grouping — otherwise `show` would restore the
    /// split immediately and a single pane would be unreachable.
    func collapseSplit() {
        guard let focused = focusedTabID else { return }
        for id in displayed { forgetSplit(containing: id) }
        displayed = [focused]
        paneRatios = [1]
        save()
    }

    func focusPane(_ offset: Int) {
        guard let idx = displayed.firstIndex(where: { $0 == focusedTabID }), displayed.count > 1 else { return }
        focusedTabID = displayed[(idx + offset + displayed.count) % displayed.count]
    }

    // MARK: - Peek

    func peek(_ url: URL) {
        let tab = BrowserTab(url: url, state: self, tier: .today)
        tab.isPeek = true
        applyBlocking(to: tab)
        peekTab = tab
    }

    func dismissPeek() {
        peekTab?.webView.stopLoading()
        peekTab = nil
    }

    /// Promotes the peeked page into a real Today tab.
    func promotePeek() {
        guard let tab = peekTab else { return }
        tab.isPeek = false
        peekTab = nil
        todayItems.append(SidebarItem(tab: tab))
        show(tab)
        save()
    }

    // MARK: - Tiers

    func pin(_ tab: BrowserTab) {
        guard tab.tier != .pinned else { return }
        detach(tab)
        tab.tier = .pinned
        tab.pinnedURL = tab.webView.url?.absoluteString ?? tab.urlString
        pinned.append(SidebarItem(tab: tab))
        save()
    }

    func unpin(_ tab: BrowserTab) {
        guard tab.tier != .today else { return }
        detach(tab)
        tab.tier = .today
        tab.pinnedURL = nil
        todayItems.append(SidebarItem(tab: tab))
        save()
    }

    func addToFavorites(_ tab: BrowserTab) {
        guard tab.tier != .favorite else { return }
        detach(tab)
        tab.tier = .favorite
        tab.pinnedURL = tab.webView.url?.absoluteString ?? tab.urlString
        favorites.append(tab)
        save()
    }

    /// Removes a tab from whichever section holds it, without closing it.
    private func detach(_ tab: BrowserTab) {
        favorites.removeAll { $0.id == tab.id }
        todayItems.removeNode(id: tab.id)
        pinned.removeNode(id: tab.id)
    }

    // MARK: - Groups

    /// Where a group lives. Today groups keep their tabs ephemeral, so grouping
    /// no longer implies pinning.
    enum GroupPlacement { case pinned, today }

    @discardableResult
    func newGroup(named name: String = "New Group",
                  containing tab: BrowserTab? = nil,
                  placement: GroupPlacement = .today) -> SidebarItem {
        let group = SidebarItem(groupName: name)
        if let tab {
            detach(tab)
            adopt(tab, into: placement)
            group.children.append(SidebarItem(tab: tab))
        }
        switch placement {
        case .pinned: pinned.append(group)
        case .today: todayItems.append(group)
        }
        save()
        return group
    }

    /// Which section a group node currently sits in.
    func placement(of group: SidebarItem) -> GroupPlacement {
        pinned.findNode(id: group.id) != nil ? .pinned : .today
    }

    /// Applies a section's tier rules to a tab.
    private func adopt(_ tab: BrowserTab, into placement: GroupPlacement) {
        if placement == .pinned {
            tab.tier = .pinned
            if tab.pinnedURL == nil {
                tab.pinnedURL = tab.webView.url?.absoluteString ?? tab.urlString
            }
        } else {
            tab.tier = .today
            tab.pinnedURL = nil
        }
    }

    /// Moves a group and its tabs between Today and Pinned.
    func moveGroup(_ group: SidebarItem, to placement: GroupPlacement) {
        guard group.isGroup else { return }
        pinned.removeNode(id: group.id)
        todayItems.removeNode(id: group.id)
        for tab in group.allTabs { adopt(tab, into: placement) }
        switch placement {
        case .pinned: pinned.append(group)
        case .today: todayItems.append(group)
        }
        save()
    }

    func move(_ tab: BrowserTab, into group: SidebarItem) {
        guard group.isGroup else { return }
        // The tab takes on whichever section its group lives in — dropping into
        // a Today group must not silently pin it.
        let target = placement(of: group)
        detach(tab)
        adopt(tab, into: target)
        group.children.append(SidebarItem(tab: tab))
        group.isExpanded = true
        save()
    }

    /// Deletes a group; its tabs fall back to Today rather than vanishing.
    func deleteGroup(_ group: SidebarItem) {
        let orphans = group.allTabs
        pinned.removeNode(id: group.id)
        todayItems.removeNode(id: group.id)
        for tab in orphans {
            tab.tier = .today
            tab.pinnedURL = nil
            todayItems.append(SidebarItem(tab: tab))
        }
        save()
    }

    /// Moves any sidebar node — tab or group — next to a target, adopting the
    /// target section's tier rules. Refuses to nest a group inside itself.
    func moveNode(_ nodeID: UUID, besideNodeID target: UUID, before: Bool) {
        guard nodeID != target else { return }
        guard let node = pinned.findNode(id: nodeID) ?? todayItems.findNode(id: nodeID) else { return }
        if node.isGroup, node.children.findNode(id: target) != nil { return }

        let targetInPinned = pinned.findNode(id: target) != nil
        pinned.removeNode(id: nodeID)
        todayItems.removeNode(id: nodeID)
        for tab in node.allTabs { adopt(tab, into: targetInPinned ? .pinned : .today) }

        if targetInPinned {
            pinned.insertNode(node, besideNodeID: target, before: before)
        } else {
            todayItems.insertNode(node, besideNodeID: target, before: before)
        }
        save()
    }

    /// Nests a group inside another, guarding against cycles.
    func nestGroup(_ groupID: UUID, into targetID: UUID) {
        guard groupID != targetID,
              let group = pinned.findNode(id: groupID) ?? todayItems.findNode(id: groupID),
              group.isGroup,
              group.children.findNode(id: targetID) == nil,
              let host = pinned.findNode(id: targetID) ?? todayItems.findNode(id: targetID),
              host.isGroup else { return }

        let hostInPinned = pinned.findNode(id: targetID) != nil
        pinned.removeNode(id: groupID)
        todayItems.removeNode(id: groupID)
        for tab in group.allTabs { adopt(tab, into: hostInPinned ? .pinned : .today) }
        host.children.append(group)
        host.isExpanded = true
        save()
    }

    // MARK: - Drag commit

    /// Applies whatever the coordinator resolved, then clears it. One place, so
    /// every destination behaves consistently.
    func commitDrag() {
        defer { drag.end() }

        // Groups move as whole subtrees; tabs take the path below.
        if drag.draggingIsGroup, let groupID = drag.draggingID {
            switch drag.target {
            case .beside(let targetID, let before):
                moveNode(groupID, besideNodeID: targetID, before: before)
            case .intoGroup(let hostID):
                nestGroup(groupID, into: hostID)
            case .root(let pinnedSection):
                if let group = pinned.findNode(id: groupID) ?? todayItems.findNode(id: groupID) {
                    moveGroup(group, to: pinnedSection ? .pinned : .today)
                }
            case .split, .none:
                break
            }
            return
        }

        guard let id = drag.draggingTabID, let dragged = tab(withID: id) else { return }

        // Dragging a tab that's part of a ⌘-click selection moves the whole
        // selection. The primary tab lands on the target, then the others queue
        // up after it — which is why they're taken in sidebar order and inserted
        // one behind the last, rather than all beside the same anchor.
        let companions = selectedTabIDs.contains(id)
            ? selectedTabsInOrder.filter { $0.id != id }
            : []

        switch drag.target {
        case .none:
            break
        case .beside(let targetID, let before):
            guard targetID != id else { break }
            move(dragged, besideTabID: targetID, before: before)
            var anchor = id
            for tab in companions {
                move(tab, besideTabID: anchor, before: false)
                anchor = tab.id
            }
            clearSelection()
        case .intoGroup(let groupID):
            guard let group = pinned.findNode(id: groupID)
                    ?? todayItems.findNode(id: groupID), group.isGroup else { break }
            move(dragged, into: group)
            for tab in companions { move(tab, into: group) }
            group.isExpanded = true
            clearSelection()
        case .root(let pinnedSection):
            _ = handleDropOnRoot(idString: id.uuidString,
                                 placement: pinnedSection ? .pinned : .today)
        case .split(let paneTabID, let left):
            guard let neighbour = tab(withID: paneTabID), neighbour.id != id else { break }
            addToSplit(dragged, beside: neighbour, on: left ? .left : .right)
        }
    }

    // MARK: - Drag and drop

    func tab(withID id: UUID) -> BrowserTab? {
        allTabs.first { $0.id == id }
    }

    /// Drops a dragged tab next to `target`, inside whatever container holds it.
    /// `before` decides which side, so the insertion indicator can be honest.
    func move(_ tab: BrowserTab, besideTabID target: UUID, before: Bool = false) {
        guard tab.id != target, let targetTab = self.tab(withID: target) else { return }

        // Favorites are a flat grid with no groups, so they stay a special case.
        if targetTab.tier == .favorite {
            detach(tab)
            adopt(tab, into: .pinned)
            tab.tier = .favorite
            let idx = favorites.firstIndex { $0.id == target } ?? favorites.count
            favorites.insert(tab, at: min(max(before ? idx : idx + 1, 0), favorites.count))
            save()
            return
        }

        // Branch on the *container* holding the target, not on its tier. Tier
        // said "today" for a tab sitting inside a Today group, so reordering
        // within that group used to yank the tab out to the top level.
        let parentGroup = pinned.findParentGroup(of: target)
            ?? todayItems.findParentGroup(of: target)
        let inPinnedSection: Bool = {
            if let parentGroup { return placement(of: parentGroup) == .pinned }
            return pinned.contains { $0.id == target }
        }()

        detach(tab)
        adopt(tab, into: inPinnedSection ? .pinned : .today)
        let node = SidebarItem(tab: tab)

        // Indices are computed *after* detaching, so dragging a tab down past
        // its own former position lands where the indicator promised.
        func insertion(_ count: Int, _ found: Int?) -> Int {
            guard let found else { return count }
            return min(max(before ? found : found + 1, 0), count)
        }

        if let parentGroup {
            let found = parentGroup.children.firstIndex { $0.id == target }
            parentGroup.children.insert(node, at: insertion(parentGroup.children.count, found))
            parentGroup.isExpanded = true
        } else if inPinnedSection {
            let found = pinned.firstIndex { $0.id == target }
            pinned.insert(node, at: insertion(pinned.count, found))
        } else {
            let found = todayItems.firstIndex { $0.id == target }
            todayItems.insert(node, at: insertion(todayItems.count, found))
        }
        save()
    }

    /// Reparents a group next to another node, rejecting drops into itself.
    func move(folderID: UUID, besideNodeID target: UUID) {
        guard folderID != target,
              let folder = pinned.findNode(id: folderID),
              folder.isGroup,
              folder.children.findNode(id: target) == nil else { return }
        pinned.removeNode(id: folderID)
        todayItems.removeNode(id: folderID)
        if let parent = pinned.findParentGroup(of: target) ?? todayItems.findParentGroup(of: target),
           let idx = parent.children.firstIndex(where: { $0.id == target }) {
            parent.children.insert(folder, at: idx + 1)
        } else if let idx = pinned.firstIndex(where: { $0.id == target }) {
            pinned.insert(folder, at: idx + 1)
        } else {
            pinned.append(folder)
        }
        save()
    }

    /// Handles a dropped id string, whether it names a tab or a group.
    func handleDrop(idString: String, onNodeID target: UUID, before: Bool = false) -> Bool {
        guard let id = UUID(uuidString: idString) else { return false }
        if let tab = tab(withID: id) {
            move(tab, besideTabID: target, before: before)
            return true
        }
        move(folderID: id, besideNodeID: target)
        return true
    }

    func handleDrop(idString: String, intoGroup folder: SidebarItem) -> Bool {
        guard let id = UUID(uuidString: idString) else { return false }
        if let tab = tab(withID: id) {
            move(tab, into: folder)
            return true
        }
        // Moving a group into another folder, guarding against cycles.
        guard let dragged = pinned.findNode(id: id) ?? todayItems.findNode(id: id), dragged.isGroup,
              dragged.id != folder.id,
              dragged.children.findNode(id: folder.id) == nil else { return false }
        pinned.removeNode(id: id)
        folder.children.append(dragged)
        folder.isExpanded = true
        save()
        return true
    }

    /// Lifts a tab out of its group to the top level of its own section.
    func ungroup(_ tab: BrowserTab) {
        guard groupContaining(tab.id) != nil else { return }
        let wasPinned = tab.tier != .today
        detach(tab)
        if wasPinned {
            tab.tier = .pinned
            if tab.pinnedURL == nil {
                tab.pinnedURL = tab.webView.url?.absoluteString ?? tab.urlString
            }
            pinned.append(SidebarItem(tab: tab))
        } else {
            tab.tier = .today
            tab.pinnedURL = nil
            todayItems.append(SidebarItem(tab: tab))
        }
        save()
    }

    /// Which section holds the group the dragged tab is in, or nil when the
    /// dragged tab isn't grouped — so the "leave a group" strip only appears
    /// when leaving a group is actually possible.
    var draggedTabGroupSection: GroupPlacement? {
        guard let id = drag.draggingTabID, let group = groupContaining(id) else { return nil }
        return placement(of: group)
    }

    /// The group holding a node, in either section.
    func groupContaining(_ id: UUID) -> SidebarItem? {
        pinned.findParentGroup(of: id) ?? todayItems.findParentGroup(of: id)
    }

    /// Dropping on a section's empty tail lifts a tab to top level there.
    func handleDropOnRoot(idString: String, placement: GroupPlacement) -> Bool {
        guard let id = UUID(uuidString: idString), let tab = tab(withID: id) else { return false }
        detach(tab)
        adopt(tab, into: placement)
        switch placement {
        case .pinned: pinned.append(SidebarItem(tab: tab))
        case .today: todayItems.append(SidebarItem(tab: tab))
        }
        save()
        return true
    }

    /// Dropping on the Today header unpins.
    func handleDropOnToday(idString: String) -> Bool {
        guard let id = UUID(uuidString: idString), let tab = tab(withID: id) else { return false }
        unpin(tab)
        return true
    }

    var allGroups: [SidebarItem] {
        func walk(_ items: [SidebarItem]) -> [SidebarItem] {
            items.filter(\.isGroup).flatMap { [$0] + walk($0.children) }
        }
        return walk(pinned) + walk(todayItems)
    }

    // MARK: - Closing

    /// Arc's rule: closing a pinned tab resets it instead of removing it.
    func close(_ tab: BrowserTab) {
        selectedTabIDs.remove(tab.id)
        if tab.tier != .today {
            tab.resetToPinned()
            if displayed.count > 1 { removeFromSplit(tab) }
            return
        }
        let wasDisplayed = displayed.contains(tab.id)
        let order = orderedTabs
        let idx = order.firstIndex { $0.id == tab.id }

        if let url = tab.webView.url ?? URL(string: tab.urlString) {
            closedStack.insert((url, tab.displayTitle), at: 0)
            if closedStack.count > 20 { closedStack.removeLast() }
        }
        tab.webView.stopLoading()
        detach(tab)
        displayed.removeAll { $0 == tab.id }

        if wasDisplayed && displayed.isEmpty {
            let remaining = orderedTabs
            if remaining.isEmpty {
                newTab(url: URL(string: "https://duckduckgo.com")!)
            } else if let idx {
                show(remaining[max(0, min(idx, remaining.count - 1))])
            } else {
                show(remaining[0])
            }
        } else if focusedTabID == tab.id {
            focusedTabID = displayed.first
        }
        save()
    }

    /// Clears the Today section except whatever you're currently looking at.
    /// Every closed tab goes onto the reopen stack, so ⌘⇧T walks them back —
    /// that's the undo, rather than a confirmation dialog.
    func closeAllTodayTabs() {
        // The active tab survives, unless it's pinned (in which case nothing in
        // Today is active and the whole section clears).
        let keepID: UUID? = {
            guard let focused = focusedTab, focused.tier == .today else { return nil }
            return focused.id
        }()
        let doomed = todayTabs.filter { $0.id != keepID }
        guard !doomed.isEmpty else { return }

        for tab in doomed {
            if let url = tab.webView.url ?? URL(string: tab.urlString) {
                closedStack.insert((url, tab.displayTitle), at: 0)
            }
            tab.webView.stopLoading()
        }
        if closedStack.count > 20 { closedStack.removeLast(closedStack.count - 20) }

        let cleared = Set(doomed.map(\.id))
        for id in cleared { todayItems.removeNode(id: id) }
        // Groups left holding nothing are noise; drop them.
        todayItems.removeAll { $0.isGroup && $0.allTabs.isEmpty }
        displayed.removeAll { cleared.contains($0) }
        paneRatios = Self.normalized([], count: max(displayed.count, 1))
        splitGroups.removeAll { !$0.tabs.filter(cleared.contains).isEmpty }

        if displayed.isEmpty {
            if let survivor = orderedTabs.first {
                show(survivor)
            } else {
                newTab(url: URL(string: "https://duckduckgo.com")!)
            }
        } else if let focused = focusedTabID, cleared.contains(focused) {
            focusedTabID = displayed.first
        }
        save()
    }

    /// What the Today clear button would actually close, for its label.
    var clearableTodayCount: Int {
        let keep = focusedTab.flatMap { $0.tier == .today ? $0.id : nil }
        return todayTabs.filter { $0.id != keep }.count
    }

    func closeFocusedTab() {
        if peekTab != nil { dismissPeek(); return }
        if let tab = focusedTab { close(tab) }
    }

    /// ⌘⇧T — reopens the most recently closed tab.
    func reopenClosedTab() {
        guard !closedStack.isEmpty else { return }
        let entry = closedStack.removeFirst()
        newTab(url: entry.url)
    }

    var canReopenClosedTab: Bool { !closedStack.isEmpty }

    /// ⌘1…⌘9 — jumps to the nth tab in sidebar order. ⌘9 is the last tab.
    func jumpToTab(_ number: Int) {
        let order = orderedTabs
        guard !order.isEmpty else { return }
        let index = number == 9 ? order.count - 1 : number - 1
        guard order.indices.contains(index) else { return }
        show(order[index])
    }

    /// Escape, handled globally: peek first, then find, then the command bar.
    /// Returns true when something was actually dismissed.
    @discardableResult
    func dismissTopmostOverlay() -> Bool {
        if peekTab != nil { dismissPeek(); return true }
        if let tab = focusedTab, tab.autofillAnchor != nil {
            tab.autofillAnchor = nil
            return true
        }
        if showDownloads { showDownloads = false; return true }
        if showFindBar { showFindBar = false; findQuery = ""; return true }
        if commandBarMode != nil {
            MainActor.assumeIsolated { closeCommandBar(committed: false) }
            return true
        }
        if passwords.savePrompt != nil { passwords.dismissSave(); return true }
        return false
    }

    func copyCurrentURL() {
        guard let url = focusedTab?.webView.url?.absoluteString ?? focusedTab?.urlString,
              !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func cycleTab(by offset: Int) {
        let order = orderedTabs
        guard !order.isEmpty,
              let current = order.firstIndex(where: { $0.id == focusedTabID }) else { return }
        show(order[(current + offset + order.count) % order.count])
    }

    // MARK: - Archiving

    private func startArchiveTimer() {
        let interval: TimeInterval =
            ProcessInfo.processInfo.environment["ARK_SNOOZE_MINUTES"] != nil ? 5 : 120
        archiveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.archiveStaleTabs()
                await self?.sweepSnooze()
            }
        }
        startMemoryPressureWatch()
    }

    /// When the system says memory is tight, free every background page at once
    /// rather than waiting for the idle timer. This is the case the feature
    /// exists for, so it shouldn't be on a two-minute delay.
    private func startMemoryPressureWatch() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.snoozeAllBackgroundTabs() }
        }
        source.activate()
        memoryPressureSource = source
    }

    /// Closes Today tabs untouched for longer than `archiveHours`.
    func archiveStaleTabs() {
        guard archiveHours > 0 else { return }
        let cutoff = Date().addingTimeInterval(-archiveHours * 3600)
        let stale = todayTabs.filter { $0.lastAccessed < cutoff && !displayed.contains($0.id) }
        guard !stale.isEmpty else { return }
        for tab in stale {
            tab.webView.stopLoading()
            detach(tab)
        }
        save()
    }

    // MARK: - Bookmarks & history

    func toggleBookmark() {
        guard let tab = focusedTab, let url = tab.webView.url else { return }
        if let existing = bookmarks.firstIndex(where: { $0.url == url.absoluteString }) {
            bookmarks.remove(at: existing)
        } else {
            bookmarks.append(Bookmark(title: tab.displayTitle, url: url.absoluteString))
        }
        save()
    }

    var focusedTabIsBookmarked: Bool {
        guard let url = focusedTab?.webView.url?.absoluteString else { return false }
        return bookmarks.contains { $0.url == url }
    }

    func recordVisit(url: URL, title: String) {
        let str = url.absoluteString
        history.removeAll { $0.url == str }
        history.insert(HistoryEntry(title: title, url: str, visitedAt: Date()), at: 0)
        if history.count > 2000 { history.removeLast(history.count - 2000) }
        save()
    }

    // MARK: - Command bar search

    struct Suggestion: Identifiable, Hashable {
        enum Kind { case openTab, bookmark, history, search, ai }
        var id: String { "\(kind)-\(url)-\(label)" }
        var kind: Kind
        var label: String
        var detail: String
        var url: String
        var tabID: UUID?
    }

    /// Instant, local results. AI rows are appended separately by the view.
    func localSuggestions(for query: String, limit: Int = 8) -> [Suggestion] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var out: [Suggestion] = []

        for tab in allTabs where tab.displayTitle.lowercased().contains(q) || tab.urlString.lowercased().contains(q) {
            out.append(Suggestion(kind: .openTab, label: tab.displayTitle,
                                  detail: "Switch to tab", url: tab.urlString, tabID: tab.id))
        }
        for mark in bookmarks where mark.title.lowercased().contains(q) || mark.url.lowercased().contains(q) {
            out.append(Suggestion(kind: .bookmark, label: mark.title, detail: mark.url, url: mark.url))
        }
        var seen = Set(out.map(\.url))
        for entry in history where entry.title.lowercased().contains(q) || entry.url.lowercased().contains(q) {
            guard seen.insert(entry.url).inserted else { continue }
            out.append(Suggestion(kind: .history, label: entry.title, detail: entry.url, url: entry.url))
        }
        return Array(out.prefix(limit))
    }

    /// The strongest "this is a site, not a search" candidate for what's typed.
    ///
    /// Ranked by how the host matches, because a host prefix is a much better
    /// signal than a title substring: exact host, then host prefix, then a
    /// domain-label prefix. Titles are deliberately ignored here — matching them
    /// is what made "notes" open a random article instead of a site.
    func bestSiteMatch(for query: String) -> Suggestion? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2, !q.contains(" ") else { return nil }

        func host(_ raw: String) -> String {
            let h = URL(string: raw)?.host?.lowercased() ?? ""
            return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }
        func score(_ h: String) -> Int? {
            guard !h.isEmpty else { return nil }
            if h == q { return 0 }
            if h.hasPrefix(q) { return 1 }
            // "gith" -> github.com via the first label
            if let label = h.split(separator: ".").first, label.hasPrefix(q) { return 2 }
            return nil
        }

        var best: (Int, Suggestion)?
        func consider(_ suggestion: Suggestion) {
            guard let s = score(host(suggestion.url)) else { return }
            if best == nil || s < best!.0 { best = (s, suggestion) }
        }

        for tab in allTabs where !tab.urlString.isEmpty {
            consider(Suggestion(kind: .openTab, label: tab.displayTitle,
                                detail: "Switch to tab", url: tab.urlString, tabID: tab.id))
        }
        for mark in bookmarks {
            consider(Suggestion(kind: .bookmark, label: mark.title,
                                detail: mark.url, url: mark.url))
        }
        for entry in history.prefix(400) {
            consider(Suggestion(kind: .history, label: entry.title,
                                detail: entry.url, url: entry.url))
        }
        return best?.1
    }

    func open(_ suggestion: Suggestion) {
        if let tabID = suggestion.tabID, let tab = allTabs.first(where: { $0.id == tabID }) {
            show(tab)
        } else if let url = URL(string: suggestion.url) {
            MainActor.assumeIsolated { openFromCommandBar(url) }
        }
        MainActor.assumeIsolated { closeCommandBar(committed: true) }
    }

    // MARK: - Blocking

    func applyBlocking(to tab: BrowserTab) {
        let controller = tab.webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        let host = tab.webView.url?.host ?? ""
        let allowed = !blockingEnabled || blockerAllowlist.contains(where: { host.hasSuffix($0) })
        guard !allowed, let list = ContentBlocker.shared.ruleList else { return }
        controller.add(list)
    }

    func applyBlockingEverywhere() {
        for tab in allTabs { applyBlocking(to: tab) }
        if let peekTab { applyBlocking(to: peekTab) }
    }

    func toggleBlocking(forHostOf tab: BrowserTab) {
        guard let host = tab.webView.url?.host else { return }
        if blockerAllowlist.contains(host) { blockerAllowlist.remove(host) }
        else { blockerAllowlist.insert(host) }
        applyBlocking(to: tab)
        tab.reload()
        save()
    }

    func blockingActive(for tab: BrowserTab?) -> Bool {
        guard blockingEnabled, let host = tab?.webView.url?.host else { return blockingEnabled }
        return !blockerAllowlist.contains(where: { host.hasSuffix($0) })
    }

    // MARK: - Persistence

    private struct TabSnap: Codable {
        var id: UUID
        var url: String
        var title: String
        var customTitle: String?
        var emoji: String?
        var pinnedURL: String?
        var lastAccessed: Date
    }

    private struct NodeSnap: Codable {
        var groupName: String?
        var isExpanded: Bool
        var tab: TabSnap?
        var children: [NodeSnap]

        // Groups used to be called folders. Accept the old key so existing
        // state files keep loading after the rename.
        enum CodingKeys: String, CodingKey {
            case groupName, folderName, isExpanded, tab, children
        }

        init(groupName: String?, isExpanded: Bool, tab: TabSnap?, children: [NodeSnap]) {
            self.groupName = groupName
            self.isExpanded = isExpanded
            self.tab = tab
            self.children = children
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
                ?? c.decodeIfPresent(String.self, forKey: .folderName)
            isExpanded = try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
            tab = try c.decodeIfPresent(TabSnap.self, forKey: .tab)
            children = try c.decodeIfPresent([NodeSnap].self, forKey: .children) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(groupName, forKey: .groupName)
            try c.encode(isExpanded, forKey: .isExpanded)
            try c.encodeIfPresent(tab, forKey: .tab)
            try c.encode(children, forKey: .children)
        }
    }

    private struct Snapshot: Codable {
        var version: Int
        var favorites: [TabSnap]
        var pinned: [NodeSnap]
        var today: [TabSnap]?
        var todayNodes: [NodeSnap]?
        var displayed: [UUID]
        var paneRatios: [Double]?
        var splitGroups: [SplitGroup]?
        var focusedTabID: UUID?
        var bookmarks: [Bookmark]
        var history: [HistoryEntry]
        var allowlist: [String]
        var blockingEnabled: Bool
        var aiSuggestionsEnabled: Bool
        var glassChrome: Bool?
        var glassIntensity: Double?
        var chromeTintStrength: Double?
        var sidebarStyle: String?
        /// Pre-picker flag. Keeps the original key name — renaming it would
        /// decode as nil and silently lose the migration.
        var tintChromeFromPage: Bool?
        var sidebarColorRGB: [Double]?
        var groupingEngine: String?
        var archiveHours: Double
        var snoozeMinutes: Double?
        var lastSeenVersion: String?
        var passwordSource: String?
        var sidebarWidth: Double
        var aiWidth: Double
        var showSidebar: Bool
        var sidebarAutoHide: Bool?
    }

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    private func snap(_ tab: BrowserTab) -> TabSnap {
        TabSnap(id: tab.id,
                url: tab.webView.url?.absoluteString ?? tab.urlString,
                title: tab.title,
                customTitle: tab.customTitle,
                emoji: tab.emoji,
                pinnedURL: tab.pinnedURL,
                lastAccessed: tab.lastAccessed)
    }

    private func snap(_ item: SidebarItem) -> NodeSnap {
        NodeSnap(groupName: item.groupName,
                 isExpanded: item.isExpanded,
                 tab: item.tab.map(snap),
                 children: item.children.map(snap))
    }

    func save() {
        let shot = Snapshot(
            version: 2,
            favorites: favorites.map(snap),
            pinned: pinned.map(snap),
            today: nil,
            todayNodes: todayItems.map(snap),
            displayed: displayed,
            paneRatios: paneRatios,
            splitGroups: splitGroups,
            focusedTabID: focusedTabID,
            bookmarks: bookmarks,
            history: Array(history.prefix(500)),
            allowlist: Array(blockerAllowlist),
            blockingEnabled: blockingEnabled,
            aiSuggestionsEnabled: aiSuggestionsEnabled,
            glassChrome: glassChrome,
            glassIntensity: glassIntensity,
            chromeTintStrength: chromeTintStrength,
            sidebarStyle: sidebarStyle.rawValue,
            sidebarColorRGB: sidebarColorRGB,
            groupingEngine: groupingEngine.rawValue,
            archiveHours: archiveHours,
            snoozeMinutes: snoozeMinutes,
            lastSeenVersion: lastSeenVersion,
            passwordSource: passwords.source.rawValue,
            sidebarWidth: sidebarWidth,
            aiWidth: aiWidth,
            showSidebar: showSidebar,
            sidebarAutoHide: sidebarAutoHide
        )
        guard let data = try? JSONEncoder().encode(shot) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    private func restore(_ s: TabSnap, tier: TabTier) -> BrowserTab {
        let tab = BrowserTab(id: s.id, url: URL(string: s.url), state: self, tier: tier)
        tab.title = s.title
        tab.customTitle = s.customTitle
        tab.emoji = s.emoji
        tab.pinnedURL = s.pinnedURL ?? (tier == .today ? nil : s.url)
        // Deliberately NOT s.lastAccessed: the archive clock restarts each
        // launch. Otherwise reopening after a few days would archive every Today
        // tab before the window even appeared.
        tab.lastAccessed = Date()
        return tab
    }

    private func restore(_ n: NodeSnap, tier: TabTier = .pinned) -> SidebarItem? {
        if let name = n.groupName {
            return SidebarItem(groupName: name,
                               children: n.children.compactMap { restore($0, tier: tier) },
                               isExpanded: n.isExpanded)
        }
        if let t = n.tab { return SidebarItem(tab: restore(t, tier: tier)) }
        return nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let shot = try? JSONDecoder().decode(Snapshot.self, from: data),
              shot.version == 2 else { return }
        bookmarks = shot.bookmarks
        history = shot.history
        blockerAllowlist = Set(shot.allowlist)
        blockingEnabled = shot.blockingEnabled
        aiSuggestionsEnabled = shot.aiSuggestionsEnabled
        glassChrome = shot.glassChrome ?? true
        glassIntensity = min(max(shot.glassIntensity ?? 0.6, 0), 1)
        chromeTintStrength = shot.chromeTintStrength ?? 0.55
        // Migration: a state file written before the style picker carries the
        // old boolean. Honour it once — someone who had page tinting off wanted
        // plain glass, and silently switching them to tinted is a surprise.
        if let stored = shot.sidebarStyle.flatMap(SidebarStyle.init(rawValue:)) {
            sidebarStyle = stored
        } else {
            sidebarStyle = (shot.tintChromeFromPage ?? true) ? .pageTint : .glass
        }
        sidebarColorRGB = shot.sidebarColorRGB ?? [0.24, 0.36, 0.72]
        // "automatic" was the old default and only ever meant "prefer
        // on-device", so it lands on the explicit on-device setting. An explicit
        // .claude choice is left alone — that one was deliberate.
        let saved = shot.groupingEngine.flatMap(GroupingEngine.init(rawValue:))
        groupingEngine = (saved == nil || saved == .automatic) ? .appleIntelligence : saved!
        archiveHours = shot.archiveHours
        snoozeMinutes = shot.snoozeMinutes ?? 20
        lastSeenVersion = shot.lastSeenVersion
        if let raw = shot.passwordSource,
           let parsed = PasswordManager.Source(rawValue: raw) {
            passwords.source = parsed
        }
        sidebarWidth = shot.sidebarWidth
        aiWidth = shot.aiWidth
        showSidebar = shot.showSidebar
        sidebarAutoHide = shot.sidebarAutoHide ?? false
        favorites = shot.favorites.map { restore($0, tier: .favorite) }
        pinned = shot.pinned.compactMap { restore($0, tier: .pinned) }
        // todayNodes is the current shape; `today` is the pre-groups flat list.
        if let nodes = shot.todayNodes {
            todayItems = nodes.compactMap { restore($0, tier: .today) }
        } else if let flat = shot.today {
            todayItems = flat.map { SidebarItem(tab: restore($0, tier: .today)) }
        } else {
            todayItems = []
        }

        let live = Set(allTabs.map(\.id))
        displayed = shot.displayed.filter(live.contains)
        paneRatios = normalized(shot.paneRatios ?? [], count: max(displayed.count, 1))
        splitGroups = (shot.splitGroups ?? []).filter { group in
            group.tabs.filter(live.contains).count > 1
        }
        focusedTabID = shot.focusedTabID.flatMap { live.contains($0) ? $0 : nil }
    }
}
