---
feature_id: MP-N1
base_main_sha: 45a290e3
date: 2026-10-06
status: proposed; DESIGN-N1 confirms the split
---

# MP-N1 — surface-by-surface web/native boundary

Each row names one phone surface, where it is built, and the evidence for the
choice. "Native" means a React Native screen (TypeScript) backed by the native
core where needed. "WebView" means the existing LiveView route loaded in
`react-native-webview` with a session minted by pairing (MP-N2).

The default is **WebView**: the dashboard is already responsive
(`layouts.ex:20`, 39 `@media` rules in `dashboard.css`), and duplicating it would
fork product behaviour. A surface becomes native only for one of these reasons:

- **R-push:** it must work from a notification without loading the dashboard.
- **R-multi:** it spans several instances or machines, which no single dashboard can show.
- **R-secret:** it handles credentials or keys that must not touch web content.
- **R-device:** it needs a device API (mic, camera, haptics, watch link) with OS-level permission UX.
- **R-offline:** it must render a truthful stale or unreachable state when the daemon cannot be reached.

## 1. Boundary table

| # | Surface | Owner feature | Built as | Reasons | Route or source | Notes |
|---|---|---|---|---|---|---|
| 1 | First run, add machine, scan QR | MP-N2 | Native | R-secret, R-device | Pairing contract (MP-N2) | Camera permission states. No web content sees the pairing secret. |
| 2 | Paired machines and devices list, revoke, unpair-all | MP-N2 | Native | R-secret, R-multi | MP-N2 | D19 remote unpair-everything. |
| 3 | Meta-dashboard (instance list with counts) | MP-N3 | Native | R-multi, R-offline | Capability report + MP-N3 status projection per instance | It must show `unreachable`, `stale` and `unavailable` as different states, never zero (client-capability-model.md §4). |
| 4 | Instance dashboard (landing after tapping an instance) | MP-N3 | **WebView** | — | `/` (`router.ex:140`) | A native header bar holds Back, the instance name, a freshness pill and the Executor-chat button. |
| 5 | Executor chat (secondary button) | MP-E3 | **WebView** | — | Executor route added by MP-E3 | Same conversation system as workers (brief E3). |
| 6 | Worker conversation | MP-E4 | **WebView** | — | `/chat/:owner/:repository/:identifier` (`router.ex:141`) plus the MP-E4 anchor parameter | Opens at an anchor from a notification (row 8). |
| 7 | Commands inbox (per instance) | MP-E2 | **WebView** | — | `/commands` (`router.ex:142`) | The per-instance inbox stays (brief §3). No combined inbox. |
| 8 | Command response from a notification (context, 2–3 options, mic choice) | MP-N6 | **Native** | R-push, R-device, R-offline | MP-E2 contract: `GET` Command + answer with `idempotency_key`, `client.surface: "phone"` | Shares its view model with the watch (MP-N7). "Open full conversation" goes to row 6 at the Command's anchor. |
| 9 | Mic choice (Dictate / Converse, D16) and capture UI on native screens | MP-E5, MP-E6, MP-N6 | Native | R-device | Voice contract for non-browser clients (MP-E5/MP-R5, see plan.md §6 A5) | No auto-record on open (brief N6). |
| 10 | Mic inside WebView surfaces (rows 5–7) | MP-E5 | WebView (existing browser voice) | — | `/voice` socket (`endpoint.ex:26-29`) | Needs an HTTPS origin (secure context) and the WKWebView media-capture delegate (S17). On HTTP the WebView mic is shown as unavailable, not broken. |
| 11 | Build orders | build-orders | **WebView** | — | `/build-orders[/:root]` (`router.ex:144-145`) | — |
| 12 | Analytics, Units | dashboard-ui | **WebView** | — | `/analytics` (`router.ex:146`) | Low phone value; reachable, not promoted. |
| 13 | Stream Deck emulator | streamdeck-server | **Hidden** on phone | — | `/streamdeck` | No phone use case. |
| 14 | Notification preferences | MP-N5 | Native | R-push, R-multi | MP-N5 preference contract, capability-aware | Options hidden or marked unavailable by capability (`build_orders.progress`, `push`). |
| 15 | Notification banner, actions, grouping | MP-N4 | Native (OS) | R-push | MP-N4 payload contract | Decrypted by the NSE or FCM service in the native core. |
| 16 | Watch settings (paired watch status, watch notifications on or off) | MP-N7 | Native | R-device | WatchConnectivity / Data Layer state | — |
| 17 | Connection diagnostics (reachability, transport, version mismatch) | MP-N1 | Native | R-offline | Capability report, probe | Feeds every "why is this unavailable" link. |
| 18 | Demo mode (synthetic instances for App Review) | MP-N1 | Native, fixture data | — | Bundled fixtures | Only if a public listing is chosen (OQ-N1-1). |

## 2. Rules at the boundary

1. **Native → WebView hand-off** passes only a route plus identifiers (`instance_id`,
   `ticket`, `decision_id`, `anchor_id`). It never passes credentials in the URL. The
   WebView session comes from the MP-N2 session-bootstrap call, made by native code
   before the first load and stored in the WebView cookie store for that origin.
2. **WebView → native** happens through a small allow-listed message bridge
   (`window.ReactNativeWebView.postMessage`). Allowed messages: `open-native-command
   {decision_id}`, `session-expired`, `request-mic-permission`. Every other message is
   dropped and logged. The dashboard keeps working in a plain browser: it feature-detects
   the bridge and never requires it.
3. **Navigation containment.** The WebView may navigate only within the paired
   instance origin. Other links (GitHub PRs, issues, docs) open in the system browser
   (`SFSafariViewController` / Custom Tabs). This keeps the 2.5.6 posture and stops a
   rendered link from navigating the authenticated WebView elsewhere.
4. **One origin per instance.** Instances on one machine have different ports
   (`server.port`, default `0` = random, baseline fact 16). Each instance gets its own
   cookie scope. MP-N2's extended instance record must carry the advertised URL.
5. **Native screens read JSON, never HTML.** Rows 3, 8 and 14 consume the shared
   contracts (`identity-and-capabilities`, `command-request-and-resolution`,
   `conversations-transcripts-anchors`). They do not scrape LiveView markup.
6. **Lifecycle.** When the app backgrounds, LiveView sockets drop. On foreground the
   native shell refetches capabilities first, then reloads the WebView only if the
   session or capability revision changed. LiveView reconnects otherwise.

## 3. What would move a WebView surface to native later

A WebView row moves to native only through DESIGN-N1, with a reason from the list
above. Candidates to watch during physical-device validation (device-validation.md):

- Row 6 (conversation): if long transcripts scroll poorly in the WebView, or anchor jumps are unreliable.
- Row 4 (instance landing): if a large layout gap appears below 390 px.

Moving a surface is a new ticket. It is never an implementer's improvisation.
