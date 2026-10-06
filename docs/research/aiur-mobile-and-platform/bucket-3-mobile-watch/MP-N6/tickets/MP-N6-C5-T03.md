---
ticket_id: MP-N6-C5-T03
feature_id: MP-N6
chunk_id: MP-N6-C5
bucket: 3-mobile-watch
title: "Open on phone" hand-off from the watch card to the same Command
status: blocked
blocked_by: [DESIGN-N7, DESIGN-N6, MP-N6-C5-T01, MP-N6-C2-T01, MP-N7 watch-link (N7-C1)]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N7]
prior_findings: [E-B5]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C5-T03 — Open on phone

## Identity and outcome

Bucket 3, MP-N6, chunk C5. "Open on phone" sends the Command's destination (contract v2
§3.1 shape) over the MP-N7 watch link; the phone runs the C2-T01 resolver and opens the
Command screen (or shows a notification prompting the user to pick up the phone, per
DESIGN-N7 — watchOS cannot foreground the iPhone app silently).

## Dependencies and blockers

**Blocked** on DESIGN-N7 (hand-off presentation), MP-N7 watch link (N7-C1), C5-T01.

## Verified starting point

E-B5; contract v2 §3.1.

## Chosen design (fixed parts)

The hand-off carries only the destination (no Command content).

## Implementation steps

After unblocking.

## Non-happy paths

Phone unreachable → watch shows "Phone not reachable".

## Compatibility and rollout

n/a.

## Verification

Device V-W2 extension; unit test that the hand-off payload is a valid destination.

## Completion and handoff

- [ ] Dependents: none.
