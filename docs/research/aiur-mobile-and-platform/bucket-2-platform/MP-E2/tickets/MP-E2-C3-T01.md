---
ticket_id: MP-E2-C3-T01
feature_id: MP-E2
chunk_id: MP-E2-C3
bucket: 2-platform
title: Refuse Executor supersede of a human answer; add ConflictSummary
status: blocked
blocked_by: [DESIGN-E2]
prior_units: [U6]
prior_boundaries: [DEC #27]
prior_features: []
prior_findings: [D11, contract §6 rules 1 and 4, plan §1.1 ("supersede has no actor restriction")]
size_owner: "DECISIONS (decision_store.ex — one guard in supersede_current)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C3-T01 — Refuse Executor supersede of a human answer; add `ConflictSummary`

## Identity and outcome

- Bucket 2, MP-E2, chunk C3 (answer resolution).
- **User value:** once you answer a Command, the Executor cannot silently replace your
  answer; and every surface that loses an answer race can say who won and when.
- **Deliverable:**
  1. Store guard: `supersede` by an `:executor` actor is refused with
     `{:conflict, {:human_answer, action_id}}` when the active answer's actor is human.
  2. PROPOSED `Aiur.Commands.ConflictSummary.for/1` →
     `%{actor_kind, actor_id, summary, accepted_at, delivery_status, delivered?, in_flight?}`.
  3. `ExecutorCommandCLI` error copy for the new refusal; 409 body in the supervisor API
     gains `"winner"` (summary) for `already_decided` conflicts.
- **Non-goals:** human supersede path (C3-T02); UI (C3-T03); changing the conflict tuple.

## Dependencies and blockers

- Blocked by **DESIGN-E2** (pack rule; behaviour is settled by D11).
- #3005 (open, `agent:ci-wait`) adds actor kind `operator_relayed`; `human?/1` below
  includes it when present (`DecisionAnswer` actor kinds at base:
  `decision_answer.ex:17-19`).
- May run concurrently with every C1/C2 ticket.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/decision_store.ex:1206-1225` `handle_supersede/4` (only `fetch_actor/1`,
  no kind check); `:1227-1238` `supersede_current/4` → `require_supersedable/1`
  `:1240-1248` → `require_withdrawable/1` `:1965-1971`.
- `:1557` `{:conflict, {:already_decided, accepted.action_id}}`.
- `src/lib/aiur/decision.ex:211-214` `active_answer/1`; `:234-240` `delivered?/1`;
  `:256-257` `send_in_flight?/1`.
- `src/lib/aiur/executor_command_cli.ex:148-159` supersede call; `:253-281` error mapping
  (`answer_delivered`, `answer_in_flight`).
- `src/lib/aiur_web/controllers/decision_api_controller.ex:114-116` 409 render.
- Tests: `src/test/aiur/decision_withdrawal_test.exs`, `executor_command_cli_test.exs`,
  `decision_api_controller_test.exs`.

## Chosen design

- `Aiur.Commands.Answering.human_actor?/1` (defined here, reused by C3-T02):
  `kind in [:operator, :operator_relayed]` (atom compared by name so code compiles before
  #3005).
- Guard placed in `supersede_current/4` before `require_supersedable/1`:

  ```elixir
  with :ok <- Aiur.Commands.Answering.require_actor_may_supersede(actor, Decision.active_answer(decision)) do
  # executor actor + human active answer -> {:error, {:conflict, {:human_answer, active.action_id}}}
  ```

  `handle_supersede/4` passes the fetched actor through (today it discards it as
  `_actor`). Replays (`find_revision_replay`) are unaffected.
- `ConflictSummary.for(decision)`: reads `Decision.active_answer/1`; `summary` = option
  label (from `decision.options`) or the first 120 chars of `custom_response`;
  `delivery_status` from the Decision; booleans from `delivered?/1` / `send_in_flight?/1`.
  Pure; callers already hold the Decision or `get/2` it after a conflict.
- API 409 for `{:conflict, {:already_decided, _}}` adds `"winner": ConflictSummary` (the
  controller already has the decision id; one `DecisionStore.get/2`).

## Implementation steps

1. PROPOSED `src/lib/aiur/commands/conflict_summary.ex` (≈60 lines);
   PROPOSED `src/lib/aiur/commands/answering.ex` (start with `human_actor?/1` and
   `require_actor_may_supersede/2`; C3-T02 grows it).
2. `decision_store.ex`: thread actor into `supersede_current/4`; add the `with` step.
3. `executor_command_cli.ex` error mapping: `{:conflict, {:human_answer, _}}` →
   "a human answered this Command; the Executor cannot replace it" (exit 1). Final CLI
   copy is DESIGN-E2 §3; placeholder until approved.
4. `decision_api_controller.ex`: add the `winner` field for `already_decided`.

## Non-happy paths

- Executor supersede of its own undelivered answer: still allowed (D11 only protects
  human answers).
- Executor supersede after a human *superseded* the Executor's answer: refused (active
  answer is the human revision).
- `get/2` fails while building the 409 winner: return 409 without `winner` (never 500).
- Supervisor actor: not human, not executor → unchanged behaviour.

## Compatibility and rollout

- New refusal only for a path that today silently overrides a human (a fix, per D11).
- API: additive field in an error body. No config.

## Verification

```bash
env -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- env -C src mix test \
  test/aiur/decision_withdrawal_test.exs test/aiur/executor_command_cli_test.exs \
  test/aiur/commands/conflict_summary_test.exs test/aiur_web/controllers/decision_api_controller_test.exs
```

| Test (PROPOSED) | Expected | Fails without |
| --- | --- | --- |
| `decision_withdrawal_test` "executor cannot supersede an operator answer" | `{:error, {:conflict, {:human_answer, id}}}`; log unchanged | guard (step 2) |
| "executor can still supersede its own undelivered answer" | `{:ok, %{status: :accepted}}` | guard must not over-match |
| "executor cannot supersede after an operator superseded it" | `{:human_answer, _}` | active-answer use |
| `executor_command_cli_test` "supersede refusal message names the human answer" | exit 1 + message | step 3 |
| `conflict_summary_test` table (option answer, custom answer, delivered, in flight) | fields as specified | `for/1` |
| `decision_api_controller_test` "409 already_decided carries winner" | body `winner.actor_kind == "operator"` | step 4 |

Mutation check per row.

## Completion and handoff

- [ ] Guard + summary + mappings.
- Docs: `website/docs-app/concepts/commands.md` "who can replace an answer" (short
  paragraph; behaviour change to a documented surface).
- Dependents: C3-T02, C3-T03, C3-T04, MP-N6.
