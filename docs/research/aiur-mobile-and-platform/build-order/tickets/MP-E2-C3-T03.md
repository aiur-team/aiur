---
ticket_id: MP-E2-C3-T03
feature_id: MP-E2
chunk_id: MP-E2-C3
bucket: 2-platform
title: Dashboard replace-answer, already-answered and too-late states
status: blocked
blocked_by: [DESIGN-E2, MP-E2-C3-T02]
prior_units: [U6, U8]
prior_boundaries: [WEB #34, DEC #27]
prior_features: [MP-E4 (conversation link in the too-late state), MP-N6 (same copy)]
prior_findings: [D11, DESIGN-E2 §4.4, contract §6 rule 7]
size_owner: "WEB (decision_commands.ex 386; decision_action.ex 198; decision_revision_action.ex) — no file may pass 500"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C3-T03 — Dashboard replace-answer, already-answered and too-late states

## Identity and outcome

- Bucket 2, MP-E2, chunk C3. **Visible surface — blocked on DESIGN-E2 approval.**
- **User value:** on the dashboard you can replace the Executor's answer while it has not
  reached the agent, see who answered first when you lose a race, and see plainly when it
  is too late.
- **Deliverable:** dashboard answer and replace go through `Aiur.Commands.Answering`
  (C3-T02); a "Replace" action with confirmation; outcome notices for every DESIGN-E2
  §4.4 row; the revise control relabelled "Send correction".
- **Non-goals:** routing chips, timeline (C7); Stream Deck (C3-T04); phone (MP-N6).

## Dependencies and blockers

- **DESIGN-E2 approval** — specifically §4.4 copy ("Already answered by …", "Replace the
  Executor's answer? …", "Already delivered at … Send a follow-up message instead.") and
  §5 states (stale, resolved elsewhere, delivered). The drafts in DESIGN-E2 are not final;
  implement only the approved strings.
- Predecessor: C3-T02. Optional: MP-E4 conversation route for the "follow-up message" link
  (if absent, link to the unit's chat via the existing `/chat/:owner/:repository/:identifier`
  route, `router.ex:141`).
- May run concurrently with C3-T04, C7-T01.

## Verified starting point (`45a290e3`)

- Events: `aiur_web/operator_control_center/decision_events.ex:11-16,26-62`
  (`answer-decision`, `defer-decision`, `dismiss-decision`, `retry-decision`,
  `revise-decision`).
- Commands: `decision_commands.ex:24-99` (`record_answer/4`, `submit_answer/4` building
  the payload with `idempotency_key` + `expected_version`), `:174` direct
  `DecisionStore.answer/4`; error copy `:347-380` (`already_decided` → generic message
  at `:350`).
- Components: `components/operator_control_center/decision_action.ex` (198 lines;
  `Defer to Executor` `:117`, `Retry delivery` `:166`),
  `decision_revision_action.ex:46` ("Revise Command"), `:85` (`revise-decision` form),
  `decision_detail.ex`, `decision_card.ex`.
- Tests: `src/test/aiur_web/live/dashboard_live_test.exs`.

## Chosen design

- New LiveView event `replace-decision` (PROPOSED) handled by `decision_events.ex` →
  `DecisionCommands.replace/4` → `Answering.supersede/3` with actor
  `DecisionCommands.actor/0` and `client: %{surface: :dashboard}`.
- `record_answer/4` switches from `DecisionStore.answer/4` to `Answering.answer/3`;
  notices render from the outcome atom, not from error tuples (one mapping function
  `outcome_notice/1` in a PROPOSED `aiur_web/operator_control_center/decision_outcomes.ex`
  so `decision_commands.ex` does not grow).
- "Replace" is shown only when: active answer actor is `:executor`, not delivered, not in
  flight (`ConflictSummary` booleans). It opens a confirmation (DESIGN-E2 §4.4 row 5),
  then the normal answer form pre-filled empty.
- After `:too_late`, the form is disabled and the follow-up link is shown.
- Relabel `decision_revision_action.ex:46` heading and button to the approved
  "Send correction" wording (contract §6 rule 7); behaviour unchanged.

## Implementation steps

1. `decision_outcomes.ex` (new, ≈120 lines): outcome → `{level, text, actions}`.
2. `decision_commands.ex`: route answer through `Answering`; add `replace/4`.
3. `decision_events.ex`: `replace-decision` clause.
4. `decision_action.ex`: Replace button + confirm (behind the visibility rule).
5. `decision_revision_action.ex`: relabel.

## Non-happy paths

- Stale view (409-equivalent `:stale`): "This Command changed. Refresh …" + reload.
- Store unavailable: existing message (`decision_commands.ex:369-372`).
- Observe-only dashboard (`dashboard_writable` false): actions hidden as today; note live
  bug #3010 (`dashboard_writable` defaults true) — do not change that default here.
- Race: Replace clicked as delivery confirms → `:too_late` notice (store guard is the
  authority, the button state is only a hint).

## Compatibility and rollout

- UI only; no config. Older clients (none) unaffected.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur_web/live/dashboard_live_test.exs test/aiur_web/operator_control_center/decision_outcomes_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| "Replace shown for undelivered executor answer only" | button present for executor+undelivered; absent for operator answer, delivered, in flight | visibility rule |
| "replace-decision records an operator revision" | store active answer actor operator | step 2–3 |
| "losing an answer race shows the winner" | notice contains winner actor and time from `ConflictSummary` (assert the value, not only the string) | outcome mapping |
| "too late after delivery disables the form and links to the conversation" | form disabled; link href to the unit chat | `:too_late` branch |
| "unknown outcome renders a neutral error, not success" (AGENTS.md unknown-branch rule) | replace `outcome_notice/1`'s `:error` branch with the success text → test fails | error branch |
| "revise is labelled Send correction" | label present | step 5 |

Mutation check per row. Browser check at 390 px width (`ce-test-browser` or Playwright)
for `/commands/:id` with each state. Manual: `aiurdev --test` wrapper-tmux; answer a
Command as Executor (`scripts/aiurdev executor-answer …`), replace it in the dashboard
before the worker turn picks it up, and confirm the agent chat pane (0.1) shows the
replacement answer, not the original.

## Completion and handoff

- [ ] Approved copy only; every §4.4 row reachable in tests.
- Docs: `website/docs-app/guide/gui.md` Commands section (replace,
  send correction) — the page that documents `/commands` today.
- Dependents: C7-T02, MP-N6 (same outcome atoms).
