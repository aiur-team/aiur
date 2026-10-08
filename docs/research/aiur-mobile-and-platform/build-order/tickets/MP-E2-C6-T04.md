---
ticket_id: MP-E2-C6-T04
feature_id: MP-E2
chunk_id: MP-E2-C6
bucket: 2-platform
title: Dashboard "From Executor" filter and badge
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C6-T01, MP-E2-C1-T04]
prior_units: [U6, U8]
prior_boundaries: [WEB #34]
prior_features: [MP-N3 (counts), MP-N6]
prior_findings: [DESIGN-E2 §2 item 4, §6.6 (one inbox with a filter vs separate section)]
size_owner: "WEB (decision_inbox.ex 154; decision_card.ex 244; units_filters)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C6-T04 — Dashboard "From Executor" filter and badge

## Identity and outcome

- Bucket 2, MP-E2, chunk C6. **Visible surface — blocked on DESIGN-E2 §6.6.**
- **User value:** you can see at a glance which Commands the Executor itself is asking you,
  and filter to just those.
- **Deliverable:** a requester badge on inbox rows and the detail header for
  `requester.kind == :executor`; a "From Executor" filter on `/commands` (URL param, so
  the link is shareable); the requester line ("Executor" instead of `#<ticket>`).
- **Non-goals:** the other routing chips and filters (C7-T01 — this ticket adds only the
  requester dimension; if C7-T01 lands first, add the filter to its filter bar).

## Dependencies and blockers

- **DESIGN-E2 §6.6** decides one inbox + filter (proposed) vs a separate section; §4.1
  decides the requester-line wording. If Kevin picks a separate section, this ticket's
  filter becomes a section with the same query.
- Predecessors: C6-T01 (data), C1-T04 (presenter field `requester`).

## Verified starting point (`45a290e3`)

- `src/lib/aiur_web/components/operator_control_center/decision_inbox.ex` (154 lines;
  heading `Commands inbox` `:42`); `decision_card.ex` (244; status badges incl.
  `Deferred to Executor` `:127`); `decision_detail.ex`.
- Row data: `aiur_web/operator_control_center/decision_presenter.ex:50-95` (`ticket`,
  `source` today; `requester` after C1-T04).
- Query: `Aiur.DecisionQuery.list/2` via `DecisionProvider.list/2`
  (`decision_provider.ex:41-54`); filters for CLI are `~w(all open blocking resolved)a`
  (`commands_cli.ex:7`).
- Routes `/commands`, `/commands/:decision_id` (`router.ex:142-143`).

## Chosen design

- Filter param `requester=executor` handled in the provider (post-filter of the page rows
  when `DecisionQuery` has no requester index; document that counts for this filter are
  computed over the retained page, labelled as such — AGENTS.md "collapsed cause" rule:
  never show a partial count as total).
- Badge text and filter label: DESIGN-E2 §4.1 / §6.6 (draft "From Executor").
- Requester line: `Executor` for executor requests; `#<ticket> · <agent>` otherwise.

## Implementation steps

1. `decision_provider.ex`: requester filter.
2. `decision_inbox.ex`: filter control + empty state ("No Commands from the Executor",
   copy per DESIGN-E2 §5).
3. `decision_card.ex`, `decision_detail.ex`: badge + requester line.

## Non-happy paths

- Pre-C1 Commands (no requester): treated as worker.
- Retained data partial (existing `health.partial?`): filter result labelled partial, never
  "0 from Executor" when unknown (AGENTS.md unknown-branch rule).

## Compatibility and rollout

- UI only.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur_web/live/dashboard_live_test.exs test/aiur_web/operator_control_center/decision_provider_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "requester=executor shows only executor Commands" | rows' `requester.kind` all executor; count equals fixture | provider filter |
| "executor Command row shows the badge and Executor requester line" | badge present; no `#executor` ticket text | card change |
| "partial retained data labels the filtered list partial" | partial notice; replace with a plain count → test fails | partial branch |
| "empty state" | approved empty copy | inbox change |

Mutation check per row. Browser check at 390 px for `/commands?requester=executor`.

## Completion and handoff

- [ ] Approved copy; filter + badge.
- Docs: `website/docs-app/guide/gui.md` Commands row (filter).
- Dependents: C7-T01 (merges into its filter bar), MP-N3.
