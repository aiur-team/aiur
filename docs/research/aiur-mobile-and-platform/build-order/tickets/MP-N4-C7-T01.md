---
ticket_id: MP-N4-C7-T01
feature_id: MP-N4
chunk_id: MP-N4-C7
bucket: 3-mobile-watch
title: Device-validation harness — relay test tool, report template, capture scripts
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C2-T05, MP-N4-C3-T03]
prior_units: []
prior_boundaries: [relay service, push-relay]
prior_features: []
prior_findings: [device-validation-plan.md]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C7-T01 — Validation harness

## Identity and outcome

Bucket 3, MP-N4, chunk C7. Build what the physical-device run (C7-T02) needs, without
running it:

1. `mix aiur.push.test_send` (PROPOSED, daemon) — sends crafted payloads to a registered
   device through the relay: normal, at-size-cap (V-L1), forged signature, replayed `nid`,
   expired (V-S1), a burst for coalescing (V-R1/V-R2 setup).
2. A timestamp log: daemon send, relay accept, provider status (relay `send_log`), to pair
   with on-device screenshots.
3. `docs/research/…/MP-N4/validation-report-template.md` (PROPOSED) with one row per
   scenario of device-validation-plan.md §2 (device, OS build, app build, relay build,
   timestamps, pass/fail, evidence link).
4. A capture recipe for V-P1 (relay request bodies) using the relay's debug mode that
   logs **sizes and field names only**, and provider-side request capture via the
   adapter's recorded-request hook.

## Dependencies and blockers

- C2-T05 (relay image), C3-T03 (daemon sender). No device needed to build it.
- DESIGN-N4: no UI.

## Verified starting point

- device-validation-plan.md §1–§4 (scenarios, matrix, report requirements).

## Chosen design

The test tool reuses `Aiur.Push.Seal` with an injected wrong signer / old `expires_at` /
fixed `nid`; it refuses to run unless `push.allow_loopback_relay` is false **and** an
explicit `--i-am-validating` flag is given, so it cannot be fired at a production relay
by accident.

## Implementation steps

Mix task + template + a short README section in the package.

## Non-happy paths

Tool run against a device that is not registered → explicit error, nothing sent.

## Compatibility and rollout

Dev-only task (not in user docs).

## Verification

`src/test/mix/tasks/aiur_push_test_send_test.exs` (PROPOSED): forged mode produces a
payload that `Seal.open/3` rejects with `:bad_signature` (must fail if the tool signs
with the real key); refuses without the flag.

## Completion and handoff

- [ ] Template committed. Dependents: C7-T02.
