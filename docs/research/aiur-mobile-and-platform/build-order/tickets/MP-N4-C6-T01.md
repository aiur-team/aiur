---
ticket_id: MP-N4-C6-T01
feature_id: MP-N4
chunk_id: MP-N4-C6
bucket: 3-mobile-watch
title: Apple Watch delivery — verify forwarded NSE content; direct-push fallback decision
status: blocked
blocked_by: [DESIGN-N4, DESIGN-N7, RQ-N4-2, MP-N4-C4-T02, MP-N4-C4-T03, OQ-N4-1]
prior_units: []
prior_boundaries: [mobile-app (watch apps inside packages/aiur-mobile, RC-17)]
prior_features: [MP-N7]
prior_findings: [E-B1, E-B2, E-B6 (UNVERIFIED), E-C1]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C6-T01 — Apple Watch delivery

## Identity and outcome

Bucket 3, MP-N4, chunk C6. Decide, with device evidence, how encrypted notifications
reach the Apple Watch:

- **Path A (default, no extra code):** iPhone-forwarded notifications. Works only if the
  watch shows the iPhone NSE's decrypted content (E-B6, UNVERIFIED).
- **Path B:** the watch app registers as its own push device (child device,
  `parent_device_id`, pairing contract RC-4), with its own per-machine X25519 key and a
  watchOS NSE (NSE exists on watchOS 6+, E-A3; CryptoKit HPKE watchOS 10+, E-C1); the
  daemon sends to phone and watch; the system shows one (E-B2).

Deliverable: the V-W1 result recorded in platform-evidence.md, the decision recorded with
MP-N7, and (if Path B) the watch-side registration reusing C4-T01/T02/T05 code.

## Dependencies and blockers

- **RQ-N4-2 / V-W1 (device test)** decides A vs B — blocks the decision and any code.
- Needs a physical iPhone + Apple Watch and a sandbox relay with the publisher's APNs key
  (OQ-N4-1) or a self-built app.
- DESIGN-N7 / DESIGN-N4 (watch short/long look).
- C4-T02/T03 (phone NSE exists to be forwarded).

## Verified starting point

- E-B1 forwarding rules (phone unlocked → phone; else watch on wrist → watch); background
  pushes never forwarded. E-B2: dependent watch app can receive its own pushes; "the
  system ensures that the user only receives one notification" when sent to both.
  E-B6: forwarded-content behaviour UNVERIFIED.

## Chosen design

Pending V-W1. If Path B: watch device record `platform: "watchos"`,
`parent_device_id` = phone; registration via the phone's paired channel (watch has no
own pairing UI in v1, MP-N7); daemon fan-out treats it as another device (no N4 daemon
change).

## Implementation steps

1. Run V-W1 (C7 harness) and record.
2. If B: watch extension target with NSE (MP-N7 owns the target), reuse `AiurClientKit`.

## Non-happy paths

Watch off-wrist / locked: forwarding rules keep it on the phone (E-B1); nothing to do.

## Compatibility and rollout

watchOS 10 minimum (KD-N4-8).

## Verification

Device V-W1 with screenshots; if B, XCTest of the watch registration record shape.

## Completion and handoff

- [ ] E-B6 resolved in platform-evidence.md; decision recorded in MP-N7 plan.
- Dependents: C6-T03, MP-N7, MP-N6-C5.
