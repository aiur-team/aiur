---
ticket_id: MP-N6-C1-T00
feature_id: MP-N6
chunk_id: MP-N6-C1
bucket: 3-mobile-watch
title: Post-refactor path refresh for the device Command API
status: ready
blocked_by: [DESIGN-N6 (no-UI release), MP-R1-C1-T04, MP-R1-C1-T05, MP-E2-C1-T01, MP-E2-C3-T01, MP-N2-C6-T01]
prior_units: [as landed by MP-R1]
prior_boundaries: [DEC #27, WEB #34]
prior_features: [MP-R1, MP-E2, MP-N2]
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C1-T00 — Plan refresh

## Identity and outcome

Bucket 3, MP-N6, chunk C1. Documentation-only: map the pre-refactor router, controller and
DecisionStore paths cited by MP-N6-C1-T01..T04 to the post-refactor `web-shell` and
`commands` packages, and confirm the shapes predecessors shipped:

| Cited at `45a290e3` | Confirm against |
| --- | --- |
| `src/lib/aiur_web/router.ex:48-62` (`:api_write`, `:require_writable`), `:111-199` (dashboard scopes, `/api/v1/:issue_identifier` catch-alls) | `web-shell` router |
| `Aiur.DecisionStore.answer/5` (`decision_store.ex:190`), `supersede/5` (`:287`), `get/2` (`:388`), `list/1` (`:393`) | `commands` package |
| `Aiur.DecisionAnswer` payload keys `idempotency_key`, `expected_version`, `option_id`, `custom_response` (`decision_answer.ex:55-59`), `@response_max 4_000` (`:15`) | `commands` package |
| E2 v2 fields (`requester`, `short_label`, `route_*`, `human_visible_at`) | MP-E2-C1-T01 as landed |
| `{:conflict, {:already_decided, _}}` winner summary | MP-E2-C3-T01 as landed |
| device-auth pipeline name and `conn.assigns.device_id` | MP-N2-C6-T01 as landed (CR-N6-1) |

## Dependencies and blockers

Frontmatter. DESIGN-N6 releases C1 (no UI).

## Verified starting point

As in the table.

## Chosen design

Record the mapping in MP-N6 `plan.md` §10 and in each C1 ticket. Any shape that differs
from MP-N6's assumptions becomes a CONTRACT-REQUEST, not a workaround.

## Implementation steps

Read landed code; update tickets; list deferrals.

## Non-happy paths

E2-C3-T01 not landed → C1-T03 ships without the winner summary and says so in the API
(`winner: null`); the app shows "Already answered" without who/when until it lands.

## Compatibility and rollout

n/a — documentation.

## Verification

Reviewer checklist: every symbol resolves at the refresh SHA.

## Completion and handoff

- [ ] Mapping committed. Dependents: C1-T01..T04.
- [ ] Docs: none, because this is a plan refresh with no user-visible change.
