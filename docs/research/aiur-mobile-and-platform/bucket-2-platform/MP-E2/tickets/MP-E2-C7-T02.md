---
ticket_id: MP-E2-C7-T02
feature_id: MP-E2
chunk_id: MP-E2-C7
bucket: 2-platform
title: Command detail — escalation timeline and native multi-question form
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C2-T02, MP-E2-C2-T04, MP-E2-C3-T02, MP-E2-C1-T02]
prior_units: [U6, U8]
prior_boundaries: [WEB #34]
prior_features: [MP-E4 (conversation anchor link), MP-E5 (mic placement on custom response), MP-N6 (same anatomy)]
prior_findings: [DESIGN-E2 §4.1–§4.4, contract §5 causes, §6]
size_owner: "WEB (decision_detail.ex 164; decision_action.ex 198; history.ex 300) — new components for the timeline and the multi-question form"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C7-T02 — Command detail: escalation timeline and native multi-question form

## Identity and outcome

- Bucket 2, MP-E2, chunk C7. **Visible — blocked on DESIGN-E2.**
- **User value:** on one page you see why a Command reached you (timeline with causes and
  times), and you can answer a native multi-question request in one submit, with the
  recommended option first and "Other" always available.
- **Deliverable:** PROPOSED components `decision_timeline.ex` and
  `decision_questions_form.ex`; detail view composes them; suggested-response ordering.
- **Non-goals:** supersede states (C3-T03 owns them; this page hosts them).

## Dependencies and blockers

- **DESIGN-E2 items blocking by name:** §4.2 `[decide]` multi-question layout (one card +
  single Submit vs stepper) and multi-select presentation; §4.2 `[decide]` 4-option native
  exception; §4.3 timeline anatomy and cause wording (the cause atoms are the contract §5
  list; DESIGN-E2's names are being aligned — CONTRACT-REQUESTS.md); §5 states.
- MP-E5 decides mic placement on the custom-response field (D16) — leave a slot.
- MP-E4: "Open conversation at this point" link — render only when the E4 anchor exists.

## Verified starting point (`45a290e3`)

- `components/operator_control_center/decision_detail.ex:12-20` attrs (`decision`,
  `history`, `action_state`, `writable`, `filter`, `query`), 164 lines.
- `decision_action.ex` (answer form, `Defer to Executor` `:117`, `Retry delivery` `:166`).
- `history.ex:224-266` history rows (`Deferred to Executor`, `Handed to the Executor`,
  `Executor answer`).
- Answer submit: `operator_control_center/decision_commands.ex:84-99` (C3-T02/T03 route it
  through `Answering`).

## Chosen design

- **Timeline** from durable facts only (`routed`, `escalated`, `executor_acknowledged`,
  `human_needed`, `answer_recorded`, `revision_recorded`, `delivered`,
  `native_released`, `requester_notified`) read via `DecisionStore.audit_history/2`
  (`decision_store.ex:514`) — no inferred steps. Each entry: label (approved copy for the
  cause), absolute time, relative age. Unknown fact types render a neutral "Updated"
  entry (never dropped silently).
- **Questions form** (only when `questions != []`): one fieldset per question; radio
  (single) or checkbox (multi-select); "Other" text input when `allow_other`; client and
  server validation that every question is answered (C3-T02 rejects partial); submits
  `question_answers`.
- **Suggested responses** (single-question Commands): recommended option first and marked
  (approved label, draft "Recommended"); options beyond 3 for agent-authored Commands
  still render (the rule is a warning, C1-T02).

## Implementation steps

1. `decision_timeline.ex` (≈120 lines), `decision_questions_form.ex` (≈150 lines).
2. `decision_detail.ex`: compose; pass `audit_history`.
3. `decision_events.ex`/`decision_commands.ex`: accept `question_answers` form params.

## Non-happy paths

- Audit history unavailable: timeline shows the approved unavailable state, not an empty
  list presented as "nothing happened".
- Stale view (version moved): submit returns `:stale` → C3-T03 notice.
- Secret questions never reach this page (C4-T01).

## Compatibility and rollout

- UI only.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test test/aiur_web/live/dashboard_live_test.exs test/aiur_web/components/operator_control_center/decision_timeline_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "timeline lists routed → escalated(executor_answer_timeout) → human_needed with times" | three entries in order, times equal fixture facts | timeline |
| "unknown fact type renders neutral entry" — swap that branch for dropping the entry and confirm the test fails | entry present | unknown branch |
| "audit unavailable shows unavailable state" | approved copy, not empty timeline | unavailable branch |
| "two-question native Command requires both answers" | submit with one answered → validation error, store not called | form validation |
| "multi-select submits a list" | `question_answers.q2 == ["a","b"]` | checkbox mapping |
| "recommended option rendered first and marked" | first option id = recommendation | ordering |

Mutation check per row. Browser check at 390 px (single and multi-question). Manual:
`aiurdev --test` with Codex capture on (C4 scratch config); answer a two-question native
Command in the detail view; pane `0.1` shows both answers in the tool result.

## Completion and handoff

- [ ] Approved copy; timeline from facts; form validated both sides.
- Docs: `guide/gui.md` (detail view), `concepts/commands.md` (C8-T01).
- Dependents: MP-N6 (reuses anatomy), MP-E5 (mic slot).
