---
design_task: DESIGN-N1
feature_id: MP-N1
owner: Kevin (operator)
status: open — not approved
blocks: every MP-N1 implementation ticket (../bucket-3-mobile-watch/MP-N1/chunks.md, N1-C1..C8)
shared_with: DESIGN-N2 (pairing screens), DESIGN-N3 (meta-dashboard), DESIGN-N4/N5 (notifications), DESIGN-N6 (Command response), DESIGN-N7 (watch), DESIGN-E5/E6 (mic controls)
base_main_sha: 45a290e3
date: 2026-10-06
---

# DESIGN-N1 — Kevin: approve the phone app's shape, the native/WebView split, and the app shell

Deliver the decisions, the shell screens and states listed below, the copy, and an
explicit approval. **MP-N1 implementation stays blocked until this task is
approved.** Research and planning continue meanwhile.

This task does **not** design the meta-dashboard, pairing, notifications, the
Command response screen or the watch. Those are DESIGN-N2, N3, N4/N5, N6 and N7. It
designs the frame they live in and confirms which surfaces are native.

## 1. What already exists (do not redesign by accident)

Verified at `45a290e3`:

- The dashboard is responsive: viewport meta (`layouts.ex:20`), apple-touch-icon (`:23`), and 39 `@media` rules in `dashboard.css` (20 width breakpoints from 320 to 1024 px).
- Phone-relevant routes: `/`, `/chat/:owner/:repository/:identifier`, `/commands`, `/commands/:decision_id`, `/build-orders`, `/analytics` (`router.ex:140-146`).
- UI terms: "Commands", "Commands inbox", "N units awaiting commands" (`decision_inbox.ex:42`, `overview.ex:168-169`).
- Read-only text in the conversation drawer: "Read-only dashboard — use the TUI to message or pause this agent."

## 2. Decisions needed from you

| # | Decision | Recommendation | Why it matters |
|---|---|---|---|
| D-N1-1 | Confirm the native/WebView split in [surface-boundary.md](../bucket-3-mobile-watch/MP-N1/surface-boundary.md) §1 (18 rows) | Approve as written | It fixes which screens Phase C writes as native tickets |
| D-N1-2 | Distribution: private (internal TestFlight and Play internal testing) or public store listings (OQ-N1-1) | Private first | Public needs a demo mode (App Review 2.1(a)) and a 4.2 review |
| D-N1-3 | Minimum OS (OQ-N1-2) | iOS 17+, Android 10+ | Sets the device-validation matrix |
| D-N1-4 | App name and icon | "aiur" with the existing logo (`/aiur-logo.png`) | Store and home-screen identity |
| D-N1-5 | The native header over WebView pages: contents | Back, instance name (`owner/name`), freshness pill, Executor-chat button | Seen on every WebView page |
| D-N1-6 | HTTP-degraded mode (no HTTPS on the machine): allowed with warnings, or refuse to pair | Allow, with a persistent warning and the WebView mic off | Affects whether a plain tailnet setup works at all (MP-N1 §5) |
| D-N1-7 | Demo mode: include it even for private distribution? | Only if D-N1-2 = public | Extra screens and a "Demo" badge |
| D-N1-8 | Devices available for validation (OQ-N1-4) | List them | Unlisted slots are reported as not validated |

## 3. Surfaces to design

1. **App frame and navigation:** tab bar or stack? Proposal: a stack rooted at the machines/instances list (DESIGN-N3 owns that list), with a Settings entry. No combined inbox anywhere.
2. **WebView page header** (D-N1-5), including how the freshness pill reads when stale.
3. **Loading a dashboard in the WebView:** the first-load state, the reload state, and what shows while the session is being minted.
4. **Connection diagnostics screen:** per-machine reachability, transport (HTTPS / HTTP-degraded / certificate mismatch), app and aiur versions, and "Why is X unavailable?" explanations from the capability model.
5. **Capability-unavailable presentation:** one shared pattern for "this exists but is off here" (reason text plus an optional "how to enable" line), used by every native screen.
6. **Update-required banners:** "Update the app" and "Update aiur on <machine>".
7. **Revoked / unpaired notice.**
8. **Demo mode** entry and badge (if D-N1-7).
9. **External-link behaviour:** confirm that GitHub links open the system browser.

## 4. States to cover (per surface where applicable)

| State | Must show |
|---|---|
| Loading | Which machine and instance is loading |
| Empty | No machines paired → route to DESIGN-N2 first run |
| Offline / unreachable | Last seen time; Retry; Diagnostics link |
| Stale | Age always visible; it is never shown as live |
| Unavailable | Reason text; no zero values; no dead buttons |
| Permission denied | Which permission; a Settings link |
| Error | Typed cause where known; "unknown" where not, never a guessed cause |
| Session expired | Silent retry once, then a clear message |
| Revoked | One notice, then the machine disappears |
| Needs update | Which side needs updating |
| Success | No toast for navigation; only for actions (owned by N6) |

## 5. Acceptance conditions

- Every row of surface-boundary.md §1 is marked approved, changed or removed.
- D-N1-1..D-N1-8 are answered in writing.
- Mock-ups (any fidelity) exist for surfaces 1–7 in at least the states in §4 marked as relevant.
- Copy for the unavailable, stale, unreachable and revoked states is written.
- Kevin records "DESIGN-N1 approved" with the date in this file. Until then every MP-N1 ticket is blocked.

## 6. Out of scope here

Instance list content (DESIGN-N3), pairing and QR (DESIGN-N2), notification banners and
preferences (DESIGN-N4/N5), the Command response screen and mic choice (DESIGN-N6,
DESIGN-E5/E6), watch interactions (DESIGN-N7).
