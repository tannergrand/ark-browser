# Ark

A macOS browser, built with SwiftUI and WKWebView. Arc-shaped: vertical tabs,
pinned tabs as icons, split view, peek, folders, a floating command bar, and no
persistent address bar.

WebKit, not Chromium — so it is small and native, and **Chrome extensions will
never work**. That was a deliberate trade.

## Install

Download the latest `.zip` from [Releases](https://github.com/tannergrand/ark-browser/releases),
unzip, and drag `Ark.app` to `/Applications`.

**First launch:** right-click `Ark.app` → **Open**, then confirm. A double-click
will be blocked. Ark is signed locally but not notarised by Apple, which means
macOS cannot vouch for it — that warning is accurate, and worth reading rather
than clicking through out of habit.

Ark checks for updates at launch and can install them itself. Updates come from
this repo's release feed over HTTPS, the archive must match the SHA-256 published
in the release notes, and nothing installs without a click.

## What's in it

- **Tabs** — vertical sidebar, pinned tabs as icons, groups, drag to reorder or
  into a group, drag onto the page to split, shift-click to peek.
- **Snoozing** — idle background tabs release their page and keep their place.
  Measured at ~760 MB reclaimed across five real sites.
- **Blocking** — a compiled `WKContentRuleList`, per-site toggle.
- **Passwords** — Keychain and 1Password (via the `op` CLI), inline autofill,
  right-click to fill.
- **On-device AI** — tab grouping, command-bar completions, and a page assistant
  on Apple Intelligence. Page text and queries stay on the Mac.
- **New tab** — a colour field, and a verse suggested from the themes in your
  recent history. The model returns a *reference*; the text is looked up, never
  generated.

## Building

Requires macOS 14+ and Command Line Tools. No Xcode project.

```
./build.sh            # build and assemble Ark.app
./build.sh --install  # also copy to /Applications
./Ark.app/Contents/MacOS/Ark --selftest
```

`--selftest` runs ~140 headless checks. It is the main verification path: this
was built without the ability to take screenshots, so anything worth trusting
got a test instead.

`ARK_PROBE_PNG=/tmp/w.png` makes the app render its own window to a PNG at
launch — no Screen Recording permission needed, since nothing is captured off
the screen.

## Releasing

```
tools/release.sh 0.27.0 "What changed"
tools/publish.sh "Sync"
```

## Not implemented

Chrome extensions (WebKit), private windows, and Claude driving the browser.
`CHANGELOG.md` has the full history, including the things that took several
attempts and why.
