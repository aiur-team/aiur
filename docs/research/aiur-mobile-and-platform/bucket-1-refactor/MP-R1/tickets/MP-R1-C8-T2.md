---
ticket_id: MP-R1-C8-T2
feature_id: MP-R1
chunk_id: MP-R1-C8
bucket: 1-refactor
title: Invert Command answer delivery into an orchestration-provided delivery target port
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C8-T1, U6 journal outcome matrix (prior unit)]
prior_units: [U6, U2]
prior_boundaries: [DEC #27, MSG #16, DSP #13, ORC #12]
prior_features: []
prior_findings: [loose-1-02, loose-1-03, orch-b-01]
size_owner: DECISIONS (decision_store.ex) and LIFECYCLE_DISPATCH (dispatcher.ex, operator_messages.ex) — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T2
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C8-T2 — Answer delivery through a delivery-target port

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C8 (step S10, prior #27 "answer
  delivery by event").
- **User value:** none visible. Commands stop calling into `Aiur.Orchestrator`, which
  removes the commands → orchestration edge that blocks packaging Commands
  (`aiur_decisions`) and lets MP-E2-C6 add an Executor delivery target beside the
  worker one without touching orchestration.
- **Deliverable:** a behaviour `Aiur.Commands.DeliveryTarget` (PROPOSED
  `src/lib/aiur/commands/delivery_target.ex`), an orchestration implementation
  `Aiur.Orchestrator.CommandDeliveryTarget` (PROPOSED
  `src/lib/aiur/orchestrator/command_delivery_target.ex`), and the four commands
  modules switched to resolve it from application config.
- **Non-goals:** no change to delivery semantics (interrupt policy, `queue_next`
  fallback, correlation fields, retry ladder, exactly-once outbox); no change to the
  existing `ticket.<id>.agent.decision.answered` wake event; no Executor target
  (MP-E2-C6).

### Plan correction (finding)

`plan.md` C8 and `migration-plan.md` S10 say "`decision.answered` event replaces the
direct `OperatorMessages` call". At `45a290e3` that is not possible without changing
behaviour:

- The event **already exists** and is only a wake: `DecisionStore` publishes
  `ticket.<id>.agent.decision.<slug>` with slug `answered` for `:answer_recorded`
  (`decision_store.ex:2555-2558`, `:2633`); orchestration subscribes
  (`orchestrator/lifecycle.ex:40`), classifies it
  (`orchestrator/event_topics.ex:174,181-186`) and runs `Lifecycle.wake_tick/1`
  (`event_topics.ex:31-36`).
- The answer **text** goes through an outbox: `DecisionStore.maybe_start_dispatch/4`
  enqueues an operation on `DecisionDispatchTasks` and settles from the synchronous
  result `{:ok, map} | {:error, reason}` (`decision_store.ex:3827-3870`), then later
  transport transitions arrive from `OperatorMessages`
  (`orchestrator/operator_messages.ex:994` → `DecisionStore.record_transport_batch_async/4`,
  `decision_store.ex:363-374`). A fire-and-forget bus event has no synchronous
  result, so the outbox could not distinguish "queued" from "lost" (U6 KTD10).

The chosen design keeps the synchronous call and inverts only its **direction of
dependency**.

## Dependencies and blockers

- DESIGN-R1 §1. MP-R1-C8-T1 (facade and manifest entry exist).
- **U6 first:** U6 owns `decision_store.ex`; its journal outcome matrix (KTD10) lands
  before any edit there (migration-plan §3, S10 row).
- U2 owns `orchestrator/dispatcher.ex` and `operator_messages.ex`; this ticket adds one
  new orchestration file and does not edit those two, so it does not wait for U2.
- RC-19: if MP-E1-C1 hooks are present in `dispatch_policy.ex` at the head, this
  ticket must not touch them (it only calls `terminal_state_set/0` and
  `terminal_issue_state?/2`).
- May run concurrently with C8-T3..T7. Not with C8-T1 (it goes first).

## Verified starting point (45a290e3)

Commands → orchestration references (all four are this ticket's scope):

| Site | Reference |
|---|---|
| `decision_dispatch.ex:20,39-40,65` | `alias Aiur.Orchestrator.OperatorMessages`; default `server = Aiur.Orchestrator`, `send_fun = &OperatorMessages.send_correlated_operator_message/3` |
| `decision_revision_dispatch.ex:13-14,111-112` | same pair for revisions; `alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy}` |
| `decision_revision_dispatch.ex:184,221,231` | `DispatchPolicy.terminal_issue_state?/2`, `terminal_state_set/0`, `&Dispatcher.revalidate_issue_for_dispatch/3` |
| `decision_expiry.ex:93-97` | `GenServer.call(Aiur.Orchestrator, :list_active_identifiers, …)` with `catch :exit → {:error, {:orchestrator_unavailable, reason}}` |
| `decision_store.ex:63,3258,3273` | `alias Aiur.Orchestrator.DispatchPolicy`; `terminal_state_set/0`, `terminal_issue_state?/2` in `default_terminal_ticket_resolver/1` |

Targets on the orchestration side: `OperatorMessages.send_correlated_operator_message/3`
(`operator_messages.ex:60`), `Dispatcher.revalidate_issue_for_dispatch/4` with a
3-arity default head (`dispatcher.ex:1860-1893`), `DispatchPolicy.terminal_issue_state?/2`
(`dispatch_policy.ex:1113-1119`), `DispatchPolicy.terminal_state_set/0`
(`dispatch_policy.ex:1266`).

Existing injection seams already used by tests: `:operator_messages`, `:send_fun`
(`decision_dispatch.ex:39-40`), `:revalidate_fun`, `:terminal_states`
(`decision_revision_dispatch.ex:221,231`), `:active_identifiers_fun`
(`decision_expiry.ex:86-90`), `:dispatcher` (`decision_store.ex:567`).
Precedent for a module bound by app config: `config :aiur, :build_order_data_source, …`
(`src/config/config.exs`, the `AIUR_BUILD_ORDER_DEMO` block).

Failure classification: `decision_store.ex:4427-4450` maps `:unavailable` →
`"orchestrator_unavailable"` (transient), `:dispatcher_crashed` → `"dispatcher_crashed"`.

Tests: `src/test/aiur/decision_dispatch_test.exs`, `decision_revision_dispatch_test.exs`,
`decision_expiry_test.exs`, `decision_store_test.exs`,
`src/test/support/decision_dispatch_test_support.ex`.

## Chosen design

```elixir
defmodule Aiur.Commands.DeliveryTarget do
  @callback send_correlated(ticket_identifier :: String.t(), payload :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback revalidate_issue(Aiur.Issue.t(), issue_fetcher :: function(), MapSet.t()) ::
              {:ok, Aiur.Issue.t()} | {:skip, :missing | Aiur.Issue.t()} | {:error, term()}
  @callback terminal_state_set() :: MapSet.t(String.t())
  @callback terminal_issue_state?(String.t() | term(), MapSet.t()) :: boolean()
  @callback active_identifiers() :: {:ok, [String.t()]} | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:aiur, :commands_delivery_target, Aiur.Commands.DeliveryTarget.Unbound)
end
```

- `Aiur.Orchestrator.CommandDeliveryTarget` implements each callback by calling the
  current target exactly (`send_correlated/2` → `OperatorMessages.send_correlated_operator_message(Aiur.Orchestrator, id, payload)`;
  `active_identifiers/0` keeps the `catch :exit` and the
  `{:error, {:orchestrator_unavailable, reason}}` shape).
- Binding: `src/config/config.exs` adds
  `config :aiur, :commands_delivery_target, Aiur.Orchestrator.CommandDeliveryTarget`.
  Config files are composition, outside `src/lib`, so the checker sees no
  commands → orchestration edge.
- `Aiur.Commands.DeliveryTarget.Unbound` returns `{:error, :delivery_target_unbound}`
  from `send_correlated/2` and `active_identifiers/0`, an empty `MapSet` from
  `terminal_state_set/0`, `false` from `terminal_issue_state?/2`, and
  `{:error, :delivery_target_unbound}` from `revalidate_issue/3`. A new
  `dispatch_failure_class(:delivery_target_unbound) -> "delivery_target_unbound"`
  clause is **not** transient. Per AGENTS.md "a collapsed cause names the collapse
  at the source", an unbound target must not be reported as
  `orchestrator_unavailable`.
- Existing per-call opts keep priority: `Keyword.get(opts, :send_fun, …)` defaults to
  `fn _server, id, payload -> DeliveryTarget.impl().send_correlated(id, payload) end`,
  so every existing test that injects `:send_fun` keeps working.
- **Invariant:** for the production binding, payload, correlation, return value and
  failure class are byte-for-byte what they were.

## Implementation steps

1. Add `commands/delivery_target.ex` (behaviour + `impl/0`, ≈40 lines) and
   `commands/delivery_target/unbound.ex` (≈25 lines).
2. Add `orchestrator/command_delivery_target.ex` (≈50 lines).
3. Edit the four call sites in the table: remove the `Aiur.Orchestrator.*` aliases and
   route defaults through `DeliveryTarget.impl()`.
4. Add the failure-class clause in `decision_store.ex` (+2 lines; U8 owner `DECISIONS`
   is told the file grew by 2 lines; no net growth if the PR removes the alias line).
5. Add the config line; declare `Aiur.Orchestrator.CommandDeliveryTarget` as an
   orchestration facade and `Aiur.Commands.DeliveryTarget` as a commands facade in
   `components.json`; remove the four allowlist entries. Production diff ≈150 lines.

## Non-happy paths

- **Orchestrator down:** unchanged — `send_correlated_operator_message/3` exits are
  handled where they are today; `active_identifiers/0` keeps the "skip the whole
  sweep" behaviour (`decision_expiry.ex` moduledoc: an outage must never look like an
  empty run).
- **Unbound target** (test env or a future composition without orchestration):
  answers stay recorded, delivery fails once with `delivery_target_unbound`, the
  existing delivery-failure attention fires (`decision_store.ex:3453` topic); expiry
  skips its sweep. Nothing is silently dropped.
- **Hot code / config race:** the binding is read per call; it is static in a
  release.
- **Concurrency/idempotency:** unchanged; the outbox fence and `attempt_id` stay in
  `DecisionStore`.

## Compatibility and rollout

One new compile-time config key (`:commands_delivery_target`) internal to the app — not
an operator key in `.aiur/config`, so no `configuration.md` entry. Rollback: revert.

## Verification

New tests (`src/test/aiur/commands/delivery_target_test.exs`):

1. `test "production config binds the orchestration delivery target"` —
   `assert Aiur.Commands.DeliveryTarget.impl() == Aiur.Orchestrator.CommandDeliveryTarget`.
   Fails if the config line is removed.
2. `test "unbound target fails delivery with its own cause, not orchestrator_unavailable"` —
   start a `DecisionStore` under a temp `state_dir` with
   `Application.put_env(:aiur, :commands_delivery_target, Aiur.Commands.DeliveryTarget.Unbound)`
   (restored in `on_exit`), record a decision and an answer, assert the recorded
   delivery failure class is `"delivery_target_unbound"` and that no retry is scheduled.
   **Mutation:** replace the new `dispatch_failure_class` clause with a fall-through to
   `"orchestrator_unavailable"` → test fails.
3. `test "DecisionDispatch default send goes through the bound target"` — bind a test
   module that records `{id, payload}`, call `DecisionDispatch.dispatch(decision, attempt_id: "a1")`
   without `:send_fun`, assert one recorded call with `payload.delivery_policy == :interrupt`
   and `payload.correlation.decision_id == decision.decision_id`. **Mutation:** restore
   the old default `&OperatorMessages.send_correlated_operator_message/3` → the recorder
   sees nothing and the test fails.
4. `test "DecisionExpiry skips the sweep when the target reports an error"` — bound
   module returns `{:error, :boom}`; assert no Decision is mooted.

Existing suites green, unmodified:
`env -C src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/decision_dispatch_test.exs test/aiur/decision_revision_dispatch_test.exs test/aiur/decision_expiry_test.exs test/aiur/decision_store_test.exs test/aiur/orchestrator/event_topics_test.exs test/aiur/commands/delivery_target_test.exs`.
`make -C src fmt-check lint`; `python3 scripts/check-components.py` shows four fewer
violations. Run each mutation in a clean worktree with `git status --porcelain`
showing only the reverted hunk (AGENTS.md), and paste the commands in the PR body.

Manual (AGENTS.md "manual testing"): foreground `scripts/aiurdev --test` in the wrapper
tmux; have an agent file a Command, answer it from the dashboard `/commands` page,
open the agent's chat pane (`0.1`) and confirm the answer text arrives (`QUEUED` then
delivered), exactly as before.

## Completion and handoff

- [ ] No `Aiur.Orchestrator` reference under the commands component (checker).
- [ ] Four tests above pass; the two mutation checks fail as described.
- [ ] Manual answer delivery observed in a chat pane.
- **Docs:** none (internal). `plan.md` C8 / `migration-plan.md` S10 wording corrected
  by the coordinator (see correction above).
- **Dependents:** MP-E2-C6 (adds an Executor delivery target implementing the same
  behaviour); MP-R1-C9-T9 (effects return) must keep `CommandDeliveryTarget` as the
  only orchestration entry for Commands.
