import Combine
import SwiftUI

/// Window setup that must happen in AppKit. Done from a delegate as well as the
/// helper view, because the helper's `viewDidMoveToWindow` can run before the
/// window is fully configured.
final class ArkAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureWindows()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.configureWindows() }
    }

    private func configureWindows() {
        for window in NSApp.windows where window.contentView != nil {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.acceptsMouseMovedEvents = true
            window.isMovableByWindowBackground = false
            NSLog("Ark: window fullSizeContentView=%d titlebarTransparent=%d",
                  window.styleMask.contains(.fullSizeContentView) ? 1 : 0,
                  window.titlebarAppearsTransparent ? 1 : 0)
        }
    }
}

@main
struct ArkApp: App {
    @NSApplicationDelegateAdaptor(ArkAppDelegate.self) private var appDelegate
    @State private var state: BrowserState

    init() {
        // Exits before any window when run with --selftest.
        SelfTest.runIfRequested()
        // Before any state is read or any web view exists.
        Migration.runIfNeeded()
        let state = BrowserState()
        _state = State(initialValue: state)
        Self.installEscapeMonitor(state)
        Self.installDragEndMonitor(state)
        Self.installSidebarEdgeMonitor(state)
        WindowProbe.armIfRequested(state)
    }

    /// Left-edge hover reveal for the auto-hidden sidebar.
    ///
    /// A local monitor sees the event before delivery, so this still works while
    /// the pointer is over a web view — which is why `.onHover` on an edge strip
    /// was not enough.
    private static func installSidebarEdgeMonitor(_ state: BrowserState) {
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            // Cursor ownership first, and this has to happen before the
            // auto-hide guard: it applies to any floating panel, not just the
            // sidebar. Swallowing the event is the point — WebKit sets the
            // cursor while handling mouseMoved, and it gets those through its own
            // tracking area no matter what is drawn above it. Cursor rects can't
            // win that argument; not delivering the event can.
            if let window = event.window,
               CursorShield.coversPointer(event.locationInWindow, in: window) {
                NSCursor.arrow.set()
                return nil
            }
            guard state.sidebarAutoHide, event.window != nil else { return event }
            let x = event.locationInWindow.x
            let revealEdge: CGFloat = 16
            // Hysteresis: reveal from a narrow strip, but keep it open across the
            // whole sidebar plus a margin, so it doesn't close under the pointer.
            let keepOpen = CGFloat(state.sidebarWidth) + 16
            Task { @MainActor in
                if x <= revealEdge {
                    state.revealSidebar()
                } else if x > keepOpen {
                    state.scheduleSidebarHide()
                }
            }
            return event
        }
    }

    /// A drag that ends outside any pane never reports a drop, so the flag that
    /// makes pane drop layers live has to be cleared on mouse-up.
    private static func installDragEndMonitor(_ state: BrowserState) {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            if state.tabDragActive {
                Task { @MainActor in
                    state.tabDragActive = false
                    // Animate the row settling into its new home.
                    withAnimation(Motion.settle) { state.draggingTabID = nil }
                }
            }
            return event
        }
    }

    /// Escape isn't a menu shortcut, so a local event monitor handles it —
    /// dismissing peek, downloads, find, and the command bar in that order.
    /// The event is only swallowed when something was actually dismissed, so
    /// pages still see Escape otherwise.
    private static func installEscapeMonitor(_ state: BrowserState) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            return state.dismissTopmostOverlay() ? nil : event
        }
    }

    var body: some Scene {
        Window(AppPaths.isStaging ? "Ark Staging" : "Ark", id: "main") {
            RootView()
                .environment(state)
                .background(WindowMouseTracking().frame(width: 0, height: 0))
                .task {
                    await ContentBlocker.shared.compile()
                    state.applyBlockingEverywhere()
                    state.archiveStaleTabs()
                    // Deliberately no `op` call here. Loading the 1Password item
                    // list at launch cost an authorization prompt before the user
                    // had asked for anything.

                    // Release notes for the version just installed, once.
                    let version = Updater.currentVersion
                    if let page = WhatsNew.prepare(lastSeen: state.lastSeenVersion,
                                                   current: version) {
                        state.openInNewTab(page)
                    }
                    if state.lastSeenVersion != version {
                        state.lastSeenVersion = version
                        state.save()
                    }

                    // Update check, after the window is up. Silent unless there
                    // is something newer; a launch-time modal for "you're up to
                    // date" is the wrong trade.
                    if state.updater.automaticallyChecks {
                        await state.updater.check()
                    }
                }
                .onDisappear { state.save() }
                // Coming back to Ark is the cheapest moment to notice that
                // 1Password locked while we were away.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Mark stale only — no process spawn, so no prompt.
                    state.passwords.markOnePasswordStale()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands { ArkCommands(state: state) }

        Settings {
            SettingsView().environment(state)
        }
    }
}

struct ArkCommands: Commands {
    let state: BrowserState

    var body: some Commands {
        // Grouped because a Commands builder takes at most ten children, and a
        // eleventh reports as an "extra argument" error on an unrelated group.
        Group {
            CommandGroup(replacing: .appInfo) {
                Button("Check for Updates…") {
                    Task { await state.updater.check(userInitiated: true) }
                }
            }
            CommandGroup(replacing: .help) {
                Button("Request a Feature…") { state.showFeatureRequest = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift, .option])
            }
        }



        CommandGroup(replacing: .newItem) {
            Button("New Tab") { state.beginNewTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Group") { state.newGroup() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Button("Close Tab") { state.closeFocusedTab() }
                .keyboardShortcut("w", modifiers: .command)
            Button("Reopen Closed Tab") { state.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!state.canReopenClosedTab)
            Divider()
            Button("Downloads") { state.showDownloads.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }

        CommandMenu("Navigate") {
            Button("Open Location…") { state.commandBarMode = .editURL }
                .keyboardShortcut("l", modifiers: .command)
            Button("Reload") { state.focusedTab?.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Find on Page…") { state.showFindBar = true }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Back") { state.focusedTab?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { state.focusedTab?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("Next Tab") { state.cycleTab(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { state.cycleTab(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Copy Address") { state.copyCurrentURL() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            // ⌘1–⌘8 jump to that tab; ⌘9 jumps to the last one, like Safari.
            ForEach(1...9, id: \.self) { n in
                Button("Tab \(n)") { state.jumpToTab(n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { state.focusedTab?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { state.focusedTab?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { state.focusedTab?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
        }

        CommandMenu("Tabs") {
            Button("Deselect All Tabs") { state.clearSelection() }
                .disabled(state.selectionCount == 0)
            Divider()
            Button("Pin Tab") {
                if let tab = state.focusedTab {
                    tab.tier == .today ? state.pin(tab) : state.unpin(tab)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Add to Favorites") {
                if let tab = state.focusedTab { state.addToFavorites(tab) }
            }
            Button("Reset Pinned Tab") { state.focusedTab?.resetToPinned() }
            Divider()
            Button("Split with Next Tab") { state.splitWithNextTab() }
                .keyboardShortcut("\\", modifiers: [.command, .option])
            Button("Collapse Split") { state.collapseSplit() }
                .keyboardShortcut("\\", modifiers: [.command, .option, .shift])
            Button("Focus Next Pane") { state.focusPane(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Focus Previous Pane") { state.focusPane(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            Button("Open Peek as Tab") { state.promotePeek() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.peekTab == nil)
            Divider()
            Button("Archive Stale Tabs Now") { state.archiveStaleTabs() }
            Divider()
            Button(state.organizing ? "Organizing…" : "Group Tabs with AI…") {
                Task { await state.organizeTabs() }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(state.organizing || state.organizableTabs.count < 2)
        }

        CommandMenu("Bookmarks") {
            Button(state.focusedTabIsBookmarked ? "Remove Bookmark" : "Add Bookmark") {
                state.toggleBookmark()
            }
            .keyboardShortcut("d", modifiers: .command)
            Divider()
            if state.bookmarks.isEmpty {
                Text("No bookmarks yet")
            } else {
                ForEach(state.bookmarks) { mark in
                    Button(mark.title.isEmpty ? mark.url : mark.title) {
                        if let url = URL(string: mark.url) { state.newTab(url: url) }
                    }
                }
            }
        }

        CommandMenu("History") {
            if state.history.isEmpty {
                Text("No history yet")
            } else {
                ForEach(state.history.prefix(20)) { entry in
                    Button(entry.title.isEmpty ? entry.url : entry.title) {
                        if let url = URL(string: entry.url) { state.newTab(url: url) }
                    }
                }
                Divider()
                Button("Clear History") { state.history = []; state.save() }
            }
        }

        CommandMenu("Passwords") {
            Button("Fill Login") {
                if let tab = state.focusedTab {
                    Task { _ = await state.passwords.fill(into: tab) }
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Lock Vault") { state.passwords.lock() }
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { state.showSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button(state.sidebarAutoHide ? "Pin Sidebar" : "Auto-Hide Sidebar") {
                state.sidebarAutoHide.toggle()
                state.save()
            }
            .keyboardShortcut("s", modifiers: [.command, .option, .shift])
            Button("Toggle AI Panel") { state.showAISidebar.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
    }
}
