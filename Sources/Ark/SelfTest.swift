import AppKit
import Foundation
import UniformTypeIdentifiers

/// `Ark.app/Contents/MacOS/Ark --selftest`
///
/// Exercises the non-UI logic against the real keychain and real parsers, then
/// exits. Exists because the app's UI can't be driven headlessly, so this is how
/// the vault, CSV import, URL resolution, and blocker rules get verified.
enum SelfTest {
    /// Unbuffered, so output survives a killed probe.
    private static func say(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            if !condition { failures += 1 }
            print("[\(mark)] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        print("== Ark self-test ==")
        print("keychain sync available: \(Keychain.syncAvailable)")

        // URL resolution — pinned to a known engine, then restored.
        let savedEngine = SearchEngine.current
        SearchEngine.current = .duckduckgo
        check("resolve bare host",
              BrowserTab.resolve("example.com").absoluteString == "https://example.com")
        check("resolve full URL",
              BrowserTab.resolve("https://a.io/x?y=1").absoluteString == "https://a.io/x?y=1")
        check("resolve search",
              BrowserTab.resolve("how tall is denali").absoluteString.contains("duckduckgo.com/?q="))
        check("resolve trailing dot is a search",
              BrowserTab.resolve("hello.").host == "duckduckgo.com")

        SearchEngine.current = .kagi
        check("search engine honored",
              BrowserTab.resolve("swift concurrency").host == "kagi.com",
              BrowserTab.resolve("swift concurrency").absoluteString)
        check("search query encoded",
              BrowserTab.resolve("a b&c").absoluteString.contains("q=a%20b%26c"),
              BrowserTab.resolve("a b&c").absoluteString)
        SearchEngine.current = savedEngine

        // Domain normalization
        check("normalize subdomain",
              Keychain.normalize(host: "login.example.com") == "example.com")
        check("normalize www",
              Keychain.normalize(host: "www.example.com") == "example.com")
        check("normalize two-part suffix",
              Keychain.normalize(host: "shop.marks.co.uk") == "marks.co.uk",
              Keychain.normalize(host: "shop.marks.co.uk"))

        // Vault round trip against the real keychain
        let probe = Keychain.Credential(domain: "drift-selftest.invalid",
                                        username: "probe@drift", password: "first-pw")
        Keychain.delete(probe)
        let saveStatus = Keychain.save(probe)
        check("vault save", saveStatus == errSecSuccess, Keychain.describe(saveStatus))

        let found = Keychain.summaries(for: "sub.drift-selftest.invalid")
        check("vault summary by subdomain (silent)", found.count == 1, "got \(found.count)")
        check("silent existence check", Keychain.hasCredentials(for: "sub.drift-selftest.invalid"))
        check("vault password round trip",
              Keychain.firstCredential(for: "drift-selftest.invalid")?.password == "first-pw")

        var rotated = probe
        rotated.password = "second-pw"
        let updateStatus = Keychain.save(rotated)
        check("vault update", updateStatus == errSecSuccess, Keychain.describe(updateStatus))
        check("vault reflects update",
              Keychain.firstCredential(for: "drift-selftest.invalid")?.password == "second-pw")

        let listed = Keychain.allSummaries()
        check("vault appears in full list",
              listed.contains { $0.domain == "drift-selftest.invalid" },
              "\(listed.count) total")

        let deleteStatus = Keychain.delete(rotated)
        check("vault delete", deleteStatus == errSecSuccess, Keychain.describe(deleteStatus))
        check("vault empty after delete",
              Keychain.summaries(for: "drift-selftest.invalid").isEmpty)
        check("existence check false after delete",
              !Keychain.hasCredentials(for: "drift-selftest.invalid"))

        // CSV parsing
        let csv = """
        Title,URL,Username,Password,Notes
        Example,https://example.com/login,me@example.com,"pa,ss""word",hello
        Bare,another.org,user2,secret2,
        """
        let rows = PasswordManager.parseCSV(csv)
        check("csv row count", rows.count == 3, "\(rows.count)")
        check("csv quoted comma + escaped quote",
              rows[safe: 1]?[safe: 3] == "pa,ss\"word",
              rows[safe: 1]?[safe: 3] ?? "nil")
        check("csv header order detected", rows[0].contains("Password"))

        // Autocomplete parsing tolerance
        let fenced = """
        Here you go:
        ```json
        [{"label":"Apple","url":"https://apple.com"},{"label":"bad","url":"not a url"}]
        ```
        """
        let parsed = Autocomplete.parse(fenced)
        check("ai suggestion parse drops invalid urls", parsed.count == 1, "\(parsed.count)")
        check("ai suggestion label", parsed.first?.label == "Apple")

        // On-device suggestion parsing: line format, and no invented domains.
        let lines = OnDeviceSuggestions.parse("""
        1. GitHub|https://github.com
        - Apple Developer|developer.apple.com
        Bogus|not a domain
        Dupe|https://github.com
        """)
        check("on-device parse strips numbering and bullets", lines.count == 2,
              "\(lines.count)")
        check("on-device parse adds a scheme", lines.last?.url == "https://developer.apple.com",
              lines.last?.url ?? "nil")
        check("on-device parse drops non-domains and dupes",
              !lines.contains { $0.label == "Bogus" || $0.label == "Dupe" })
        check("on-device parse survives empty input",
              OnDeviceSuggestions.parse("").isEmpty)

        // 1Password CLI parsing, from fixtures — no live `op` required.
        check("op installed detection matches PATH probe",
              OnePassword.isInstalled == (OnePassword.binaryPath != nil))

        let itemsJSON = Data("""
        [{"id":"abc123","title":"GitHub","vault":{"name":"Private"},
          "urls":[{"primary":true,"href":"https://github.com/login"}]},
         {"id":"def456","title":"Acme (acme.co.uk)","vault":{"name":"Work"}}]
        """.utf8)
        let opItems = OnePassword.parseItems(itemsJSON)
        check("op item parse count", opItems.count == 2, "\(opItems.count)")
        check("op item host from url", opItems.first?.hosts.first == "github.com",
              opItems.first?.hosts.first ?? "nil")
        check("op item host from title fallback",
              opItems.last?.hosts.first == "acme.co.uk", opItems.last?.hosts.first ?? "nil")
        check("op vault name", opItems.first?.vault == "Private")

        check("op match by subdomain",
              OnePassword.bestMatch(for: "gist.github.com", in: opItems)?.id == "abc123")
        check("op no match returns nil",
              OnePassword.bestMatch(for: "example.org", in: opItems) == nil)

        let loginJSON = Data("""
        {"id":"abc123","fields":[
          {"id":"username","purpose":"USERNAME","value":"me@example.com"},
          {"id":"password","purpose":"PASSWORD","value":"s3cr3t!"},
          {"id":"otp","type":"OTP","label":"one-time password","totp":"123456"}]}
        """.utf8)
        let parsedLogin = OnePassword.parseLogin(loginJSON)
        check("op login username", parsedLogin?.username == "me@example.com")
        check("op login password", parsedLogin?.password == "s3cr3t!")
        check("op login totp", parsedLogin?.totp == "123456")
        check("op login rejects item with no password",
              OnePassword.parseLogin(Data("""
              {"id":"x","fields":[{"id":"u","purpose":"USERNAME","value":"a"}]}
              """.utf8)) == nil)

        // additional_information is where op puts the username in list output —
        // it's what lets the autofill menu label rows without reading secrets.
        let hintJSON = Data("""
        [{"id":"h1","title":"GitHub","vault":{"name":"Private"},
          "additional_information":"me@example.com",
          "urls":[{"href":"https://github.com"}]},
         {"id":"h2","title":"Acme","vault":{"name":"Work"},
          "additional_information":"—","urls":[{"href":"https://acme.com"}]}]
        """.utf8)
        let hinted = OnePassword.parseItems(hintJSON)
        check("op username hint parsed", hinted.first?.usernameHint == "me@example.com",
              hinted.first?.usernameHint ?? "nil")
        check("op placeholder hint discarded", hinted.last?.usernameHint == nil,
              hinted.last?.usernameHint ?? "nil")
        check("op matches() returns all for host",
              OnePassword.matches(for: "www.github.com", in: hinted).count == 1)
        check("op matches() empty for unknown host",
              OnePassword.matches(for: "nope.example", in: hinted).isEmpty)

        check("op account parse",
              OnePassword.parseAccounts(Data("""
              [{"email":"me@example.com","url":"my.1password.com"}]
              """.utf8)) == ["me@example.com"])

        // Reordering inside a group. The regression this covers: tier said
        // "today" for a tab inside a Today group, so reordering within the group
        // moved the tab out to the top level instead.
        do {
            // Build: [ group("Work") -> [A, B], C ]
            let group = SidebarItem(groupName: "Work")
            let itemA = SidebarItem(groupName: "A"); itemA.groupName = nil
            let itemB = SidebarItem(groupName: "B"); itemB.groupName = nil
            let itemC = SidebarItem(groupName: "C"); itemC.groupName = nil
            var tree: [SidebarItem] = [group, itemC]
            group.children = [itemA, itemB]

            check("first-to-second inside a group stays in the group",
                  tree.moveNode(id: itemA.id, besideNodeID: itemB.id, before: false))
            check("group still holds both tabs", group.children.count == 2,
                  "\(group.children.count)")
            check("order swapped within the group",
                  group.children.first?.id == itemB.id && group.children.last?.id == itemA.id)
            check("top level untouched", tree.count == 2, "\(tree.count)")

            // Moving back to first place.
            _ = tree.moveNode(id: itemA.id, besideNodeID: itemB.id, before: true)
            check("moving before puts it back first",
                  group.children.first?.id == itemA.id)
            check("still two children", group.children.count == 2)

            // Out of the group, next to a top-level node.
            _ = tree.moveNode(id: itemA.id, besideNodeID: itemC.id, before: false)
            check("beside a top-level node leaves the group",
                  group.children.count == 1 && tree.count == 3,
                  "children=\(group.children.count) top=\(tree.count)")

            // Into the group again.
            _ = tree.moveNode(id: itemA.id, besideNodeID: itemB.id, before: true)
            check("moving beside a grouped node re-enters the group",
                  group.children.count == 2 && tree.count == 2,
                  "children=\(group.children.count) top=\(tree.count)")

            check("moving a node beside itself is refused",
                  !tree.moveNode(id: itemB.id, besideNodeID: itemB.id, before: true))
        }

        // Drag target resolution. The pointer-based coordinator replaced six
        // failed drag-and-drop attempts, so its geometry maths is under test.
        do {
            let coordinator = TabDragCoordinator()
            let rowA = UUID(), rowB = UUID(), groupID = UUID(), paneID = UUID()
            coordinator.setFrame(CGRect(x: 0, y: 0, width: 200, height: 30), for: .row(rowA))
            coordinator.setFrame(CGRect(x: 0, y: 30, width: 200, height: 30), for: .row(rowB))
            coordinator.setFrame(CGRect(x: 0, y: 60, width: 200, height: 26), for: .group(groupID))
            coordinator.setFrame(CGRect(x: 0, y: 90, width: 200, height: 24),
                                 for: .rootStrip(pinned: false))
            coordinator.setFrame(CGRect(x: 300, y: 0, width: 600, height: 400),
                                 for: .pane(paneID))

            let moving = UUID()
            coordinator.draggingID = moving
            coordinator.draggingIsGroup = false

            coordinator.update(to: CGPoint(x: 100, y: 36))
            check("top half of a row inserts before",
                  coordinator.target == .beside(rowB, before: true), "\(coordinator.target)")

            coordinator.update(to: CGPoint(x: 100, y: 54))
            check("bottom half of a row inserts after",
                  coordinator.target == .beside(rowB, before: false), "\(coordinator.target)")

            coordinator.update(to: CGPoint(x: 100, y: 70))
            check("group row means drop into group",
                  coordinator.target == .intoGroup(groupID), "\(coordinator.target)")

            coordinator.update(to: CGPoint(x: 100, y: 100))
            check("root strip lifts out of a group",
                  coordinator.target == .root(pinned: false), "\(coordinator.target)")

            coordinator.update(to: CGPoint(x: 400, y: 200))
            check("left half of a pane splits left",
                  coordinator.target == .split(paneID, left: true), "\(coordinator.target)")

            coordinator.update(to: CGPoint(x: 800, y: 200))
            check("right half of a pane splits right",
                  coordinator.target == .split(paneID, left: false), "\(coordinator.target)")

            coordinator.update(to: CGPoint(x: 100, y: 500))
            check("empty space is no target", coordinator.target == .none)

            // A tab must never be droppable onto its own row.
            coordinator.draggingID = rowA
            coordinator.update(to: CGPoint(x: 100, y: 10))
            check("cannot drop a tab onto itself", coordinator.target == .none,
                  "\(coordinator.target)")

            coordinator.draggingID = moving
            check("insert edge reported for the targeted row only",
                  { coordinator.update(to: CGPoint(x: 100, y: 36))
                    return coordinator.insertEdge(for: rowB) == .top
                        && coordinator.insertEdge(for: rowA) == nil }())
        }

        // AI tab grouping — the parser must never move a tab it wasn't given.
        let tabIDs = (0..<5).map { _ in UUID() }
        let good = TabOrganizer.parse("""
        {"groups":[{"name":"Rock Tickets","tabs":[0,1]},
                   {"name":"Research","tabs":[2,3,4]}]}
        """, tabs: tabIDs)
        check("organizer parses groups", good.groups.count == 2, "\(good.groups.count)")
        check("organizer maps indices to ids",
              good.groups.first?.tabIDs == [tabIDs[0], tabIDs[1]])
        check("organizer leaves nothing ungrouped here", good.ungrouped.isEmpty)

        let fencedGroups = TabOrganizer.parse("""
        Sure! Here you go:
        ```json
        {"groups":[{"name":"Docs","tabs":[1,2]}]}
        ```
        """, tabs: tabIDs)
        check("organizer tolerates fences and prose", fencedGroups.groups.count == 1)
        check("organizer reports the rest as ungrouped", fencedGroups.ungrouped.count == 3,
              "\(fencedGroups.ungrouped.count)")

        let hallucinated = TabOrganizer.parse("""
        {"groups":[{"name":"Bogus","tabs":[9,42]},{"name":"Real","tabs":[0,1]}]}
        """, tabs: tabIDs)
        check("organizer discards out-of-range indices",
              hallucinated.groups.count == 1 && hallucinated.groups[0].name == "Real",
              "\(hallucinated.groups.map(\.name))")

        let duplicated = TabOrganizer.parse("""
        {"groups":[{"name":"A","tabs":[0,1]},{"name":"B","tabs":[1,0,2]}]}
        """, tabs: tabIDs)
        check("organizer never puts a tab in two groups",
              Set(duplicated.groups.flatMap(\.tabIDs)).count
                == duplicated.groups.flatMap(\.tabIDs).count)

        let tooSmall = TabOrganizer.parse("""
        {"groups":[{"name":"Lonely","tabs":[0]}]}
        """, tabs: tabIDs)
        check("organizer drops single-tab groups", tooSmall.groups.isEmpty)
        check("dropped group's tabs stay available", tooSmall.ungrouped.count == 5,
              "\(tooSmall.ungrouped.count)")

        check("organizer survives garbage",
              TabOrganizer.parse("not json at all", tabs: tabIDs).groups.isEmpty)

        // Split ratio normalisation — static, so no BrowserState is constructed
        // here; building one would load real tabs and create web views.
        check("ratios normalise to 1",
              abs(BrowserState.normalized([2, 2], count: 2).reduce(0, +) - 1.0) < 0.0001)
        check("ratio count mismatch falls back to even",
              BrowserState.normalized([0.9], count: 3) == [1.0/3, 1.0/3, 1.0/3])
        check("zero-sum ratios fall back to even",
              BrowserState.normalized([0, 0], count: 2) == [0.5, 0.5])
        check("normalised ratios preserve proportion",
              abs(BrowserState.normalized([3, 1], count: 2)[0] - 0.75) < 0.0001,
              "\(BrowserState.normalized([3, 1], count: 2))")

        // Split memory
        let tabA = UUID(), tabB = UUID(), tabC = UUID()
        var groups = BrowserState.remembering(displayed: [tabA, tabB],
                                              ratios: [0.6, 0.4], in: [])
        check("split remembered", groups.count == 1)
        check("remembered ratios kept",
              groups.first.map { abs($0.ratios[0] - 0.6) < 0.0001 } == true)

        // Re-splitting one of those tabs must replace the group, not add a second.
        groups = BrowserState.remembering(displayed: [tabB, tabC],
                                          ratios: [0.5, 0.5], in: groups)
        check("a tab belongs to only one group", groups.count == 1,
              "\(groups.count) groups")
        check("superseded member is dropped",
              groups.first?.tabs.contains(tabA) == false)

        groups = BrowserState.forgetting(tabB, in: groups)
        check("forgetting removes the whole group", groups.isEmpty)

        check("single pane is never remembered",
              BrowserState.remembering(displayed: [tabA], ratios: [1], in: []).isEmpty)

        // Liquid Glass intensity ramp
        check("glass off at zero", !GlassRamp.active(true, 0))
        check("glass off when toggle is off", !GlassRamp.active(false, 1.0))
        check("glass on at mid", GlassRamp.active(true, 0.5))
        check("page tint accepts a saturated colour",
              BrowserTab.tintCandidate(NSColor(srgbRed: 0.20, green: 0.42, blue: 0.85, alpha: 1)) != nil)
        check("page tint accepts GitHub's near-black navy",
              BrowserTab.tintCandidate(NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1)) != nil,
              "#0d1117 — used to fail the brightness floor")
        // Deliberately rejected: at sat 0.025 the hue is essentially noise, and
        // normalisation would amplify it into a confident wrong colour. Sites
        // like this are meant to be tinted from their accent colour instead,
        // which is what the probe now collects.
        check("page tint rejects a near-neutral off-white",
              BrowserTab.tintCandidate(NSColor(srgbRed: 0.957, green: 0.949, blue: 0.933, alpha: 1)) == nil,
              "#f4f2ee, LinkedIn — sat 0.025, hue is noise")
        check("page tint rejects white", BrowserTab.tintCandidate(.white) == nil)
        check("page tint rejects grey",
              BrowserTab.tintCandidate(NSColor(srgbRed: 0.27, green: 0.27, blue: 0.27, alpha: 1)) == nil,
              "#454545, Atlassian")
        check("page tint rejects nil", BrowserTab.tintCandidate(nil) == nil)
        check("page tint rejects a transparent colour",
              BrowserTab.tintCandidate(NSColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 0.2)) == nil)

        // Normalisation is what makes an extreme colour usable as a tint.
        if let dark = BrowserTab.tintCandidate(NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1)) {
            let lifted = NSColor(BrowserTab.presentable(dark)).usingColorSpace(.sRGB)!
            check("near-black navy is lifted into a usable band",
                  lifted.brightnessComponent >= 0.5 && lifted.saturationComponent >= 0.4,
                  String(format: "b=%.2f s=%.2f", lifted.brightnessComponent, lifted.saturationComponent))
            check("normalisation preserves hue",
                  abs(lifted.hueComponent - dark.color.hueComponent) < 0.01,
                  String(format: "%.3f vs %.3f", lifted.hueComponent, dark.color.hueComponent))
        } else {
            check("near-black navy is lifted into a usable band", false, "candidate rejected")
        }

        check("brand colour outranks an off-white",
              {
                  let colors = [NSColor(srgbRed: 0.96, green: 0.95, blue: 0.93, alpha: 1),
                                NSColor(srgbRed: 0.04, green: 0.40, blue: 0.76, alpha: 1)]
                  let best = colors.compactMap(BrowserTab.tintCandidate).max { $0.score < $1.score }
                  return (best?.saturation ?? 0) > 0.5
              }(),
              "#0A66C2 must beat #F4F2EE")
        check("a light vivid colour outranks a near-black navy",
              {
                  // Stripe: #533AFD (purple) vs #061B31 (dark navy). Ranking on
                  // raw saturation picked the navy, whose hue is too thin to
                  // survive normalisation and so read as no tint at all.
                  let purple = BrowserTab.tintCandidate(
                      NSColor(srgbRed: 0.325, green: 0.227, blue: 0.992, alpha: 1))!
                  let navy = BrowserTab.tintCandidate(
                      NSColor(srgbRed: 0.024, green: 0.106, blue: 0.192, alpha: 1))!
                  return purple.score > navy.score && navy.saturation > purple.saturation
              }(),
              "the navy is *more* saturated and must still lose")

        check("CSS colour parser handles hex and rgb",
              BrowserTab.parseCSSColor("#0d1117") != nil
              && BrowserTab.parseCSSColor("#abc") != nil
              && BrowserTab.parseCSSColor("rgb(13, 17, 23)") != nil
              && BrowserTab.parseCSSColor("rgba(13, 17, 23, 0.1)") == nil)

        // the parser is the only thing standing between it and a wrong lookup.
        // Snooze policy. The sweep itself needs live web views; the policy
        // doesn't, so it is the part worth pinning down.
        let now = Date()
        let fresh = BrowserTab(id: UUID())
        fresh.urlString = "https://a.example"
        fresh.lastAccessed = now
        let stale = BrowserTab(id: UUID())
        stale.urlString = "https://b.example"
        stale.lastAccessed = now.addingTimeInterval(-3600)
        let staleOnScreen = BrowserTab(id: UUID())
        staleOnScreen.urlString = "https://c.example"
        staleOnScreen.lastAccessed = now.addingTimeInterval(-3600)
        let blank = BrowserTab(id: UUID())
        blank.lastAccessed = now.addingTimeInterval(-3600)
        let pool = [fresh, stale, staleOnScreen, blank]

        let picked = BrowserState.snoozeCandidates(
            pool, displayed: [staleOnScreen.id], focused: fresh.id,
            idleMinutes: 20, now: now)
        check("snooze picks only the idle background tab",
              picked.map(\.id) == [stale.id],
              "\(picked.count) picked of \(pool.count)")
        check("snooze never touches a displayed tab",
              !picked.contains { $0.id == staleOnScreen.id })
        check("snooze skips a tab with nothing loaded",
              !picked.contains { $0.id == blank.id })
        check("snooze off means no candidates",
              BrowserState.snoozeCandidates(pool, displayed: [], focused: nil,
                                            idleMinutes: 0, now: now).isEmpty)
        check("snooze respects the exempt set",
              {
                  let out = BrowserState.snoozeCandidates(
                      pool, displayed: [], focused: nil, idleMinutes: 20,
                      exempt: [stale.id], now: now)
                  // staleOnScreen is equally idle and not displayed here, so it
                  // must still be picked — the exemption is per tab, not global.
                  return !out.contains { $0.id == stale.id }
                      && out.contains { $0.id == staleOnScreen.id }
              }(),
              "loose pinned tabs stay resident; other idle tabs still go")
        check("snooze at a longer threshold spares a 1h-old tab",
              BrowserState.snoozeCandidates(pool, displayed: [], focused: nil,
                                            idleMinutes: 180, now: now).isEmpty)

        // Updater. Version comparison and asset trust are the two places a
        // mistake means either never updating or installing the wrong thing.
        // On-device is the default and the legacy value must land there too.
        check("default engine is on-device",
              BrowserState().groupingEngine == .appleIntelligence)
        check("the legacy automatic value is not offered",
              !GroupingEngine.selectable.contains(.automatic))
        check("only two engines are selectable",
              GroupingEngine.selectable == [.appleIntelligence, .claude])

        // What's-new page: which changelog sections a given upgrade shows.
        let log = """
        ## v0.27.0 — Later (2026-08-21)
        - future
        ## v0.26.1 — Now (2026-08-20)
        - **bold** and `code`
        ## v0.26.0 — Before (2026-08-20)
        - earlier
        ## Not a version heading
        - ignored
        """
        check("an upgrade shows only what you missed",
              WhatsNew.sections(from: log, since: "0.26.0", upTo: "0.26.1").count == 1)
        check("an upgrade never shows unreleased sections",
              !WhatsNew.sections(from: log, since: "0.26.0", upTo: "0.26.1")
                  .joined().contains("future"),
              "a changelog can describe a version this build isn't")
        check("skipping two versions shows both",
              WhatsNew.sections(from: log, since: "0.25.0", upTo: "0.26.1").count == 2)
        check("no previous version means nothing to catch up on",
              WhatsNew.prepare(lastSeen: nil, current: "0.26.1") == nil,
              "a fresh install shouldn't open release notes")
        check("same version shows nothing",
              WhatsNew.prepare(lastSeen: "0.26.1", current: "0.26.1") == nil)
        check("an unparseable heading is skipped, not guessed",
              WhatsNew.parseVersion(from: "## Not a version heading") == nil)
        check("version parses out of a heading",
              WhatsNew.parseVersion(from: "## v0.26.1 — Now (2026-08-20)") == "0.26.1")
        check("markdown renders bold and code",
              {
                  let out = WhatsNew.html(
                      from: WhatsNew.sections(from: log, since: "0.26.0", upTo: "0.26.1"),
                      version: "0.26.1")
                  return out.contains("<strong>bold</strong>") && out.contains("<code>code</code>")
              }())
        check("only http links survive rendering",
              {
                  let out = WhatsNew.html(from: ["## v1.0 — x (2026)\n- [a](javascript:alert(1)) [b](https://ok.example)"],
                                          version: "1.0")
                  return !out.contains("javascript:") && out.contains("https://ok.example")
              }(),
              "the notes open automatically, so they must not carry a live scheme")

        // Pinned URL editing: the field takes what a person would type, and an
        // empty box means "use the page I'm on" rather than "clear it".
        check("a bare host becomes a URL",
              BrowserState.resolvePinnedURL("github.com", fallback: "")?
                  .hasPrefix("https://github.com") == true)
        check("a full URL passes through",
              BrowserState.resolvePinnedURL("https://a.example/x", fallback: "")
              == "https://a.example/x")
        check("an empty field falls back to the current page",
              BrowserState.resolvePinnedURL("  ", fallback: "https://now.example")
              == "https://now.example")
        check("an empty field with nothing loaded is refused",
              BrowserState.resolvePinnedURL("", fallback: "") == nil,
              "a typo must not silently blank a pinned tab's home")
        check("whitespace around a URL is tolerated",
              BrowserState.resolvePinnedURL("  https://a.example  ", fallback: "")
              == "https://a.example")

        check("newer patch version wins", Updater.isNewer("0.26.1", than: "0.26.0"))
        check("newer minor version wins", Updater.isNewer("0.27", than: "0.26.9"))
        check("same version is not newer", !Updater.isNewer("0.26.0", than: "0.26.0"))
        check("older version is not newer", !Updater.isNewer("0.25.9", than: "0.26.0"))
        check("v prefix is tolerated", Updater.isNewer("v1.0", than: "0.26.0"))
        check("shorter version compares by component",
              !Updater.isNewer("0.26", than: "0.26.1"),
              "0.26 must not beat 0.26.1")
        check("checksum is read from release notes",
              Updater.checksum(in: "notes\n\nsha256: "
                               + String(repeating: "a", count: 64)) != nil)
        check("a short hex string is not a checksum",
              Updater.checksum(in: "sha256: abc123") == nil)
        check("github asset URLs are trusted",
              Updater.isTrustedAssetURL(URL(string:
                "https://github.com/x/y/releases/download/v1/Ark.zip")!))
        check("githubusercontent asset URLs are trusted",
              Updater.isTrustedAssetURL(URL(string:
                "https://objects.githubusercontent.com/a/b")!))
        check("a non-GitHub download is refused",
              !Updater.isTrustedAssetURL(URL(string: "https://evil.example/Ark.zip")!),
              "release notes must not be able to redirect the installer")
        check("plain http is refused",
              !Updater.isTrustedAssetURL(URL(string: "http://github.com/a.zip")!))
        check("a lookalike host is refused",
              !Updater.isTrustedAssetURL(URL(string: "https://github.com.evil.example/a.zip")!))

        // The ripple: a packet that starts at the caret and runs right, with the
        // ends pinned so the bar's corners never move.
        let bar: CGFloat = 620
        let early = JellyWave(travel: 0, origin: 0.2, amplitude: 1)
        let late = JellyWave(travel: 1, origin: 0.2, amplitude: 1)
        check("the crest starts near the caret",
              abs(early.displacement(at: bar * 0.2, width: bar))
              > abs(early.displacement(at: bar * 0.8, width: bar)))
        check("the crest ends up to the right of where it began",
              abs(late.displacement(at: bar * 0.8, width: bar))
              > abs(late.displacement(at: bar * 0.2, width: bar)))
        check("a later caret starts the wave further right",
              {
                  let right = JellyWave(travel: 0, origin: 0.8, amplitude: 1)
                  return abs(right.displacement(at: bar * 0.8, width: bar))
                      > abs(right.displacement(at: bar * 0.2, width: bar))
              }())
        check("both ends stay pinned",
              early.displacement(at: 0, width: bar) == 0
              && early.displacement(at: bar, width: bar) == 0,
              "a wave that moved the corners would look like the bar sliding")
        check("no amplitude means no displacement",
              JellyWave(travel: 0.5, origin: 0.5, amplitude: 0)
                  .displacement(at: bar / 2, width: bar) == 0)
        check("the wave loses energy as it runs",
              abs(late.displacement(at: bar * 0.95, width: bar))
              < abs(early.displacement(at: bar * 0.2, width: bar)))

        // The blank-tab tint has to resemble the field it is taken from.
        check("a field's signature colour is a blend, not one accent",
              {
                  // Palette 0 runs indigo → violet → cyan → teal. Blending the
                  // drawn blobs must not come back as the violet accent alone,
                  // which is what left the sidebar purple over a teal field.
                  let signature = NSColor(LiquidBackdrop.signature(seed: 0))
                      .usingColorSpace(.sRGB)!
                  let violet = NSColor(srgbRed: 0.35, green: 0.24, blue: 0.78, alpha: 1)
                  let distance = abs(signature.redComponent - violet.redComponent)
                      + abs(signature.greenComponent - violet.greenComponent)
                      + abs(signature.blueComponent - violet.blueComponent)
                  return distance > 0.1
              }())
        check("signature colours are stable for a seed",
              LiquidBackdrop.signature(seed: 7) == LiquidBackdrop.signature(seed: 7))

        // Multi-select. The pure parts: toggling, pruning, and the fact that a
        // selection is not the same thing as what's on screen.
        let picker = BrowserState()
        let one = picker.newTab(url: URL(string: "https://one.example"), activate: false)
        let two = picker.newTab(url: URL(string: "https://two.example"), activate: false)
        picker.toggleSelection(one.id)
        picker.toggleSelection(two.id)
        check("cmd-click builds a selection", picker.selectionCount == 2)
        check("cmd-clicking again deselects",
              { picker.toggleSelection(two.id); return picker.selectionCount == 1 }())
        check("selection order follows the sidebar, not the Set",
              {
                  picker.toggleSelection(two.id)
                  return picker.selectedTabsInOrder.map(\.id)
                      == picker.orderedTabs.filter { picker.isSelected($0.id) }.map(\.id)
              }())
        check("closing a tab drops it from the selection",
              { picker.close(two); return !picker.isSelected(two.id) }())
        check("pruning removes ids that no longer exist",
              {
                  picker.selectedTabIDs.insert(UUID())
                  picker.pruneSelection()
                  return picker.selectedTabIDs.allSatisfy { id in
                      picker.allTabs.contains { $0.id == id }
                  }
              }())
        check("a selection is not the displayed set",
              !picker.displayed.contains(where: { picker.isSelected($0) })
              || picker.displayed.count != picker.selectionCount
              || picker.selectionCount == 0,
              "selecting five tabs must not open five panes")
        check("clearing empties it",
              { picker.clearSelection(); return picker.selectionCount == 0 }())
        check("grouping needs more than one tab",
              MainActor.assumeIsolated { picker.groupSelected() } == nil,
              "a one-tab group is what the single-tab menu item is for")

        // Feature requests: the local store is the thing that must not lose
        // anything, so it gets the coverage.
        let requestFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ark-requests-\(UUID().uuidString).jsonl")
        let first = FeatureRequest(title: "Range select with shift-click",
                                   detail: "Peek could move to alt-click.")
        let second = FeatureRequest(title: "Vertical split", detail: "")
        try? FeatureRequest.append(first, to: requestFile)
        try? FeatureRequest.append(second, to: requestFile)
        let stored = (try? String(contentsOf: requestFile, encoding: .utf8)) ?? ""
        check("requests append one JSON object per line",
              stored.split(separator: "\n").count == 2,
              "a crash mid-write should cost one line, not the file")
        check("each stored line is valid JSON on its own",
              stored.split(separator: "\n").allSatisfy {
                  (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil
              })
        check("a request with no title is refused",
              !FeatureRequest(title: "   ", detail: "detail").isValid)
        check("whitespace is trimmed from the title",
              FeatureRequest(title: "  spacing  ", detail: "").title == "spacing")
        try? FileManager.default.removeItem(at: requestFile)

        check("the issue URL carries title, body and label",
              {
                  guard let url = first.issueURL(repository: "a/b"),
                        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems else { return false }
                  let names = Set(items.map(\.name))
                  return url.host == "github.com"
                      && names == ["title", "body", "labels"]
                      && items.first { $0.name == "labels" }?.value == "feature-request"
              }())
        check("an issue URL survives characters that need escaping",
              FeatureRequest(title: "a & b?#=", detail: "x=1&y=2")
                  .issueURL(repository: "a/b") != nil)
        check("a long body is capped rather than sent whole",
              {
                  let huge = FeatureRequest(title: "t",
                                            detail: String(repeating: "x", count: 9000))
                  guard let url = huge.issueURL(repository: "a/b"),
                        let body = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "body" })?.value
                  else { return false }
                  return body.count <= 4000
              }(),
              "an over-long URL fails as a blank page, which is worse than truncation")

        // Channels. The whole point is that staging cannot touch production's
        // data, so the path derivation is what gets pinned down.
        check("this build knows its channel",
              AppPaths.channel == .production || AppPaths.channel == .staging)
        check("the support folder follows the bundle name",
              AppPaths.supportDirectory.lastPathComponent == AppPaths.folderName,
              AppPaths.supportDirectory.path)
        check("staging and production can't resolve to the same folder",
              !AppPaths.supportDirectory.path.hasSuffix("/Ark")
              || AppPaths.channel == .production,
              "a staging build in production's folder could lose real tabs")
        check("support files live under the support folder",
              AppPaths.supportFile("x.json").deletingLastPathComponent()
              == AppPaths.supportDirectory)
        check("staging never auto-checks for updates",
              MainActor.assumeIsolated {
                  !AppPaths.isStaging || Updater().automaticallyChecks == false
              },
              "a release download would replace the build under test")

        check("tint scales with intensity",
              GlassRamp.tintOpacity(1.0) > GlassRamp.tintOpacity(0.0),
              String(format: "%.3f vs %.3f", GlassRamp.tintOpacity(1.0), GlassRamp.tintOpacity(0.0)))
        check("rim scales with intensity",
              GlassRamp.rimHighlight(1.0) > GlassRamp.rimHighlight(0.0))
        check("rim stays within a sane opacity range",
              GlassRamp.rimHighlight(1.0) <= 0.4 && GlassRamp.rimHighlight(0) >= 0,
              String(format: "%.3f", GlassRamp.rimHighlight(1.0)))
        check("interactive only above the threshold",
              !GlassRamp.interactive(0.4) && GlassRamp.interactive(0.8))

        // Motion must never resolve to a repeating animation.
        check("reduce-motion flag readable", Motion.reduced == Motion.reduced)
        check("press scale dents but stays visible",
              Motion.pressScale < 1 && Motion.pressScale > 0.85,
              "\(Motion.pressScale)")

        // Blocker rules must be valid JSON of the expected shape
        let json = ContentBlocker.rulesJSON()
        let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        check("blocker rules parse", (obj ?? nil) != nil)
        check("blocker rule count",
              (obj ?? nil)?.count == ContentBlocker.blockedDomains.count + 1,
              "\((obj ?? nil)?.count ?? 0)")

        print(failures == 0 ? "== all checks passed ==" : "== \(failures) FAILED ==")
        exit(failures == 0 ? 0 : 1)
    }
}
