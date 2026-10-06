---
ticket_id: MP-N1-C5-T04
feature_id: MP-N1
chunk_id: MP-N1-C5
bucket: 3-mobile-watch
title: "Option T-B client: SPKI pin enforcement in native HTTP clients and both WebViews (no blanket trust)"
status: blocked
blocked_by: [DESIGN-N1, DESIGN-N2, "RQ-TRANSPORT (DESIGN-N2 §transport = T-B)", MP-N1-C9-T01, MP-N2-C10-T04, MP-N1-C2-T03, MP-N1-C4-T02, MP-N1-C5-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N2]
prior_findings: [RC-15]
size_owner: n/a (new package code plus a react-native-webview patch)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C5-T04 — T-B: pinned self-signed transport on the phone

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C5.
- **User value:** if the operator chose an aiur-managed self-signed certificate (T-B), the phone
  trusts exactly that machine's key and nothing else, in native calls and in the WebView.
- **Deliverable:**
  1. Native HTTP: fill the `TransportPolicy` pin branch of MP-N1-C2-T03. iOS `URLSessionDelegate`
     `urlSession(_:didReceive:completionHandler:)` for `NSURLAuthenticationMethodServerTrust`:
     compute SHA-256 of the leaf SubjectPublicKeyInfo, compare with the stored pin (from QR `t=`
     or a signed `/v1/machine` `tls_spki_sha256[_next]`), then `.useCredential(URLCredential(trust:))`
     only on match, else `.cancelAuthenticationChallenge` → `tls_pin_mismatch`. Android OkHttp:
     a per-machine `X509TrustManager` that **throws** unless the leaf SPKI hash matches, plus a
     `HostnameVerifier` that accepts only the pinned machine's advertised hosts.
  2. WebView: `react-native-webview` patch (via `patch-package`, pinned version) adding a
     `pinnedSpkiSha256ByHost` prop. iOS `RNCWebView` `webView:didReceiveAuthenticationChallenge:`
     uses the same SPKI check; Android `RNCWebViewClient.onReceivedSslError` calls
     `handler.proceed()` **only** when the error's certificate SPKI matches the pin for that
     host, otherwise `handler.cancel()`.
  3. WebSocket gap: iOS WebView WebSockets cannot use the trust override, so the dashboard must
     run on the `/live-lp` long-poll socket from MP-N2-C10-T04; the WebView mic stays
     `unavailable/tls_websocket_untrusted` on iOS under T-B unless MP-N1-C9-T01 disproves the gap.
- **Non-goals:** generating certificates (MP-N2-C10-T04); T-A (platform trust store, no code).

## Dependencies and blockers

- **Applies only if DESIGN-N2 §transport selects T-B.** Otherwise closed.
- **MP-N1-C9-T01** (prototype) must show a pinned LiveView page loading on both platforms.
- MP-N2-C10-T04 (`t=`, `tls_spki_sha256`, `/live-lp`), MP-N1-C2-T03 (`TransportPolicy`),
  MP-N1-C4-T02 (WebView host), MP-N1-C5-T01 (`tls_pin_mismatch` kind).

## Verified starting point (base `45a290e3`)

- `/live` and `/voice` are WebSocket-only (`src/lib/aiur_web/endpoint.ex:14-17,26-29`).
- Evidence (accessed 2026-10-06):
  - Apple DTS: WKWebView's server-trust override does not apply to its WebSocket
    implementation (r. 25491679) — <https://developer.apple.com/forums/thread/104376>
    (thread predates iOS 17; current behaviour UNVERIFIED → C9-T01).
  - `react-native-webview` does not expose a server-trust hook to JS; pinning needs a change to
    `RNCWebView` (issue #1710, <https://github.com/react-native-webview/react-native-webview/issues/1710>).
  - Google Play flags `onReceivedSslError` handlers that proceed without validating, and may
    remove such apps — <https://support.google.com/faqs/answer/7071387>. Play also warns about
    `X509TrustManager` implementations that accept all certificates —
    <https://support.google.com/faqs/answer/6346016>. Both handlers here validate and fail closed.
  - Android Network Security Config supports static `<pin-set>` only (build time,
    <https://developer.android.com/privacy-and-security/security-config>, updated 2026-08-28), so
    runtime pins learned from a QR need code, not XML.

## Chosen design

- Pin = base64url SHA-256 of the DER SPKI (matches MP-N2-C10-T04). The stored record holds
  `pins: [current, next?]`; either matches during rotation.
- A pin is learned only from (a) the signed QR at pairing or (b) a `/v1/machine` response whose
  `sig` verifies with the pinned `machine_key` (contract §4.3). Never from a TLS handshake (no TOFU).
- Hosts: the pin applies to the gateway endpoints and to every instance device URL host of that
  machine; other hosts use the platform trust store unchanged.

## Implementation steps

1. Swift `PinnedTrustEvaluator`; Kotlin `PinnedTrustManager` + `PinnedHostnameVerifier`.
2. `patches/react-native-webview+<pinned version>.patch` (iOS + Android) and the prop wiring in
   `InstanceScreen`.
3. Resolver row: `mic_webview` under T-B on iOS → `unavailable/tls_websocket_untrusted`.
About 250 lines plus the patch.

## Non-happy paths

Pin mismatch (hard error, diagnostics → "scan the QR again"); rotation in progress (either pin);
a react-native-webview upgrade drops the patch (CI fails: patch-package exits non-zero on a
failed apply); a non-machine HTTPS host with an invalid cert (rejected normally, no pin applied).

## Compatibility and rollout

Shipped only in builds where the operator chose T-B; T-A builds carry the code dormant (no pins
stored → no override). Rollback: re-pair with a T-A QR.

## Verification

- Swift `PinnedTrustEvaluatorTests` with two generated self-signed certs:
  `test_matching_pin_is_trusted`, `test_other_key_is_rejected` (mutation: return
  `.useCredential` unconditionally → fails), `test_next_pin_accepted_during_rotation`.
- Kotlin `PinnedTrustManagerTest`: same three; `checkServerTrusted_throws_on_mismatch`.
- WebView patch tests: Android Robolectric `RNCWebViewClientSslTest.proceeds_only_on_pin_match`
  (mutation: always `proceed()` → fails); iOS covered on device (WKWebView challenge cannot be
  unit-tested without a server; C9-T01 + TR-4/TR-5).
- Jest resolver fixture for the iOS mic row.

```bash
xcodebuild test -scheme AiurClientKit -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:AiurClientKitTests/PinnedTrustEvaluatorTests
./gradlew :aiur-client-core:testDebugUnitTest --tests '*PinnedTrustManagerTest*'
./gradlew :app:testDebugUnitTest --tests '*RNCWebViewClientSslTest*'
npm --prefix packages/aiur-mobile test -- src/capability
```

Device: MP-N2-C10-T05 rows TR-4 and TR-5 on iPhone-min (iOS 17.x), iPhone-cur (iOS 26.x),
Android-cur (Android 13+).

## Completion and handoff

- [ ] Tests and TR-4/TR-5 pass; mutation checks recorded.
- [ ] Docs: mobile guide "Self-signed mode" limits (iOS WebView mic) — shared page with MP-N2-C10-T04.
- [ ] Play pre-launch report (if Play distribution) shows no SSL handler warning; record it.
