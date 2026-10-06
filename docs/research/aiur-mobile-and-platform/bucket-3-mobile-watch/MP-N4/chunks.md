---
feature_id: MP-N4
base_main_sha: 45a290e3
date: 2026-10-06
---

# MP-N4 chunks

**Phase C (2026-10-06):** full ticket docs are in [tickets/](tickets/README.md). Changes
from the Phase B lists below: C2 splits packaging (T05, ready) from the default deployment
(T06, blocked on OQ-N4-1) and moves Workers to T07; C3 adds T07 (status line and setup
copy, blocked on DESIGN-N4); C7 splits the harness (T01) from the authorized run (T02);
`push.*` settings move to `~/.aiur/machine` (RC-03); RQ-N4-1/E-C4 is resolved.

Every ticket below lists its gates. **Blocked-by-design** means DESIGN-N4 must be approved
first. All tickets are wave 5 and wait for the MP-R1/R2 refactor tickets they name; C1 and
C2 have no aiur-internal dependency and may be researched and built earliest within wave 5.

| Chunk | Outcome | Depends on | Design gate |
| --- | --- | --- | --- |
| MP-N4-C1 | Sealing library + cross-platform golden vectors | contract draft reconciled | none (no UI) |
| MP-N4-C2 | Relay service (reference) with APNs + FCM adapters | C1 constants only; OQ-N4-1 for prod creds | none (no UI) |
| MP-N4-C3 | Daemon `push-relay` component: registry read, outbox, fan-out, capability | C1, MP-N2 device registry, MP-R2 events, MP-R1 capability API | none for core; setup copy blocked-by-design |
| MP-N4-C4 | iOS: NSE decrypt/verify/render, keychain group, fallback, retraction | C1, MP-N1 app shell, MP-N2 pairing | blocked-by-design |
| MP-N4-C5 | Android: data-message decrypt/post, channels, fallback, retraction | C1, MP-N1 app shell, MP-N2 pairing | blocked-by-design |
| MP-N4-C6 | Watch delivery: forwarding verification, Wear OS bridging config, direct-watch registration hook for MP-N7 | C4, C5, MP-N7 plan | blocked-by-design (shared with DESIGN-N7) |
| MP-N4-C7 | Physical-device validation run and report | C2–C6 | none (it validates) |

---

## MP-N4-C1 — Sealing library and golden vectors

**Outcome:** one specification-tested implementation of contract §3–§6 per platform
(Elixir daemon side; Swift and Kotlin test fixtures), proven interoperable by shared
golden vectors.

Tickets:
- MP-N4-C1-T01 Resolved in Phase C: OTP 28 `:crypto` has every primitive (E-C4). The
  ticket adds `Aiur.Push.Crypto.Primitives` with a runtime support guard.
- MP-N4-C1-T02 Implement HPKE base-mode seal/open (daemon) and pass RFC 9180 Appendix A
  vectors for the chosen suite.
- MP-N4-C1-T03 Payload encoder with size budget and truncation order; inner frame with a
  detached Ed25519 signature over the exact bytes (no RFC 8785; contract §11).
- MP-N4-C1-T04 `nid` and `collapse_token` derivation (HMAC) and golden vectors file
  (`aiur-contracts/push/v1/vectors.json`, proposed path) consumed by Swift and Kotlin
  tests.

Test strategy: RFC vectors; property tests (seal→open round trip, any byte flip fails);
over-budget fixture fails loudly; mutation check per `AGENTS.md` (replace AAD with empty →
cross-device replay test must fail).

Open research: E-C4 only.

## MP-N4-C2 — Relay service (reference implementation)

**Outcome:** a deployable HTTPS service implementing contract §7–§8 with APNs (token
auth, HTTP/2) and FCM HTTP v1 adapters, no content logging, per-handle rate limit, and a
container image. A Cloudflare Workers deployment is an optional adapter, not required.

Tickets:
- MP-N4-C2-T01 Service skeleton, storage interface (SQLite for container; KV adapter
  later), handle create/delete with `sha256(send_secret)`; no accounts.
- MP-N4-C2-T02 APNs adapter: JWT from `.p8` (refresh 20–60 min, E-A6), headers per
  contract §5, error mapping (`Unregistered`/`BadDeviceToken` → 410 to daemon).
- MP-N4-C2-T03 FCM HTTP v1 adapter: data-only message, priority/ttl/collapse_key mapping,
  `UNREGISTERED` → 410.
- MP-N4-C2-T04 Abuse controls: per-handle rate limit (default 60/hour, burst 10),
  payload size check (≤ 4,096 final), request log retention ≤ 7 days, no body logging
  (test asserts the sealed field never reaches the logger).
- MP-N4-C2-T05 Packaging: container image, CI workflow, health endpoint, operator docs
  page (`website/docs-app/guide/` new page + sidebar, `AGENTS.md` docs rule).
- MP-N4-C2-T06 Default deployment for store apps (blocked: OQ-N4-1, RQ-N4-7).
- MP-N4-C2-T07 (optional) Cloudflare Workers port (blocked: RQ-N4-8, OQ-N4-1).

Test strategy: provider adapters against recorded-response fakes (APNs/FCM error
catalogue fixtures); sandbox APNs + a test Firebase project in C7 only.

Open research: OQ-N4-1 (who holds production credentials), RQ-N4-7 (cost/limits).

## MP-N4-C3 — Daemon push-relay component

**Outcome:** an optional supervised component that, given intents from MP-N5, seals per
device, persists to an outbox, sends to the relay, handles responses, and reports the
`push` capability.

Tickets:
- MP-N4-C3-T00 Plan refresh: map pre-refactor paths in this plan to MP-R1/R2 packages
  (see plan §12) before coding.
- MP-N4-C3-T01 `push:` section in `~/.aiur/machine` (RC-03), docs entry in
  `website/docs-app/reference/configuration.md` (checked by the MP-N2-C3-T05 extension of
  `scripts/check-config-docs.py`).
- MP-N4-C3-T02 Outbox: append-only ndjson + projection under `runtime_state_dir`
  (`src/lib/aiur/config/paths.ex:243`), persist-before-send, idempotent on
  `(intent_id, device_id)`, restart resumes unsent entries subject to N5 staleness rules.
- MP-N4-C3-T03 Fan-out: read MP-N2 device registry, filter by N5 audience, seal (C1),
  send with backoff; 404/410 → mark device `push_state: gone` and surface it.
- MP-N4-C3-T04 Capability reporting `push` (`available | unavailable(reason) |
  degraded(reason, since)`) via the MP-R1 registry; `aiur status` line.
- MP-N4-C3-T05 Deregistration function (in the push-relay package) that the MP-N2
  gateway calls on revoke and unpair-all: delete the relay handle (best effort, retried,
  reported as "push deregistration pending" per pairing contract §4.5); each instance
  purges outbox entries for a device that disappears from `devices.json`.
- MP-N4-C3-T06 Privacy tests: no summary text or identifiers in logs or in the HTTP
  request to the relay (assert on captured request body = only contract §8 fields).
- MP-N4-C3-T07 `aiur status` / `aiur mobile status` push line and setup copy (blocked:
  DESIGN-N4, DESIGN-N2).

Test strategy: fake relay (Bandit/Plug test server) for success/429/410/5xx; restart test
(kill after persist, before send → exactly one send after restart); unpair test.

## MP-N4-C4 — iOS Notification Service Extension

**Outcome:** NSE target that decrypts, verifies, applies dedup/stream rules, sets title,
subtitle, body, `threadIdentifier` (per instance), `categoryIdentifier`,
`interruptionLevel` and `targetContentIdentifier` (destination), and shows the uniform
fallback on any failure.

Tickets:
- MP-N4-C4-T01 Keychain access group shared by app + NSE; X25519 key created on device
  with `AfterFirstUnlockThisDeviceOnly`; Ed25519 machine public keys stored per machine.
- MP-N4-C4-T02 Decrypt + verify + expiry + seen-`nid` store (app-group container file
  with `completeUntilFirstUserAuthentication` protection), within a 5 s self-imposed budget.
- MP-N4-C4-T03 Presentation mapping per DESIGN-N4 (blocked-by-design).
- MP-N4-C4-T04 Retraction handling (`retracts`) — depends on RQ-N4-5/OQ-N4-3 outcome.
- MP-N4-C4-T05 APNs registration + relay handle creation per paired machine; token
  refresh re-registers.

Test strategy: XCTest with C1 golden vectors; NSE unit tests for every failure branch
(each must yield fallback, verified by replacing it with a plausible default and seeing
the test fail, per `AGENTS.md` unknown-path rule); device runs in C7.

## MP-N4-C5 — Android messaging service

**Outcome:** `FirebaseMessagingService` that decrypts data messages, verifies, dedups,
posts the notification on the right channel within the FCM window, and posts the
fallback on failure.

Tickets:
- MP-N4-C5-T01 Tink HPKE keyset, Keystore-wrapped without unlocked-device requirement;
  machine public keys store.
- MP-N4-C5-T02 `onMessageReceived` decrypt/verify/post within 2 s; WorkManager only for
  non-display bookkeeping.
- MP-N4-C5-T03 Channels (Commands, Progress, Other) and `POST_NOTIFICATIONS` request flow
  (blocked-by-design for copy).
- MP-N4-C5-T04 Retraction: cancel by tag (`nid`), stream supersession.
- MP-N4-C5-T05 Force-stop detection and settings warning (E-F7), token refresh
  re-registration.

Test strategy: Robolectric/instrumented tests with golden vectors; deprioritization guard
test: every high-priority fixture that verifies results in a posted notification.

## MP-N4-C6 — Watch delivery

**Outcome:** verified behaviour for forwarded notifications on Apple Watch and bridged
notifications on Wear OS, plus the registration hook MP-N7 uses if a watch receives
pushes directly (own device record, own key).

Tickets:
- MP-N4-C6-T01 Apple Watch: test forwarded NSE content (V-W1); if the watch shows the
  fallback, register the watch app as a direct-push device (watchOS NSE exists since
  watchOS 6, E-A3; CryptoKit HPKE watchOS 10, E-C1) — decision recorded with MP-N7.
- MP-N4-C6-T02 Wear OS: confirm bridging of app-posted notifications and set bridge tags
  / dismissal ids so retraction on phone dismisses on watch (E-W1).
- MP-N4-C6-T03 Watch device record (`platform: watchos|wearos`) in the MP-N2 registry.

## MP-N4-C7 — Physical-device validation

**Outcome:** the run described in [device-validation-plan.md](device-validation-plan.md),
with a dated report committed next to this plan. AC-N4-9 is met only by this report.

Tickets: MP-N4-C7-T01 harness, test-send tool and report template (ready);
MP-N4-C7-T02 the authorized run (blocked: OQ-N4-1, owner authorization, devices).
