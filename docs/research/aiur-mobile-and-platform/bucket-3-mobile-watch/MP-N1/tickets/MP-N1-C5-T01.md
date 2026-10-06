---
ticket_id: MP-N1-C5-T01
feature_id: MP-N1
chunk_id: MP-N1-C5
bucket: 3-mobile-watch
title: Reachability probe and typed transport-error classification in both native cores and the TS client
status: blocked
blocked_by: [DESIGN-N1, RQ-TRANSPORT, MP-N2-C10-T01, MP-N2-C10-T02, MP-N1-C2-T03, MP-N1-C2-T05, MP-N1-C3-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N2, MP-R1]
prior_findings: [RC-15, RC-04]
size_owner: n/a (new package code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C5-T01 — Probe and transport-error classifier

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C5 "Connection diagnostics and degraded transport".
- **User value:** when a machine or instance cannot be reached, the phone says *why* — the
  tailnet is off, the certificate does not match, cleartext was blocked, the phone was
  unpaired, or the versions disagree — instead of one generic "can't connect". Every "why is
  this unavailable" link (surface-boundary row 17) reads from this classification.
- **Deliverable:**
  1. A native classifier in each core (`AiurClientKit.TransportErrorClassifier`,
     `aiur-client-core` `TransportErrorClassifier`, PROPOSED) that maps platform errors to the
     I2 kinds of `contracts/client-capability-model.md` §2:
     `tls_untrusted | tls_name_mismatch | tls_pin_mismatch | cleartext_blocked | timeout | refused | unknown`.
     `signedFetch` (MP-N1-C2-T05) returns `{error: "transport", kind}` instead of throwing a
     platform message string.
  2. A TS probe `probeInstance(instanceId)` / `probeMachine(machineId)` (PROPOSED
     `src/diagnostics/probe.ts`): `GET /v1/machine` (gateway) and `GET /api/v1/capabilities`
     (instance) with a 5 s timeout, producing a `ProbeResult` that is one of
     `reachable{transportMode: "https"|"http_degraded", ageMs}`, `transport_error{kind}`,
     `device_revoked`, `version_mismatch{side: "app"|"aiur"}`, `http_error{status}`.
  3. Feeding `ProbeResult` into the capability cache (MP-N1-C3-T02) as input I2.
- **Non-goals:** UI (MP-N1-C5-T03); HTTP-degraded build config (T02); pinning (T04).

## Dependencies and blockers

- DESIGN-N1 (error copy lives in the diagnostics design, surface 4); RQ-TRANSPORT and
  MP-N2-C10-T01/T02 (the server must actually serve HTTPS before the TLS classes can be
  exercised end to end).
- MP-N1-C2-T03 (core transport and `TransportPolicy` hook), MP-N1-C2-T05 (`signedFetch`),
  MP-N1-C3-T01 (resolver consumes I2).
- Concurrent with: MP-N1-C5-T02, MP-N1-C4-T03..T06.

## Verified starting point (base `45a290e3`)

- No client exists. The contract I2 kinds were added 2026-10-06
  (`contracts/client-capability-model.md` §2, §4 rule 3: "never collapsed into one cause;
  `unknown` when unclassified").
- Server-side errors the probe must distinguish: `401 device_revoked`, `401
  device_auth_disabled` (contract `pairing-and-instance-registry.md` §4.2, §4.4); a missing
  `/api/v1/capabilities` route on an older daemon is a 404 caught by the router catch-all
  `get("/api/v1/:issue_identifier", ...)` (`src/lib/aiur_web/router.ex:193`), which the
  client capability model §8 maps to `needs_update` ("Update aiur on <machine>").
- Platform error sources (accessed 2026-10-06):
  - Apple `URLError` codes: `.serverCertificateUntrusted`, `.serverCertificateHasUnknownRoot`,
    `.serverCertificateHasBadDate`, `.secureConnectionFailed`, `.appTransportSecurityRequiresSecureConnection`,
    `.timedOut`, `.cannotConnectToHost`, `.cannotFindHost`, `.notConnectedToInternet`
    (<https://developer.apple.com/documentation/foundation/urlerror/code>).
  - Android/OkHttp: `javax.net.ssl.SSLPeerUnverifiedException` (hostname or pin),
    `javax.net.ssl.SSLHandshakeException` with `CertPathValidatorException` cause (untrusted),
    `java.net.UnknownServiceException` "CLEARTEXT communication … not permitted by network
    security policy" (cleartext blocked; Network Security Config page, updated 2026-08-28,
    <https://developer.android.com/privacy-and-security/security-config>),
    `java.net.SocketTimeoutException`, `java.net.ConnectException`.

## Chosen design

Classification table (first match; anything not listed → `unknown`, never a guessed cause,
AGENTS.md "a collapsed cause names the collapse at the source"):

| Platform signal | Kind |
|---|---|
| Apple `.appTransportSecurityRequiresSecureConnection`; Android `UnknownServiceException` with "CLEARTEXT" | `cleartext_blocked` |
| core pin check failed (T-B, MP-N1-C5-T04) | `tls_pin_mismatch` |
| Apple `.serverCertificateHasUnknownRoot` / `.serverCertificateUntrusted` / `.serverCertificateHasBadDate`; Android `SSLHandshakeException` caused by `CertPathValidatorException` or `CertificateExpiredException` | `tls_untrusted` |
| Apple trust result with a name error (`SecTrustEvaluateWithError` error `errSecHostNameMismatch`); Android `SSLPeerUnverifiedException` "Hostname … not verified" | `tls_name_mismatch` |
| Apple `.timedOut`; Android `SocketTimeoutException` | `timeout` |
| Apple `.cannotConnectToHost`; Android `ConnectException` | `refused` |
| Apple `.cannotFindHost`, `.notConnectedToInternet`, `.networkConnectionLost`; Android `UnknownHostException` | `unknown` with `detail: "dns_or_offline"` (not a TLS cause) |

`ProbeResult` precedence: `device_revoked` (401 with that code) → `transport_error` →
`version_mismatch` (404 on `/api/v1/capabilities`, or `min_client_versions` above the app,
RC-04) → `http_error` → `reachable`. The probe records `observedAt` and computes `ageMs`
from the server's `age_ms` when present (MP-R1 clock-skew rule).

## Implementation steps

1. Swift `TransportErrorClassifier.classify(_ error: Error, trust: SecTrust?) -> TransportKind`.
2. Kotlin `TransportErrorClassifier.classify(t: Throwable): TransportKind`.
3. `signedFetch` and `bootstrapWebSession` return typed errors (update the TS facade types).
4. `src/diagnostics/probe.ts`; wire results into the C3-T02 cache. About 220 lines total.

## Non-happy paths

- Captive portal (HTTP 200 HTML from a different host): HTTPS fails with `tls_name_mismatch`
  or `tls_untrusted`; the diagnostics copy says "network intercepting traffic" only if
  DESIGN-N1 approves that wording; the kind stays as classified.
- Revoked during probe: `device_revoked` wins; the core wipes the machine (C2-T03).
- Probe storms: one in-flight probe per target; callers share the promise.

## Compatibility and rollout

App-internal. New kinds may be added later; unknown kinds from an older core map to `unknown`.

## Verification

- Swift `TransportErrorClassifierTests` (XCTest, constructed `URLError` values and a fake
  trust result) — one test per table row plus `test_unlisted_error_is_unknown`. Mutation:
  change the fallback to `.tls_untrusted` → `test_unlisted_error_is_unknown` fails.
- Kotlin `TransportErrorClassifierTest` (JUnit) — same rows with constructed exceptions,
  including the exact OkHttp cleartext message.
- TS `src/diagnostics/__tests__/probe.test.ts` (Jest, mocked `AiurNative`):
  `revoked_wins_over_transport`, `capabilities_404_is_needs_update_not_unreachable` (mutation:
  map 404 to `transport_error/unknown` → fails), `min_client_version_above_app_is_version_mismatch`,
  `age_uses_server_age_ms`.

```bash
npm --prefix packages/aiur-mobile test -- src/diagnostics
xcodebuild test -scheme AiurClientKit -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:AiurClientKitTests/TransportErrorClassifierTests
./gradlew :aiur-client-core:testDebugUnitTest --tests '*TransportErrorClassifierTest*'
```

Device: covered by MP-N2-C10-T05 rows TR-5, TR-6 and MP-N3-C4-T06 row MD-3 (tailnet off).

## Completion and handoff

- [ ] All tests pass; mutation checks recorded in the PR body.
- [ ] Docs: none on their own; the diagnostics guide text ships with MP-N1-C5-T03.
- [ ] Dependents: MP-N1-C5-T03, MP-N3-C4-T01 (machine states), MP-N6 Command screen (offline state).
