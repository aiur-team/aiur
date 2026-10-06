---
ticket_id: MP-N1-C9-T01
feature_id: MP-N1
chunk_id: MP-N1-C9
bucket: 3-mobile-watch
title: "PROPOSAL — Expo throwaway feasibility prototype (out of repo; NOT authorized; requires Kevin's explicit go-ahead)"
status: blocked
blocked_by: [OWNER-AUTH-N1-PROTO, DESIGN-N1]
prior_units: []
prior_boundaries: []
prior_features: [MP-N2, MP-N4, MP-N7]
prior_findings: [RC-15, N1-RQ1, N1-RQ3, N1-RQ4, N1-RQ5, N1-RQ6, N1-RQ7]
size_owner: n/a (out-of-repo spike; no production code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C9-T01 — Feasibility prototype (proposal only)

> **This ticket is a proposal.** Brief §2 Phase D: "Propose any executable prototype or paid
> validation experiment separately rather than treating it as implicitly authorized." No agent or
> implementer may start it until Kevin records `OWNER-AUTH-N1-PROTO: approved <date>` in
> `owner-design-tasks/DESIGN-N1.md` (or in this ticket), including approval of the Apple Developer
> Program cost if no account exists.

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C9 "Feasibility prototype".
- **User value:** the framework recommendation (React Native + Expo CNG, WebView dashboards, native
  NSE and watch targets) and the transport choice (RQ-TRANSPORT) are proven on real devices before
  ~70 tickets are built on them. A failure here is cheap; the same failure after MP-N1-C1..C4 is not.
- **Deliverable:** a disposable app in a **separate private repository or local directory** (not in
  `aiur`), and a findings report committed to the research pack
  (`bucket-3-mobile-watch/MP-N1/prototype-findings.md`) with one PASS/FAIL/INCONCLUSIVE row per
  question below, device, OS build, and evidence (screenshots, logs, timings with counts).
- **Non-goals:** reusable code (the prototype is deleted after the report); store submission;
  Android watch (Wear) beyond a build check.

## Dependencies and blockers

- **OWNER-AUTH-N1-PROTO** (owner authorization; open). DESIGN-N1 (only to confirm the questions are
  still the right ones).
- Resources: an Apple Developer Program team (paid; also OQ-N4-1), a Mac with current Xcode, a
  physical iPhone and a paired Apple Watch, an Android 13+ phone with Play services; one aiur machine
  on a tailnet. No paid cloud build service (plan AC1).
- Effort estimate: 2–3 working days (plan §11).
- Blocks: MP-N2-C10-T04 (T-B server), MP-N1-C5-T02 (degraded mode), MP-N1-C5-T04 (T-B client);
  informs MP-N1-C1-T03 (N1-RQ3) and MP-N1-C4-T02/T05.

## Verified starting point (base `45a290e3`)

- `/live`, `/streamdeck`, `/voice` are WebSocket-only (`src/lib/aiur_web/endpoint.ex:14-29`); the
  dashboard is HTTP-only today (`src/lib/aiur/http_server.ex:64,147`).
- Versions to use (accessed 2026-10-06): Expo SDK 57 → React Native 0.86
  (<https://docs.expo.dev/versions/latest/>); `expo-apple-targets` needs SDK 53+ and Xcode 16
  (community, <https://github.com/EvanBacon/expo-apple-targets>); `react-native-webview` New
  Architecture only, iOS 15.1+ (community, <https://github.com/react-native-webview/react-native-webview>).
- Evidence that motivates each question: MP-N1 `framework-evidence.md` S2–S7, S16–S17, S22–S23;
  contract `pairing-and-instance-registry.md` §8.1; Apple DTS WebSocket trust thread
  (<https://developer.apple.com/forums/thread/104376>).

## Chosen design — questions and procedures

| ID | Question | Procedure | Pass |
|---|---|---|---|
| P1 (N1-RQ3) | Do an NSE and a watch target survive `expo prebuild --clean` with app-group and keychain-group entitlements? | Add both via `expo-apple-targets`; prebuild twice; diff entitlements; build and run on device | Identical entitlements; both targets run signed |
| P2 (S2, N1-RQ4) | NSE decrypts a sealed test vector within budget | Send an APNs sandbox push with `mutable-content: 1` via `curl` (token auth); NSE opens an MP-N4-C1 HPKE vector; measure time and peak memory in Instruments | Plaintext shown; time and memory recorded (median of 20) |
| P3 (DV-W1 preview) | Apple Watch shows NSE-modified text | iPhone locked, watch on wrist, repeat P2 | Watch shows decrypted text (records S39 vendor claim) |
| P4 (T-A, RQ-TRANSPORT) | LiveView over a publicly trusted cert in `react-native-webview` | `tailscale cert` on the machine; minimal Phoenix LiveView app on HTTPS; load in the WebView on iPhone 17.x/26.x and Android | Page renders; `/live` WebSocket `101`; live updates arrive |
| P5 (T-B, RQ-TRANSPORT) | Pinned self-signed origin in both WebViews | Self-signed cert; patch WebView trust handler to SPKI pin; LiveView with WebSocket, then with long-poll enabled | Record: does the iOS WebSocket fail (DTS claim)? Does long-poll work? Does Android `onReceivedSslError` path with pin check work? |
| P6 (N1-RQ5) | Native-minted session cookie reaches the WebView per origin, survives Android process death | Native POST sets a cookie; inject via `WKHTTPCookieStore` / `CookieManager`; kill app process (Android `adb shell am kill`) | WebView authenticated after restart without re-login, or documented re-bootstrap |
| P7 (N1-RQ6) | Does `react-native-webview` Android `onPermissionRequest` check the origin before granting mic? | Load two origins, request mic from each | Behaviour recorded; patch needed or not |
| P8 (N1-RQ7) | Do ATS `ts.net` exceptions / `NSAllowsLocalNetworking` permit HTTP to a MagicDNS name and to a `100.x` IP, in `URLSession` and `WKWebView`, on iOS 17.x and 26.x? Does Android `domain-config` apply to WebView loads? | Build with each Info.plist variant; load `http://host.tailnet.ts.net:port` and `http://100.x.y.z:port` | Matrix recorded |
| P9 (S6) | Watch `sendMessage` wakes the suspended iPhone app and gets a reply with JS not loaded | SwiftUI watch target calls `sendMessage`; iPhone app suspended; native handler replies | Reply received; latency median of 20 |
| P10 (S7) | `URLSessionWebSocketTask` on a real watch stays `.waiting` | Open a WebSocket from the watch to the machine | Confirms watch must not use WebSockets |

## Implementation steps

1. Create the throwaway project outside the repo; pin versions above.
2. Run P1–P10 in order (P1 first: later steps need its targets).
3. Write `prototype-findings.md` (table, devices, evidence); delete the project or archive it privately.

## Non-happy paths

A FAIL on P4 (T-A) reopens the framework recommendation (MP-Q4) and blocks MP-N1-C4 until DESIGN-N1
reconsiders. A FAIL on P5 removes T-B from DESIGN-N2 §transport. A FAIL on P1 moves the NSE/watch to
hand-maintained Xcode targets (bare workflow) — a plan change, not an implementer choice.

## Compatibility and rollout

n/a — nothing ships.

## Verification

The findings report is the verification; every row has device model, OS build, date, and evidence.
Latency and memory figures are medians with counts (AGENTS.md "A claimed saving must be measured").

## Completion and handoff

- [ ] Owner authorization recorded before start.
- [ ] `prototype-findings.md` committed by the coordinator; N1-RQ1/RQ3/RQ4/RQ5/RQ6/RQ7 and the
      RQ-TRANSPORT device questions marked closed or reopened.
- [ ] DESIGN-N1 and DESIGN-N2 §transport updated with the results by the owner.
