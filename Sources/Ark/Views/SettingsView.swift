import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings, one tab per group.
///
/// It used to be four tabs where "General" held default-browser, appearance,
/// search, tabs, blocking *and* updates — a dumping ground you had to read
/// top-to-bottom to find anything. Splitting by subject means the tab bar is the
/// index, which is what a tab bar is for.
///
/// Passwords and 1Password are one tab: they are two halves of the same
/// question, and choosing between two tabs to find out where a login lives is a
/// decision nobody should have to make.
struct SettingsView: View {
    @Environment(BrowserState.self) private var state

    /// `.tabItem` is the pre-macOS-15 spelling, and on 26 it produced a tab bar
    /// of identical labels — the labels stopped binding to their tabs. `Tab` is
    /// the current API and gets it right; the old path stays for the macOS 14
    /// floor.
    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                TabView {
                    Tab("General", systemImage: "gearshape") { GeneralPane() }
                    Tab("Appearance", systemImage: "paintbrush") { AppearancePane() }
                    Tab("Tabs", systemImage: "square.on.square") { TabsPane() }
                    Tab("Privacy", systemImage: "hand.raised") { PrivacyPane() }
                    Tab("Passwords", systemImage: "key.fill") { PasswordsPane() }
                    Tab("AI", systemImage: "sparkles") { AIPane() }
                    Tab("Backups", systemImage: "clock.arrow.circlepath") { BackupsPane() }
                    Tab("Updates", systemImage: "arrow.down.circle") { UpdatesPane() }
                }
            } else {
                TabView {
                    GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
                    AppearancePane().tabItem { Label("Appearance", systemImage: "paintbrush") }
                    TabsPane().tabItem { Label("Tabs", systemImage: "square.on.square") }
                    PrivacyPane().tabItem { Label("Privacy", systemImage: "hand.raised") }
                    PasswordsPane().tabItem { Label("Passwords", systemImage: "key.fill") }
                    AIPane().tabItem { Label("AI", systemImage: "sparkles") }
                    BackupsPane().tabItem { Label("Backups", systemImage: "clock.arrow.circlepath") }
                    UpdatesPane().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                }
            }
        }
        .frame(width: 620, height: 560)
        // No `ignoresSafeArea` at this level, deliberately. Extending the
        // backdrop under the title bar let the tab strip ride up into it, so the
        // traffic lights ended up sitting *inside* the row of tab icons.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// An opaque backing for the window and its section headers.
///
/// The window inherits the app's vibrancy, so over a bright page the headers and
/// the tab bar washed out to ghost text. `Form`'s own scroll background is hidden
/// and replaced with this, which is also what gives the headers something to sit
/// on rather than floating over whatever is behind the window.
struct SettingsBackdrop: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(Color.primary.opacity(0.03))
    }
}

private struct GeneralPane: View {
    @Environment(BrowserState.self) private var state
    @State private var browserStatus: String?
    @State private var asking = false

    var body: some View {
        Form {
            Section("Default browser") {
                LabeledContent("Currently") {
                    if DefaultBrowser.isDrift {
                        Label("Ark", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Text(DefaultBrowser.current ?? "unknown")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(asking ? "Asking macOS…" : "Set Ark as Default Browser") {
                        asking = true
                        Task {
                            let result = await DefaultBrowser.requestDefault()
                            await MainActor.run { browserStatus = result; asking = false }
                        }
                    }
                    .disabled(asking || DefaultBrowser.isDrift)
                    Spacer()
                }
                if let browserStatus {
                    Text(browserStatus)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !DefaultBrowser.isInApplications {
                    Text("Ark is running from its project folder. macOS will accept that, but the registration is rebuilt every time you run build.sh — copy Ark.app to /Applications if you want this to stick.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Search") {
                Picker("Search engine", selection: Binding(
                    get: { SearchEngine.current },
                    set: { SearchEngine.current = $0 }
                )) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                Text("Used for anything typed in the command bar that isn't a URL.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(SettingsBackdrop())
    }
}

private struct AppearancePane: View {
    @Environment(BrowserState.self) private var state

    /// One explanation per mode, so the slider's meaning is never ambiguous.
    private var sidebarStyleNote: String {
        switch state.sidebarStyle {
        case .glass:
            return "Glass only, no colour. The slider drives rim highlight and whether small controls get the pointer-tracking variant — the two things glass actually exposes, since the effect itself has no intensity parameter."
        case .pageTint:
            return "Ranks every colour the page exposes — theme colour, header and body backgrounds, accent colour, link and button colours — and takes the most usable one, discounting very dark shades because their hue is too thin to survive being lightened. Blank tabs use their own colour field. Cross-fades when you switch pages."
        case .custom:
            return "One fixed colour over the glass, ignoring the page. The slider sets how strongly it shows."
        }
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Liquid Glass chrome", isOn: Binding(
                    get: { state.glassChrome },
                    set: { state.glassChrome = $0; state.save() }
                ))

                GlassIntensitySlider()
                    .disabled(!state.glassChrome)
                    .opacity(state.glassChrome ? 1 : 0.45)

                Text("Applies glass to the sidebar, panel edges, and pane rims. Never behind live web content — that is the large-area case that would actually cost battery. Falls back to standard materials when off, or on macOS below 26.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Sidebar", selection: Binding(
                    get: { state.sidebarStyle },
                    set: { state.sidebarStyle = $0; state.save() }
                )) {
                    ForEach(BrowserState.SidebarStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                if state.sidebarStyle == .custom {
                    ColorPicker("Colour", selection: Binding(
                        get: { state.sidebarColor },
                        set: { state.sidebarColor = $0; state.save() }
                    ), supportsOpacity: false)
                }

                HStack(spacing: 10) {
                    Text(state.sidebarStyle == .glass ? "Glass intensity" : "Colour strength")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { state.sidebarIntensity },
                        set: { state.sidebarIntensity = $0 }
                    ), in: 0...1, onEditingChanged: { editing in
                        if !editing { state.save() }
                    })
                    Text("\(Int(state.sidebarIntensity * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }

                Text(sidebarStyleNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if Motion.reduced {
                    Text("Reduce Motion is on in System Settings, so Ark's springs are shortened to brief fades.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(SettingsBackdrop())
    }
}

private struct TabsPane: View {
    @Environment(BrowserState.self) private var state

    var body: some View {
        Form {
            Section("Tabs") {
                Picker("Archive Today tabs after", selection: Binding(
                    get: { state.archiveHours },
                    set: { state.archiveHours = $0; state.save() }
                )) {
                    Text("6 hours").tag(6.0)
                    Text("12 hours").tag(12.0)
                    Text("24 hours").tag(24.0)
                    Text("Never").tag(0.0)
                }
                Text("Pinned tabs and favorites are never archived.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Memory") {
                Picker("Snooze idle tabs after", selection: Binding(
                    get: { state.snoozeMinutes },
                    set: { state.snoozeMinutes = $0; state.save() }
                )) {
                    Text("Never").tag(0.0)
                    Text("5 minutes").tag(5.0)
                    Text("20 minutes").tag(20.0)
                    Text("1 hour").tag(60.0)
                    Text("3 hours").tag(180.0)
                }
                Text("WebKit gives every tab its own process, and a page's DOM and JavaScript heap are most of what it holds. Snoozing frees the page and keeps the tab: scroll position and back/forward history are preserved, and clicking the tab restores it. Tabs on screen are never snoozed, nor is anything playing audio or video. Ark also frees every background page immediately when macOS reports memory pressure.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(state.snoozedCount == 0
                         ? "No tabs snoozed right now."
                         : "\(state.snoozedCount) tab\(state.snoozedCount == 1 ? "" : "s") snoozed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Snooze Background Tabs Now") {
                        Task { await state.snoozeAllBackgroundTabs() }
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(SettingsBackdrop())
    }
}

private struct PrivacyPane: View {
    @Environment(BrowserState.self) private var state

    var body: some View {
        Form {
            Section("Blocking") {
                Toggle("Block ads and trackers", isOn: Binding(
                    get: { state.blockingEnabled },
                    set: { state.blockingEnabled = $0; state.applyBlockingEverywhere(); state.save() }
                ))
                Text("\(ContentBlocker.shared.ruleCount) rules active. Counts shown in the sidebar are approximate — WebKit reports no per-block callback.")
                    .font(.caption).foregroundStyle(.secondary)

                if !state.blockerAllowlist.isEmpty {
                    LabeledContent("Allowed sites") {
                        VStack(alignment: .leading) {
                            ForEach(Array(state.blockerAllowlist).sorted(), id: \.self) { host in
                                HStack {
                                    Text(host).font(.caption)
                                    Button {
                                        state.blockerAllowlist.remove(host)
                                        state.applyBlockingEverywhere()
                                        state.save()
                                    } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(SettingsBackdrop())
    }
}

private struct AIPane: View {
    @Environment(BrowserState.self) private var state
    @State private var keyDraft = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("Anthropic API key") {
                SecureField("sk-ant-…", text: $keyDraft)
                HStack {
                    Button("Save to Keychain") {
                        Keychain.writeAPIKey(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                        keyDraft = ""
                        saved = true
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Remove") {
                        Keychain.deleteAPIKey()
                        saved = false
                    }
                    Spacer()
                    if ClaudeClient.hasKey {
                        Label("Key found", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Label("No key", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Stored in your local keychain, not synced, and never written to disk by Ark. ANTHROPIC_API_KEY in the environment takes precedence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tab grouping") {
                Picker("AI engine (grouping and suggestions)", selection: Binding(
                    get: { state.groupingEngine },
                    set: { state.groupingEngine = $0; state.save() }
                )) {
                    ForEach(GroupingEngine.selectable) { engine in
                        Text(engine.label).tag(engine)
                    }
                }

                LabeledContent("Apple Intelligence") {
                    if OnDeviceOrganizer.availability.isAvailable {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Label("Unavailable", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(OnDeviceOrganizer.availability.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Will use") {
                    Text(state.effectiveGroupingEngine == .appleIntelligence
                         ? "Apple Intelligence — on-device"
                         : "Claude — sends titles and hostnames")
                        .font(.caption)
                        .foregroundStyle(state.effectiveGroupingEngine == .appleIntelligence
                                         ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }

                Text("On-device grouping is private and free: no tab titles or hostnames leave this Mac, and it works offline. It handles up to \(TabOrganizer.onDeviceTabCap) tabs at a time. The Claude path is the fallback when Apple Intelligence is off or unsupported — it sends titles and hostnames only, never page content.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Command bar") {
                Toggle("AI suggestions while typing", isOn: Binding(
                    get: { state.aiSuggestionsEnabled },
                    set: { state.aiSuggestionsEnabled = $0; state.save() }
                ))
                Text("Uses the engine selected under Tab grouping. On Apple Intelligence the query never leaves your Mac; on Claude it is sent to the API after a 400 ms pause. Either way, local history and bookmark matches appear instantly and never leave your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Page assistant") {
                Text("Uses \(ClaudeClient.model). Page text is sent as context when you ask a question, and is labeled as untrusted data in the prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(SettingsBackdrop())
    }
}

private struct BackupsPane: View {
    @Environment(BrowserState.self) private var state

    var body: some View {
        Form {
            Section("Backups") {
                BackupList()
                Text("A copy of the tab list is kept before each save, at most one every ten minutes — and always when the tab count drops by three or more, which is the shape of the failure this exists for. The newest \(StateBackups.keep) are kept. Restoring copies the current file aside first, then needs a relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(SettingsBackdrop())
    }
}

private struct UpdatesPane: View {
    @Environment(BrowserState.self) private var state

    @ViewBuilder
    private var updateStatus: some View {
        switch state.updater.phase {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("Up to date.", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .available(let release):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Ark \(release.version) is available.").font(.caption)
                    Spacer()
                    Button("Update") { Task { await state.updater.install(release) } }
                        .controlSize(.small)
                }
                if release.sha256 == nil {
                    Label("This release publishes no checksum — the download can't be verified.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !release.notes.isEmpty {
                    Text(release.notes.prefix(400))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading…").font(.caption) }
        case .readyToRelaunch:
            HStack {
                Text("Installed. Relaunch to finish.").font(.caption)
                Spacer()
                Button("Relaunch") { state.updater.relaunch() }.controlSize(.small)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        Form {
            Section("Updates") {
                HStack {
                    Text("Ark \(Updater.currentVersion)")
                    if AppPaths.isStaging {
                        Text("STAGING")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.22), in: Capsule())
                    }
                    Spacer()
                    Button("Check Now") {
                        Task { await state.updater.check(userInitiated: true) }
                    }
                    .controlSize(.small)
                    .disabled(AppPaths.isStaging)
                }
                if AppPaths.isStaging {
                    Text("This is the staging copy — separate identifier, separate data folder, separate cookies. It updates when you run `tools/stage.sh`, not from the release feed, so a release can't replace what you're testing.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Check for updates at launch", isOn: Binding(
                    get: { state.updater.automaticallyChecks },
                    set: { state.updater.automaticallyChecks = $0 }
                ))
                updateStatus
                Text("Releases come from github.com/\(Updater.repository). The download must be served by GitHub over HTTPS, and if the release notes publish a SHA-256 the archive has to match it or the update is refused. Nothing installs without a click.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Ark is not notarised by Apple. Updates replace the app bundle in place, which is a real trust decision — it is why this is opt-in and never silent.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(SettingsBackdrop())
    }
}

/// Both password sources in one tab. The vault list is the thing you came for, so
/// it leads; the 1Password connection sits under it as a disclosure.
private struct PasswordsPane: View {
    @State private var showingOnePassword = false

    var body: some View {
        VStack(spacing: 0) {
            PasswordSettings()
            Divider()
            DisclosureGroup("1Password connection", isExpanded: $showingOnePassword) {
                OnePasswordSettings()
                    .frame(height: 300)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(SettingsBackdrop())
    }
}

private struct PasswordSettings: View {
    @Environment(BrowserState.self) private var state
    @State private var credentials: [Keychain.Summary] = []
    @State private var revealedPasswords: [String: String] = [:]
    @State private var status: String?
    @State private var importing = false

    private var manager: PasswordManager { state.passwords }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            explanation

            Divider()

            if credentials.isEmpty {
                VStack(spacing: 6) {
                    Text("No saved logins yet")
                        .font(.system(size: 13, weight: .medium))
                    Text("Log in to a site and Ark will offer to save it, or import a CSV below.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(credentials) { credential in
                    HStack(spacing: 10) {
                        Favicon(host: credential.domain).frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(credential.domain).font(.system(size: 12, weight: .medium))
                            Text(credential.username).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let shown = revealedPasswords[credential.id] {
                            Text(shown)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Button(revealedPasswords[credential.id] != nil ? "Hide" : "Reveal") {
                            toggleReveal(credential)
                        }
                        .font(.caption)
                        Button {
                            Keychain.deleteSummary(credential)
                            state.passwords.invalidateHostCache()
                            reload()
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()
            footer
        }
        .onAppear(perform: reload)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.commaSeparatedText, .text]) { result in
            switch result {
            case .success(let url):
                let outcome = manager.importCSV(at: url)
                status = "Imported \(outcome.imported), skipped \(outcome.skipped)."
                    + (outcome.errors.isEmpty ? "" : " " + outcome.errors.joined(separator: " "))
                reload()
            case .failure(let error):
                status = error.localizedDescription
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: Keychain.syncAvailable ? "icloud.fill" : "internaldrive.fill")
                    .foregroundStyle(Keychain.syncAvailable
                                     ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(Keychain.syncAvailable
                     ? "Synced through iCloud Keychain"
                     : "Stored in this Mac's keychain — not synced")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(Keychain.syncAvailable
                 ? "Logins are written as synchronizable keychain items, so they reach your other Macs."
                 : "iCloud Keychain sync needs an Apple Developer signing identity; an ad-hoc signed build gets errSecMissingEntitlement. Set ARK_SIGN_IDENTITY before ./build.sh to enable it. Until then these live only on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Either way, Ark cannot read passwords already saved in Safari or the Passwords app — macOS reserves that for Apple. Use Import CSV to bring those over.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Toggle("Require Touch ID", isOn: Binding(
                get: { manager.requireBiometrics },
                set: { manager.requireBiometrics = $0 }
            ))
            .font(.caption)

            Spacer()

            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            Button("Import CSV…") { importing = true }
            Button("Refresh", action: reload)
        }
        .padding(10)
    }

    /// Reveal is the only place Settings reads a secret — behind Touch ID, one
    /// item at a time. Listing the vault stays attribute-only and silent.
    private func toggleReveal(_ summary: Keychain.Summary) {
        if revealedPasswords[summary.id] != nil {
            revealedPasswords[summary.id] = nil
            return
        }
        Task {
            guard await manager.unlock(reason: "reveal a saved password") else { return }
            let fetched = Keychain.credential(domain: summary.domain, username: summary.username)
            await MainActor.run {
                if let fetched { revealedPasswords[summary.id] = fetched.password }
                else { status = "Couldn't read that item from the keychain." }
            }
        }
    }

    private func reload() {
        credentials = Keychain.allSummaries()
        revealedPasswords = [:]
    }
}

// MARK: - AI

private struct OnePasswordSettings: View {
    @Environment(BrowserState.self) private var state
    @State private var checking = false

    private var manager: PasswordManager { state.passwords }

    var body: some View {
        Form {
            Section("Source") {
                Picker("Fill logins from", selection: Binding(
                    get: { manager.source },
                    set: { manager.source = $0; state.save() }
                )) {
                    ForEach(PasswordManager.Source.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                Text("With 1Password selected, Ark asks it first and falls back to its own vault when 1Password has no match for the site.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("1Password CLI") {
                LabeledContent("Status") {
                    if OnePassword.isInstalled {
                        Label("op found", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Label("op not installed", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let path = OnePassword.binaryPath {
                    LabeledContent("Path") {
                        Text(path).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("1Password app") {
                    switch manager.opUnlocked {
                    case .some(true):
                        Label("Unlocked — Ark is authorized", systemImage: "lock.open.fill")
                            .font(.caption).foregroundStyle(.green)
                    case .some(false):
                        Label("Locked — unlock 1Password to fill", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.orange)
                    case nil:
                        Text("not checked").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Toggle("Follow the 1Password app's lock state", isOn: Binding(
                    get: { manager.mirrorOnePasswordLock },
                    set: { manager.mirrorOnePasswordLock = $0 }
                ))
                Text("On: once 1Password is unlocked, Ark stays authorized for as long as the app does, and cached logins are dropped the moment it locks. Off: cached logins expire on a 30-minute timer instead.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let accounts = manager.opAccounts {
                    LabeledContent("Account") {
                        Text(accounts).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(checking ? "Checking…" : "Test Connection") {
                        checking = true
                        Task {
                            await manager.refreshOnePassword()
                            await MainActor.run { checking = false }
                        }
                    }
                    .disabled(checking)
                    Spacer()
                }
                if let status = manager.opStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Setup") {
                Text("""
                1. Install the CLI:  brew install 1password-cli
                2. In the 1Password app: Settings ▸ Developer ▸ turn on \
                "Integrate with 1Password CLI"
                3. Come back here and hit Test Connection.
                """)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Ark never sees your 1Password password and never passes a secret on a command line. Authorization is handled by the 1Password app, which prompts for Touch ID itself.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Worth knowing: op is scoped to your whole account, not to browser logins, so this grants Ark read access to any item it can match. The built-in vault only ever holds what Ark saved.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // No automatic probe on appear: opening Settings shouldn't cost a
        // 1Password authorization. Use Test Connection.
    }
}


// MARK: - Glass intensity

/// Slider plus a live sample, so the setting can be judged while dragging
/// instead of by guessing at a number.
private struct GlassIntensitySlider: View {
    @Environment(BrowserState.self) private var state

    private var label: String {
        let value = state.glassIntensity
        if !GlassRamp.active(state.glassChrome, value) { return "Off" }
        if value < 0.3 { return "Subtle" }
        if value < 0.6 { return "Medium" }
        if value < 0.85 { return "Strong" }
        return "Maximum"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Glass intensity").font(.system(size: 12))
                Spacer()
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f%%", state.glassIntensity * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
            }

            Slider(
                value: Binding(
                    get: { state.glassIntensity },
                    set: { state.glassIntensity = $0 }
                ),
                in: 0...1,
                // Persist on release, not on every drag tick — otherwise the
                // state file gets rewritten dozens of times per drag.
                onEditingChanged: { editing in
                    if !editing { state.save() }
                }
            )

            preview

            Text(GlassRamp.interactive(state.glassIntensity)
                 ? "Above 55%, small controls also track the pointer, which costs a little more."
                 : "Below 55%, controls use static glass — cheaper, and the difference is subtle.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Sits over a striped backdrop so refraction is actually visible.
    private var preview: some View {
        ZStack {
            LinearGradient(colors: [.blue.opacity(0.55), .purple.opacity(0.5), .orange.opacity(0.45)],
                           startPoint: .leading, endPoint: .trailing)
            HStack(spacing: 8) {
                Text("Preview")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassSurface(.floating, in: Capsule(),
                                  enabled: state.glassChrome, intensity: state.glassIntensity)
                    .glassRim(cornerRadius: 20, enabled: state.glassChrome,
                              intensity: state.glassIntensity)

                Text("Chrome")
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassSurface(.chrome, in: RoundedRectangle(cornerRadius: 8, style: .continuous),
                                  enabled: state.glassChrome, intensity: state.glassIntensity)
                    .glassRim(cornerRadius: 8, enabled: state.glassChrome,
                              intensity: state.glassIntensity)
            }
        }
        .frame(height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(Motion.settle, value: state.glassIntensity)
    }
}


/// The restore list. Shows tab counts, not just timestamps — "12 tabs, 09:14" is
/// a decision you can make; a bare filename isn't.
private struct BackupList: View {
    @Environment(BrowserState.self) private var state
    @State private var entries: [StateBackups.Entry] = []
    @State private var message: String?
    @State private var confirming: StateBackups.Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty {
                Text("No backups yet — one is written before the next save.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entries.prefix(6)) { entry in
                HStack(spacing: 8) {
                    Text(entry.date, format: .dateTime.month().day().hour().minute())
                        .font(.system(size: 12).monospacedDigit())
                    Text("\(entry.tabCount) tab\(entry.tabCount == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore") { confirming = entry }
                        .controlSize(.small)
                }
            }
            if entries.count > 6 {
                Text("+\(entries.count - 6) older")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil,
                    inFileViewerRootedAtPath: StateBackups.directory.path)
            }
            .controlSize(.small)
        }
        .onAppear { entries = StateBackups.list() }
        .alert("Restore this backup?",
               isPresented: Binding(get: { confirming != nil },
                                    set: { if !$0 { confirming = nil } })) {
            Button("Cancel", role: .cancel) { confirming = nil }
            Button("Restore and Quit") {
                if let entry = confirming {
                    if let failure = state.restoreBackup(entry) {
                        message = failure
                    } else {
                        NSApp.terminate(nil)
                    }
                }
                confirming = nil
            }
        } message: {
            Text("Your current tab list is copied aside first. Ark quits so the restored state loads cleanly on next launch — reusing the running window would leave web views for tabs that no longer exist.")
        }
    }
}
