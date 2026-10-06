---
ticket_id: MP-E7-C3-T02
feature_id: MP-E7
chunk_id: MP-E7-C3
bucket: 2-platform
title: "Aiur.Listener.Scheduler and the :listener delivery policy behind config :aiur, :listener_send_routing (default :legacy)"
status: ready
repo: aiur-team/aiur
wave: 3
blocked_by: [DESIGN-E7, MP-E7-C2-T03, MP-E7-C3-T01]
prior_units: [U3, U4]
prior_boundaries: [MSG (16), RUN (18)]
prior_features: [integrations-43, cli-15]
prior_findings: [agent-runtime-01]
size_owner: LIFECYCLE_DISPATCH (operator_messages.ex 1,167 lines: ≤ 20 lines — the :listener branch and the checkpoint-matcher exclusion; delivery_policy.ex 186 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C3-T02 — Scheduler and the `:listener` policy (flagged)

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E7 / C3.
- **User value:** one place decides how a conversation message lands, based
  on the receiving agent's effective mode instead of on which button sent it
  (plan Problem Frame). Wave 3 ships it **dark**: with the default routing
  `:legacy`, every send resolves to exactly today's per-entry-point policy
  (RC-05), so nothing an operator sees changes until DESIGN-E7 approves E7-D6.
- **Deliverable:**
  1. `Aiur.Listener.Scheduler` (PROPOSED `src/lib/aiur/listener/scheduler.ex`),
     pure:

```elixir
@type origin :: :agent_chat | :http | :tui | :internal
@spec routing() :: :legacy | :listener
@spec resolve(origin(), view :: map() | nil, capabilities :: map(), fallback :: atom() | nil) ::
        {:ok, keyword()} | {:error, :listener_mode_unavailable | atom()}
@spec restamp_fun(view :: map()) :: (map() -> map())
```

     `routing/0` reads `Application.get_env(:aiur, :listener_send_routing, :legacy)`;
     any value other than `:listener` is `:legacy`.
  2. `DeliveryPolicy.normalize_delivery_request/3` gains a `:listener`
     clause reached through `OperatorMessages.do_enqueue_running_operator_message/5`
     (`operator_messages.ex:791-811`), which, for `delivery_policy: :listener`,
     reads the mode view (C2-T03 handler module, in-process — no GenServer
     call, it already runs inside the Orchestrator) and calls `Scheduler.resolve/4`.
  3. Wake rule: `DeliveryPolicy.deliver_now?/3` returns `false` for an item
     whose `delivery.consume_at == :pull` (async never wakes, contract §3
     rule 3), before the self-pause clause (`delivery_policy.ex:124-137`).
  4. **Sync is never claimed mid-turn.** `claim_next_checkpoint_queue_item_call/2`
     (`operator_messages.ex:392-401`, matcher `interrupt_requested != true`)
     additionally skips items stamped `listener_mode_at_claim: :sync`. Reason:
     the OpenAI-compatible backends run tools in-process and call the safe
     checkpoint handler at every `:tool_result`
     (`open_ai_compat/coding_agent.ex:222-232`, `Checkpoint.defer`), which
     claims through `CheckpointDelivery.fallback_checkpoint_claim/6`
     (`agent_runner/checkpoint_delivery.ex:66-88,124-130`); without this rule a
     `sync` message would land mid-turn on `kimi`/`deepseek`/`openrouter`.
     (App-server backends are already protected by the single-writer lock,
     `app_server/operator_delivery.ex:41-51`.) Sync items are claimed only by
     the turn-boundary drain (`QueueDrain.claim_next_operator_item/2`,
     `queue_drain.ex:399-408`). Legacy items carry no stamp, so today's
     OpenAI-compat mid-turn checkpoint delivery is unchanged under `:legacy`.
     Only steer items may be claimed at a tool boundary; MP-E7-C4-T02 adds a
     `steer_requested` item flag and a `:steer` wake value on top of this rule.
  5. On a mode-view change (broadcast from C2-T04 or `set_mode`), the handler
     re-stamps pending listener items with `AgentQueueStore.update_pending_delivery/3`
     and `Scheduler.restamp_fun/1`, then calls
     `DeliveryPolicy.notify_running_queue_update/3` for the first pending
     item so a sync→steer change can wake the runner.
- **Non-goals:** switching callers to `:listener` (C3-T03); receipts (C3-T04);
  native steer (MP-E7-C4); async pull (MP-E7-C5); flipping the default
  (MP-E7-C7-T04).

## Dependencies and blockers

- DESIGN-E7; MP-E7-C2-T03 (view); MP-E7-C3-T01 (queue rows).
- E7-D2 enters only as the `emulated_interrupt_accepted?` option of
  `Effective` (default false); E7-D6 decides the routing default (C7-T04).
- Concurrent with MP-E7-C3-T04 once T01 lands.

## Verified starting point (aiur `45a290e3`)

- Policy normalization: `delivery_policy.ex:9-48` (`:auto` → `:immediate` when
  `immediate_delivery`, else `:checkpoint`; `:interrupt` → `:interrupt` when
  `can_interrupt`, else `:checkpoint` with `fallback: :queue_next`).
- Enqueue path: `enqueue_operator_message/5` builds `request` with
  `delivery_policy: Map.get(payload, :delivery_policy, :checkpoint)`
  (`operator_messages.ex:570-580`); `do_enqueue_running_operator_message/5`
  normalizes and builds the queue item (:791-811); plain sends then call
  `notify_running_queue_update/3` (:813-824).
- Wake decision: `deliver_now?/3` (`delivery_policy.ex:124-137`),
  `wake_now?/2` (:139-143), idle/sleeping wake via `queue_wake_required?/1`
  (:177-180) — this already gives contract §3 rule 2 "if idle, start a turn now".
- Self-pause lift: `:agent_pause_request` only (`delivery_policy.ex:106-131,160-163`).
- App-env toggle pattern: `operator_message_call_timeout_ms/0`
  (`operator_messages.ex:110-112`, `Application.get_env(:aiur, …, default)`);
  test seams `Application.get_env(:aiur, :agent_control_cli_message_fun, …)`
  (`agent_control_cli.ex:1479`). The new flag follows this pattern and is
  **not** an operator config key (no `Aiur.Config.Schema.*` entry; E7-D7 is an
  owner item), so `scripts/check-config-docs.py` is not affected.
- Batching (research answer): today one operator item is claimed per turn
  (`QueueDrain.claim_next_operator_item/2`, `agent_runner/queue_drain.ex:399-408`),
  and `OperatorWaitLog` records queued/delivered per request id
  (`operator_messages.ex:1016,1050`; `operator_wait_log.ex:1-20`). Batching
  several sync messages into one turn would merge wait samples and transcript
  echoes per request. **Decision: no batching in wave 3**; sync messages are
  delivered one per turn boundary in arrival order, which keeps per-request
  wait metrics and anchors intact. Contract §3 rule 2 is relaxed to "MAY claim
  as one batch" (edit reported to the parent).

## Chosen design

`Scheduler.resolve/4`:

| routing | origin | result (today's behaviour in the legacy column) |
| --- | --- | --- |
| `:legacy` | `:agent_chat` | `normalize_delivery_request(:interrupt, :queue_next, caps)` (`agent_chat.ex:27-28`) |
| `:legacy` | `:http` | `normalize_delivery_request(:checkpoint, nil, caps)` (`operator_messages.ex:572`) |
| `:legacy` | `:tui` | `normalize_delivery_request(:auto, nil, caps)` (`operator_dispatch.ex:46-50`) |
| `:legacy` | `:internal` | `{:error, :invalid_message}` (internal callers pass an explicit policy) |
| `:listener` | any | by `view.effective`: `:sync` → `[delivery_policy: :checkpoint, listener_mode: :sync]`; `:steer` + carrier `:emulated_interrupt` → `[delivery_policy: :interrupt, fallback: :queue_next, listener_mode: :steer, steer_carrier: :emulated_interrupt]`; `:async` → `[listener_mode: :async]`; `nil` → `{:error, :listener_mode_unavailable}` |

Invariants:
- Under `:legacy` the produced keyword list is **identical** to today's for
  each origin (no `listener_mode` key), so `AgentQueue.operator_message/3`
  builds byte-identical items and the MP-R7-C1-T02 matrix passes unchanged.
- Under `:listener`, Command answers and digests never reach the scheduler:
  they use `send_correlated_operator_message` with explicit `:interrupt`
  (`decision_dispatch.ex:40,51-63`) or `coordination_event` items
  (`agent_queue.ex:34-53`) — contract §2.
- Mode is read at enqueue and re-stamped while pending; a claimed item keeps
  its stamp (§3 rule 6).
- Pause: no change; `deliver_now?/3` already refuses paused entries except the
  cooperative self-pause, and async items never wake (new clause first).

## Implementation steps

1. Add `scheduler.ex` (~110 lines) with `@spec`s.
2. `delivery_policy.ex`: add the `:pull` clause to `deliver_now?/3` (+3 lines).
3. `operator_messages.ex`: in `do_enqueue_running_operator_message/5`, branch on `request.delivery_policy == :listener` to `Scheduler.resolve(request.origin, view, capabilities, request.fallback)`; carry `origin` in the request map built at :571-580 (+1 line). Keep everything else.
4. `orchestrator/listener_modes.ex`: re-stamp + notify on view change.
5. `src/config/config.exs` (the only config file) gets no entry: the default lives in `routing/0`. Tests opt in with `Application.put_env/3` and restore in `on_exit` (pattern: `agent_chat_test.exs:57,86`).

## Non-happy paths

- `view.effective == nil` under `:listener` (not running, unknown harness) →
  `{:error, :listener_mode_unavailable}`; the caller surfaces it, nothing is
  queued (never a silent downgrade, contract §4).
- Mode changes between a `:timeout` and the retry: idempotent `message_id`
  returns the first item (`enqueue_plain/3`, `operator_messages.ex:854-860`),
  re-stamped if still pending.
- A misspelt flag value is `:legacy`, logged once at warning level.
- Steer race with a turn ending: emulated steer uses the existing interrupt
  path, which already falls back to `:queue_next`.

## Compatibility and rollout

- **Flag:** `config :aiur, :listener_send_routing, :legacy | :listener`;
  default `:legacy` until MP-E7-C7-T04 flips it after E7-D6. Precedent for a
  dark, build-time app-env switch: `AIUR_BUILD_ORDER_DEMO` sets
  `config :aiur, :build_order_data_source, …` in `src/config/config.exs:19-24`.
  Dogfood opt-in is a local, uncommitted `config :aiur, :listener_send_routing, :listener`
  line in `src/config/config.exs` followed by `scripts/aiurdev build`; no
  environment variable is added (an operator-facing variable would need docs
  and is an E7-D7 decision).
- Rollback: set `:legacy` (no restart of agents needed beyond the daemon
  restart that reloads app env) or revert.

## Verification

```sh
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/listener/scheduler_test.exs test/aiur/orchestrator/operator_messages/delivery_policy_test.exs
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test test/aiur/delivery_entry_points_test.exs test/aiur/orchestrator/operator_messages/delivery_matrix_test.exs
env -C src mise exec -- make lint
```

Tests (`Aiur.Listener.SchedulerTest`, plus `ListenerDeliveryTest` against a test Orchestrator):

- "legacy routing reproduces today's policy for agent_chat, http and tui on every harness profile" (table over the R7-C1-T02 profiles; compares keyword lists).
- "listener routing: sync never sets interrupt_requested" — enqueue to an active codex entry, assert `deliver_now?` false while a turn is active and the item is claimed by the checkpoint claim after the turn.
- "listener routing: emulated steer interrupts only when the option is accepted".
- "listener routing: async item never wakes idle, active, sleeping or self-paused entries" (five entry states).
- "listener routing: paused entry receives nothing in any mode; self-pause lifts for sync and steer only".
- "listener routing: effective nil refuses with listener_mode_unavailable and queues nothing".
- "listener routing: a sync item is not claimed at an OpenAI-compat tool_result checkpoint while the turn runs, and is claimed at the turn boundary" (calls `claim_next_checkpoint_queue_item_call/2` then `claim_next_operator_queue_item_call/2`).
- "legacy routing: OpenAI-compat checkpoint claim still takes an unstamped item mid-turn" (guard; already passes).
- "mode change re-stamps pending sync items to steer and notifies the runner once".
- "Command answers keep :interrupt under listener routing" (correlated send unchanged).

Mutation checks (AGENTS.md): under `:listener`, restore `:interrupt` for
`:agent_chat` in the resolve table → the "sync never sets interrupt_requested"
test fails; drop the `:sync` exclusion from the checkpoint matcher → the
OpenAI-compat tool_result test fails; remove the `:pull` clause in `deliver_now?/3` → the async wake test
fails; make `routing/0` default to `:listener` → the legacy table test fails
(it runs with the flag unset).

## Completion and handoff

- [ ] Scheduler, `:listener` clause and wake rule merged with the flag default `:legacy`.
- [ ] R7-C1-T02 matrix unchanged (CI green on the head SHA).
- Dependents: MP-E7-C3-T03 (callers opt in), MP-E7-C3-T05, MP-E7-C4 (native steer row), MP-E7-C5 (async pull), MP-E7-C7-T04 (flip default).
- Docs: none while `:legacy` is the default (no documented behaviour changes).
