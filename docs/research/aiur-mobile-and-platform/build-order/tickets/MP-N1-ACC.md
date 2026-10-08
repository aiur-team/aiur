# MP-N1-ACC — MP-N1 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-N1-C3-T04, MP-N1-C5-T04, MP-N1-C7-T02, MP-N1-C8-T02, MP-N1-C8-T03, MP-N1-C10-T01, MP-N1-C10-T02

## Outcome

The Executor proves MP-N1 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-N1/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (31)

- MP-N1-C1-T01 — Create the packages/aiur-mobile Expo app skeleton with pinned versions, tests and a local-build guide page
- MP-N1-C1-T02 — Add the path-filtered mobile-package CI workflow (Android on Linux, iOS on macOS, no signing)
- MP-N1-C1-T03 — Wire expo-apple-targets with the shared app-group and keychain-group entitlements and prove they survive prebuild --clean (resolves N1-RQ3)
- MP-N1-C2-T01 — Apple native core (AiurClientKit) — shared-keychain store and per-machine Secure Enclave device auth key
- MP-N1-C2-T02 — Android native core (aiur-client-core) — Keystore device auth key per machine and Keystore-wrapped secret file
- MP-N1-C2-T03 — Device-side pairing and token protocol in both native cores (QR verify, claim/relink, challenge signing, token refresh, endpoint failover) against MP-N2 vectors
- MP-N1-C2-T04 — Generate Swift and Kotlin wire models from aiur-contracts JSON Schemas (quicktype, pinned) with a three-language fixture decode check (resolves N1-RQ2, AC8)
- MP-N1-C2-T05 — AiurNative Expo module — the only JS-visible API over the native cores, with no secret-returning method and host-restricted signedFetch (AC6)
- MP-N1-C3-T01 — TypeScript affordance resolver — precedence table, version handling and the shared fixture table of the client capability model
- MP-N1-C3-T02 — Capability cache and refresh policy keyed by instance_id, boot_id and revision, with typed write-error patching
- MP-N1-C3-T03 — Swift and Kotlin ports of the affordance resolver in the native cores, driven by the same fixture table
- MP-N1-C3-T04 — Native watch snapshot builder — compact per-instance Facts plus pre-resolved affordances, under a size budget
- MP-N1-C4-T01 — Native navigation skeleton and typed in-app route table (internal aiur:// scheme for notification routing only)
- MP-N1-C4-T02 — Instance WebView host with native device-session bootstrap (native POST → bootstrap_path → WebView navigation) and one silent re-bootstrap on 401
- MP-N1-C4-T03 — WebView origin confinement (external links to the system browser) and the allow-listed WebView-to-native message bridge
- MP-N1-C4-T04 — Dashboard-side native bridge emitter (feature-detected; no behaviour change in a browser)
- MP-N1-C4-T05 — WebView microphone permission — grant capture only to the paired instance origin, OS permission flow on both platforms
- MP-N1-C4-T06 — Native header over WebView pages — Back, instance name, freshness pill with age, capability-gated Executor-chat button
- MP-N1-C5-T01 — Reachability probe and typed transport-error classification in both native cores and the TS client
- MP-N1-C5-T02 — HTTP-degraded mode: build-time cleartext exceptions scoped to tailnet names, runtime allow-list of paired hosts, persistent warning, WebView mic off
- MP-N1-C5-T03 — Connection diagnostics screen (per machine and instance) plus a debug-build key-state section
- MP-N1-C5-T04 — Option T-B client: SPKI pin enforcement in native HTTP clients and both WebViews (no blanket trust)
- MP-N1-C6-T01 — Push plumbing in the app shell: aps-environment and FCM build config, native device-token getter, hand-off points for MP-N4 and MP-N6
- MP-N1-C7-T01 — Demo mode data layer: fixture-backed adapter behind the same typed client (conditional on a public listing)
- MP-N1-C7-T02 — Demo mode entry point and a persistent Demo badge
- MP-N1-C8-T01 — Signing and provisioning runbook plus a local signed-build script (credentials stay in the operator's keychain)
- MP-N1-C8-T02 — Privacy disclosures: App Store privacy details and manifest, Play Data safety, in-app privacy text separating push privacy from cloud voice
- MP-N1-C8-T03 — Manual-dispatch release-configuration CI dry run (unsigned) for iOS and Android
- MP-N1-C9-T01 — PROPOSAL — Expo throwaway feasibility prototype (out of repo; NOT authorized; requires Kevin's explicit go-ahead)
- MP-N1-C10-T01 — Physical-device validation: notification shell rows DV-P1–P4, DV-P11, DV-P12 (run with MP-N4-C7)
- MP-N1-C10-T02 — Physical-device validation: app shell rows DV-P6–DV-P10 and DV-P13 (WebView, mic, conflicts, revocation, network transition, battery)

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
