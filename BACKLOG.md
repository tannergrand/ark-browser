# Ark backlog

Where ideas live before they're built, and where the changelog gets its material.

**How this works**
- You add anything you want, anywhere in **Inbox**, in whatever shape. Bullet, half sentence, screenshot path — it doesn't need to be well formed.
- I don't build straight from Inbox. When you say go, we walk it together and move items into **Queue** in priority order, then I take them one at a time from the top.
- Shipping an item moves its line to **Shipped** with the version it went out in. `tools/release.sh` reads those lines for the release notes, so the wording you see here is the wording your friends see.

Priority tags: `P0` breaks something · `P1` next up · `P2` wanted · `P3` someday.

---

## Inbox

*(Yours. Add freely — nothing here is committed to.)*

-

---

## Queue

*(Agreed order. I work top-down.)*

| # | Item | Priority | Notes |
|---|------|----------|-------|
| 1 | **Redesign the settings window** | P1 | Your report: General is a dumping ground, Passwords and 1Password should be one tab, and the section headers have no background so they don't read as headers. One tab per real group of settings — General, Appearance, Tabs, Privacy, Passwords, AI, Updates, Backups — and give the headers a surface. |
| 2 | **Guard against two Ark instances** | P2 | Found while testing: launching the same bundle id from two paths gives two processes sharing one `state.json`, and they clobber each other's saves. Backups now soften it, but the fix is a single-instance check that activates the existing window instead. |
| 3 | **Slimmer top strip with the sidebar hidden** | P2 | Your screenshot: the traffic-light strip is 26pt plus an 8pt gutter above the page, so ~34pt of empty chrome. The floor is whatever clears the traffic lights (~22pt) — worth checking whether the gutter can be shared rather than stacked. |
| 4 | **Close animations, single and bulk** | P2 | Rows vanish instantly today. Bulk close especially — closing four tabs should read as four rows leaving, staggered, not the list jumping. `Motion.appear` already handles insertion; removal is a plain fade. |
| 5 | **Loading shown on the container, not as a bar** | P2 | Today it's a 1.5pt `ProgressView` hairline under the URL pill. Instead animate the pill itself — a travelling sheen or a filling border tinted from the page — so loading reads as the chrome breathing rather than a separate widget. `JellyWave` already does a travelling packet on a shape; same idea, driven by `tab.progress` instead of keystrokes. |
| 6 | **Audio indicator on a tab** | P2 | No public KVO for this — `requestMediaPlaybackState` has to be polled, which is the wrong shape for a per-row badge. Better: extend the existing page bridge to listen for `play`/`pause`/`ended` on media elements and report, which is event-driven and free when nothing is playing. A mute toggle is the natural companion, and snoozing already skips tabs with playing media, so the state is worth having anyway. |
| 7 | Cross-origin iframe autofill | P2 | Okta/Auth0/Stripe login widgets get no bridge — `forMainFrameOnly: true`. Turning it off runs the password script in every frame on every page, which is a real surface-area increase. Your call, not mine. |
| 8 | Rolling backups of `state.json` | P1 | One file, no history. You already lost a set of Today tabs to a state bug once. |
| 9 | Private window | P2 | Every tab shares one cookie store today. |
| 10 | TOTP autofill | P3 | Already parsed out of `op`; nothing fills it. |
| 11 | Vault scoping for 1Password | P2 | Currently whole-account read access. |
| 12 | Boosts — per-site CSS/JS | P3 | Arc parity. |
| 13 | Reader mode | P3 | |
| 14 | Claude driving the browser | P2 | Deferred to "v2" early on. Prompt injection is the actual design problem, not the tool surface. |

---

## In staging

*(Built and running in `Ark Staging.app`, not yet released.)*

- **Rolling backups of `state.json`** — a copy before each save (throttled to ten minutes, and always on a sharp drop in tab count), newest 12 kept, with a restore list in Settings ▸ Backups. Verified against real state files: 10 and 11 tabs captured.
- **Cursor no longer bleeds through floating panels** — `CursorShield` claims the cursor for the floating sidebar and the ⌘L overlay without taking clicks. Needs your eyes: hover behaviour can't be tested from a script.
- **Faster command-bar suggestions** — shared session + prewarm, a 40-entry cache, debounce 400→180 ms, and a 2.5 s ceiling. Measured 489 → 340 ms per query, 1 ms on a repeat. Capping output to one line measured *slower* and was dropped.

## Shipped

- `0.28.4` — Staging channel (`tools/stage.sh`): a separate app with its own data, which never self-updates. Release script fixed to operate on the publish mirror.
- `0.28.3` — Darker, simpler, centred icon: one hull, one cabin, one waterline on a near-black tile.
- `0.28.2` — Fixed the repeating "would like to access data from other apps" prompt: the rename left the signing certificate named for Drift, so every build fell back to ad-hoc and got a new code identity.
- `0.28.1` — In-app feature requests (Help ▸ Request a Feature…), synced into this Inbox by `tools/inbox-sync.sh`. Chatbot toggle moved beside the shield.
- `0.28.0` — ⌘-click multi-select in the sidebar, with bulk group/pin/close and multi-drag.
- `0.27.2` — Pinned tiles stretch to fill the sidebar width (height fixed). Settings window has an opaque backing so the tab bar is readable. Command-bar ripple moved onto the field row.
- `0.27.1` — Verse card removed. Command-bar ripple now starts at the caret and travels right. Blank-tab sidebar tint blends the whole field instead of one accent.
- `0.27.0` — Pinned tab URLs are editable: right-click → *Set Pinned URL to This Page*, or *Edit Pinned URL…* for the full value.
- `0.26.1` — Travelling jelly wave in the command bar; pinned tabs on an Arc/Zen four-across grid; click-anchored row squash.
- `0.26.0` — Renamed to Ark, published, in-app updates from GitHub Releases, all AI on-device by default, simplified-ark icon.
- `0.25` — Pinned tabs as fixed icons; verse card made visible; `--verse` probe.
- `0.24` — Tab snoozing (~760 MB reclaimed, measured); three sidebar surface styles; page-colour tint rebuilt; login-field detection rebuilt; right-click autofill.
- `0.23` — Page tint layering fixed; AI grouping and chatbot swapped places.
- `0.22` — Page assistant on Apple Intelligence; deferred split resize; new-tab colour field; sidebar page tint.
- `0.1`–`0.21` — See `CHANGELOG.md`. The interesting entries are the ones that took several attempts: drag and drop (six), chrome resize (four).
