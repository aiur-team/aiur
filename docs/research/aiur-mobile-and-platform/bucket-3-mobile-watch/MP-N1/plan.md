---
artifact_contract: ce-unified-plan/v1
artifact_readiness: planned-with-blockers
feature_id: MP-N1
bucket: 3-mobile-watch
base_main_sha: 45a290e3
date: 2026-10-06
execution: code
research_question: MP-Q4 (resolved, pending a feasibility prototype)
owner_gate: owner-design-tasks/DESIGN-N1.md
companion_files: [framework-evidence.md, surface-boundary.md, chunks.md, device-validation.md]
---

# MP-N1 — Cross-platform phone app architecture (plan)

## 0. Summary

Build one phone app for iOS and Android in **React Native (New Architecture) on
Expo with Continuous Native Generation**. It is a separate monorepo package,
`packages/aiur-mobile`. The per-instance dashboard is reused in a WebView. Native
screens are used only where notifications, multiple machines, secrets, device
APIs or offline truthfulness require them (surface-boundary.md).

Native-language code lives in two small **native cores**: a Swift package for iOS,
the Notification Service Extension and watchOS, and a Kotlin module for Android,
the FCM service and Wear OS. The watch apps are native (MP-N7).

Evidence and the full comparison are in [framework-evidence.md](framework-evidence.md).
The selection is a recommendation, not a commitment. It is confirmed by a throwaway
feasibility prototype (§11) and by DESIGN-N1.

**Blockers:** DESIGN-N1. Contracts from MP-N2 (pairing, session bootstrap, transport
security) and MP-N4 (payload). The voice wire for non-browser clients (MP-E5/MP-R5).
Owner question OQ-N1-1 (public store vs private distribution).

## 1. Problem frame

The operator wants to notice a blocker and steer an agent from a phone without
exposing the aiur machine publicly (brief §3). Today there is no mobile client of
any kind (baseline N1: no React Native, Expo, Capacitor, manifest or service
worker). The dashboard is a responsive Phoenix LiveView app on plain HTTP with one
shared Basic Auth pair. MP-N1 decides the client architecture that MP-N2–N7 build
on. It does not decide pairing, push, or Command semantics; it consumes them.

## 2. Repository findings (extends baseline N1; all at `45a290e3`)

| # | Finding | Evidence | Planning consequence |
|---|---|---|---|
| F1 | The HTTP server is plain HTTP; the config has only `host` and `port` | `src/lib/aiur/http_server.ex:64,147`; `src/lib/aiur/config/schema/server.ex:12-13` | iOS ATS blocks HTTP and IP literals on iOS 17+; Android blocks cleartext by default (S16, S31). An HTTP origin is not a secure context, so WebView `getUserMedia` fails. → Assumption A3 (transport security from MP-N2/MP-R3). |
| F2 | Every LiveView page is in `live_session :dashboard`, mounted through `AiurWeb.FinancialDataAccess` | `src/lib/aiur_web/router.ex:133-148`; `financial_data_access.ex:98-110` (`on_mount`) | A WebView with a valid session cookie can host every page unchanged. |
| F3 | Dashboard auth is one shared Basic Auth pair, then a signed session marker | `financial_data_access.ex:50-95` (`authenticate_request`, `persist_session`); `router.ex:9-15,203-212` | The phone must not store the shared pair. MP-N2 mints a per-device session for the WebView (A1). |
| F4 | JSON writes require a same-origin `Origin` plus `X-Aiur-Request: 1`, and are disabled unless `observability.dashboard_writable` | `router.ex:50-62,215-256` | Native writes (Command answer, send message) need a device-credential API. When the dashboard is read-only, phone writes show `disabled`, not an error (client-capability-model.md). |
| F5 | The `/voice` socket needs a CSRF token, a session and `dashboard_writable`; frames up to 400,000 bytes | `src/lib/aiur_web/voice_socket.ex:21-37` (`:23` checks `dashboard_writable`); `endpoint.ex:26-29` | Native capture needs a device-authenticated voice path (A5). WebView surfaces keep the browser path on HTTPS. |
| F6 | The Command model already has the fields a native response screen needs | `src/lib/aiur/decision.ex:21-27,120-126` | The native Command screen renders the MP-E2 contract and does not duplicate dashboard logic. |
| F7 | The `/commands/:decision_id` route exists; no deep-link scheme exists | `router.ex:143`; baseline N6 | Notification taps route inside the app from the decrypted destination (MP-N4). A custom scheme is used only for internal routing. Universal or App Links are not required. |
| F8 | No capability endpoint exists; clients infer from missing fields and join errors | baseline R1; `voice_channel.ex:253-254`; `streamdeck_projection.ex:34-38` (the only explicit availability projection) | Consume MP-R1's capability report; the client rules are in `contracts/client-capability-model.md`. |
| F9 | Separate TS packages are standalone npm projects with path-filtered CI; the root `package.json` has no workspaces | `package.json` (root, only a `setup` script); `packages/streamdeck/package.json`; `.github/workflows/streamdeck-package.yml` | `packages/aiur-mobile` follows the Stream Deck pattern: own `package.json`, own workflow. |
| F10 | Dashboard responsiveness: viewport meta, apple-touch-icon, 20 width breakpoints (320–1024 px), plus `pointer: coarse`, reduced-motion and forced-colors rules | `src/lib/aiur_web/components/layouts.ex:20,23`; `src/priv/static/dashboard.css` (39 `@media`) | WebView reuse is credible for reading. Device validation checks 320–430 px widths (device-validation.md DV-P6). |
| F11 | Instances use a random port by default and their records carry no URL | baseline facts 14 and 16; `aiur-engine.sh:1586` | Each instance is its own WebView origin. MP-N2 must advertise URLs (A2). |

Prior research mapping: **Prior-boundaries:** `WEB` #34 (web-shell / dashboard-ui), `VOX`
#36 (voice), `SD` #35 (the pattern for an out-of-core client). **Prior-units:** none; U0–U9
do not touch clients. U6 (`src/lib/aiur_web/`) touches routes the WebView loads, so
a plan refresh is needed when U6 lands (§10). **Size-owner:** none of the new paths exist.

## 3. Proposed boundaries

### 3.1 Package layout (proposed; nothing exists today)

```text
packages/
  aiur-contracts/              # MP-R1-C3 (owned by MP-R1): JSON Schemas + generated TS types
  aiur-mobile/                 # MP-N1: one Expo app, iOS + Android
    package.json               # standalone, like packages/streamdeck
    app.config.ts              # Expo config; plugins register native targets
    src/
      shell/                   # navigation, WebView host, bridge allow-list
      screens/                 # native screens: machines, meta, command, prefs, diagnostics, demo
      capability/              # client capability model (contracts/client-capability-model.md)
      api/                     # typed client over aiur-contracts; no credentials in JS
    modules/aiur-native/       # Expo module (Swift + Kotlin) wrapping the native cores
    native/
      apple-core/              # Swift package: AiurClientKit (keys, signing, decrypt, models)
      android-core/            # Kotlin library: aiur-client-core (same responsibilities)
    targets/                   # Apple targets via config plugin (S22)
      notification-service/    # iOS NSE (MP-N4 decrypt), links AiurClientKit
      watch/                   # watchOS app (MP-N7), links AiurClientKit
    wear/                      # Gradle project for the Wear OS app (MP-N7), includes android-core
    fixtures/                  # demo-mode data + contract conformance fixtures
```

Required dependencies: `aiur-contracts`, the daemon's web-shell API, `pairing-discovery`
(MP-N2). Optional: `push-relay` (MP-N4), voice (MP-R5/E5/E6), conversations (MP-E4),
build orders. Every optional one is detected through the capability report. The app never
imports Elixir code and never reads monolith internals (MP-R1 rule "R-client",
component-map.md L5).

### 3.2 Public interfaces this package exposes

None to the daemon. It is a leaf client. Internally:

- `AiurNative` Expo module: `pair(qrPayload)`, `listMachines()`, `revokeLocal(machineId)`,
  `signedFetch(instanceId, request)`, `bootstrapWebSession(instanceId) → cookie`,
  `pushToken()`, `watchLink.*` (MP-N7). JS never sees private keys, device credentials or
  push decryption keys (reason R-secret).
- Native cores: one API surface per language, specified by shared conformance fixtures
  in `fixtures/contract/` (§7).

### 3.3 Mapping to MP-R1

MP-R1's component map lists `mobile-app` as `packages/aiur-mobile` and `watch-apps` as
"inside `packages/aiur-mobile` or a sibling, decided by MP-N1". **Decision:** inside
`packages/aiur-mobile` (`targets/watch`, `wear/`). Reasons: the watch apps share the
native cores and the app identifiers. A watchOS app ships inside the iOS app bundle,
and the Wear app must share the phone app's package name for the Data Layer.

## 4. Alternatives and recommendation

Full matrix: framework-evidence.md §4. In short:

| Option | Verdict | Deciding reason |
|---|---|---|
| React Native + Expo CNG + WebView | **Recommended** | Lowest duplication. TS matches the repo and MP-R1's contract types. The native cores keep secrets and watch logic out of JS. |
| Capacitor | Rejected | Remote-origin hosting is "not intended for production" (S24). Web-first raises 4.2 risk. |
| Flutter | Rejected | New language. No watch support (S25). No advantage over RN. |
| Native ×2 | Rejected for the phone UI | Three native surfaces built twice for one maintainer. Kept for the NSE, FCM service and watch apps, where it is unavoidable. |
| KMP + Compose Multiplatform | Runner-up | Kotlin core sharable with Wear OS, but watchOS KMP is Beta (S26), the NSE and watch still need Swift, and there is no Kotlin in the repo. Revisit trigger: native core code > 50% of the mobile LOC after N7-C3. |
| PWA only | Rejected (not evaluated in depth) | No E2E push decryption extension, no watch, no background notification rendering control. Out of the brief's stated targets. |

Why a WebView at all: the dashboard already exists and is responsive (F2, F10). Rebuilding
the instance dashboard natively would fork behaviour that MP-E3/E4 are still defining.

Why not WebView for everything: notifications must open the right Command without
loading a whole dashboard (R-push). The meta-dashboard spans machines (R-multi).
Keys must not be reachable from web content (R-secret). And 4.2 (framework-evidence.md §3).

## 5. Transport and session (cross-feature prerequisites)

The architecture works only if two things owned elsewhere exist. They are recorded
here because MP-N1 is where their absence becomes visible.

1. **Transport security — RQ-TRANSPORT (RC-15; MP-N2 owns with MP-R3).** Settled shape in
   `contracts/pairing-and-instance-registry.md` §8.1 and chunk MP-N2-C10. The owner chooses in
   DESIGN-N2 §transport between **T-A** (publicly trusted certificate files, e.g.
   `tailscale cert`; recommended, discloses the machine name to Certificate Transparency) and
   **T-B** (aiur self-signed certificate with an SPKI pin in the QR). Phase C evidence against
   T-B as the default: WKWebView's server-trust override does not cover WebSockets (Apple DTS,
   <https://developer.apple.com/forums/thread/104376>, accessed 2026-10-06), and `/live` and
   `/voice` are WebSocket-only today (`endpoint.ex:14-29`); Google Play flags unvalidated
   `onReceivedSslError` handlers (<https://support.google.com/faqs/answer/7071387>). The
   HTTP-degraded mode survives only if the owner keeps `transport.allow_cleartext_overlay`.
   N1-RQ1 is answered for T-A by MP-N2-C10-T05 and for T-B by the prototype MP-N1-C9-T01.
   Every N1 ticket that loads a dashboard in a WebView is blocked on RQ-TRANSPORT and
   MP-N2-C10-T01.
2. **Session bootstrap (MP-N2 owns).** A device-credential call that returns the
   per-instance session cookie (`_aiur_key_<instance_key>`; cookies ignore ports, contract §4.4) carrying a `FinancialDataAccess` session marker for one
   instance origin. Native code places it in the WebView cookie store. The shared Basic
   Auth pair is never stored on the phone.

## 6. Contracts

### Owned

- `contracts/client-capability-model.md`: how every client (phone, watch, and by
  extension the dashboard JS and the Stream Deck) discovers capabilities and degrades.

### Consumed (assumptions the coordinator must reconcile)

| ID | Contract (owner) | Assumption N1 needs |
|---|---|---|
| A1 | Pairing credentials (MP-N2) | A per-device credential (an asymmetric key in Keychain/Keystore, or a token) authorizes JSON calls and can mint a WebView session for any instance on the machine (D19). Revocation makes the next call fail with a typed `device_revoked` error. |
| A2 | Pairing / discovery (MP-N2) | A machine endpoint lists instances with `instance_id`, advertised URL, repository and liveness. Instance URLs may change; the app re-resolves by `instance_id`. |
| A3 | Transport (MP-N2/MP-R3) | §5.1. Without HTTPS, N1 runs degraded and says so. |
| A4 | Identity and capabilities (MP-R1) | `GET /api/v1/capabilities` exactly as drafted (`contract_version` 1, `revision`, `freshness`, IDs from capability-matrix.md §2), accepted with the device credential. `system.capabilities.changed` on the MP-R2 external subscription API. |
| A5 | Voice for non-browser clients (MP-E5, MP-R5) | A device-authenticated way to stream 16 kHz mono PCM and receive partial and final transcripts, equivalent to `voice:dictation`, plus a conversation entry point (MP-E6). Raw audio is never retained (D17). If absent, native mic buttons show `unavailable: not_supported_by_server`. |
| A6 | Command request and resolution (MP-E2) | `GET` one Command by `decision_id`, and answer with `expected_version`, `idempotency_key`, `client.surface ∈ {phone, watch}`, `device_id`. A 409 conflict returns the winning answer summary. |
| A7 | Conversations and anchors (MP-E4) | A route form that opens `/chat/...` at an `anchor_id`, and a JSON read of the entries around an anchor for the native Command screen's context excerpt. |
| A8 | Notification payload (MP-N4) | A sealed payload, decryptable by the native core, that yields `{machine_id, instance_id, kind, decision_id?, anchor_id?, short_summary, urgency}`. iOS payloads carry `mutable-content: 1` with a generic placeholder alert. Android uses high-priority data messages that always produce a visible notification (S29). |
| A9 | Event subscription (MP-R2) | An external subscriber API for live counts. If absent, the meta-dashboard polls (client-capability-model.md §6). |

## 7. Code-sharing strategy

| Layer | Shared across | Mechanism |
|---|---|---|
| Wire types | Dashboard JS, Stream Deck, phone JS | `packages/aiur-contracts` generated TS types (MP-R1-C3) |
| Wire types (native) | Apple core, Android core, watch apps | Code generated from the same JSON Schemas, with Swift `Codable` and Kotlin `kotlinx.serialization` models. **N1-RQ2:** pick a generator (for example quicktype) and pin it, or hand-write with conformance fixtures. Either way, a CI check decodes every fixture in `fixtures/contract/` in all three languages. |
| Crypto and signing | Phone app, NSE / FCM service, watch | One native core per platform. Shared **test vectors** (sealed payload → plaintext; request → signature) are the cross-language contract. No crypto in JS. |
| Command response view model | Phone native screen, watch apps | Specified once as a state machine in `contracts/client-capability-model.md` §5 and the MP-E2 contract. Implemented in TS (phone), Swift (watchOS) and Kotlin (Wear). Fixtures drive identical state tests in each. |
| UI | — | Not shared between phone and watch: no framework produces both (framework-evidence.md §5). |
| Dashboard pages | Browser and phone | Same LiveView pages; the phone adds only a native header and the bridge allow-list. |

## 8. Non-happy paths

| Case | Behaviour |
|---|---|
| Machine unreachable (tailnet off, host asleep) | Meta row shows `unreachable` with the last-seen time and age; cached counts are labelled stale, never shown as live. The WebView is not opened; a native "can't reach <label>" screen offers Retry and Diagnostics. |
| Reachable but capability `stale` | Data shown with an age pill (AGENTS.md "if a surface computes an age, it renders the age"). |
| Optional component absent (build orders, voice, push) | The affordance is absent or marked unavailable with the reason. Never a zero or a dead button (client-capability-model.md). |
| Dashboard read-only (`dashboard_writable` false) | Reading works. Answer and send controls show `disabled` with the reason. |
| Device revoked while the app is open | The next call returns `device_revoked`. The app wipes that machine's credential and WebView cookies, keeps nothing cached for it, and shows "This phone was unpaired". |
| Session cookie expired in the WebView | The bridge `session-expired` message, or a 401 on load, makes native code re-bootstrap once, then reload. A second failure shows the pairing error. |
| Notification for a Command already resolved | The native Command screen fetches before rendering options. Resolved Commands show who resolved them and when (MP-E2 conflict data); options are not offered. |
| Duplicate submit (double tap, retry after timeout) | Same `idempotency_key` per submit intent; the server dedupes (A6). The UI shows `sending → delivered | conflict | failed`. |
| Two phones answer at once | First answer wins (D11). The loser sees the winner's summary. |
| App killed or force-quit | Notifications still render through the NSE / FCM service (no app process needed for the NSE; S2). A force-quit iOS app is not relaunched for background pushes (S41), so N1 relies on no background fetch. |
| Device locked since reboot (before first unlock) | Keys stored `AfterFirstUnlockThisDeviceOnly` are unreadable (S5). The NSE shows the generic placeholder ("Aiur needs your attention"). Device validation DV-P3 confirms this. |
| Instance moved (new `instance_key`) | The old row goes stale, then is removed per MP-N2 garbage-collection. A new row appears. |
| Server contract older than the client | Missing capability IDs show `unknown` with "update aiur on <machine>". |
| Client older than the server | Unknown IDs are ignored. If the server's `min_client_version` (proposed to MP-R1) exceeds the app's, a "Update the app" banner appears and writes are blocked. |
| Privacy | JS never holds keys. WebView navigation is confined to the instance origin. Logs exclude bodies and tokens. Cloud voice processing is disclosed separately from push privacy (brief §7). |

## 9. Acceptance criteria (feature level)

- AC1. One codebase builds signed iOS and Android apps from `packages/aiur-mobile` with a documented local command (no paid cloud build service required).
- AC2. With no paired machine, the app shows the first-run pairing flow; with demo mode enabled, it shows synthetic instances and every native surface.
- AC3. After pairing, every instance on the machine appears. Tapping one loads its dashboard in the WebView without any password prompt.
- AC4. A capability that the server reports `unavailable` is never rendered as zero or as a working control (fixture tests per capability state).
- AC5. Unreachable, stale and unavailable render as three distinct states (fixture tests plus DV-P5).
- AC6. JS bundle and WebView never receive a private key, device credential or Basic Auth pair (static check: no such strings cross the `AiurNative` boundary; a test asserts the module API).
- AC7. WebView navigation outside the instance origin opens the system browser (test with a GitHub link).
- AC8. The contract fixture suite decodes in TS, Swift and Kotlin in CI.
- AC9. Every row in device-validation.md marked "required" passes on physical devices before N1 is called complete.
- AC10. DESIGN-N1 is approved before any N1 implementation ticket starts.

## 10. Plan-refresh note (refactor MP-R1..R7)

MP-N1 lands after the refactor (wave 5). When the refactor merges, refresh:

- Route and module paths cited here (`router.ex`, `financial_data_access.ex`, `voice_socket.ex`, `endpoint.ex`) move to `aiur_web_shell` and `aiur_web` (MP-R1 component map rows `web-shell`, `dashboard-ui`). Update citations; the URLs are unchanged by design.
- The `/api/v1/capabilities` path and the capability IDs come from MP-R1-C3. Confirm the final names in `packages/aiur-contracts`.
- U6 (`src/lib/aiur_web/`) may change dashboard markup that the WebView hosts. No N1 code depends on markup, but the bridge messages (surface-boundary.md §2) need a dashboard-side ticket that U6 must not drop.
- If MP-R2's external subscription API ships as a websocket, note that watchOS cannot use it (S7). Only the phone subscribes.

## 11. Proposed feasibility prototype (NOT authorised)

A disposable, out-of-repo spike (about 2–3 days, no paid services): an Expo SDK 57 app
with an NSE via `expo-apple-targets` that decrypts a test-vector payload sent with
`curl` to APNs (sandbox), a `react-native-webview` loading a local LiveView over HTTPS
with a pinned self-signed certificate, and a SwiftUI watch target receiving a
WatchConnectivity message. It exists only to validate S22, S23 and N1-RQ1 before
Phase C freezes tickets. It needs Kevin's explicit authorisation, an Apple developer
account and a physical iPhone and Apple Watch.

## 12. Open questions

### Owner (Kevin)

- **OQ-N1-1.** Distribution: private only (internal TestFlight and Play internal testing, ≤100 testers each, S18 and S28), or public store listings? Public listings require a demo mode for review (2.1(a)) and add review risk under 4.2.
- **OQ-N1-2.** Minimum OS versions. Proposal: iOS 17+ and Android 10+ (API 29). Owner to confirm against owned devices.
- **OQ-N1-3.** Confirm the surface split in surface-boundary.md (DESIGN-N1).
- **OQ-N1-4.** Which devices are available for physical validation (iPhone model, Apple Watch model, Android phone, Wear OS watch)?

### Research (Phase C)

- **N1-RQ1.** Pinned self-signed TLS in both WebViews (§5).
- **N1-RQ2.** Schema-to-Swift/Kotlin generator choice.
- **N1-RQ3.** Expo CNG plus `expo-apple-targets`: does a watch target plus an NSE target survive `expo prebuild --clean` with app-group and keychain-group entitlements intact?
- **N1-RQ4.** NSE memory headroom for the chosen crypto library (Apple does not state the limit on the pages read; measure on device).
- **N1-RQ5.** The Android WebView cookie API for injecting the bootstrap session per origin, and its behaviour across process death.
