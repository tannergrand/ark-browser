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
| 1 | Cross-origin iframe autofill | P2 | Okta/Auth0/Stripe login widgets get no bridge — `forMainFrameOnly: true`. Turning it off runs the password script in every frame on every page, which is a real surface-area increase. Your call, not mine. |
| 2 | Rolling backups of `state.json` | P1 | One file, no history. You already lost a set of Today tabs to a state bug once. |
| 3 | Private window | P2 | Every tab shares one cookie store today. |
| 4 | TOTP autofill | P3 | Already parsed out of `op`; nothing fills it. |
| 5 | Vault scoping for 1Password | P2 | Currently whole-account read access. |
| 6 | Boosts — per-site CSS/JS | P3 | Arc parity. |
| 7 | Reader mode | P3 | |
| 8 | Claude driving the browser | P2 | Deferred to "v2" early on. Prompt injection is the actual design problem, not the tool surface. |

---

## Shipped

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
