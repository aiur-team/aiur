---
ticket_id: MP-N4-C5-T04
feature_id: MP-N4
chunk_id: MP-N4-C5
bucket: 3-mobile-watch
title: Android retraction — cancel by nid tag and stream supersession
status: blocked
blocked_by: [DESIGN-N4 (D-4), MP-N4-C5-T03]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N5, MP-N6-C6]
prior_findings: [plan §7.4, E-W1 (dismissal ids bridge to Wear OS)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C5-T04 — Android retraction

## Identity and outcome

Bucket 3, MP-N4, chunk C5. On an accepted payload with `retracts`, cancel the posted
notifications whose tag is each listed `nid` (`NotificationManagerCompat.cancel(tag, id)`),
mark the `nid`s seen (late originals are dropped), and present the retraction per
DESIGN-N4 D-4. On a newer `seq` for a stream, cancel the older notification of that
stream.

## Dependencies and blockers

- **Blocked on DESIGN-N4 D-4**: silent removal vs a quiet "Answered on <surface>" line —
  on Android both are technically possible (no entitlement needed), so the design answer
  alone decides the behaviour.
- C5-T03 (tags and ids are set there).

## Verified starting point

- Contract v2 §6 device rules; plan §7.4.
- E-W1: dismissal ids let a phone-side cancel dismiss the bridged Wear OS notification
  (used by C6-T02).

## Chosen design (fixed parts)

Tag = `nid`, id = constant per channel; retraction payloads use normal priority (no
deprioritization risk, contract §5). Set the Wear dismissal id = stream key so C6-T02
gets watch dismissal for free.

## Implementation steps

After D-4: `Retraction.kt` (PROPOSED) + tests.

## Non-happy paths

- Retraction before original (reorder): seen-store marks it; the original is dropped.
- Original never delivered: cancel is a no-op.

## Compatibility and rollout

n/a beyond C5-T03.

## Verification

Robolectric: `retractionCancelsTaggedNotification`, `lateOriginalAfterRetractionIsDropped`
(must fail without the seen-store write), `newerSeqCancelsOlder`. Device: V-M1, V-W3.

## Completion and handoff

- [ ] D-4 recorded. Dependents: C6-T02, C7.
