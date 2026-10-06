---
ticket_id: MP-N1-C5-T02
feature_id: MP-N1
chunk_id: MP-N1-C5
bucket: 3-mobile-watch
title: "HTTP-degraded mode: build-time cleartext exceptions scoped to tailnet names, runtime allow-list of paired hosts, persistent warning, WebView mic off"
status: blocked
blocked_by: [DESIGN-N1, DESIGN-N2, "RQ-TRANSPORT (DESIGN-N2 §transport keeps allow_cleartext_overlay)", MP-N2-C10-T02, MP-N1-C2-T03, MP-N1-C4-T02, MP-N1-C5-T01, MP-N1-C9-T01, OQ-N1-1]
prior_units: []
prior_boundaries: []
prior_features: [MP-N2, MP-R3]
prior_findings: [RC-15]
size_owner: n/a (new package code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C5-T02 — HTTP-degraded mode (conditional)

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C5.
- **User value:** an operator whose machine is reachable only over an encrypted overlay (a
  tailnet) and who has not set up a certificate can still pair and read dashboards, with an
  honest, persistent warning and the WebView microphone shown as unavailable.
- **Deliverable (only if DESIGN-N2 §transport keeps `transport.allow_cleartext_overlay`):**
  1. Build configuration (Expo config plugin, PROPOSED `plugins/withCleartextOverlay.ts`):
     iOS `NSAppTransportSecurity` → `NSExceptionDomains` `ts.net` with
     `NSIncludesSubdomains: true` and `NSExceptionAllowsInsecureHTTPLoads: true`; Android
     `res/xml/network_security_config.xml` with `base-config cleartextTrafficPermitted="false"`
     and one `domain-config cleartextTrafficPermitted="true"` for `ts.net` (`includeSubdomains`).
     No global `NSAllowsArbitraryLoads`, no global Android cleartext.
  2. Runtime allow-list in both cores (`TransportPolicy`, MP-N1-C2-T03): an `http://` request is
     sent only to a host that appears in a paired machine's endpoint list, or in an instance
     device URL from that machine's signed registry response. Everything else → `cleartext_blocked`.
  3. App state `transportMode: "http_degraded"` per machine, consumed by the resolver
     (MP-N1-C3-T01: open dashboard → `degraded`; WebView mic → `unavailable/insecure_context`),
     and a persistent banner on the native header (MP-N1-C4-T06) per DESIGN-N1 D-N1-6.
  4. App Review justification text for the ATS exception (drafted here, used by MP-N1-C8-T02 if
     OQ-N1-1 = public).
- **Non-goals:** IP-literal hosts on iOS (see below); any LAN without an overlay (the server
  refuses to advertise those, MP-N2-C10-T02); TLS pinning (T04).

## Dependencies and blockers

- **Conditional:** if DESIGN-N2 §transport removes the cleartext overlay (recommended T-A
  only), this ticket is closed as not needed and DESIGN-N1 D-N1-6 is answered "refuse to pair".
- MP-N2-C10-T02 (server only advertises `http://` endpoints with the overlay flag),
  MP-N1-C2-T03 (`TransportPolicy` hook), MP-N1-C4-T02 (WebView host), MP-N1-C5-T01 (kinds).
- **MP-N1-C9-T01:** must confirm on device that the `ts.net` exception permits HTTP to a
  MagicDNS name in both `URLSession` and `WKWebView`, and whether `NSAllowsLocalNetworking`
  would also cover `100.64.0.0/10` IP literals (N1-RQ7, below).
- OQ-N1-1: a public listing needs a review justification for every ATS exception.

## Verified starting point (base `45a290e3`)

- The dashboard serves plain HTTP (`src/lib/aiur/http_server.ex:64,147`) and binds loopback by
  default (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:728-730`).
- Contract `pairing-and-instance-registry.md` §8.1 rule 2: without TLS, `http://` endpoints are
  advertised only with `allow_cleartext_overlay: true`; the app then shows a persistent warning
  and the WebView mic `unavailable`.
- Platform facts (accessed 2026-10-06):
  - ATS requires HTTPS and, since iOS 17, no longer allows IP-address connections by default;
    exceptions need a justification at review (`NSAppTransportSecurity`,
    <https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity>;
    MP-N1 framework-evidence S16). The exception keys are **static Info.plist entries** fixed at
    build time, so per-paired-host exceptions at runtime are impossible.
  - Android cleartext is off by default for target API 28+ and opts in per `domain-config`;
    the configuration is a static XML resource (page updated 2026-08-28,
    <https://developer.android.com/privacy-and-security/security-config>). The page does not
    state whether it governs `android.webkit.WebView` loads: **UNVERIFIED**, checked in C9-T01.
  - An HTTP origin is not a secure context, so `getUserMedia` is unavailable in the WebView
    (MP-N1 plan F1).

## Chosen design

- **Why `ts.net` only:** both platforms fix exceptions at build time; the only overlay whose host
  names are knowable at build time is Tailscale MagicDNS (`*.<tailnet>.ts.net`). Any other overlay
  must use HTTPS (T-A). This keeps Tailscale optional for the product (HTTPS works everywhere) while
  making the degraded mode honest about being Tailscale-specific. The QR therefore must carry a
  MagicDNS host, not a `100.x` address; the server-side endpoint selection (MP-N2-C10-T02) is
  asked to prefer DNS names (see CONTRACT-REQUESTS.md).
- **Defence in depth:** the static exception permits more hosts than the user paired; the core
  allow-list narrows it back to paired hosts, and WebView navigation confinement
  (MP-N1-C4-T03) keeps the WebView on the paired origin.

## Implementation steps

1. Config plugin and `app.config.ts` flag `AIUR_CLEARTEXT_OVERLAY=1` (default off).
2. `TransportPolicy.allowsCleartext(host, machineRecord)` in both cores.
3. `transportMode` derivation from the endpoint scheme in use; resolver input.
4. Header banner key; justification text in `docs/mobile/ats-justification.md` (PROPOSED, in
   the package). About 120 lines plus config.

## Non-happy paths

- Endpoint is an IP literal on iOS: `cleartext_blocked` with a diagnostics hint to use the
  MagicDNS name (unless C9-T01 proves `NSAllowsLocalNetworking` covers it).
- The machine later enables TLS: the next signed `/v1/machine` lists `https://` first; the
  core switches and `transportMode` becomes `https` without re-pairing.
- Build without the flag pairs an `http://` QR: pairing refused with `cleartext_blocked`.

## Compatibility and rollout

Build flag off by default; enabling it changes only `Info.plist` and the Android network config.
Rollback: rebuild without the flag.

## Verification

- `plugins/__tests__/withCleartextOverlay.test.ts` (Jest): with the flag, the generated plist has
  exactly the `ts.net` exception and no `NSAllowsArbitraryLoads`; the generated XML has a
  `false` base-config. Mutation: emit `NSAllowsArbitraryLoads: true` → the test fails.
- Swift `TransportPolicyTests.test_http_to_unpaired_host_is_blocked` and Kotlin
  `TransportPolicyTest.httpToUnpairedHostIsBlocked`. *Fails without:* the allow-list check.
- TS `resolver` fixture `open_dashboard_http_degraded` → `degraded`, `mic_webview` →
  `unavailable/insecure_context` (fixtures owned by MP-N1-C3-T01; this ticket adds the rows).

```bash
npm --prefix packages/aiur-mobile test -- plugins src/capability
xcodebuild test -scheme AiurClientKit -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:AiurClientKitTests/TransportPolicyTests
./gradlew :aiur-client-core:testDebugUnitTest --tests '*TransportPolicyTest*'
```

Device: MP-N2-C10-T05 row TR-7 on iPhone-min (iOS 17.x), iPhone-cur (iOS 26.x), Android-cur.

## Completion and handoff

- [ ] Tests pass; TR-7 recorded; mutation checks in the PR body.
- [ ] Docs: mobile guide page "Without a certificate (tailnet only)" with the warning text and
      the mic limitation; link from the pairing guide transport section (MP-N2-C10-T03).
- [ ] New research item N1-RQ7 closed by C9-T01 or TR-7.
