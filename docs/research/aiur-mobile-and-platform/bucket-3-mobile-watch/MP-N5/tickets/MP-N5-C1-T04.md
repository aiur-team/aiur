---
ticket_id: MP-N5-C1-T04
feature_id: MP-N5
chunk_id: MP-N5-C1
bucket: 3-mobile-watch
title: Seed defaults at pairing and baseline progress trackers silently per instance
status: ready
blocked_by: [DESIGN-N5 (no-UI release), MP-N5-C1-T01, MP-N5-C2-T03, MP-N2-C5-T02]
prior_units: []
prior_boundaries: [new #41 candidate push-relay, pairing gateway]
prior_features: [MP-N2, MP-E1]
prior_findings: [N5 plan §5.2 rule 5 (baseline on enable)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C1-T04 — Seed and baseline

## Identity and outcome

Bucket 3, MP-N5, chunk C1. (1) When MP-N2 pairs a device, the gateway writes a D18 default
record for it in the same store write (no separate race). A direct-push watch child
(`parent_device_id`) is seeded from its parent's current record. (2) Each instance, on
first sight of a device (registry diff, like MP-N4-C3-T05) and whenever that device's
`progress_step_pct` changes, sets `last_notified_pct = floor(current / step) * step` for
every open progress scope — silently, so no retroactive milestones (N5 plan §5.2 rule 5;
AC-N5-4).

## Dependencies and blockers

- C1-T01 (record), C2-T03 (tracker state module), MP-N2-C5-T02 (claim endpoint hook).
- DESIGN-N5 no-UI release.

## Verified starting point

- Pairing contract §4.1 (claim creates the device row; `parent_device_id`).
- Progress facts from `Aiur.BuildProgress.facts/1` (MP-E1-C7, RC-10; queue-readiness
  contract §4.1, §5).

## Chosen design

- Gateway: `Preferences.seed(device_id, parent_device_id)` called inside the claim write.
- Instance: `Aiur.Push.Policy.Progress.baseline(device_id, step, facts)` writes tracker
  rows `{device_id, instance_id, scope, id, generation, last_notified_pct}`; it runs before
  the first evaluation for that device (ordering enforced in the policy process).

## Implementation steps

1. Gateway hook (MP-N2 gateway code path) + test.
2. Registry diff → baseline in the policy process; preference mtime change → re-baseline
   only devices whose step changed.

## Non-happy paths

- Progress facts unavailable at baseline time → baseline deferred until facts arrive;
  until then no progress notifications for that device (better silent than retroactive).
- Step changed to `0` (off) → trackers dropped.

## Compatibility and rollout

Additive.

## Verification

`src/test/aiur/push/policy/progress_baseline_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"changing step 25→10 at 63% emits nothing; next at 70%"` (AC-N5-4) | 0 intents, then one at 70 | skip re-baseline |
| `"new device at 80% gets no 25/50/75 backlog"` | 0 intents | baseline at 0 |
| `"watch child seeded from parent record"` | equal defaults | D18 defaults |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/policy/progress_baseline_test.exs`.

## Completion and handoff

- [ ] AC-N5-4 covered. Dependents: C2-T03.
- Docs: `website/docs-app/guide/` notifications page (owned by MP-N5-C5-T01) gains one
  sentence: enabling progress or changing the step never sends past milestones
  (Phase D T-6).
