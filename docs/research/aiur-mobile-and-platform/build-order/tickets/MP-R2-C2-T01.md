---
ticket_id: MP-R2-C2-T01
feature_id: MP-R2
chunk_id: MP-R2-C2
bucket: 1 (refactor)
title: Aiur.Events.Delivery behaviour for per-ticket delivery and dead-letter reporting
status: blocked
blocked_by: [DESIGN-R2 §1, MP-R2-C1-T02, MP-R2-C1-T06, U3-event-subscription-delivery (events-webhooks-executor-01)]
prior_units: [U3, U7, U8]
prior_boundaries: [BUS #10, ORC #12, signal port #11]
prior_features: []
prior_findings: [events-webhooks-executor-01]
size_owner: EVENTS (subscription_store.ex, 748 lines at base; re-check at start per RC-23)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C2-T01 — `Aiur.Events.Delivery` behaviour

## Identity and outcome

- **Bucket 1, MP-R2, chunk C2 (in-place seams).**
- **User value:** none visible. The event bus stops calling the orchestrator
  and the alert system by name, so it can be reused (MP-R1 component
  `event-bus`) and so MP-E7 listener modes can plug a different sink in later.
- **Deliverable:** a behaviour `Aiur.Events.Delivery` with two callbacks,
  a default implementation that does exactly what `SubscriptionStore` does
  today, and `SubscriptionStore` calling only the configured implementation.
- **Non-goals:** no change to stall, buffer, retry or cursor logic (that is
  U3's fix); no change to the enqueue timeout (1 000 ms) or error
  classification; no move of `subscription_store.ex`; no rename.

## Dependencies and blockers

- **DESIGN-R2 §1** (owner confirms no user-facing change).
- **U3 event-subscription-delivery ticket first.** Prior finding
  `events-webhooks-executor-01` (P1, source-reachable) is still present at
  `45a290e3`: `resolve_stall/2` re-sends buffered events to its own mailbox
  (`src/lib/aiur/events/subscription_store.ex:484-492`) behind newer queued
  events, which then advance the cursor so the stale-id branch
  (`:397-400`) drops the buffered ones. The U3 worker boundary
  (`docs/research/refactor-2026-09-26/synthesis/u3-worker-boundary-current-main-2026-09-30.md`,
  row "Event subscription delivery") owns `SubscriptionStore` and its focused
  tests and must "preserve the enqueue callback contract to Orchestrator".
  This ticket edits the same functions (`process_new_event/4`,
  `handle_info({:retry_stalled}, _)`, `emit_dead_letter_alert/5`,
  `enqueue_event/2`). Running both at once is a guaranteed file conflict and
  would let a refactor PR hide a behaviour change. No commit touches
  `subscription_store.ex` between `45a290e3` and current main (checked
  2026-10-06), so the U3 fix has not landed.
- **MP-R2-C1-T02** (out-of-order witness) and **C1-T06** (boundary baseline)
  must be merged so this PR can show one allowlist entry removed.
- **Concurrent with:** C2-T02..T07 (different files). Not concurrent with any
  other PR touching `subscription_store.ex` (C2-T03 touches lines 424 and
  449: merge T03 first or rebase; both are small).

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| Test seam `set_enqueue_fn/1` stores a 2-arity fun in `:persistent_term` | `subscription_store.ex:255-261` |
| Dispatch: persistent_term fun, else orchestrator | `subscription_store.ex:577-582` |
| Fun wrapper: `:ok`, `{:error,_}`, other → `{:error,{:unexpected_return,other}}`, raise → `{:error,{:raised,e}}` | `subscription_store.ex:584-592` |
| Orchestrator path: `Process.whereis(Aiur.Orchestrator)` nil → `{:error,:no_orchestrator}`; `GenServer.call(pid, {:enqueue_event_digest, id, event}, 1_000)`; exit → `{:error,{:exit,reason}}` | `subscription_store.ex:594-610` |
| Error classes: `:no_orchestrator`, `{:exit,_}` transient; `{:raised,_}` permanent; else transient | `subscription_store.ex:494-498` |
| Dead letter: Logger.warning + `Aiur.Alerts.emit_system("system.subscription_store.event_dead_lettered", reason:, needs_attention: true, severity: "warning")` | `subscription_store.ex:500-514` |
| Orchestrator handler | `orchestrator.ex:695-696` (`OM.enqueue_event_digest_call/3`) |
| Other `set_enqueue_fn` users | tests only: `test/aiur/events/subscription_store_test.exs` (15), `event_delivery_test.exs`, `orchestrator_deactivate_test.exs`, `regression/event_flow_e2e_test.exs`, `test/support/test_support.exs:208,354` (reset to nil) |
| Existing tests guarding today's behaviour | `subscription_store_test.exs:349-499` ("enqueue failure handling", "stall retry and dead-letter") |

Proposed new paths: `src/lib/aiur/events/delivery.ex` (PROPOSED),
`src/lib/aiur/orchestrator/event_delivery.ex` (PROPOSED, default adapter in
the orchestration component), `src/test/aiur/events/delivery_test.exs`
(PROPOSED).

## Chosen design

```elixir
defmodule Aiur.Events.Delivery do
  @moduledoc "Sink for per-ticket subscription delivery."
  @type result :: :ok | {:error, term()}
  @callback enqueue(identifier :: String.t(), event :: map()) :: result()
  @callback dead_letter(identifier :: String.t(), event_id :: integer(),
              topic :: String.t(), reason :: term(), attempts :: pos_integer()) :: :ok
end
```

- **Selection:** `Application.get_env(:aiur, Aiur.Events.Delivery,
  Aiur.Orchestrator.EventDelivery)`, read once in `SubscriptionStore.init/1`
  and kept in state. The app env default lives in `src/config/config.exs`
  so the bus module never names `Aiur.Orchestrator.EventDelivery` in code
  (the source-scan test from C1-T06 then shows the `Aiur.Orchestrator` edge
  gone).
- **Default adapter** `Aiur.Orchestrator.EventDelivery`: `enqueue/2` is the
  body of today's `call_orchestrator_enqueue/2` verbatim (same 1 000 ms
  timeout, same return mapping). `dead_letter/5` is today's
  `emit_dead_letter_alert/5` verbatim (same Logger text, same alert topic,
  same options).
- **Test seam kept:** `set_enqueue_fn/1` remains and keeps priority over the
  configured module (persistent_term fun → `call_enqueue_fn/3`, unchanged).
  Removing it would touch five test files for no gain.
- **Error classification stays in `SubscriptionStore`** (`error_kind/1`): it
  is retry policy, which is the bus's job, not the sink's.
- **Invariant:** for every input, the sequence of enqueue calls, alerts,
  cursor writes and Logger lines is identical before and after.

## Implementation steps

1. Rebase onto main containing the U3 event-delivery fix; re-read
   `subscription_store.ex` and re-map the line numbers above.
2. Add `Aiur.Events.Delivery` (behaviour only, ~20 lines).
3. Add `Aiur.Orchestrator.EventDelivery` with `@behaviour Aiur.Events.Delivery`;
   move the bodies of `call_orchestrator_enqueue/2` and
   `emit_dead_letter_alert/5` there unchanged.
4. `src/config/config.exs`: `config :aiur, Aiur.Events.Delivery, Aiur.Orchestrator.EventDelivery`.
5. `SubscriptionStore`: add `delivery: module` to the `init/1` state map;
   `enqueue_event/2` → `enqueue_event(state, event)` calling
   `state.delivery.enqueue/2` when no test fun is set; replace both
   `emit_dead_letter_alert/5` calls with `state.delivery.dead_letter/5`.
   Delete the two private functions. Net change to the file must be ≤ 0 lines.
6. Remove the `Aiur.Orchestrator` and `Aiur.Alerts` entries for
   `subscription_store.ex` from the C1-T06 allowlist.

## Non-happy paths

- **Sink module missing or misconfigured** (undefined module): `enqueue/2`
  raises `UndefinedFunctionError`. Wrap the call exactly like
  `call_enqueue_fn/3` does (`rescue e -> {:error, {:raised, e}}`), which
  classifies as permanent → dead letter → cursor advances. Same outcome as a
  raising test fun today. Boot does not fail.
- **Orchestrator down / restarting:** unchanged `{:error, :no_orchestrator}`
  → transient → stall and retry.
- **Dead-letter sink raises:** today an `Alerts.emit_system` raise would
  crash the store; keep that (no new rescue), because swallowing it would
  be a behaviour change. Document it in the moduledoc.
- **Concurrency/idempotency:** unchanged; one GenServer per ticket.

## Compatibility and rollout

- No config key, no file format, no migration. The app-env key is internal
  (not in `.aiur/config`), so no `configuration.md` row.
- Rollback: revert the PR; no state written differently.

## Verification

New tests (`src/test/aiur/events/delivery_test.exs`, PROPOSED):

1. `"uses the configured Delivery module when no test fun is set"` —
   `Application.put_env(:aiur, Aiur.Events.Delivery, FakeDelivery)` where
   `FakeDelivery.enqueue/2` sends `{:delivered, id, event}` to the test pid;
   attach a store, subscribe `ticket.42.#`, `send(pid, {:event, %{id: 100,
   topic: "ticket.42.branch.push"}})`; expect `{:delivered, ^id, %{id: 100}}`
   and cursor 100. **Fails without step 5** (the store would call the
   orchestrator and get `:no_orchestrator` in this isolated setup).
2. `"dead letters through the configured module"` — `RaisingDelivery.enqueue/2`
   raises, which the store's rescue maps to `{:error, {:raised, _}}`
   (permanent); `RaisingDelivery.dead_letter/5` sends its arguments to the
   test pid. Expect `{:dead_letter, id, 100, "ticket.42.branch.push", _, 1}`
   and cursor 100. **Fails without step 5** (Alerts would be called instead).
3. `"default adapter preserves the orchestrator contract"` — unit test of
   `Aiur.Orchestrator.EventDelivery.enqueue/2` with no registered
   `Aiur.Orchestrator` returns `{:error, :no_orchestrator}`; with a stub
   GenServer registered under the name that sleeps 1 100 ms returns
   `{:error, {:exit, {:timeout, _}}}`. Guards the moved body (fails if the
   timeout or mapping changes).
4. Existing `subscription_store_test.exs` (all), `event_delivery_test.exs`,
   `orchestrator_deactivate_test.exs`, `regression/event_flow_e2e_test.exs`
   pass unchanged.
5. C1-T06 boundary test passes with the two allowlist rows removed; it
   **fails** if step 5 is reverted (edge reappears).

Commands (never run during research):

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events/delivery_test.exs test/aiur/events/subscription_store_test.exs \
  test/aiur/events/event_delivery_test.exs test/aiur/orchestrator_deactivate_test.exs \
  test/aiur/regression/event_flow_e2e_test.exs test/aiur/events/bus_boundary_test.exs
env -C <worktree>/src mise exec -- make fmt-check lint
```

Mutation check: in a clean worktree, revert only the `SubscriptionStore`
hunk of step 5 (`git status --porcelain` shows only that file), run tests 1
and 2: both must fail; restore: both pass. Record the command in the PR body.

## Completion and handoff

- [ ] U3 event-delivery fix merged first; this PR rebased on it.
- [ ] `subscription_store.ex` does not grow; no `Aiur.Orchestrator` or
      `Aiur.Alerts` reference remains in it.
- [ ] Tests 1–3 added and mutation-checked; all listed suites green on the
      merge ref.
- [ ] Docs: none (no user-facing change; AGENTS.md "Docs ship with the
      change" does not apply to internal seams).
- Dependents: MP-R2-C4-T01 (component registration), MP-E7-C3 (listener
  modes may supply a different `Delivery` module), MP-R1-C9 (orchestration
  core owns `Aiur.Orchestrator.EventDelivery`).
