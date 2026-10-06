---
ticket_id: MP-N6-C1-T02
feature_id: MP-N6
chunk_id: MP-N6-C1
bucket: 3-mobile-watch
title: GET /api/v1/device/commands?state=needs_you — reconciliation list on app open
status: ready
blocked_by: [DESIGN-N6 (no-UI release), MP-N6-C1-T01, MP-E2-C2-T02]
prior_units: []
prior_boundaries: [DEC #27, WEB #34]
prior_features: [MP-E2, MP-N3]
prior_findings: [N4 plan §7.3 (push is not a queue; app reconciles on open)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C1-T02 — Needs-you list

## Identity and outcome

Bucket 3, MP-N6, chunk C1. `GET /api/v1/device/commands?state=needs_you` returns the
instance's Commands that currently need the human (E2: `human_visible_at` set and status
answerable and not yet answered), as compact rows `{decision_id, version, short_label,
requester, blocking, urgency, created_at, human_visible_at}` plus `observed_at`, `age_ms`,
`freshness` and a `count`. Used on app open and foreground to reconcile delivered
notifications (C6-T02) and by MP-N3 for "Commands awaiting" counts.

## Dependencies and blockers

C1-T01 (scope), MP-E2-C2-T02 (`human_visible_at` maintained by the routing engine).
DESIGN-N6 no-UI release.

## Verified starting point

- `Aiur.DecisionStore.list/1 :: [Decision.t()]` (`decision_store.ex:393`).
- Answerable rule: retired = `:expired | :moot | :resolved` (`decision_store.ex:1440`);
  `dismissed`/`deferred` still accept answers (command contract §6 rule 6).
- `state` values other than `needs_you` are not offered in v1 (`422 unsupported_state`).

## Chosen design

Rows ordered blocking first, then `human_visible_at` ascending. Hard cap 200 rows with
`truncated: true` (more than 200 open blockers is itself an alarm the dashboard shows).

## Implementation steps

`index/2` in `DeviceCommandController`; reuse the view builder for row fields.

## Non-happy paths

Store unavailable → `503`; the app keeps last-known rows with their age and shows stale
(never zero; pairing contract §9 "never zeros").

## Compatibility and rollout

Additive.

## Verification

Same test file as C1-T01:

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"lists only human-visible open Commands"` | excludes `with_executor`-only and answered | list all open |
| `"deferred still listed, resolved not"` | as stated | treat deferred as terminal |
| `"store down is 503, not an empty list"` | 503 | return `[]` (unknown-path rule) |
| `"age_ms and freshness present"` | present | omit |

Commands (from `src/`): `mise exec -- mix test test/aiur_web/controllers/device_command_controller_test.exs`.

## Completion and handoff

- [ ] Dependents: C6-T02, MP-N3 counts.
- [ ] Docs (same PR): the "Device API" section of `website/docs-app/guide/mobile-pairing.md`
  (MP-N2-C9) lists `GET /api/v1/device/commands?state=needs_you`, its row fields and the
  200-row cap.
