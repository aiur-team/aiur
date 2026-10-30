---
ticket_id: MP-N5-C3-T03
feature_id: MP-N5
chunk_id: MP-N5-C3
bucket: 3-mobile-watch
title: Send-time staleness hook for the push outbox (no burst after reconnect)
status: ready
blocked_by: [DESIGN-N5 (no-UI release), MP-N4-C3-T02, MP-N5-C3-T01]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: [MP-N4]
prior_findings: [N5 plan §5.6, AC-N5-8, AC-N4-7, events-and-replay §7.2 rule 6]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C3-T03 — Staleness hook

## Identity and outcome

Bucket 3, MP-N5, chunk C3. Implement `Aiur.Push.Outbox.StalenessHook` (behaviour from
MP-N4-C3-T02) as `Aiur.Push.Policy.Staleness` (PROPOSED). The outbox calls it before
sealing each due job (also after restart and after a relay outage):

| Job | Check | Result |
| --- | --- | --- |
| `command.needs_you` | Command still open and human-visible (public `Aiur.Commands.get/1,2`; adapter pending CR-N5-PATH-1) | `:send`, else `{:drop, :resolved}` |
| any | a newer job on the same `(device, stream)` is queued | `{:drop, :superseded}` |
| progress / opt-in / pr.merged | age > `push.outbox.max_age_seconds` (default 24 h) | `{:drop, :stale}` |
| several still-open Commands older than max age for one (device, instance) | — | `{:fold, digest}`: one digest naming the count |
| any | `expires_at` passed | `{:drop, :expired}` |

Result: after a 3 h relay outage with 4 open Commands (2 resolved meanwhile), the device
gets one digest naming 2 Commands and nothing about the resolved ones (AC-N5-8; V-R1/V-R2).

## Dependencies and blockers

MP-N4-C3-T02 (hook behaviour), C3-T01 (digest builder). DESIGN-N5 no-UI release.

## Verified starting point

Path refresh at `3b00b8f2cd0bfc9acdffe3b07ee5f1c6ca2ab56a` (2026-10-27).
See [plan §10](../plan.md#10-notification-policy-starting-point) for the complete
mapping, topic catalog and integration gates. Historical `base_sha` is retained.
All `policy/**`, `Aiur.Push.*` and push test paths here are **PROPOSED** under
`push-relay`; this refresh does not assert they shipped.

- Private `DecisionStore.get/2` is now `src/lib/aiur/decision_store.ex:365`.
  Public `Aiur.Commands.get/1,2` (`commands.ex:36-37`) returns a retained-read
  envelope, not a bare Decision; see CR-N5-PATH-1 before implementing the lookup.
- Unavailable/indeterminate reads must remain distinct from `:not_found`.
- Outbox `StalenessHook` and supervisor registration remain PROPOSED MP-N4 APIs;
  device open-time reconciliation remains MP-N6-C6-T02.

## Chosen design

- The hook is pure given a `lookup` function (injected), so tests do not need a store.
- Fold: the outbox writes terminal `{:dropped, :folded}` for folded jobs and accepts the
  digest as a new intent through the policy (ledger key
  `digest:<device>:<instance>:stale:<date-hour>`).

## Implementation steps

`policy/staleness.ex` (PROPOSED); register as the outbox hook in `Aiur.Push.Supervisor`.

## Non-happy paths

`DecisionStore` unavailable → `:send` for Commands (prefer a possibly-stale blocker over a
lost one); the device's open-time reconciliation (MP-N6-C6-T02) corrects it.

## Compatibility and rollout

Replaces MP-N4's default hook (expiry only).

## Verification

`src/test/aiur/push/policy/staleness_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"3 h outage, 4 open Commands, 2 resolved → one digest naming 2"` (AC-N5-8) | 1 digest, counts 2 | send each Command |
| `"resolved Command job dropped at send time"` | `{:drop, :resolved}` | check at intent time only |
| `"older milestone superseded by newer on same stream"` | old dropped | no stream check |
| `"store unavailable sends the Command"` | `:send` | drop on error (unknown-path rule: replace with `{:drop, _}` and the test fails) |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/policy/staleness_test.exs`.

## Completion and handoff

- [ ] AC-N5-8 covered; feeds MP-N4-C7 V-R1/V-R2.
- Dependents: MP-N4-C7-T02.
