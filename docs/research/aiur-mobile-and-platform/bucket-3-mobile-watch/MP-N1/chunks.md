---
feature_id: MP-N1
base_main_sha: 45a290e3
date: 2026-10-06
gate: every ticket below is blocked on DESIGN-N1 (owner-design-tasks/DESIGN-N1.md)
---

# MP-N1 — chunks and candidate tickets

Every ticket is **blocked by DESIGN-N1**. Tickets that render Command, pairing,
meta-dashboard or notification UI are also blocked by the design gate of the
feature that owns that surface (DESIGN-N2, N3, N4, N6). Ticket IDs are candidates
for Phase C, which writes the full brief §9 ticket bodies.

Dependency notation: `→` means "must finish first".

## N1-C1 — Package scaffold and build pipeline

- **Outcome:** `packages/aiur-mobile` exists as a standalone Expo SDK 57 (or the then-current) app with TypeScript strict mode, lint, unit tests, and reproducible local iOS and Android debug builds. A path-filtered CI workflow builds Android on Linux and iOS on macOS runners.
- **Depends on:** DESIGN-N1. Cross-feature: `packages/aiur-contracts` (MP-R1-C3) for types; can start with a stub copy if R1-C3 lags, behind a single import path.
- **Tickets:**
  - N1-C1-T1 Create the Expo app skeleton, TS config, ESLint, Vitest or Jest, matching `packages/streamdeck` conventions.
  - N1-C1-T2 Add `.github/workflows/mobile-package.yml`: path filter `packages/aiur-mobile/**`, Android assemble on `ubuntu-latest`, iOS `xcodebuild` on the macOS runner already used by `release-npm.yml` (`macos-14`, `release-npm.yml:179`). No signing in CI for PRs.
  - N1-C1-T3 Document local build commands in `website/docs-app/guide/` (a new mobile page added to the sidebar, per AGENTS.md "Docs ship with the change").
  - N1-C1-T4 Pin the RN, Expo, `react-native-webview` and `expo-apple-targets` versions, and add an upgrade note template.
- **Tests:** CI builds both platforms from a clean checkout; `npm test` runs at least one rendering test; a test asserts the workflow's path filter.
- **Open research:** N1-RQ3 (prebuild with extra targets).

## N1-C2 — Native cores and the `AiurNative` module

- **Outcome:** Swift package `AiurClientKit` and Kotlin library `aiur-client-core` provide key storage (Keychain with a shared access group; Android Keystore), request signing per the MP-N2 contract, sealed-payload decryption per MP-N4, and contract models. An Expo module exposes only the non-secret API in plan.md §3.2.
- **Depends on:** N1-C1; the MP-N2 credential contract (A1); the MP-N4 payload contract (A8); N1-RQ2 (generator).
- **Tickets:**
  - N1-C2-T1 Apple core: keychain wrapper with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and an access group shared with the NSE and the watch-broker code.
  - N1-C2-T2 Android core: Keystore-backed key wrapper; encrypted preferences for non-key secrets.
  - N1-C2-T3 Sealed-payload decrypt in both cores against shared test vectors (fixtures from MP-N4).
  - N1-C2-T4 Request signing in both cores against shared vectors (fixtures from MP-N2).
  - N1-C2-T5 Generated models plus the cross-language fixture decode check (AC8).
  - N1-C2-T6 `AiurNative` Expo module with an API test asserting no secret-returning method exists (AC6).
- **Tests:** XCTest and JUnit run the same vectors; CI fails if any vector disagrees; mutation check: corrupt one vector byte and confirm both suites fail (AGENTS.md "Tests must fail without the production change").
- **Open research:** N1-RQ2, N1-RQ4.

## N1-C3 — Client capability model (implements the owned contract)

- **Outcome:** a TS module (and Swift and Kotlin equivalents for the watch broker) that turns the capability report, reachability, pairing state and local permissions into affordance states (`contracts/client-capability-model.md`).
- **Depends on:** N1-C1; MP-R1 capability report (A4). Swift/Kotlin parts depend on N1-C2.
- **Tickets:**
  - N1-C3-T1 Capability cache keyed by `instance_id` + `revision` + `boot_id`, with the refresh triggers from the contract §6.
  - N1-C3-T2 Affordance resolver: the precedence table from contract §4, driven by fixtures.
  - N1-C3-T3 Version handling: unknown IDs ignored; missing IDs → `unknown`; `min_client_version` → `needs_update`.
  - N1-C3-T4 Typed write-error mapping (`device_revoked`, capability errors, 409 conflict) into cache updates.
  - N1-C3-T5 Watch snapshot projection (the payload the phone sends to the watch; contract §7).
- **Tests:** a fixture per state × affordance. Unknown-path mutation: replace the `unknown` branch with `available` and with `0` and confirm tests fail (AGENTS.md last bullet of the test rules).

## N1-C4 — Shell, navigation and WebView host

- **Outcome:** native navigation (machines → meta-dashboard → instance WebView, with native Command and settings screens), the WebView host with session bootstrap, origin confinement and the bridge allow-list (surface-boundary.md §2).
- **Depends on:** N1-C2, N1-C3; MP-N2 session bootstrap (A1) and transport (A3); a dashboard-side ticket for the bridge (below).
- **Tickets:**
  - N1-C4-T1 Navigation skeleton and in-app route table (`aiur://` internal scheme for notification routing only).
  - N1-C4-T2 WebView host: per-instance origin, cookie injection from `bootstrapWebSession`, re-bootstrap once on `session-expired` or 401.
  - N1-C4-T3 Origin confinement: external links to the system browser (AC7).
  - N1-C4-T4 Bridge allow-list (`open-native-command`, `session-expired`, `request-mic-permission`); drop and log others.
  - N1-C4-T5 **Dashboard-side** (Elixir/JS, owned by dashboard-ui): emit the bridge messages only when `window.ReactNativeWebView` exists; no behaviour change in a browser. Needs a DESIGN-N1 sign-off line, since it touches the dashboard.
  - N1-C4-T6 WebView media-capture permission delegate (iOS `requestMediaCapturePermissionFor`, S17; Android `onPermissionRequest`) granting the mic only to the paired instance origin.
- **Tests:** component tests for routing; a WebView integration test against the fixture dashboard (memory: the OCC dashboard local parity fixture runs the dashboard with synthetic data); DV-P6, DV-P7, DV-P9, DV-P11.

## N1-C5 — Connection diagnostics and degraded transport

- **Outcome:** a native diagnostics screen and the reachability probe that distinguishes `unreachable`, `tls_mismatch`, `http_degraded`, `device_revoked`, `version_mismatch`.
- **Depends on:** N1-C3, N1-C4; A3.
- **Tickets:**
  - N1-C5-T1 Probe: capability fetch with timeout; classify transport errors without collapsing them into one cause (AGENTS.md "a collapsed cause names the collapse at the source").
  - N1-C5-T2 HTTP-degraded mode: ATS and cleartext exceptions only for the paired hosts, with the mic-unavailable explanation; review justification text drafted for OQ-N1-1.
  - N1-C5-T3 Diagnostics screen (DESIGN-N1 states).
- **Tests:** unit tests per error class; DV-P5.
- **Open research:** N1-RQ1.

## N1-C6 — Notification plumbing (client side of MP-N4)

- **Outcome:** the iOS NSE target and the Android `FirebaseMessagingService` decrypt via the native cores and post the notification. Taps route into the app. MP-N4 owns the payload and relay; N1-C6 owns the in-app wiring.
- **Depends on:** N1-C2; MP-N4 contract (A8); DESIGN-N4 for presentation.
- **Tickets:**
  - N1-C6-T1 NSE target via config plugin; app group and keychain group entitlements; placeholder-on-failure.
  - N1-C6-T2 Android FCM service: decrypt, always post a visible notification (avoid deprioritization, S29), channel set-up, `POST_NOTIFICATIONS` request flow (S30).
  - N1-C6-T3 Tap routing: decrypted destination → N1-C4 route.
  - N1-C6-T4 Push token registration hand-off to MP-N2/N4 (token sent through the signed client).
- **Tests:** unit tests against vectors; DV-P1–P4, DV-P11, DV-P12.

## N1-C7 — Demo mode (conditional on OQ-N1-1 = public listing)

- **Outcome:** a self-contained synthetic machine with instances, Commands and conversations, exercising every native surface without a daemon, for App Review 2.1(a).
- **Depends on:** N1-C3, N1-C4, and the native screens from N3 and N6.
- **Tickets:**
  - N1-C7-T1 Fixture-backed API adapter behind the same typed client.
  - N1-C7-T2 Demo entry point and a persistent "Demo" badge so demo data is never confused with live data.
- **Tests:** the full UI test suite runs in demo mode.

## N1-C8 — Release and distribution

- **Outcome:** signed builds distributed to the chosen channels (internal TestFlight and Play internal testing at minimum), with privacy disclosures (App Store privacy labels, Play data safety) that separate push transport privacy from opted-in cloud voice processing (brief §7).
- **Depends on:** N1-C1..C6; OQ-N1-1.
- **Tickets:**
  - N1-C8-T1 Signing and provisioning runbook (no secrets in the repo; credentials in the operator's keychain).
  - N1-C8-T2 Privacy disclosures text, reviewed against MP-N4 (what the relay sees) and MP-E6 (voice provider).
  - N1-C8-T3 Release workflow (manual dispatch), modelled on `streamdeck-package.yml` channels.
- **Tests:** a dry-run build in CI; the device-validation matrix on the release candidate (AC9).

## Chunk dependency graph

```text
DESIGN-N1 ─► N1-C1 ─► N1-C2 ─► N1-C3 ─► N1-C4 ─► N1-C5
                         │                 │
                         └──────► N1-C6 ◄──┘   (also needs MP-N4 contract)
                                   N1-C7 (needs N3/N6 screens; conditional)
                                   N1-C8 (after C1–C6)
Cross-feature: MP-R1-C3 (contracts, capabilities) → N1-C1/C3; MP-N2 → N1-C2/C4/C5;
MP-N4 → N1-C2/C6; MP-E2 → native Command screen (MP-N6); MP-N7 consumes N1-C2/C3.
```

## Open research handed to Phase C

N1-RQ1 (pinned TLS in WebViews), N1-RQ2 (schema generator), N1-RQ3 (prebuild with
targets), N1-RQ4 (NSE memory), N1-RQ5 (Android WebView cookie injection).

## Phase C final tickets (2026-10-06)

Ticket bodies and the dependency table are in [tickets/README.md](tickets/README.md).
Candidate → final mapping:

- **C1:** T1+T3+T4 → C1-T01 (skeleton, pins, Jest, guide page); T2 → C1-T02 (CI); new C1-T03
  (expo-apple-targets with app-group and keychain-group entitlements; settles N1-RQ3).
- **C2:** T1 → C2-T01; T2 → C2-T02 (Keystore-wrapped vault file; androidx security-crypto is
  deprecated); T3 (decrypt) **moved to MP-N4-C4/C5**; T4 widened to the full pairing and token
  protocol → C2-T03 (vectors from MP-N2-C5-T05, contract §4.0); T5 → C2-T04 (quicktype; settles
  N1-RQ2); T6 → C2-T05 (`AiurNative`; `bootstrapWebSession` returns nothing to JS).
- **C3:** T2+T3 → C3-T01 (resolver); T1+T4 → C3-T02 (cache, typed errors incl. `device_revoked`);
  new C3-T03 (Swift and Kotlin resolver ports, because the watch broker runs without JS); T5 → C3-T04.
- **C4:** T1 → C4-T01; T2 → C4-T02 (session via one-time `/device-session/<code>`, MP-N2-C6-T02;
  settles N1-RQ5); T3+T4 → C4-T03; T5 → C4-T04; T6 → C4-T05 (new N1-RQ6: Android
  `onPermissionRequest` origin check); new C4-T06 (native header, D-N1-5).
- **C5:** T1 → C5-T01; T2 → C5-T02 (conditional on the owner keeping the HTTP-degraded mode;
  new N1-RQ7); T3 → C5-T03; new C5-T04 (T-B client pinning; conditional on DESIGN-N2 §transport = T-B).
- **C6:** collapsed to C6-T01 (entitlements, FCM build config, `pushToken()`, open callback). NSE
  target → C1-T03 + MP-N4-C4; FCM service body → MP-N4-C5-T02; tap routing → MP-N6-C2-T02; token
  registration → MP-N4-C4-T05/C5-T05.
- **C7:** unchanged, conditional on OQ-N1-1 = public listing.
- **C8:** unchanged; signing stays local, no secrets in CI.
- **New C9:** C9-T01, the throwaway Expo prototype — a **proposal blocked on owner authorization**
  (`OWNER-AUTH-N1-PROTO`), never executed by an implementer without it.
- **New C10:** device validation. C10-T01 (DV-P1–P4, P11, P12, with MP-N4-C7), C10-T02 (DV-P6–P10,
  P13). DV-P5 is in MP-N3-C4-T06; transport rows are in MP-N2-C10-T05; watch rows in MP-N7-C6.
- **RC-15:** every ticket that loads a dashboard in a WebView is blocked on RQ-TRANSPORT and
  MP-N2-C10-T01.
