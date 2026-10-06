---
ticket_id: MP-N5-C1-T05
feature_id: MP-N5
chunk_id: MP-N5-C1
bucket: 3-mobile-watch
title: Per-instance mute of blocker Commands on a device (if DESIGN-N5 D-1 = yes)
status: blocked
blocked_by: [DESIGN-N5 (D-1 / OQ-N5-1), MP-N5-C1-T02, MP-N5-C2-T02, DESIGN-N3 (muted badge)]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: [MP-N3]
prior_findings: [D18 "blocker commands are always on"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C1-T05 — Per-instance blocker mute

## Identity and outcome

Bucket 3, MP-N5, chunk C1. If the owner answers DESIGN-N5 D-1 "yes": allow
`instance_overrides.<instance_id>.commands_needs_you = "muted"` (never at machine level),
make the Command rules (C2-T02) skip muted instances for that device, and expose
`muted: true` in the options API so MP-N3 shows a "muted" badge.

## Dependencies and blockers

**Blocked on DESIGN-N5 D-1 (OQ-N5-1)** — it decides whether this exists. D18 says blocker
Commands are always on; a mute weakens it per instance. If D-1 = no, close the ticket.
DESIGN-N3 owns the badge.

## Verified starting point

C1-T01 schema accepts only `"on"` in v1; this ticket widens the enum for overrides only.

## Chosen design

Pending D-1. Constraint if built: mute applies to `command.needs_you` only; retractions
(`command.resolved`) for already-sent notifications still flow.

## Implementation steps

n/a until D-1.

## Non-happy paths

Muted instance with a blocking Command and no other device: the Command still reaches the
dashboard and the Executor; nothing is silently lost (E2 no-vanish invariant), only this
device's push.

## Compatibility and rollout

Additive enum value.

## Verification

When unblocked: `"muted instance produces no needs_you for that device, others unaffected"`
(must fail if mute is applied machine-wide).

## Completion and handoff

- [ ] D-1 answer recorded in DESIGN-N5.
