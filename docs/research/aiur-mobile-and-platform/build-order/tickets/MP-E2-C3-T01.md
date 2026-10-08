---
ticket_id: MP-E2-C3-T01
feature_id: MP-E2
chunk_id: MP-E2-C3
bucket: 2-platform
title: Answer precedence (direct operator > relayed > Executor), actor_source, ConflictSummary
status: blocked
blocked_by: [DESIGN-E2, MP-R1-C11-T03]
prior_units: [U6]
prior_boundaries: [DEC #27]
prior_features: []
prior_findings: [D11, RC-41, security B2 and M4, contract §6 rules 1, 3a, 4, 4a, plan §1.1 ("supersede has no actor restriction")]
size_owner: "DECISIONS (decision_store.ex — one guard call in handle_revision/4, actor_source in normalize_actor)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E2-C3-T01 — Answer precedence, `actor_source`, and `ConflictSummary`

## Identity and outcome

- Bucket 2, MP-E2, chunk C3 (answer resolution).
- **User value:** once you answer a Command on a surface you log in to, neither the
  Executor nor an Executor-relayed answer can silently replace it; every surface that
  loses an answer race can say who won, through which entry point, and when.
- **Deliverable:**
  1. Store precedence guard (RC-41, contract §6 rules 3a, 4, 4a) on **both** replace
     paths (supersede and revise): a caller may replace only an answer of equal or lower
     rank, `direct operator (3) > operator_relayed (2) > executor | supervisor (1)`.
     Refusals: `{:conflict, {:human_answer, action_id}}` (Executor over any
     human-attributed answer) and `{:conflict, {:direct_operator_answer, action_id}}`
     (relay over a direct operator answer).
  2. `actor_source` (contract §6, security M4): `normalize_actor/1` keeps an optional
     `source` atom from the closed list; `DecisionStore.answer/5`, `supersede/5` and
     `revise/5` read it from `opts[:actor_source]` (set by the entry point, never the
     payload) and default it to `:rpc`.
  3. PROPOSED `Aiur.Commands.ConflictSummary.for/2` (decision, caller actor) →
     `%{actor_kind, actor_id, actor_source, summary, accepted_at, delivery_status,
     delivered?, in_flight?, replaceable}`; `replaceable` uses the rank comparison.
  3. `ExecutorCommandCLI` error copy for the new refusal; 409 body in the supervisor API
     gains `"winner"` (summary) for `already_decided` conflicts.
- **Non-goals:** human supersede path (C3-T02); UI (C3-T03); changing the conflict tuple.

## Dependencies and blockers

- **MP-R1-C11-T03** (final plan refresh after the refactor): enforces "refactor before
  features" (D1, RC-35). Re-read this ticket's paths against the refreshed plan before starting.
- Blocked by **DESIGN-E2** (pack rule; behaviour is settled by D11).
- #3005/#3006 (open on 2026-10-06; #3006 "Record operator answers with explicit relay
  attribution") add actor kind `operator_relayed` and a guard that refuses a relay
  revise/supersede of an active direct operator answer (its placement is still under
  review on 2026-10-06; read the merged diff before starting). **Rebase on
  #3006 and keep its guard.** This ticket's guard sits beside it (in `handle_revision/4`,
  which both paths call) and does not replace or reorder it. If #3006 has not merged
  when this starts, the `operator_relayed` rows below run against a fixture actor kind
  and the ticket says so in its PR body (`DecisionAnswer` actor kinds at base:
  `decision_answer.ex:17-19`).
- May run concurrently with every C1/C2 ticket.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/decision_store.ex:1206-1220` `handle_supersede/4` (only `fetch_actor/1`,
  no kind check); `:1222-1233` `supersede_current/4` → `require_supersedable/1`
  `:1235-1243` → `require_withdrawable/1` `:1965-1971`. Revise: `handle_call({:revise, …})`
  `:944-946` → `handle_revision/4` `:1178`, which supersede also reaches.
- `src/lib/aiur/decision_event.ex:469-478` `normalize_actor/1` (rebuilds the actor from
  `kind` and `id`, so an older binary drops an extra `source` key on replay).
- `:1557` `{:conflict, {:already_decided, accepted.action_id}}`.
- `src/lib/aiur/decision.ex:211-214` `active_answer/1`; `:234-240` `delivered?/1`;
  `:256-257` `send_in_flight?/1`.
- `src/lib/aiur/executor_command_cli.ex:148-159` supersede call; `:253-281` error mapping
  (`answer_delivered`, `answer_in_flight`).
- `src/lib/aiur_web/controllers/decision_api_controller.ex:114-116` 409 render.
- Tests: `src/test/aiur/decision_withdrawal_test.exs`, `executor_command_cli_test.exs`,
  `decision_api_controller_test.exs`.

## Chosen design

- `Aiur.Commands.Answering` (defined here, grown by C3-T02) replaces the old boolean
  `human_actor?/1` with:

  ```elixir
  def direct_human?(%{kind: k}), do: k == :operator
  def human_attributed?(%{kind: k}), do: k in [:operator, :operator_relayed]  # atom by name, compiles before #3005
  def precedence(%{kind: :operator}), do: 3
  def precedence(%{kind: :operator_relayed}), do: 2
  def precedence(%{kind: k}) when k in [:executor, :supervisor, :agent, :system], do: 1
  def require_actor_may_replace(caller, %{actor: winner, action_id: id}) do
    cond do
      precedence(caller) >= precedence(winner) -> :ok
      winner.kind == :operator and caller.kind == :operator_relayed ->
        {:error, {:conflict, {:direct_operator_answer, id}}}
      true -> {:error, {:conflict, {:human_answer, id}}}
    end
  end
  ```

- Guard placed at the top of `handle_revision/4`, after `fetch_decision` and
  `fetch_actor`, against `Decision.active_answer(decision)`. It therefore covers revise
  and supersede. #3006's guard stays as is wherever it merged; both refuse the
  relay-over-direct case, and this one is the single place for the Executor case.
  `handle_supersede/4` passes the fetched actor through (today it discards it as
  `_actor`). Replays (`find_revision_replay`) are unaffected: the replayed revision's
  active answer is the caller's own, so ranks are equal.
- `actor_source`: `fetch_actor/1` merges `opts[:actor_source]` (atom in the closed list,
  else `:rpc`) into the actor as `source`; `normalize_actor/1` accepts an optional
  `source` from the same list. C3-T02 and each surface ticket set it at the entry point.
- `ConflictSummary.for(decision, caller)`: reads `Decision.active_answer/1`; `summary` =
  option label (from `decision.options`) or the first 120 chars of `custom_response`;
  `actor_source` from the stored actor (`:rpc` when absent, which is what an older record
  shows); `delivery_status` from the Decision; booleans from `delivered?/1` /
  `send_in_flight?/1`; `replaceable = not delivered? and not in_flight? and
  precedence(caller) >= precedence(winner)`. Pure; callers already hold the Decision or
  `get/2` it after a conflict.
- API 409 for `{:conflict, {:already_decided, _}}` adds `"winner": ConflictSummary` (the
  controller already has the decision id; one `DecisionStore.get/2`).

## Implementation steps

1. PROPOSED `src/lib/aiur/commands/conflict_summary.ex` (≈60 lines);
   PROPOSED `src/lib/aiur/commands/answering.ex` (start with `direct_human?/1`,
   `human_attributed?/1`, `precedence/1` and `require_actor_may_replace/2`; C3-T02
   grows it).
2. `decision_store.ex`: `fetch_actor/1` adds `source` (default `:rpc`); `handle_revision/4` calls `Answering.require_actor_may_replace/2` before any write; `handle_supersede/4` stops discarding the actor.
3. `executor_command_cli.ex` error mapping: `{:conflict, {:human_answer, _}}` →
   "a human answered this Command; the Executor cannot replace it" (exit 1);
   `{:conflict, {:direct_operator_answer, _}}` → "the operator answered this Command
   directly; a relayed answer cannot replace it" (exit 1). The executor CLI RPC verb
   passes `actor_source: :executor_cli`. Final CLI copy is DESIGN-E2 §3; placeholder
   until approved.
3a. `decision_event.ex` `normalize_actor/1`: optional `source` key, closed list.
4. `decision_api_controller.ex`: add the `winner` field for `already_decided`; the
   supervisor routes pass `actor_source: :supervisor_api`.

## Non-happy paths

- Executor supersede of its own undelivered answer: still allowed (D11 only protects
  human answers).
- Executor supersede after a human *superseded* the Executor's answer: refused (active
  answer is the human revision).
- `get/2` fails while building the 409 winner: return 409 without `winner` (never 500).
- Supervisor actor: rank 1, like the Executor. It may replace its own or an Executor
  answer and never a human-attributed one (the supervisor supersede route does not
  exist, C3-T02; revise by the supervisor follows the same rank rule).
- Relay over relay: equal rank, allowed (contract §6 rule 5).
- Unknown `actor_source` value in opts: stored as `:rpc`, never rejected (attribution,
  not authorization).
- Older record without `source`: `ConflictSummary.actor_source == :rpc`, and the
  timeline says "no surface recorded".

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
| **"relay supersede of a direct operator answer is refused"** (B2) | `{:error, {:conflict, {:direct_operator_answer, id}}}`; `decisions.ndjson` byte length unchanged | the `handle_revision/4` guard. #3006 also refuses this case, so revert **both** guards in the worktree for this row; with only one reverted the other still refuses. Record in the PR which guards each run removed |
| **"relay revise of a direct operator answer is refused"** (B2) | same refusal through `DecisionStore.revise/5` | the `handle_revision/4` guard (and #3006's guard if, as merged, it also covers revise; same rule as the row above) |
| **"operator supersedes a relayed answer"** (B2) | `{:ok, %{status: :accepted}}`; active answer kind `:operator` | rank comparison: replace `>=` with a "human-attributed winner refuses" boolean and it fails |
| "relayed supersedes a relayed answer" | `:accepted` | rank equality |
| "executor revise of a relayed answer is refused" | `{:human_answer, _}` | guard on the revise path |
| `conflict_summary_test` "replaceable is false for a relay caller against a direct operator winner, true for an operator caller against a relayed winner" | as stated | rank in `replaceable` (a boolean "caller is human" passes the second half and fails the first) |
| "answer recorded with no surface context has actor_source :rpc" (M4) | `DecisionStore.answer/5` with no `:actor_source` opt → stored `actor.source == :rpc`; `ConflictSummary.actor_source == :rpc` | the default in `fetch_actor/1` (remove it and `source` is absent) |
| "actor_source in the payload is ignored" | payload `"actor_source": "dashboard_session"`, opts none → stored `:rpc` | entry-point-only rule |
| `executor_command_cli_test` "supersede refusal message names the human answer" | exit 1 + message | step 3 |
| `conflict_summary_test` table (option answer, custom answer, delivered, in flight) | fields as specified | `for/1` |
| `decision_api_controller_test` "409 already_decided carries winner" | body `winner.actor_kind == "operator"` | step 4 |

Mutation check per row: revert that hunk in a worktree (`git status --porcelain` shows
only the revert), run the row, confirm it fails, restore. Report the commands in the PR
(AGENTS.md "Tests must fail without the production change they guard"). The fourth
B2 test ("relay answer to an Executor-originated Command is refused") is in MP-E2-C6-T01,
which owns that guard.

## Completion and handoff

- [ ] Guard + summary + mappings.
- Docs: `website/docs-app/concepts/commands.md` "who can replace an answer": the
  precedence order, that a relayed answer never replaces a direct one, and what
  `actor_source` shows, including that `:rpc` means "no surface; `human_required` does
  not stop a same-user process with the cookie" (contract §4).
- Dependents: C3-T02, C3-T03, C3-T04, MP-N6.
