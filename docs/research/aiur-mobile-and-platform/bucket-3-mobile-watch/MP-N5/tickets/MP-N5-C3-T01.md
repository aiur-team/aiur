---
ticket_id: MP-N5-C3-T01
feature_id: MP-N5
chunk_id: MP-N5-C3
bucket: 3-mobile-watch
title: Coalescing window and digest intents per (device, instance)
status: ready
blocked_by: [DESIGN-N5 (no-UI release), MP-N5-C2-T02, MP-N5-C2-T03, MP-N5-C2-T04]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: [MP-N4]
prior_findings: [N5 plan §5.5, AC-N5-6]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C3-T01 — Coalescing and digest

## Identity and outcome

Bucket 3, MP-N5, chunk C3. `Aiur.Push.Policy.Coalescer` (PROPOSED) sits between the rules
and `Outbox.accept/2`. Per `(device_id, instance_id)`: the first intent goes out
immediately and opens a 120 s window; further intents in the window are held; at window
end, one held intent is sent as itself, two or more become one `digest` intent whose
summary carries **counts per kind** and whose `retracts` lists nothing; its destination is
`target.kind: instance`; `urgency` = max of members. A held `urgency: high` Command is
never held longer than 120 s (it flushes at window end at the latest). `command.resolved`
retractions bypass the window (they only remove things).

The digest carries counts, not copy: `summary.title` = `"<n> updates"` is a placeholder the
device replaces per DESIGN-N4 digest layout; the structured counts travel in an additive
`summary.counts` field (`{"command.needs_you": 2, "progress.milestone": 1}`). Contract v2
§3 allows additive fields within `v: 1`.

## Dependencies and blockers

- C2-T02..T04 (intents to coalesce). DESIGN-N5 D-7 (digest wording) and DESIGN-N4 digest
  layout are **device-side** presentation; this ticket ships counts, so it is not blocked
  by them.

## Verified starting point

- N5 plan §5.5 (120 s window, digest example "3 updates on aiur: 2 Commands need you, build
  50 %"), AC-N5-6 (five intents in 30 s → one immediate + one digest).
- MP-N4 outbox `accept/2` (MP-N4-C3-T02).

## Chosen design

- Ledger keys of members are recorded when the digest is accepted (so a member never
  sends separately later).
- Digest `dedup_key = digest:<device>:<instance>:<window_start>`; `stream =
  digest:<instance>`; `expires_at` = max member expiry.
- Timer per (device, instance) in the policy process; injected clock for tests.

## Implementation steps

`policy/coalescer.ex` (PROPOSED); wire between rules and outbox; tests.

## Non-happy paths

Policy restart during a window → held intents are in memory only; the ledger has not
recorded them, so reconciliation regenerates still-relevant ones (Commands, progress);
opt-ins in the window may be lost (accepted: opt-in, live-class).

## Compatibility and rollout

Additive `summary.counts` field; old apps ignore it and show the placeholder title.

## Verification

`src/test/aiur/push/policy/coalescer_test.exs` (PROPOSED), clock-controlled (no sleeps):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"five intents in 30 s → one immediate + one digest"` (AC-N5-6) | 2 accepts, digest counts sum 4 | send all |
| `"single held intent is sent as itself"` | kind preserved | always digest |
| `"high Command never waits more than 120 s"` | flush at ≤ 120 s | extend window on new intents |
| `"retractions bypass the window"` | immediate | hold retractions |
| `"members never send separately after digest"` | ledger has member keys | record only digest key |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/policy/coalescer_test.exs`.

## Completion and handoff

- [ ] `summary.counts` matches contract v2 §3 (added in Phase C).
- Dependents: C3-T02, MP-N4-C4-T03/C5-T03 (render digest).
