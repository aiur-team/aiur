---
ticket_id: MP-E2-C7-T01
feature_id: MP-E2
chunk_id: MP-E2-C7
bucket: 2-platform
title: Inbox routing chips, filters, banner counts and fleet Commands column
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C2-T03, MP-E2-C1-T04]
prior_units: [U6, U8]
prior_boundaries: [WEB #34]
prior_features: [MP-N3 (meta-dashboard counts reuse the same split), MP-N5 (D18 notifications count "needs you")]
prior_findings: [DESIGN-E2 §2 items 1–2, §4.1 routing chip, §6.2 banner, §6.3 wording]
size_owner: "WEB (decision_inbox.ex 154; overview.ex 173; fleet_table.ex 194; decision_card.ex 244)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C7-T01 — Inbox routing chips, filters, banner counts and fleet Commands column

## Identity and outcome

- Bucket 2, MP-E2, chunk C7 (surfaces). **Visible — blocked on DESIGN-E2.**
- **User value:** the inbox tells you which Commands are yours to answer now, which the
  Executor is handling, and which came from the Executor; the overview banner counts only
  what needs you (if Kevin approves §6.2).
- **Deliverable:** routing chip per row (`route_state` → approved label), filter bar
  (Needs you / With Executor / From Executor / Resolved), banner counts per §6.2, fleet
  `Commands` column semantics per §6.2.
- **Non-goals:** detail view (C7-T02); unit row (C7-T03); CLI (C7-T04).

## Dependencies and blockers

- **DESIGN-E2 open items that block this ticket by name:**
  - §6.2 `[decide]`: do "With Executor" Commands count in the banner / fleet column?
  - §6.3 / §4.1 `[decide]`: exact chip wording for `with_executor`, `with_human`,
    `with_both`, executor requester.
  - §5: loading, empty ("No Commands need you" draft), offline, permission-denied, stale
    states for the inbox.
- Data: C2-T03 (route facts), C1-T04 (serialized fields). If C6-T04 landed, merge its
  "From Executor" filter into this bar.

## Verified starting point (`45a290e3`)

- `src/lib/aiur_web/components/operator_control_center/decision_inbox.ex` (154; heading
  `:42`).
- `overview.ex:35-90` `decisions_banner/1`; CTA "Issue commands" `:65`; unavailable copy
  `:83`; `banner_title/2` `:166-169` ("1 unit awaiting commands" / "N units …").
- `fleet_table.ex:39` `Commands` header; `:72-74` `row.open_decision_count` chip.
- `decision_card.ex:127` status badge `Deferred to Executor`.
- Presenter rows `aiur_web/operator_control_center/decision_presenter.ex:50-95`;
  counts `DecisionProvider.counts/1` → `DecisionQuery.counts/1` (`decision_provider.ex:58-59`).

## Chosen design

- Presenter adds `route_state`, `routed_at`, `human_visible_at` (from C1-T04/C2-T02).
  A Command with no `route_state` (routing not yet run, or older log) renders the
  **unknown** chip (approved wording; draft "Routing…"), never a guessed state.
- Filter param `route=needs_you|with_executor|from_executor|resolved` (URL, shareable).
  `needs_you` = open ∧ `route_state in [:with_human, :with_both]`.
- `DecisionQuery.counts/1` (read through `DecisionProvider.counts/1`) gains the field
  `needs_you`, computed from the projection with `needs_you?/1`, **whatever §6.2
  decides**. It is the public read MP-N3-C1-T03 calls without the LiveView, so the
  phone count matches the dashboard (Phase D, CR-N3-2).
- Banner: if §6.2 approves "only needs you", the banner reads that field; otherwise
  unchanged.
- Fleet column: same rule as the banner (one helper, `Aiur.Commands.Routing.Policy.needs_you?/1`).
- Age rendering: rows show "asked N min ago" from `created_at` and, when routed to the
  human by escalation, "needs you since …" from `human_visible_at` (AGENTS.md: a computed
  age is rendered, not only plumbed).

## Implementation steps

1. Presenter fields; `needs_you?/1` helper.
2. `decision_inbox.ex`: filter bar + chips; states per §5.
3. `overview.ex`, `fleet_table.ex`: counts via the helper (only if §6.2 says so).
4. `DecisionQuery.counts/1`: `needs_you` count.

## Non-happy paths

- Routing process down / store read-only: rows keep the last durable `route_state`; the
  inbox banner shows the existing unavailable copy (`overview.ex:83`) when counts are
  unknown — never "0 need you".
- Partial retained data: filter results labelled partial (existing `health`).

## Compatibility and rollout

- UI only; the banner behaviour change is exactly §6.2's decision.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test test/aiur_web/live/dashboard_live_test.exs test/aiur/decision_query_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "needs_you filter shows with_human and with_both only" | row ids equal fixture set | filter |
| "row without route_state shows the unknown chip" — then replace that branch with `with_executor`'s label and confirm the test fails (AGENTS.md unknown-branch rule) | unknown label | unknown branch |
| "banner counts needs-you only" (if §6.2 approves) | count = 2 for a fixture with 2 needs-you + 3 with-executor | step 3 |
| "counts unavailable shows unavailable copy, not zero" | `:83` copy | unavailable branch |
| "needs-you-since age rendered from human_visible_at" | text contains the minutes computed from the fixture clock and the value equals `now - human_visible_at` | age rendering |

Mutation check per row. Browser check at 390 px and 1280 px for `/commands` with each
filter. Manual: `aiurdev --test`; a with-executor Command, then let it escalate (short
`executor_answer_ms` scratch config) and watch the chip change without reload.

## Completion and handoff

- [ ] Approved wording; §6.2 rule implemented; unknown/unavailable branches tested.
- Docs: `website/docs-app/guide/gui.md` Commands section (chips, filters).
- Dependents: MP-N3, C8-T01.
