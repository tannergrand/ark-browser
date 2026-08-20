# Ark — Changelog

A running log so any session can pick this up cold. Newest first.
Status tags: **Shipped** (built, compiles, verified) · **In progress** ·
**Proposed** (agreed, not built) · **Blocked** (with the reason).

---

## Verified constraints — read these before re-deriving them

These were tested on this machine, not assumed. Don't spend tokens rediscovering
them.

1. **Engine is WebKit, not Chromium.** Tanner chose WKWebView knowing this
   (2026-08-04). A true Chromium build means Electron or CEF — a shell rewrite.
   Consequence: **no Chrome extensions, ever.**
2. **iCloud Keychain sync needs a real Apple Developer team identity.** Writing
   `kSecAttrSynchronizable: true` from an ad-hoc-signed app fails with
   `errSecMissingEntitlement (-34018)`. Verified with a signed probe bundle.
   Ark detects this at launch (`Keychain.syncAvailable`) and falls back to the
   local login keychain. Set `DRIFT_SIGN_IDENTITY` before `./build.sh` to enable
   sync.
3. **No third-party app can read Safari / Passwords.app website passwords.**
   Apple reserves this behind private entitlements. The CSV importer is the only
   honest migration path.
4. **`kSecReturnData` + `kSecMatchLimitAll` returns `errSecParam (-50)`** on
   macOS 26. Keychain reads must be two calls: list attributes in bulk, then
   fetch each secret with `kSecMatchLimitOne`. This bug silently returned zero
   credentials before it was caught.
5. **Screenshots of the running app are not possible from the shell.**
   `screencapture` fails with "could not create image from display" — the
   terminal lacks Screen Recording permission. Verify headlessly instead:
   `Ark.app/Contents/MacOS/Ark --selftest`, plus
   `~/Library/Application Support/Ark/state.json` and
   `~/Library/WebKit/com.tannergrandstaff.drift/ContentRuleLists/`.
6. **Only CommandLineTools is installed, no full Xcode.** Hence a Swift Package
   plus a hand-assembled `.app`, not an Xcode project.

---

## v0.28.2 — Stop the repeating permission prompt (2026-08-20)

### Fixed

- **“Ark would like to access data from other apps” asked on every 1Password
  authentication.** That prompt is TCC, and TCC remembers a decision against the
  app's *code identity*. The rename left the existing local certificate called
  “Drift Code Signing”, while `build.sh` looked for “Ark Code Signing”, found
  nothing, and fell back to **ad-hoc signing** — which has no stable identity, so
  every rebuild produced a new cdhash and macOS treated it as a new app with no
  saved answer.
  - `build.sh` now accepts either name, and says loudly when it falls through to
    ad-hoc, since that fallback is exactly what causes the prompts.
  - Confirmed: `Signature=adhoc` before, `Authority=Drift Code Signing` after.
  - Expect **one** more prompt — the bundle identifier changed with the rename,
    so the grant is being recorded fresh. It should stick after that.
  - Worth knowing: this was a developer-machine artifact. A released build isn't
    rebuilt on your friends' Macs, so they'd have been asked once regardless.

---

## v0.28.1 — Feature requests from inside Ark (2026-08-20)

### Added

- **Request a Feature…** in the Help menu (⌘⌥⇧F). Saves to
  `Application Support/Ark/requests.jsonl` immediately — local, offline, can't be
  lost to a failed network call — then *optionally* opens a pre-filled GitHub
  issue or copies the text.
  - It deliberately does **not** post the issue itself. That needs a token, and a
    token shipped inside a public app is a leaked credential with write access to
    the repo. A pre-filled URL costs one click and asks the person to
    authenticate as themselves, which is the right trade.
  - Attaches the app version and macOS version, and says so in the sheet.
    Nothing else — no page, no URL, no history.
  - JSONL rather than a JSON array: a crash mid-write costs one line instead of
    the file.
- **`tools/inbox-sync.sh`** pulls both sources — the local store and open GitHub
  issues labelled `feature-request` — into `BACKLOG.md`'s Inbox. Idempotent via a
  recorded id list, and it never touches the Queue or Shipped sections. Verified
  end to end: a request written by hand appeared in the Inbox on the next run.

### Changed

- The chatbot toggle sits in the nav row next to the shield, with the other
  page-level controls, instead of alone in the title-bar strip.

---

## v0.28.0 — ⌘-click multi-select (2026-08-20)

### Added

- **⌘-click tabs in the sidebar to select several**, then act on all of them:
  *Group N Tabs*, *Move N Tabs to Group*, *Pin N Tabs*, *Close N Tabs*. Works on
  pinned icons too. ⌘⌥A deselects, or click any tab normally.
- **Dragging one of the selection drags all of it.** The tab under the pointer
  lands on the target and the rest queue up behind it — taken in sidebar order
  and each inserted after the last, rather than all beside the same anchor, which
  would reverse them.
- Selection is drawn as a **ring**, not a fill, so "selected" and "on screen"
  stay legible at once — they mean different things, and a five-tab selection
  must not look like five open panes.

### Notes

- Selection is a separate set from `displayed`. Conflating them would mean
  selecting five tabs opened five panes.
- Closing a tab removes it from the selection, and `pruneSelection()` drops dead
  ids — a closed tab left in the set makes the count lie.
- ⇧-click stays *peek*, so range-select isn't available. Two different meanings
  for shift-click in the same list would be worse than not having ranges.

---

## v0.27.2 — One surface, ripple relocated (2026-08-20)

### Changed

- **The sidebar and the background are one surface.** They were two glass layers
  meeting, each refracting separately, which is what drew the seam down the edge
  of the sidebar. Now the window colour, the page tint, and a single glass pass
  are painted once behind everything, and the sidebar draws nothing of its own.
  Measured: sidebar interior and all four gutters read the same `#282828`.
  - The resize divider is invisible until you hover it. A permanent hairline was
    the other half of the seam — a border between two things meant to read as one.
- **The command-bar ripple moved to the field row.** Rippling the panel outline
  was the wrong target twice over: once you type, the panel is ~380pt tall with a
  suggestion list in it, so a 3pt bow on its edges is nowhere near where you're
  looking — and `glassEffect(in:)` is a compositor effect that doesn't re-clip
  smoothly against a shape changing every frame. The wave is now the field row's
  own fill, in drawn SwiftUI content, with a soft crest highlight so it reads even
  where the edge displacement is small.
- **Pinned tiles stretch to fill the sidebar.** One pinned tab gets a wide tile
  spanning nearly the full width, two get halves, up to four per row. Only the
  width stretches — the fixed 34pt height is what stops a lone pinned tab
  becoming one enormous square.
- **The settings window has an opaque backing.** It inherited the app's vibrancy,
  and over a bright page the tab bar's labels washed out to ghost text.

---

## v0.27.1 — Verse removed, the ripple follows the caret (2026-08-20)

### Removed

- **The verse card is gone**, along with `VerseSuggestion`, `VerseCard`, the
  translation setting, the `--verse` probe, and its 12 tests. Blank tabs are just
  the colour field again.

### Fixed

- **Why the sidebar was purple over a blue field.** Two causes, both real. The
  blank-tab tint used `palette[1]` — the first accent — but the accent that
  *names* a palette isn't the colour that ends up covering the tile; it now
  blends the blobs actually drawn, weighted by area. And the command-bar overlay
  seeded its field from `newTabSeed` while the pane behind it seeded from the
  tab id, so the sidebar could be tinted from a field you weren't looking at.
  One seed now feeds all three.

### Changed

- **The command-bar ripple starts at the caret and runs right.** It was a
  standing wave with a fixed envelope; it's now a travelling packet — origin at
  the caret (estimated from text length, since `TextField` doesn't expose its
  cursor), moving rightward, losing energy as it goes, ends pinned so the
  corners never move. Sampling went from 28 to 44 steps: a narrow packet sampled
  coarsely shows a visible kink.

---

## v0.27.0 — Pinned URLs are editable (2026-08-20)

### Added

- **Change a pinned tab's URL.** Right-click a pinned tab: *Set Pinned URL to
  This Page* for the common case, or *Edit Pinned URL…* for a sheet with the
  current value shown. Backlog Queue #1.
  - A sheet rather than an inline field, because the pinned URL is invisible
    normally — editing something you can't see is how you overwrite it by
    accident.
  - An empty box means "use the page I'm on", not "clear it". A bare host is
    resolved (`github.com` → `https://github.com`). Only a genuinely empty result
    is refused, so a typo can't silently blank a pinned tab's home.
  - The tooltip now names the destination ⌘W will return to, when it differs from
    what the tab is showing.

---

## v0.26.2 — Backlog, what's-new page, settings fixed (2026-08-20)

### Added

- **`BACKLOG.md`** — an Inbox you own, a Queue we agree on, and a Shipped list the
  release notes draw from. I take Queue items from the top rather than building
  whatever was mentioned last.
- **What's-new page on the first launch after an update.** Rendered from the
  changelog shipped inside the bundle, so it travels with the app. HTML in a tab
  rather than a modal: Ark already renders documents well, and a panel you must
  dismiss before using your browser is a worse greeting than a tab you can close.
  A fresh install shows nothing — nobody needs release notes for software they
  just met.
- Non-http links in the notes keep their label and lose the URL entirely. That
  page opens by itself, so a `javascript:` or `file://` target has no business
  surviving even as text someone might copy.

### Fixed

- **Tab reordering broke, and my jelly change did it.** Two `DragGesture`s on one
  row — one at `minimumDistance: 0` for the press squash, one at 8 for the drag —
  fight over the same events, and reordering and row selection lost. The real
  drag is back at 8pt, and the click-anchored squash now comes from a
  `SpatialTapGesture`, which reports where the click landed without being a drag
  at all.
- **The settings window showed seven identical "General" tabs.** `.tabItem` is the
  pre-macOS-15 spelling and its labels stopped binding on 26; `Tab` gets it right.
  Also 420pt tall clipped the 1Password pane's own button off the bottom.
- Pinned rows are centred again, with tile size still taken from the four-across
  grid — so a short row sits in the middle at full size instead of stretching.

---

## v0.26.1 — Tidal-wave jelly, Arc-shaped pinned tabs (2026-08-20)

### Motion

- **The command bar ripples as you type.** A travelling wave, not a squash:
  `JellyWave` is a `Shape`, because a transform can't do this — `scaleEffect` and
  `geometryEffect` are affine, so they can squash the whole bar but cannot bend
  one part of an edge while leaving the rest alone. The path is rebuilt each
  frame, the crest crosses once per keystroke, and the ripple decays if you stop.
  The glass surface and the rim both follow the wave, so there is no static
  outline sitting over a moving one.
  - The text field is deliberately **not** deformed. It's a hosted `NSView`, and
    distorting a live cursor and glyphs mid-edit reads as broken, not soft.
  - Idle, the shape is a plain rounded rect — the per-frame cost only exists
    during the ~0.5s a wave is alive, and nothing animates under Reduce Motion.
- **Sidebar rows squash from where you click.** A local-space gesture reports the
  press position and the scale pivots there, so a row gives way under the pointer
  instead of shrinking toward its middle.

### Changed

- **Pinned tabs match Arc and Zen properly**: a fixed four-across grid whose
  tiles divide the available width, so the row reaches both edges and tiles grow
  with the sidebar. The container box is gone — Arc and Zen let the tiles sit
  directly on the sidebar, and a bordered panel read as a widget.
- **The blank tab stays out of the sidebar until it goes somewhere.** The tab has
  to exist (it's what the command bar sits on, and what stopped the old page
  setting the cursor), but listing "New Tab" for something that may never become
  a tab was noise.
- The chatbot toggle is gone from the top-right strip entirely. A lone floating
  icon over the page looked like a stray control; ⌘⇧A does the job.

---

## v0.26.0 — Published (2026-08-20)

Live at **github.com/tannergrand/ark-browser**, release `v0.26.0`.

- Published with its own history rather than a subtree of claude-workspace, so
  nothing from the surrounding workspace can travel with it. `tools/publish.sh`
  mirrors the folder into a repo outside the workspace — no nested `.git` for the
  outer repo to trip over. 56 files, nothing outside the project.
- Scanned for secrets before the first push. The only hit was the `sk-ant-…`
  placeholder in a `SecureField`.
- Updater verified against the live feed: tag, asset URL, and the `sha256` in the
  release notes all parse, and the app's own version matches `VERSION`.
- **All AI defaults to on-device.** One setting drives grouping, command-bar
  completions and the page assistant. The legacy `automatic` value still decodes
  and resolves to on-device; an explicit Claude choice is left alone.
- The strip above the page with the sidebar hidden lost its glass fill and
  hairline — it's a gap the tinted gutter shows through, so the traffic lights
  sit on the same colour as every other edge instead of on a stray toolbar.
- Only one chatbot toggle at a time: the chrome-strip button hides while an
  auto-hidden sidebar is revealed.
- Command bar squashes on each keystroke, keyed on a counter rather than the text
  so a repeated character still animates, and only the newest keystroke releases
  the squash — holding a key stays compressed instead of flickering.

---

## v0.26 — Renamed to Ark, updates, real new tabs (2026-08-20)

### Renamed to Ark

- Module, bundle identifier, app name, JS bridge names and env vars. Two things
  deliberately **not** renamed, because they are lookup keys rather than
  branding: `Keychain.service` and the keychain security domain. Renaming those
  orphans every saved credential, silently, with the items still on disk.
- `Migration.swift` carries a Drift install forward on first launch: app state,
  and `~/Library/WebKit/<bundle-id>` — the second one holds every cookie and
  logged-in session, and is keyed on the identifier, so changing the identifier
  without moving it signs you out of everything. Copies rather than moves, so a
  failed launch leaves the old install usable.
- New icon: a simplified ark — hull, cabin, waterline. Two curves and three
  rectangles, because anything finer turns to mud at 32pt in the Dock.

### Updates

- `Updater.swift` checks GitHub Releases at launch and on demand. Not Sparkle:
  Sparkle's EdDSA and appcast machinery is ceremony around a trust anchor that
  doesn't exist for a self-signed build.
- Guarantees, stated plainly: the download must be served by GitHub over HTTPS
  (so release notes can't redirect the installer), a published `sha256:` in the
  notes is enforced and a mismatch **refuses** rather than warns, and nothing
  installs without a click. This is not a substitute for notarisation.
- The old bundle is moved aside and only deleted once the new one is in place, so
  a failure mid-swap leaves a working app.
- `tools/release.sh <version>` builds, zips with `ditto`, publishes the release
  and puts the checksum in the notes. `VERSION` is the single source of truth.

### Fixed

- **New Tab now opens a real tab.** The sidebar row only set `commandBarMode`,
  leaving the previous page live underneath — and WebKit kept setting the cursor
  from that page, so hovering a link through an opaque overlay produced a
  pointing hand. The overlay announced itself. Dismissing without typing reverts:
  the blank tab closes and the previous tab comes back. All dismissal paths now
  go through one `closeCommandBar(committed:)`.
- Pinned tile size comes from the sidebar width alone, never the tab count.
  Deriving it from the count made a single pinned tab one enormous tile.

### Motion

- `JellyRow` — press, hover, drag-lift and selection in one modifier, all
  anisotropic. Sidebar drags start at zero distance so the squash lands on
  mouse-down, while a drag still needs 8pt of travel to become a drag.

---

## v0.26 — Ten translations, the chrome blends (2026-08-20)

### Added

- **Ten English translations** for the verse card: WEB, WEB British, KJV, ASV,
  Darby, Douay-Rheims, Open English (US and Commonwealth), Bible in Basic
  English, and Young's Literal. Each was verified one request at a time against
  both a New Testament and an Old Testament reference — the first sweep looked
  like half of them were broken, which turned out to be the source throttling
  bursts, not the editions.
- **Falls back to the WEB** when the chosen edition can't answer. Young's Literal
  is New Testament only, and a throttled request looks identical to a missing
  verse from here, so one mechanism covers both. Each edition also gets one
  retry. The card always names the edition that actually answered, so a fallback
  never misattributes the text.
- English only, deliberately: the non-English editions the source carries index
  their books under localised names, so an English reference returns "not found".
  That needs a per-language book table and buys nothing here.

### Changed

- **The gutter and rim around the page take the sidebar's colour.** Left neutral,
  the 8pt frame read as a grey border drawn between two tinted surfaces.
  `glassRim` takes an optional tint for this.
- Sidebar style is a segmented control with three plain options — Liquid Glass,
  Webpage, Tinted.

---

## v0.25 — Pinned tabs as icons, verse card actually visible (2026-08-20)

### Fixed

- **The verse never appeared, and the parser was why.** `--verse` (new probe,
  writes to stderr so output survives a kill) traced it: Apple Intelligence
  available, 18 usable titles, model replies — and `parse` rejected every one.
  Asked for `reference|reason`, the on-device model reliably answers
  `Philippians 4:6 - "Do not be anxious…"` plus a paragraph. The parser now tries
  the strict form, then scans for any real reference, and takes the explanation
  from a line containing neither quotation marks nor a reference. **The model's
  own quotation is still always discarded** — the text is looked up.
- The card was also in the wrong place: on the blank pane, *behind* the new-tab
  colour field. It now renders on the command-bar overlay, which is what you're
  looking at when you open a tab.
- The first version of `--verse` deadlocked — main thread parked on a semaphore
  while awaiting `MainActor.run`. It reads history straight off disk instead.
- **Translation is now a setting** (WEB, KJV, ASV, BBE). All public domain; NIV
  and ESV aren't available from an open source at any length.

### Changed

- **Top-level pinned tabs render as icons, fixed at the top of the sidebar** —
  Arc/Zen style, favicon or emoji, no title. Favourites moved up beside them, so
  neither scrolls away with the Today list. Pinned *groups* keep their rows
  below: a group needs its name to be worth anything.
- The icons register the same `.row(id)` drag region as a full row, so
  reordering and dropping into a group still work — the coordinator is
  pointer-based and only cares about the frame, not the layout that produced it.

---

## v0.24 — Tab snoozing, sidebar styles, jelly, verse card (2026-08-20)

### Memory

- **Idle background tabs are snoozed**, freeing the page and keeping the tab.
  Measured on five real sites: WebContent memory went **2945 MB → 2185 MB**
  (~760 MB) with every tab still in the sidebar. Process count doesn't drop —
  WebKit keeps the processes and frees their pages.
- Scroll position and back/forward history survive via `interactionState`, with
  a 400 ms fallback that reloads the URL if the restore doesn't kick off a load.
- Never snoozed: tabs on screen, the focused tab, anything playing media
  (checked with `requestMediaPlaybackState`), and **top-level pinned tabs** —
  loose pinned tabs stay resident; a pinned tab inside a group is fair game.
- Immediate sweep on the system memory-pressure signal, not just the idle timer.
- **`DRIFT_SNOOZE_MINUTES=0.15` shortens the idle threshold and the sweep tick**
  to seconds. Verifying this means measuring real WebContent memory, and that is
  not possible on a 20-minute cycle.
- Title, URL, favicon and loading state are frozen while snoozed. Loading
  `about:blank` fires the title and URL observers, which renamed every snoozed
  tab to "New Tab" and blanked its URL.

### Sidebar

- **Three surface styles** — Liquid Glass, tinted from the page, or a custom
  colour — with **one** intensity slider that drives whichever is selected.
- The page tint was rebuilt after runtime tracing showed every site in daily use
  being rejected. It now ranks every colour the page exposes (theme colour,
  header/body backgrounds, `accent-color`, link and button colours), scores by
  saturation **discounted for darkness** — a near-black navy scores higher than a
  vivid purple in HSB, which is how Stripe's #061B31 beat its own #533AFD — and
  normalises the winner's lightness while preserving hue. Blank tabs tint from
  their own colour field. Loading spinners and the progress bar use the tint.
- Pinned rows show the pin **on hover only**. Clicking anywhere on a group row
  toggles it, not just the chevron. Emoji tab icons via the context menu.
- Every icon has a tooltip saying what it does.

### New tab

- **Verse suggestion** from the themes in recent history, on-device only. The
  model returns a *reference* and never writes scripture; text is looked up from
  a public-domain translation, and the card links out if the lookup fails. Verse
  of the day was the original ask and isn't cleanly reachable: no open YouVersion
  endpoint, and bible.com returned a bot challenge on one fetch in three.
- The colour field moves — 26s counter-rotation and breathe, applied *after*
  `.drawingGroup()` so the blur is still paid once.

### Motion

- `Motion.appear` is now **anisotropic** squash-and-stretch. A uniform scale
  reads as a zoom; the jelly comes from being wider than it is tall on the way
  in. Under-damped spring (0.55) so it overshoots and settles.

### Autofill

- **Login-field detection rebuilt.** Three real defects: the visibility filter
  was `offsetParent !== null || el.type === 'password'`, whose second clause made
  it a no-op for *every* password field, so hidden and honeypot fields counted;
  the username was chosen by keyword score anywhere in the form, so a search box
  could win; and detection was one-shot, so an SPA route change that swapped in a
  login form was never seen again.
- Now: `autocomplete` is decisive where present, placeholder/`aria-label`/
  `<label>` text is read, position is scored as *proximity* to the password
  field, shadow roots are searched, and registration forms (two password fields,
  or `new-password`) are recognised and never offered a fill.
- **Right-click a text box → Fill Login**, filling the field actually clicked
  rather than the page's first login field.

### Layout

- One `Layout.contentInset` (8pt) for every edge of the web content, matched to
  the resize handle's width. Top was 0, bottom and trailing 4.
- Command-bar rows from local history are capped at 3, so AI completions aren't
  pushed off the bottom by places you've already been.

---

## v0.23 — Tint actually visible, AI rows swapped (2026-08-20)

### Fixed

- **The page tint never rendered.** `.background(ChromeTint(…))` was applied
  *after* `.glassSurface(…)`, and `.background` inserts behind whatever it's
  attached to — so the glass surface sat in front of the tint and covered it
  completely. Swapping the two modifier lines is the whole fix; the tint now
  lands between the glass and the sidebar content. **Modifier order is
  load-bearing here — don't "tidy" these two lines back.**
- Widened the tint accept gate (saturation floor 0.12 → 0.06, brightness
  0.12–0.94 → 0.10–0.96). Plenty of real sites declare only a lightly tinted
  theme colour, and rejecting those made the feature look broken rather than
  deliberately neutral. The gate is now `BrowserTab.tintCandidate(_:)` — pulled
  out of the private `adoptTint` specifically so it is testable, since behind a
  live web view the thresholds were unreachable. Five self-test cases cover it.
- **The sidebar vanished when opening a new tab.** `LiquidBackdrop` is fully
  opaque and the command-bar overlay covered the entire window. The overlay is
  now inset to the content area — offset by `sidebarWidth + 5` when the sidebar
  is pinned, and rounded to match the content pane's 8pt radius.

### Changed

- **The two AI features swapped places.** *Group tabs with AI* now sits
  directly under the Today divider — it acts on the tabs listed beneath it, so
  it belongs with them — showing a count when eligible and an inline spinner
  while it runs. Its duplicate in the footer is gone.
- **The new-tab colour field moves.** A slow counter-rotation, scale breathe and
  drift (26s, autoreversing) plus a spring entrance from 1.05×. The motion is
  applied *after* `.drawingGroup()`, so it's a transform on an already-flattened
  texture and the blur is still paid exactly once — animating blob positions
  instead would re-blur every frame. This is the one deliberate exception to
  `Motion.swift`'s "nothing repeats" rule, and it holds still under Reduce
  Motion. Note the field is **not** `allowsHitTesting(false)`: the caller layers
  click-outside-to-dismiss on it.
- **The chatbot toggle moved to the title-bar strip**, right-aligned opposite
  the traffic lights, so it reads as a window-level control. Mirrored onto the
  standalone chrome bar shown when the sidebar is hidden, so hiding the sidebar
  doesn't hide the feature. ⌘⇧A still works.

---

## v0.22 — Everything on-device, page tint, new-tab colour (2026-08-07)

### Shipped

- **The page assistant now runs on Apple Intelligence** by default, streaming
  on-device. This is the feature that reads whatever you're looking at, so
  keeping the page text on the Mac matters more here than anywhere else.
  - Streams via `session.streamResponse(to:)`, which yields **cumulative**
    snapshots — only the new suffix is forwarded, so the panel's append logic is
    unchanged.
  - The on-device context window is a fraction of the API's, so the page is
    truncated to 6k characters and **the header says so** ("On-device · sees the
    first 6k characters"). Claude remains the choice for a long page.
  - Reply labels follow the engine rather than always saying "Claude".
- **Split-divider resize now matches the sidebar**: deferred, with a guide line,
  committing once on release. One consistent behaviour for every draggable edge,
  and `PaneView` lost its `resizing` flag since nothing changes mid-drag.
- **New tabs get a colour field.** A seeded, blurred multi-colour backdrop from
  six curated palettes behind the new-tab command bar and on blank tabs. Seeded
  deliberately: a re-randomising field would shimmer as you type, and a tab keeps
  its own backdrop for its lifetime. Static and flattened with `drawingGroup()`,
  so the large blur is paid once rather than per frame.
- **The sidebar takes a hint of the page's colour**, Arc-style, cross-fading over
  0.55s when you switch pages. Sourced from `WKWebView.themeColor` (free — no
  pixel sampling), falling back to the computed header/nav/body background.
  Near-white, near-black, and grey are discarded, since tinting by those muddies
  the chrome rather than colouring it. The tint clears at navigation start so the
  sidebar eases through neutral instead of snapping between two sites' colours.
  Toggle in Settings ▸ General ▸ Appearance.
- **Sidebar layout**: the AI panel is now a labelled row above the Today divider
  rather than an icon crowded into the nav row, and the auto-hide toggle moved up
  into the header.

---

## v0.21 — Chrome resize rebuilt: deferred, not live (2026-08-07)

### Rebuilt

Three attempts at making live resize cheap all failed, and the pattern was the
lesson: **anything that relayouts during the drag stutters.** A live web view
plus the sidebar plus glass simply exceeds a frame's budget, and trimming that
work never got it under — rounded widths, suppressed animations, shed glass, a
frozen page snapshot, a clipped sidebar. Each helped a little and none of it was
enough.

So the per-frame work is now **zero**. Dragging a chrome edge moves a **guide
line** with a live pixel readout, and the width is committed **exactly once** on
release. Nothing relayouts during the drag because nothing changes.

- `BrowserState.ResizePreview` holds the prospective width; `sidebarWidth` and
  `aiWidth` are untouched until mouse-up.
- Clamping moved onto the handle as an explicit `range`, so the guide stops where
  the panel will actually stop rather than sliding past its own limit.
- Ranges widened while there: sidebar 180–460, AI panel 260–620.

### Removed

All the machinery the previous attempts added, since a deferred resize makes it
dead weight: page snapshots (`BrowserTab.resizeSnapshot`), the sidebar
layout-freeze clipping, glass shedding on resize, and frame-report suppression.
Roughly 80 lines of complexity gone along with the bug.

### Trade-off, stated plainly

There is no live preview of the new layout — you see a guide, then it snaps. This
is the deliberate exchange for it being smooth by construction rather than
smooth-if-the-page-is-cheap. The split-view divider still resizes live, since it
was already acceptable there.

---

## v0.20 — Sidebar resize, group reordering, on-device suggestions (2026-08-07)

### Fixed — sidebar resize (third diagnosis)

v0.18 trimmed our per-frame work. v0.19 froze the *page*. Neither was enough,
because the **sidebar itself** was the remaining cost. Three real ones:

- **The sidebar relaid out every frame.** It now renders at the drag-start width
  and is **clipped** to the live width, so rows, text, and favicons never
  relayout — the drag becomes pure clipping. Same for the AI panel.
- **Favicons were bare `AsyncImage`s**, which re-enter the image pipeline
  whenever the view is re-created — every row, every frame, during a resize.
  Replaced with a host-keyed in-memory cache, so a repeat render is free.
  Failures are remembered too, so a site without a favicon isn't retried forever.
- **`.animation(value: array.map(\.id))` allocated a UUID array on every body
  evaluation.** Removed; the `withAnimation` already wrapped around each mutation
  is what animates reordering.
- Frame reporting is suppressed during a chrome resize (no tab drag can be in
  flight), and every row re-publishes once on release via a `geometryEpoch` bump.

### Shipped

- **Groups can be reordered and nested by dragging**, restoring what v0.16
  deliberately dropped. Safe now because it goes through the *same* coordinator
  as tabs rather than a competing API. A group drags as a whole subtree, and
  can't be dropped into itself or a descendant — hovering its own subtree offers
  a reorder instead. `Array.insertNode` and `BrowserState.moveNode`/`nestGroup`
  handle cross-section moves, adopting the destination's tier rules.
- **Command-bar suggestions now run on Apple Intelligence** by default, matching
  tab grouping. What you type in an address bar is about as sensitive as browsing
  gets, so on-device — where the query never leaves the Mac — is the right
  default; Claude remains the fallback. Output is line-based (`label|url`), since
  a small model produces short lines far more reliably than nested JSON and
  latency matters most here. Four checks cover the parser, including that a
  hallucinated non-domain is dropped.
- The engine picker is relabelled "AI engine (grouping and suggestions)" since it
  now governs both.

---

## v0.19 — Resize actually smooth: freeze the page (2026-08-07)

### The real cause

v0.18's four fixes were all about trimming **our** per-frame work — rounding
widths, suppressing animations, shedding glass. They helped and were worth doing,
but they missed the dominant cost: **WebKit reflows the page on every frame of the
drag.** On a heavy page that's tens of milliseconds per frame, and no amount of
tuning on this side changes it. That's why it stayed janky.

### Fix

While any chrome edge is being dragged, the pane shows a **still image of the
page** instead of the live web view. Scaling a bitmap is effectively free; the
page reflows exactly once, on release.

- `BrowserTab.resizeSnapshot`, captured via `WKSnapshotConfiguration` with
  `afterScreenUpdates = false` so it doesn't force an extra render pass.
- Snapshots are **pre-warmed on hover** of the handle, so the first drag frame is
  already frozen rather than a few frames late.
- The live web view is left out of the hierarchy entirely for the duration, not
  merely covered — being covered would still have cost the reflow.
- Cleared on release, and on `onDisappear` so an interrupted drag can't leave a
  stale image on screen.

Applies to the sidebar and the AI panel. The split divider keeps its own path,
which was already acceptable because it doesn't resize the sidebar too.

---

## v0.18 — Sidebar resize smoothed (2026-08-07)

### Fixed

- **Resizing the sidebar or AI panel stuttered**, the same way the split divider
  used to. The handle already had absolute drag maths, but none of the other
  three fixes from v0.11 had been carried across — I fixed one divider and left
  the other alone. Now shared:
  - **Whole-point widths.** Fractional widths make WebKit re-layout on subpixel
    boundaries, which is the visible stutter.
  - **No implicit animation on width.** The mutation runs inside a transaction
    with `animation = nil`, so a spring can't fight the drag and leave the web
    view re-laying out to stale sizes. Only the handle's hover state animates.
  - **Glass is shed for the duration.** A new `isResizingChrome` flag drops the
    sidebar and AI-panel glass, and makes the panes drop their rounded clipping
    and rims too — they're being resized just as hard as during a divider drag.
    Refraction per frame on a live web view is the expensive part.
  - **Balanced cursor push/pop.** `onHover` pushed and popped without tracking,
    so rapid hover in-and-out left the resize cursor stuck over the page. Same
    bug the pane divider had.

The lesson, since it's now twice: these four fixes belong together. Any new
draggable edge needs all of them, not whichever one seems to help.

---

## v0.17 — Reordering inside a group (2026-08-07)

### Fixed

- **Reordering a tab within a Today group threw it out of the group.**
  `move(_:besideTabID:)` branched on the target's **tier**, and a tab inside a
  Today group has tier `.today` — so it inserted at the section's top level and
  the group lost the tab. The pinned branch already handled parent groups, which
  is why only Today groups broke. It now branches on the **container** holding
  the target: a group's children, or a section's top level.
  - Insertion indices are computed *after* detaching the dragged node, so
    dragging downward past its own former slot lands where the indicator
    promised rather than one row short.
- **The "leave the group" strip appeared for ungrouped tabs.** It now only shows
  when the dragged tab is actually in a group, and only in that group's section.
- **Region resolution was order-dependent.** `resolve()` iterated a dictionary,
  so a stale or overlapping rect could beat the group header and swallow the
  drop. Priority is explicit now — strips, groups, rows, panes — and among
  equals the smallest rect wins, since a tighter target is the more specific one.

### Testability

Tree reordering moved out of `BrowserState` into
`Array<SidebarItem>.moveNode(id:besideNodeID:before:)`, and is now covered by
six checks. That matters: the bug lived only inside Today groups, and no test
could reach it while the logic sat behind real tabs and live web views.

---

## v0.16 — Drag and drop rewritten from scratch (2026-08-07)

### Fixed

- **Clicking a tab was broken.** An always-present overlay with
  `contentShape(Rectangle())` covered every row to act as a drop zone, and
  swallowed the click. My bug, introduced by the previous attempt.

### Rewritten — `TabDragCoordinator`

Sidebar drag and drop now uses **no drag-and-drop API at all**. Rows publish
their frames in global coordinates, a `DragGesture` reports the live pointer, and
the target is plain geometry. Nothing depends on pasteboards, item providers,
Transferable, or AppKit destination resolution — and because it is a gesture
rather than an overlay, it structurally cannot intercept a click.

Six attempts failed first. Recording all of them, because each is a real trap:

1. `.draggable` + `.onDrop` — crossed APIs; the drop never sees the item.
2. `.onDrag` + `.dropDestination` — the same mismatch, other direction. This is
   what silently broke reordering back in v0.7.
3. An overlay `NSView` — a bare `NSView` reports `fittingSize` of zero, so
   SwiftUI lays it out **0×0** and nothing can ever hit it.
4. The same view gated on "drag is active" — created **mid-drag**, and AppKit
   resolves drop destinations at session start, so it is never consulted.
5. An always-present, correctly sized `NSView` — proven by trace to exist, be
   sized, and be registered, and AppKit *still* never delivered
   `draggingEntered`, because SwiftUI's hosting view intercepts a
   SwiftUI-initiated session and does not route it to nested NSViews.
6. Always-present SwiftUI drop zones — these worked, and broke clicking.

Only attempt 5 was diagnosable, and only because `DRIFT_DRAG_DEBUG=1` tracing
showed `onDrag started` followed by `catcher laid out` and no `entered`.

### Consequences

- **One mechanism for every destination**: reorder, drop into a group, lift out
  of a group, and open as a split pane all resolve through the same geometry.
  The AppKit drop code in `DriftWebView` is gone; panes just publish their frames.
- A ghost of the dragged tab follows the pointer, visible over the sidebar and
  the page alike, never hit-tested.
- Nine self-test checks cover target resolution — insert above/below, into a
  group, root strip, both pane halves, empty space, and that a tab can never be
  dropped onto itself.
- **Groups no longer have a drag source.** Mixing a system drag with the
  pointer-tracked one is exactly what caused this; use Pin/Unpin Group. Group
  reordering is a gap, listed under Proposed.
- Retired: `RowDropCatcher.swift`, `SidebarDrop.swift`, and the drag half of
  `TabDropZone.swift`.

---

## v0.15 — Fewer auth prompts, sites over searches, 4th drag attempt (2026-08-07)

### Fixed

- **Two 1Password prompts on every launch.** Each `op` invocation is a separate
  authorization, and Ark was making three: the item list at launch, a
  `op vault list` lock probe on every activation, and another on opening
  Settings. Now there is **one**, loaded lazily the first time a login field is
  actually seen, cached for 10 minutes, and activation only marks it stale
  without spawning anything. Launch makes no `op` call at all — verified: zero
  `op` mentions in the launch trace.
- **The command bar preferred searches over sites.** Typing `gith` searched the
  web instead of offering github.com. The primary row is now: a typed URL, else
  the best known site for what you typed, else a search. Site matching ranks by
  *host* — exact, host prefix, then first-label prefix — and deliberately ignores
  titles, since title matching is what made a bare word open a random article.
  `localhost`, `host:port`, and scheme-prefixed input now count as URLs. Search
  is still one row down.

### In progress — sidebar drag and drop

Fourth attempt, this time on the mechanism with evidence behind it. Sidebar rows
now use an AppKit `NSView` registered for the private pasteboard type — the same
approach that made drag-to-split work — placed as a `.background` so it can never
intercept a click, with no `hitTest` override and no visibility gating (the two
tricks that made earlier attempts unreliable). All SwiftUI drop modifiers in the
sidebar are gone; two competing mechanisms is how flakiness happens.

`DRIFT_DRAG_DEBUG=1` traces the whole path to stderr — drag start, `draggingEntered`,
pasteboard type list, and the drop — so the next failure names its own cause
instead of needing another guess.

---

## v0.14 — Sidebar drops actually work (2026-08-07)

### Fixed — the root cause behind three failed attempts

**Mixing SwiftUI's two drag-and-drop APIs.** `.onDrag` produces an
`NSItemProvider` (the legacy AppKit path). `.dropDestination(for:)` is the
Transferable path and **never sees those items** — it fails silently, with no
error and no warning. So the moment the drag source changed to `.onDrag` to feed
the AppKit drop zone for split view, every sidebar drop stopped working:
reordering, dropping into groups, and the ungroup strips all became no-ops.
Drag-to-split kept working the whole time because it reads `NSPasteboard`
directly, which is exactly why the failure looked so arbitrary.

The matched partner for `.onDrag` is **`.onDrop`**, now used everywhere in the
sidebar via `DropDelegate`.

- `DropDelegate` also supplies `DropInfo`, and therefore the **live cursor
  position** — so the insert-before/insert-after indicator is now driven by where
  the pointer actually is, rather than the two-stacked-half-rows workaround that
  the position-free `isTargeted` forced. That hack is deleted.
- A self-test check now covers the **drag payload round trip** — provider
  advertises plain text, and the id survives `loadDataRepresentation`. This is
  the mechanism that broke twice with no visible symptom, so it is now guarded.

### Lesson worth keeping

`.onDrag` pairs with `.onDrop`. `.draggable` pairs with `.dropDestination`.
Crossing them compiles, runs, and does nothing.

---

## v0.13 — Precise drop indicators, drag out of groups (2026-08-07)

### Shipped

- **The indicator now shows which side you'll land on.** SwiftUI's `isTargeted`
  reports no cursor position, so each row carries **two stacked drop zones** —
  top half inserts before, bottom half inserts after — and the accent bar renders
  on that edge. `move(_:besideTabID:before:)` honours it, so the drop matches the
  preview instead of always appending after.
  - The zones only exist while a drag is in flight, and never over the row being
    dragged, so ordinary clicking is untouched.
- **Tabs can be dragged out of groups.** Each section grows a dashed
  "Move out of group" strip while dragging; dropping there lifts the tab to the
  top level of that section. There's also a "Remove from Group" context-menu item
  for when a drag is more effort than it's worth.
- Group rows expand automatically on a successful drop, so the tab you just
  filed is visible rather than hidden inside a collapsed group.

---

## v0.12 — Groups, Apple Intelligence, icon, chrome fixes (2026-08-07)

### Fixed — data loss

- **Auto-archive was wiping the Today section on launch.** Tabs were restored
  with the `lastAccessed` timestamp from the state file, so reopening Ark after
  a few days made every Today tab look 12+ hours stale and the launch sweep
  archived them all before the window appeared. The archive clock now **restarts
  each launch**, so archiving means "idle while Ark was open", which is the
  only reading that makes sense. Pinned tabs and favourites were never affected.

### Shipped

- **Folders are now Groups**, renamed throughout. The persisted `folderName` key
  is still accepted so existing state files load unchanged.
- **Groups no longer have to be pinned.** The Today section is a tree rather than
  a flat list, so a group can hold ephemeral tabs — grouping is a way to organise
  open tabs, not a commitment to keep them forever. A tab adopts the section of
  whatever group it's dropped into, and "Pin Group" / "Unpin Group" moves a whole
  group between sections.
- **AI tab grouping**, Chrome-style, on **Apple Intelligence** by default.
  - Runs on-device via FoundationModels: no tab titles or hostnames leave the
    Mac, it's free, and it works offline. Verified `.available` at runtime here.
  - `@Generable` structured output needs the FoundationModelsMacros **compiler
    plugin, which ships with Xcode and not CommandLineTools** — so this asks for
    JSON and runs it through the shared validator instead, with one retry. Worth
    knowing before trying to "improve" it to macros.
  - Claude is the automatic fallback when Apple Intelligence is off or
    unsupported; it sends titles and hostnames only, never page content.
  - **Proposal-first.** Nothing moves until you approve it; group names are
    editable and any row can be unchecked. Tabs are a working set, and silently
    reshuffling them would feel like losing your place.
  - Both engines funnel through one validator, so an out-of-range or duplicated
    index can never move the wrong tab. Ten self-test checks cover it.
- **App icon**, generated by `tools/MakeIcon.swift` (kept in the repo, so it's
  reproducible rather than a mystery binary) and packaged by
  `tools/make-icns.sh`.
- **Clear Today**, keeping the active tab. Everything closed goes on the reopen
  stack, so ⌘⇧T is the undo instead of a confirmation dialog.
- Slightly larger sidebar type, and taller rows.

### Fixed — chrome

- **The white band across the top.** Three separate causes, in order:
  `.hiddenTitleBar` alone doesn't extend the content view, so the window now gets
  `fullSizeContentView` + a transparent titlebar from an app delegate (verified
  at runtime via NSLog); SwiftUI *still* reserves a titlebar-sized safe area,
  which needed `.ignoresSafeArea(.container, edges: .top)`; and the full-window
  glass rim I'd added drew a light stroke along the flat top edge, which read as
  a stray white line — that rim is gone, panes and panels keep their own.
- **Traffic lights with the sidebar hidden** now sit on a real full-width chrome
  bar that doubles as the drag/zoom strip, rather than floating over the page.
- **Hovering a pinned tab no longer nudges the Today divider.** The close button
  was being inserted on hover, which changed the row's height; both trailing
  controls are now always laid out and cross-faded, with a fixed row height.

---

## v0.11 — Smooth split resize, split memory, auto-hide sidebar (2026-08-07)

### Fixed

- **Split resize no longer flashes.** Four separate causes, all real:
  - The divider accumulated *per-frame deltas* (`translation - lastTranslation`),
    which drifted and jittered. Now every frame is computed from the ratios
    captured at drag start plus the gesture's absolute translation.
  - Width changes were being picked up by an implicit animation, so a spring
    fought the drag and the web view re-laid out to stale sizes. Resize now runs
    inside a transaction with `animation = nil`.
  - Widths are rounded to whole points. Fractional widths make WebKit re-layout
    on subpixel boundaries — slower and visibly jittery. The last pane absorbs
    the rounding remainder so the row always fills exactly.
  - Rounded clipping and the glass rim are per-frame costs on a live web view;
    both are dropped during a drag and restored on release.
- **`underPageBackgroundColor`** is set on every web view, so any area exposed
  before the page re-lays out paints the app background instead of flashing white.
- Divider cursor push/pop is now balanced — unbalanced pushes left the resize
  cursor stuck over the page.

### Shipped

- **Splits are remembered.** Clicking away from a split and back onto any of its
  tabs restores the whole split at its previous widths, instead of collapsing to
  one pane. A tab can only belong to one group, `Collapse Split` (⌘⌥⇧\) forgets
  the grouping explicitly (otherwise a single pane would be unreachable), and
  groups referencing closed tabs are dropped on load.
- **Pane ratios now persist across launches** — they live in `BrowserState`
  rather than view state. This closes a known gap from v0.2.
- **Auto-hide sidebar, Arc-style** (⌘⌥⇧S, or the button in the sidebar footer).
  Hidden by default, slides in as a floating overlay above the content when the
  pointer reaches the left 16pt, and stays open while the pointer is inside it
  or within `sidebarWidth + 16`. Hiding is delayed 260ms so brushing the edge
  doesn't cause flicker.
  - Detection uses a **local `NSEvent` monitor**, not `.onHover` on an edge
    strip: the web view sits on top and swallows hover — the same routing
    problem that broke drag-to-split three times.
  - `acceptsMouseMovedEvents` has to be enabled on the window or macOS never
    generates `mouseMoved` at all.
- Nine self-test checks over ratio normalisation and split-group memory, written
  against **static** helpers so the test doesn't construct a real `BrowserState`
  (which would load actual tabs and spin up web views headlessly).

---

## v0.10 — 1Password lock mirroring, window zoom (2026-08-07)

### Measured, not assumed

`op whoami` returns **"account is not signed in"** even when desktop app
integration is working — it reports *token* sessions only. Meanwhile
`op item list` succeeded in 3.2s with 547 login items and no prompt, because the
unlocked 1Password app authorized it silently. Using `whoami` as the unlock probe
would have reported "locked" permanently. `op vault list` needs the same
authorization as a real read but returns only metadata, so that is the probe.

### Shipped

- **Ark's authorization now follows the 1Password app's lock state.** Unlock
  1Password once and Ark stays authorized for as long as the app does; when it
  locks, cached logins are dropped immediately. Toggle in Settings ▸ 1Password
  ("Follow the 1Password app's lock state"); off falls back to the 30-minute timer.
- Lock state is re-checked when Ark becomes the active app — the cheapest
  moment to notice 1Password locked while we were away — and throttled to at most
  once per 20s so it can't run per keystroke.
- Live status in Settings ("Unlocked — Ark is authorized" / "Locked") and a
  small "1Password locked" marker in the autofill menu header.
- **`op` calls now have timeouts** (8s probes, 30s list). A locked vault can leave
  `op` waiting on authorization, and without a bound the fill Task hung forever.
- **Double-click the top strip to zoom the window**, plus drag-to-move — standard
  title-bar behaviour that `.hiddenTitleBar` removes. Honours System Settings ▸
  Desktop & Dock ▸ "Double-click a window's title bar to" (Maximize / Minimize /
  None). Deliberately does *not* use `mouseDownCanMoveWindow`: with that set the
  window server takes the drag and the view never sees `mouseUp`, which is where
  the double-click has to be detected. The strip sits in the sidebar's
  traffic-light row, and across the content top when the sidebar is hidden.

---

## v0.9 — Glass intensity slider (2026-08-07)

### Shipped

- **Settings ▸ General ▸ Appearance → Glass intensity**, 0–100%, with a live
  preview over a colour gradient so refraction is actually judgeable while
  dragging rather than guessed at from a number. Labels: Off / Subtle / Medium /
  Strong / Maximum.
- `glassEffect` has no intensity parameter, so `GlassRamp` maps the slider onto
  the things that *are* continuous: tint opacity, rim highlight, and whether
  small controls get the pointer-tracking `interactive` variant (only above 55%,
  since tracking costs a little). Below 4% glass is skipped entirely rather than
  rendered invisibly — paying for a refraction pass nobody can see is the
  wasteful case.
- The window's inner rim follows the slider too, so the border treatment scales
  with everything else.
- Persists on slider *release*, not on every drag tick, so a single drag doesn't
  rewrite the state file dozens of times.
- Nine self-test checks pin the ramp (monotonic, bounded, correct thresholds) so
  the mapping can't silently drift.

---

## v0.8 — Jelly motion + Liquid Glass chrome (2026-08-07)

### Shipped

- **Jelly-inspired motion** (`Views/Motion.swift`). The downloaded `jelly` skill
  folder contains **no animation code** — its 40 components paint soft-body
  physics on a `<canvas>` in a remote library. So this translates the *character*
  (squish on press, gentle overshoot, bounce-in panels) into SwiftUI springs
  instead of porting canvas physics, which was also the frugal choice:
  - Only `scaleEffect` and `opacity` animate. Never shadow, blur, or colour —
    those force an off-screen pass every frame.
  - Nothing repeats. Every animation hangs off a discrete state change, so idle
    chrome costs nothing.
  - Reduce Motion collapses springs to short fades rather than killing feedback.
  - `JellyPress` button style, `jellySquish`, `jellyAppear`, and three shared
    springs (`squish` / `pop` / `settle`) so timings stay consistent.
- **Liquid Glass chrome** (`Views/Glass.swift`). Verified present in this SDK by
  test-compiling `glassEffect(_:in:)`, `GlassEffectContainer`, `.buttonStyle(.glass)`
  and `Glass.regular.interactive().tint(_:)` against macOS 26.
  - Applied to the sidebar, AI panel, command bar, autofill menu, downloads
    panel, find bar, save banner, peek chrome, pane rims, resize handles, and an
    inner rim around the window.
  - **Never behind live web content.** Glass is priced per area, so the large
    surface is exactly the case to avoid; `glassRim` covers only the stroke.
    `interactive` adds pointer tracking and is reserved for small controls.
  - Deployment floor stays macOS 14: every call site is behind `#available` with
    a material fallback.
  - **Settings ▸ General ▸ Appearance** toggles it off, persisted.

---

## v0.7 — Drag-to-split (third attempt), fewer auth prompts (2026-08-07)

### Fixed

- **Drag-to-split, properly this time.** Two earlier attempts put the drop
  target *near* the web view and lost: a SwiftUI `.dropDestination` never saw
  the drag, and an overlay NSView above it was unreliable (a representable with
  no intrinsic size can collapse to zero, and gating it on a drag-active flag
  races the drag start). The web view is always the topmost view in a pane, so
  now **the web view is the drop target**: `DriftWebView` subclasses WKWebView
  and overrides the NSDraggingDestination methods. Non-tab drags fall through to
  `super`, so links and files still drop into pages. The overlay was deleted
  rather than kept as a fallback — two competing drop targets is how you get
  intermittent behavior.
- **Peek now fires.** WebKit does not reliably report shift in `modifierFlags`
  on `.linkActivated`, so the native check never ran. Shift/⌘/middle clicks are
  intercepted in the page instead, where `e.shiftKey` is unambiguous. Also
  rebuilt peek in Arc/Zen's shape: slides in from the right, parent page stays
  visible and dimmed down the left edge, spring animation, back button.
  ⌘-click and middle-click open background tabs — they were broken for the same
  reason.
- **Autofill no longer authorizes on every fill.** Each fill re-read the secret
  from scratch, and reading a secret is what triggers the prompt. Added a
  session cache of already-unlocked credentials (30 min, memory only, never on
  disk, cleared by Lock Vault).
- **Stable code identity.** Ad-hoc signatures change every build, so the
  keychain's "Always Allow" never carried over — the real cause of the repeated
  macOS consent dialog. `build.sh` now prefers a local self-signed
  `Ark Code Signing` identity when present. Verified stable across rebuilds.
  Code-signing EKU only, so it cannot impersonate a website.
- **Autofill menu appeared inconsistently.** Two causes: 1Password items were
  not loaded until Settings was opened (no items → no rows → nothing rendered),
  and clicking an already-focused field fires no focus event. Items now load at
  launch and on demand, and the menu opens on click as well as focus.

---

## v0.6 — Autofill menu, drop-to-split, sidebar polish (2026-08-07)

### Shipped

- **Inline autofill menu in login fields.** The page reports which login field
  is focused and its viewport rect; Ark draws a native menu under it listing
  every matching credential from 1Password *and* its own vault, with the source
  labelled per row. This is the extension-style dropdown WebKit can't otherwise
  host, done natively.
  - Rows are built from attribute-only data — `op item list`'s
    `additional_information` for 1Password usernames, keychain summaries for the
    Ark vault — so **opening the menu reads no secrets**. The secret is fetched
    only for the row you click.
  - The page blurs its field the instant the native menu is clicked, so
    dismissal is delayed 350 ms and cancelled while the pointer is over the menu.
    Scroll and resize drop the anchor so it can't float in the wrong place.
  - Anchor scales by `pageZoom`, and clamps so it can't render off the pane edge.
  - Escape closes it, ahead of find and the command bar.
- **Drag a tab into the content area to open split view.** Each pane is a drop
  target with a highlight and a "Drop to open in split view" hint; it reports
  when the 4-pane limit is reached rather than silently ignoring the drop.
- **Shift-click a sidebar tab to peek it**, matching shift-click on a link
  (which already worked, via the navigation policy).
- **New Tab moved inline**, directly under the last tab in Today, scrolling with
  the list instead of pinned to the window bottom. Downloads and New Folder stay
  in the bottom bar.
- **Fixed: the command bar opened unfocused.** Setting `@FocusState` in
  `onAppear` fires before the view joins the window's responder chain, so it
  silently no-opped. Now deferred a frame, and ⌘L selects the whole URL.

---

## v0.5 — Default browser (2026-08-07)

### Shipped

- **Ark can be the system default browser.** `Info.plist` now declares
  `CFBundleURLTypes` for http/https plus `CFBundleDocumentTypes` for
  html/xhtml/url, which is what makes macOS list it under System Settings ▸
  Desktop & Dock ▸ Default web browser. Verified: Launch Services reports
  `claimed UTIs: public.html, public.xhtml, public.url,
  com.apple.default-app.web-browser`, and `open -a Ark.app https://example.com`
  lands as a new tab.
- **Settings ▸ General ▸ Default browser** shows what currently handles https and
  has a "Set Ark as Default Browser" button (`NSWorkspace.setDefaultApplication`).
  macOS shows its own confirmation — there is no silent way to switch, by design.
- `.onOpenURL` opens handed-off links in a new tab and fronts the window.
- `build.sh` registers the bundle with `lsregister` after assembly, and takes
  `--install` to copy to /Applications — the default-browser choice only sticks
  from a stable location, since each rebuild in the project folder re-registers
  a new bundle.

---

## v0.4 — 1Password + keychain prompt fix (2026-08-07)

### Fixed

- **The macOS keychain consent prompt storm.** Three code paths asked for
  `kSecReturnData` — the actual secret — when they only needed to know whether a
  login existed, and requesting a secret is what triggers the "wants to use your
  confidential information" dialog. Worse, the login-form detector ran on an
  undebounced `MutationObserver`, so every DOM change re-ran the lookup.
  - `hasCredentials` now uses an attribute-only query (silent) and caches per host.
  - Settings lists the vault from attribute-only summaries; a password is read
    only when you click Reveal, one item at a time, behind Touch ID.
  - The API key is read once per launch and memoized. It was being re-read on
    every autocomplete keystroke.
  - The page bridge reports a login form **once per page**, debounced 400 ms,
    then disconnects the observer. Submit capture dedupes identical submits.
  - Repeat save prompts are suppressed by SHA-256 fingerprint of
    host+user+password held in memory for the session — never by reading the
    stored secret back.
  - New `Keychain.Summary` / `summaries` / `hasCredentials` / `credential(domain:username:)`
    split the silent and prompting paths at the API level, so this can't regress
    by accident.

### Shipped

- **1Password integration via the official `op` CLI.** New "1Password" tab in
  Settings with source picker, install/auth status, and a Test Connection button.
  When enabled, Ark asks 1Password first and falls back to its own vault when
  there's no match for the site. Parses Login items, matches by registrable
  domain (URL first, title as a weaker fallback), and reads username/password/TOTP.
  Auth is handled by the 1Password app's own Touch ID prompt, so Ark's
  biometric gate is skipped to avoid asking twice. No secret is ever passed on a
  command line, and stdout is never logged.
- `Keychain.teamIdentifier` reads the team ID from our own signature; the sync
  capability probe is now cached per signing identity instead of re-running every
  launch.
- **Self-test at 38 checks**, including 1Password parsing from fixtures so the
  integration is verifiable without `op` installed.

### Rejected, deliberately

- Talking to 1Password's `1Password-BrowserSupport` native-messaging helper
  directly. The helper verifies the calling browser's code signature on purpose;
  working around that is defeating a security control in a password manager. The
  `op` CLI is the supported surface and needs no such workaround.

---

## v0.3 — Improvement pass (2026-08-04)

Requested: "make as many improvements as you can." Done as direct work rather
than a fanned-out workflow — parallel agents editing one Swift package collide
more than they help.

### Shipped

- **Drag and drop in the sidebar.** Drag a tab onto another tab to reorder or
  move it between sections, onto a folder to file it, or onto the Today header
  to unpin. Folders drag too, with cycle detection so a folder can't be dropped
  inside itself. Replaces right-click-only movement.
- **Downloads.** `WKDownloadDelegate` wired for both link- and response-initiated
  downloads, non-displayable MIME types auto-download, unique filenames in
  `~/Downloads` (no overwriting), live progress, Show in Finder, and a panel at
  `⌘⌥L` plus a sidebar chip that highlights on new activity.
- **Search engine choice** — DuckDuckGo, Google, Brave, Kagi, or Startpage, in
  Settings ▸ General. The AI autocomplete prompt follows the same choice.
- **Reopen closed tab** (`⌘⇧T`), backed by a 20-deep stack.
- **`⌘1`–`⌘8` jump to tab, `⌘9` jumps to the last tab**, matching Safari.
- **Zoom** — `⌘+` / `⌘-` / `⌘0`, per tab, snapped to ten sensible steps.
- **Copy address** (`⌘⇧C`).
- **Global Escape handling** via a local `NSEvent` monitor, dismissing peek →
  downloads → find → command bar → save-password prompt in priority order. The
  event is only swallowed when something was dismissed, so pages still receive
  Escape otherwise.
- **Self-test grew to 24 checks**, now covering search engine selection and
  query encoding.

---

## v0.2 — Arc-style rewrite (2026-08-04)

Requested: "as similar to Arc as possible" — split view, peek, pinned tabs,
resizable sidebars, folders instead of spaces, AI autocomplete, keychain.

### Shipped

- **Full Arc shell.** The persistent top address bar is gone. Navigation, the
  shield, bookmark, and AI toggle moved into the sidebar header, under a URL
  pill that opens the command bar when clicked. Window uses
  `.hiddenTitleBar`; the sidebar reserves 26pt for the traffic lights.
- **Floating command bar** (`⌘T` new, `⌘L` edit current). One field over
  open tabs, bookmarks, history, and the web. Arrow keys + return, escape to
  dismiss. Row 0 always acts on exactly what was typed.
- **AI autocomplete in the command bar.** Haiku 4.5, 400 ms debounce, min 4
  characters, skipped when the input already looks like a URL, in-flight
  requests cancelled on each keystroke. Local matches render instantly and never
  wait on the network. Toggle in Settings ▸ AI.
- **Split view, up to 4 panes.** Draggable dividers with a 15% minimum per
  pane, focus ring on the active pane, per-pane close button.
  `⌘⌥\` splits, `⌘⌥⇧\` collapses, `⌘⌥←/→` moves focus.
- **Peek.** Shift-click any link, or click any offsite link from a pinned tab,
  and it opens in an overlay card instead of navigating. Escape dismisses,
  `⌘↩` promotes it to a real tab.
- **Three-tier tabs.** Favorites (global icon grid, never archived) · Pinned
  (permanent, `⌘W` resets to the pinned URL instead of closing, Arc's actual
  behavior) · Today (auto-archived, interval configurable 6/12/24h/never).
- **Folders, replacing spaces.** Nestable to any depth, collapsible, renamable,
  tab counts shown. Deleting a folder drops its tabs into Today rather than
  destroying them. Spaces and the workspace color palette were removed entirely.
- **Resizable sidebars.** Both the left sidebar (180–400pt) and the AI panel
  (260–560pt), persisted across launches.
- **Password vault.** macOS keychain storage scoped to Ark via
  `kSecAttrSecurityDomain`, login-form detection, autofill, save/update prompts,
  Touch ID gate with a 15-minute unlock window, CSV import, and a management
  list in Settings. iCloud sync auto-enables when properly signed.
- **Find in page** (`⌘F`) on WebKit's native find.
- **Streaming AI sidebar.** Replaces the old block-until-done round trip. Page
  text is labeled as untrusted data in the system prompt.
- **API key in the keychain**, entered in Settings ▸ AI. Lookup order:
  `ANTHROPIC_API_KEY`, keychain, then `~/.config/drift/api-key`.
- **Self-test harness.** `--selftest` runs 22 checks over URL resolution, domain
  normalization, the real keychain round trip, CSV parsing, AI response parsing,
  and blocker rule validity. All passing.
- **Persistence v2.** Full tree snapshot: favorites, nested pinned folders,
  Today, pane layout, focus, widths, and settings.

### Removed

- Workspaces/spaces and `Palette` — superseded by folders.
- `OmniboxView.swift` — superseded by the sidebar header and command bar.

---

## v0.1 — First build (2026-08-04)

### Shipped

- SwiftUI + WKWebView browser as a Swift Package, `.app` assembled by
  `build.sh`, ad-hoc signed.
- One `WKWebView` per tab, retained for the tab's life, so switching tabs
  preserves scroll, form state, and playing media.
- Vertical tabs, omnibox with URL/search detection, history, bookmarks.
- Content blocking: 82 tracker/ad domains blocked third-party plus 14 cosmetic
  selectors, compiled once into a `WKContentRuleList` (identifier
  `drift-blocklist-v1` — bump it when rules change or WebKit serves its cache).
  Blocked counts are **approximate** by design: WebKit exposes no per-block
  callback, so the number comes from a resource-error listener. The UI says so.
  Do not "fix" this into a hard number.
- AI sidebar over the Claude Messages API.

---

## Proposed — agreed but not built

Ordered by value per hour of work.

1. **Claude driving the browser** (explicitly deferred to v2 by Tanner).
   Tool-use loop over `navigate` / `read_page` / `click(ref)` / `type` /
   `open_tab` / `split`. Use numbered DOM element refs, not vision screenshots —
   cheaper, faster, no coordinate math. Chosen posture when it lands:
   confirm-gated actions, agent browsing in the user's own session.
   **The design risk is prompt injection**, not the mechanics: page text plus
   the user's logged-in cookies means a hostile page can issue instructions.
   Needs page content treated strictly as data, a hard confirmation gate on
   anything state-changing, and a visible action log.
2. **Expose the tool surface over a local socket** so an external agent
   (Claude Code) can drive Ark. Doubles as the fix for constraint 5 — it makes
   the app verifiable without screenshots.
3. **Ask across tabs** — Claude with every tab in a folder as context, not just
   the focused one.
4. **Boosts** — per-site CSS/JS via `WKUserScript`. Cheap, and one of Arc's
   most-loved features.
5. **Sidebar auto-hide with hover reveal**, Arc-style.
6. **Action log with undo** — pairs with item 1.
6b. **1Password vault scoping** — let the user restrict `op` lookups to chosen
   vaults, so enabling the integration doesn't expose the whole account.
6c. **TOTP autofill** — the code is already parsed from `op`; nothing fills it yet.
7. **Reader mode** — readability-lite injection.
8. **Little Arc** — external links open in a lightweight window first.
9. **Per-site zoom memory** — zoom is currently per tab, not remembered per host.
10. **Split-view layout persistence** — pane ratios reset to equal on relaunch.

## Blocked

- **Chrome extensions** — impossible on WebKit. This is the most likely reason
  Ark doesn't become a daily driver, since it means no 1Password or Bitwarden
  browser extension. The built-in vault is the mitigation.
- **Reading existing Safari/iCloud passwords** — see constraint 3.
- **Passkeys** — WKWebView needs Apple's Web Browser Public Key Credential
  entitlement, which requires applying to Apple with a real Developer ID.
- **Per-tab audio indicator and mute** — WKWebView exposes no public
  "is playing audio" API.
