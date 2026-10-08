---
ticket_id: MP-N4-C6-T03
feature_id: MP-N4
chunk_id: MP-N4-C6
bucket: 3-mobile-watch
title: Watch as a direct-push child device — registration record and daemon fan-out check
status: blocked
blocked_by: [DESIGN-N4, DESIGN-N7, MP-N4-C6-T01, MP-N4-C3-T03, MP-N2-C5-T02]
prior_units: []
prior_boundaries: [push-relay, pairing-discovery]
prior_features: [MP-N2, MP-N7]
prior_findings: [pairing contract RC-4, contract A-N7-1]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C6-T03 — Direct-push watch device

## Identity and outcome

Bucket 3, MP-N4, chunk C6. Only if C6-T01 chooses Path B (or MP-N7 adopts a standalone
Wear OS push): the watch is a child device row (`platform: watchos|wearos`,
`parent_device_id`) with its own `push_registration`. Daemon work is a test-only
confirmation that fan-out (C3-T03) and deregistration (C3-T05) treat it as a normal
device and that revoking the phone removes the watch (pairing contract §4.5 cascade).

## Dependencies and blockers

- **Blocked on C6-T01's decision** (V-W1). If Path A is chosen, close this ticket.
- C3-T03, MP-N2-C5-T02 (claim with `parent_device_id`).

## Verified starting point

- Pairing contract §4.1 claim `parent_device_id`; §4.5 revoke cascades to children.
- Contract v2 §7 `platform` enum already includes `watchos`/`wearos`.

## Chosen design

No new daemon code expected; add tests. Preferences for a direct-push watch are seeded
from the phone (MP-N5 plan §4).

## Implementation steps

Daemon tests in `src/test/aiur/push/sender_test.exs`; watch-side registration lives in
MP-N7 tickets reusing C4-T05.

## Non-happy paths

Watch revoked alone: phone keeps receiving; watch handle deleted (C3-T05).

## Compatibility and rollout

n/a.

## Verification

`"child device receives its own sealed copy"`, `"revoking parent removes child jobs"`
(must fail if cascade not applied in fixture store). Device: V-W1/V-W2.

## Completion and handoff

- [ ] Closed or implemented per C6-T01. Dependents: MP-N7.
