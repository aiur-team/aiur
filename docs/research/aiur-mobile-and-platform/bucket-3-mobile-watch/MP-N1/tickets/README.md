# MP-N1 tickets — cross-platform phone app

Base `45a290e3`, researched 2026-10-06. **31 tickets, all `blocked`** (DESIGN-N1 is open, MP-REQ2).
MP-N1 is delivery wave 5. The **wave** column is the length of the longest dependency chain
through MP-N1, MP-N2, MP-N3 and MP-N7 tickets (1 = no predecessor inside that group); tickets in
the same wave with no edge between them may run concurrently once their gates open.

| ID | Title | Status | Blocked by | Wave |
|---|---|---|---|---|
| [MP-N1-C1-T01](MP-N1-C1-T01.md) | Create the packages/aiur-mobile Expo app skeleton with pinned versions, tests and a local- | blocked | DESIGN-N1, MP-R1-C3-T6 | 1 |
| [MP-N1-C9-T01](MP-N1-C9-T01.md) | PROPOSAL — Expo throwaway feasibility prototype (out of repo; NOT authorized; requires Kev | blocked | OWNER-AUTH-N1-PROTO, DESIGN-N1 | 1 |
| [MP-N1-C1-T02](MP-N1-C1-T02.md) | Add the path-filtered mobile-package CI workflow (Android on Linux, iOS on macOS, no signi | blocked | DESIGN-N1, MP-N1-C1-T01 | 2 |
| [MP-N1-C1-T03](MP-N1-C1-T03.md) | Wire expo-apple-targets with the shared app-group and keychain-group entitlements and prov | blocked | DESIGN-N1, MP-N1-C1-T01, OQ-N1-1 | 2 |
| [MP-N1-C2-T02](MP-N1-C2-T02.md) | Android native core (aiur-client-core) — Keystore device auth key per machine and Keystore | blocked | DESIGN-N1, MP-N1-C1-T01 | 2 |
| [MP-N1-C3-T01](MP-N1-C3-T01.md) | TypeScript affordance resolver — precedence table, version handling and the shared fixture | blocked | DESIGN-N1, MP-N1-C1-T01, MP-R1-C3-T6 | 2 |
| [MP-N1-C4-T01](MP-N1-C4-T01.md) | Native navigation skeleton and typed in-app route table (internal aiur:// scheme for notif | blocked | DESIGN-N1, MP-N1-C1-T01 | 2 |
| [MP-N1-C2-T01](MP-N1-C2-T01.md) | Apple native core (AiurClientKit) — shared-keychain store and per-machine Secure Enclave d | blocked | DESIGN-N1, MP-N1-C1-T03 | 3 |
| [MP-N1-C2-T04](MP-N1-C2-T04.md) | Generate Swift and Kotlin wire models from aiur-contracts JSON Schemas (quicktype, pinned) | blocked | DESIGN-N1, MP-N1-C1-T02, MP-N1-C2-T01, MP-N1-C2-T02, MP-R1-C3-T6 | 4 |
| [MP-N1-C3-T03](MP-N1-C3-T03.md) | Swift and Kotlin ports of the affordance resolver in the native cores, driven by the same  | blocked | DESIGN-N1, MP-N1-C3-T01, MP-N1-C2-T04 | 5 |
| [MP-N1-C2-T03](MP-N1-C2-T03.md) | Device-side pairing and token protocol in both native cores (QR verify, claim/relink, chal | blocked | DESIGN-N1, MP-N1-C2-T01, MP-N1-C2-T02, MP-N2-C5-T05, MP-N2-C5-T03, MP-N2-C5-T04 | 13 |
| [MP-N1-C2-T05](MP-N1-C2-T05.md) | AiurNative Expo module — the only JS-visible API over the native cores, with no secret-ret | blocked | DESIGN-N1, MP-N1-C2-T03, MP-N1-C2-T04 | 14 |
| [MP-N1-C3-T04](MP-N1-C3-T04.md) | Native watch snapshot builder — compact per-instance Facts plus pre-resolved affordances,  | blocked | DESIGN-N1, DESIGN-N7, MP-N1-C3-T03, MP-N1-C2-T03, MP-N3-C2-T01, MP-N3-C3-T01, MP-N3-C3-T02 | 14 |
| [MP-N1-C3-T02](MP-N1-C3-T02.md) | Capability cache and refresh policy keyed by instance_id, boot_id and revision, with typed | blocked | DESIGN-N1, MP-N1-C3-T01, MP-N1-C2-T05, MP-R1-C3-T3, MP-R1-C3-T5, MP-N2-C6-T01 | 15 |
| [MP-N1-C5-T01](MP-N1-C5-T01.md) | Reachability probe and typed transport-error classification in both native cores and the T | blocked | DESIGN-N1, RQ-TRANSPORT, MP-N2-C10-T01, MP-N2-C10-T02, MP-N1-C2-T03, MP-N1-C2-T05, MP-N1-C3-T01 | 15 |
| [MP-N1-C6-T01](MP-N1-C6-T01.md) | Push plumbing in the app shell: aps-environment and FCM build config, native device-token  | blocked | DESIGN-N1, DESIGN-N4, MP-N1-C1-T03, MP-N1-C2-T05, MP-N1-C4-T01, OQ-N4-1 | 15 |
| [MP-N1-C4-T02](MP-N1-C4-T02.md) | Instance WebView host with native device-session bootstrap into the platform cookie store  | blocked | DESIGN-N1, RQ-TRANSPORT, MP-N2-C10-T01, MP-N2-C6-T02, MP-N1-C4-T01, MP-N1-C2-T05, MP-N1-C3-T02 | 16 |
| [MP-N1-C5-T03](MP-N1-C5-T03.md) | Connection diagnostics screen (per machine and instance) plus a debug-build key-state sect | blocked | DESIGN-N1, MP-N1-C5-T01, MP-N1-C4-T01, MP-N1-C3-T02, MP-N1-C2-T05 | 16 |
| [MP-N1-C7-T01](MP-N1-C7-T01.md) | Demo mode data layer: fixture-backed adapter behind the same typed client (conditional on  | blocked | DESIGN-N1, "OQ-N1-1 (= public listing)", "D-N1-7", MP-N1-C2-T05, MP-N1-C3-T02, MP-N3-C3-T02, MP-N3-C5-T01, MP-N6-C1-T01 | 16 |
| [MP-N1-C8-T01](MP-N1-C8-T01.md) | Signing and provisioning runbook plus a local signed-build script (credentials stay in the | blocked | DESIGN-N1, OQ-N1-1, OQ-N4-1, MP-N1-C1-T02, MP-N1-C1-T03, MP-N1-C6-T01 | 16 |
| [MP-N1-C10-T01](MP-N1-C10-T01.md) | Physical-device validation: notification shell rows DV-P1–P4, DV-P11, DV-P12 (run with MP- | blocked | DESIGN-N1, DESIGN-N4, MP-N1-C6-T01, MP-N4-C4-T02, MP-N4-C5-T02, MP-N6-C2-T02, MP-N1-C8-T01, OQ-N1-4, OQ-N4-1 | 17 |
| [MP-N1-C4-T03](MP-N1-C4-T03.md) | WebView origin confinement (external links to the system browser) and the allow-listed Web | blocked | DESIGN-N1, RQ-TRANSPORT, MP-N2-C10-T01, MP-N1-C4-T02 | 17 |
| [MP-N1-C4-T06](MP-N1-C4-T06.md) | Native header over WebView pages — Back, instance name, freshness pill with age, capabilit | blocked | DESIGN-N1, DESIGN-N3, DESIGN-E3, RQ-TRANSPORT, MP-N2-C10-T01, MP-N1-C4-T02, MP-N1-C3-T02 | 17 |
| [MP-N1-C5-T02](MP-N1-C5-T02.md) | HTTP-degraded mode: build-time cleartext exceptions scoped to tailnet names, runtime allow | blocked | DESIGN-N1, DESIGN-N2, "RQ-TRANSPORT (DESIGN-N2 §transport keeps allow_cleartext_overlay)", MP-N2-C10-T02, MP-N1-C2-T03, MP-N1-C4-T02, MP-N1-C5-T01, MP-N1-C9-T01, OQ-N1-1 | 17 |
| [MP-N1-C5-T04](MP-N1-C5-T04.md) | Option T-B client: SPKI pin enforcement in native HTTP clients and both WebViews (no blank | blocked | DESIGN-N1, DESIGN-N2, "RQ-TRANSPORT (DESIGN-N2 §transport = T-B)", MP-N1-C9-T01, MP-N2-C10-T04, MP-N1-C2-T03, MP-N1-C4-T02, MP-N1-C5-T01 | 17 |
| [MP-N1-C8-T03](MP-N1-C8-T03.md) | Manual-dispatch release-configuration CI dry run (unsigned) for iOS and Android | blocked | DESIGN-N1, MP-N1-C1-T02, MP-N1-C8-T01 | 17 |
| [MP-N1-C4-T04](MP-N1-C4-T04.md) | Dashboard-side native bridge emitter (feature-detected; no behaviour change in a browser) | blocked | DESIGN-N1, DESIGN-N6, MP-N1-C4-T03 | 18 |
| [MP-N1-C7-T02](MP-N1-C7-T02.md) | Demo mode entry point and a persistent Demo badge | blocked | DESIGN-N1, DESIGN-N2, "OQ-N1-1 (= public listing)", "D-N1-7", MP-N1-C7-T01, MP-N1-C4-T06, MP-N3-C4-T01, MP-N6-C3-T01 | 18 |
| [MP-N1-C8-T02](MP-N1-C8-T02.md) | Privacy disclosures: App Store privacy details and manifest, Play Data safety, in-app priv | blocked | DESIGN-N1, OQ-N1-1, MP-N4-C3-T06, MP-E6-C2-T2, MP-N1-C6-T01, MP-N1-C5-T02 | 18 |
| [MP-N1-C4-T05](MP-N1-C4-T05.md) | WebView microphone permission — grant capture only to the paired instance origin, OS permi | blocked | DESIGN-N1, DESIGN-E5, RQ-TRANSPORT, MP-N2-C10-T01, MP-N1-C4-T03, MP-N1-C4-T04 | 19 |
| [MP-N1-C10-T02](MP-N1-C10-T02.md) | Physical-device validation: app shell rows DV-P6–DV-P10 and DV-P13 (WebView, mic, conflict | blocked | DESIGN-N1, RQ-TRANSPORT, MP-N2-C10-T01, MP-N2-C10-T05, MP-N1-C4-T02, MP-N1-C4-T03, MP-N1-C4-T05, MP-N1-C5-T03, MP-N2-C7-T01, MP-N6-C3-T02, MP-E5-C1-T2, MP-N1-C8-T01, OQ-N1-4 | 20 |

## Dependency order (summary)

```text
DESIGN-N1 ─► C1-T01 ─► C1-T02, C1-T03, C2-T02, C3-T01, C4-T01
C1-T03 ─► C2-T01 ─┐
C2-T02 ───────────┼─► C2-T03 (MP-N2-C5 vectors) ─► C2-T05 (AiurNative) ─► C3-T02 ─► C4-T02 (WebView host)
C2-T04 (models) ──┘                                                       │
C3-T01 ─► C3-T03 ─► C3-T04 (watch snapshot)                               ├─► C4-T03 ─► C4-T04 ─► C4-T05
                                                                          └─► C4-T06, C5-T01 ─► C5-T02/T03/T04
C6-T01 (push plumbing) ─► C8-T01 ─► C8-T03; C8-T02 ; C10-T01/T02 (devices) last
C9-T01 prototype: proposal only; runs only if Kevin authorizes it (OWNER-AUTH-N1-PROTO)
```

Every ticket that loads a dashboard in a WebView (C4-T02, C4-T03, C4-T05, C4-T06, C5-T01,
C5-T02, C5-T04, C10-T02) is also blocked on **RQ-TRANSPORT** and **MP-N2-C10-T01** (RC-15).

## Conditional tickets

- C5-T02 only if DESIGN-N2 §transport keeps the HTTP-degraded mode; C5-T04 only if it chooses T-B.
- C7-T01/T02 only if OQ-N1-1 = public store listing.
- C9-T01 only with explicit owner authorization.

## What may run concurrently

- C1-T02, C1-T03, C2-T02, C3-T01, C4-T01 after C1-T01.
- Native cores (C2-T01/T02) in parallel; C3-T01 (TS resolver) in parallel with all of C2.
- C6-T01 and C8-T01/T02 in parallel with C4/C5 once their own predecessors land.

## Research questions

Resolved in tickets: N1-RQ2 (C2-T04 quicktype), N1-RQ3 (C1-T03), N1-RQ5 (C4-T02 via one-time
device-session URL). Open, assigned: N1-RQ1 (MP-N2-C10-T05 for T-A; C9-T01 for T-B), N1-RQ4 (NSE
memory; MP-N4 device rows), **N1-RQ6** (Android `onPermissionRequest` origin check; C4-T05),
**N1-RQ7** (iOS `ts.net` / `NSAllowsLocalNetworking` HTTP to MagicDNS and 100.x; Android
`domain-config` in WebView; C9-T01 P8 or MP-N2-C10-T05 TR-7).

Contract requests: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).
