---
ticket_id: MP-E2-C7-T03
feature_id: MP-E2
chunk_id: MP-E2-C7
bucket: 2-platform
title: Unit row shows "waiting for your answer" while a native question is held
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C4-T02, REFRESH-MP-E2-C7-T03-4fbe1095]
prior_units: [U6, U8]
prior_boundaries: [WEB #34, LIFECYCLE]
prior_features: [MP-N3 (instance status), MP-R6 (Stream Deck unit faces may reuse)]
prior_findings: [DESIGN-E2 §6.8]
size_owner: "WEB (units_table.ex 412; units_presenter.ex; units_policy.ex); LIFECYCLE (status_report.ex — one field)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C7-T03 — Unit row: "waiting for your answer" while a native question is held

## Identity and outcome

- Bucket 2, MP-E2, chunk C7. **Visible — blocked on DESIGN-E2 §6.8.**
- **User value:** a unit that is blocked inside its own question no longer looks
  "Running"; you see it is waiting for you and can jump to the Command.
- **Deliverable:** the running entry's `:native_hold` (C4-T02) flows into the status
  report and the units row; the row shows the approved label (draft "Waiting for your
  answer") with a link to `/commands/:decision_id`, and the attention tone.
- **Non-goals:** TUI AgentList (follow-up if DESIGN-E2 wants it there too — not in §3).

## Dependencies and blockers

- **DESIGN-E2 §6.8** `[proposal]` label and whether it uses the blocked (red) tone.
- C4-T02 (`native_hold` on the running entry).

## Verified starting point (`45a290e3`)

Refreshed against 4fbe109541ba1e279d3eb315d8455c4d139c92ba on 2026-10-26 (MP-R1-C11-T03). Mechanical matches were byte-checked; current starting-point ranges still need the named source review `REFRESH-MP-E2-C7-T03-4fbe1095`. Do not implement from the historical ranges below. base_sha and all prior gates are retained; this is not a design rejection.

- `src/lib/aiur/orchestrator/status_report.ex:1040-1070` running-entry fields
  (`last_codex_event`, `last_codex_timestamp` at `:1060-1062`).
- `src/lib/aiur_web/operator_control_center/units_presenter.ex:31-46` builds rows with
  `activity` from `TicketActivity.snapshots/0`; `units_policy.ex` conditions.
- `src/lib/aiur_web/components/operator_control_center/units_table.ex:321-342` row tone
  (`is-blocked` from `reasons.blocking`, `has-alert`).

Refreshed against 47140566ffbf8d8ae9b6e031dbedaf0fc3c6ae9f on 2026-10-14 (MP-R1-C11-T02). Verified citations: `src/lib/aiur_web/operator_control_center/units_presenter.ex:29-44`, `src/lib/aiur_web/components/operator_control_center/units_table.ex:295-316`. base_sha retained; other citations need review.

## Chosen design

- `status_report.ex`: add `native_hold: %{decision_id, since}` (or nil) to the running
  entry export.
- `units_presenter.ex`: `reasons.native_hold` → condition `:waiting_on_you` in
  `units_policy.ex`; label + link; age "for N min" from `since` (rendered — AGENTS.md).
- Tone: per §6.8 (proposed: same as blocking).

## Implementation steps

1. `status_report.ex` field (≈3 lines).
2. `units_presenter.ex` + `units_policy.ex` condition (≈30 lines).
3. `units_table.ex`: label/link render (≈15 lines; keep file ≤ 500 — it is 412).

## Non-happy paths

- Status report unavailable: existing unavailable row handling; never infer "waiting".
- Hold released but event lost: `native_hold` cleared on the next
  `:native_question_resolved`; if the runner died, the entry disappears with it.

## Compatibility and rollout

- UI + one status field; JSON consumers ignore unknown fields.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur_web/components/operator_control_center/units_table_test.exs test/aiur/orchestrator/status_report_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "status report exports native_hold" | field equals running entry value | step 1 |
| "unit with native_hold shows waiting label and Command link" | label + href `/commands/<id>` | steps 2–3 |
| "age renders from since" | minutes equal fixture clock delta | age render |
| "unit without native_hold unchanged" | today's label | guard |

Mutation check per row. Manual: `aiurdev --test` with Codex capture; while held, the
dashboard units table and `aiurdev agents` show the waiting state.

## Completion and handoff

- [ ] Approved label/tone.
- Docs: `guide/gui.md` units section (one line).
- Dependents: MP-N3.
