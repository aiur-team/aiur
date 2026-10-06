---
ticket_id: MP-E1-C1-T06
feature_id: MP-E1
chunk_id: MP-E1-C1
bucket: 2-platform
title: ClaimProbe behaviour and its orchestration implementation
status: blocked
blocked_by: [DESIGN-E1]
prior_units: [U2, U3]
prior_boundaries: [ORC #12]
prior_features: []
prior_findings: [MP-E1 F4, RQ-7, X-1]
size_owner: "LIFECYCLE_DISPATCH / Ticket lifecycle and dispatch (orchestrator.ex, 1003 lines; provisional, RC-23)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E1-C1-T06 — `ClaimProbe`: race-free "has an agent claimed it?"

> **Plan refresh (wave 0).** Cites `45a290e3`. This is RC-11 edge 2 (the
> claim-check interface that orchestration implements). After MP-R1 the
> implementation moves with orchestration; U2 rebases over it and keeps it
> (RC-19).

## Identity and outcome

- Bucket 2, MP-E1, C1, T06. Resolves RQ-7.
- **User value:** the queue removes `agent:todo` only when no agent has the
  ticket, so a dependency change never yanks a ticket from under a running
  agent (D8).
- **Deliverable:**
  1. PROPOSED `src/lib/aiur/build_queue/claim_probe.ex`: behaviour
     `@callback status([String.t()]) :: %{String.t() => :claimed | :unclaimed | {:declined, atom()}} | :unavailable`
     and `@callback notify_demand([String.t()]) :: :ok | :unavailable`, plus
     `impl/0` reading `Application.get_env(:aiur, :build_queue_claim_probe)`
     (nil → every call answers `:unavailable`).
  2. PROPOSED `src/lib/aiur/orchestrator/build_queue_claim_probe.ex`,
     `Aiur.Orchestrator.BuildQueueClaimProbe`, implementing it.
  3. `Aiur.Orchestrator.handle_call({:build_queue_claim_status, ids}, …)`.
  4. `config/config.exs` sets `:build_queue_claim_probe` to the orchestration
     module (verify the file location when starting; the queue never names it
     in code).
- **Non-goals:** no queue server.

## Dependencies and blockers

- DESIGN-E1 (gate). Concurrent with C1-T01..T05 and C2. Consumers: C3-T04
  (notify), C3-T05 (withdrawal), C5-T04 (unauthorized).

## Verified starting point (`45a290e3`)

- The daemon does not write `in-progress` at dispatch; it records
  `state.running`/`state.claimed` (`orchestrator/dispatcher.ex:2523-2566`);
  the agent relabels later (F4). So labels cannot prove "unclaimed".
- Ownership predicate already used by the strand sweep:
  `orchestrator/issue_sync.ex:188-193` (`running`, `claimed`,
  `retry_attempts`, `auto_resume`).
- `orchestrator/state.ex:88` `dispatch_declines :: %{issue_id => reason}`;
  written by `dispatcher.ex:1316-1337`; `:unauthorized` recorded only while
  `Slots.available_slots/1 > 0` (`dispatcher.ex:1054-1070`).
- Call wrapper pattern: `orchestrator/lifecycle.ex:67-78`
  (`State.alive?/1`, `catch :exit -> :unavailable`).
- `orchestrator.ex:433-437` `note_queued_demand/1,2`; `:694-724`
  `handle_call/3` clauses.

## Chosen design

- One batched call per reconcile. Inside the orchestrator process:

  ```elixir
  def handle_call({:build_queue_claim_status, ids}, _from, state) when is_list(ids) do
    {:reply, Map.new(ids, &{&1, BuildQueueClaimProbe.classify(state, &1)}), state}
  end
  # classify/2: owned (issue_sync predicate) -> :claimed
  #             Map.get(state.dispatch_declines, id) = r when r != nil -> {:declined, r}
  #             else -> :unclaimed
  ```

  `classify/2` is a public pure function in the implementation module so it is
  unit-testable without a GenServer; the predicate is duplicated as a call to a
  newly public `IssueSync.owned_or_scheduled?/2` (make the existing private
  function public, ≤ 2 lines) rather than copied.
- **Linearizability:** dispatch runs inside the orchestrator process (F4), so
  the reply is ordered after any in-flight dispatch decision. The queue sets the
  `Hints` hold *before* calling (contract §2.4), so no later decision can start
  the ticket.
- `notify_demand/1` → `Orchestrator.note_queued_demand/1`; `:unavailable`
  passes through.
- Timeout: 1 000 ms (same as `list_running_active_identifiers/2`,
  `orchestrator.ex:653`); timeout → `:unavailable`.

## Implementation steps

1. Behaviour module with `impl/0` and nil-safe facade functions.
2. Implementation module (`status/1`, `notify_demand/1`, `classify/2`).
3. `orchestrator.ex`: one `handle_call` clause (≈ 3 lines).
4. `issue_sync.ex`: make `owned_or_scheduled?/2` public with `@doc false`.
5. Config default.

## Non-happy paths

- **Orchestrator not started / restarting / slow:** `:unavailable`. The
  queue keeps the hold and writes nothing (contract §2.4).
- **After a daemon restart** `running`/`claimed` are empty and
  `StartupClaimReconciler` relabels orphaned `in-progress` to `todo`
  (`orchestrator/startup_claim_reconciler.ex:112, 149-166`). A ticket whose
  agent died is then truly unclaimed; withdrawing it is correct.
- **Unknown id:** `:unclaimed` (no runtime entry).

## Compatibility and rollout

No user-visible change. Config default added; absent config disables the
probe safely.

## Verification

| Test | Expected | Fails without |
| --- | --- | --- |
| `src/test/aiur/orchestrator/build_queue_claim_probe_test.exs` (PROPOSED) "a running entry whose issue still carries only todo is claimed" — `%State{running: %{"7" => %{issue: %Issue{state: "todo"}}}}` | `classify(state, "7") == :claimed` | the running check |
| "a claim with a retry scheduled is claimed" | `:claimed` | the shared predicate call |
| "a declined issue reports its reason" — `dispatch_declines: %{"8" => :unauthorized}` | `{:declined, :unauthorized}` | the decline branch |
| "status answers :unavailable when the orchestrator is not running" — call with a dead/unregistered server name | `:unavailable` | the `catch :exit` |
| `src/test/aiur/build_queue/claim_probe_test.exs` (PROPOSED) "nil impl answers :unavailable" | `:unavailable` | the nil-safe facade |

Mutation check: replace `classify/2` body with `:unclaimed` → tests 1–3 fail;
remove the `catch` → test 4 crashes.

```bash
env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/orchestrator/build_queue_claim_probe_test.exs test/aiur/build_queue/claim_probe_test.exs
```

## Completion and handoff

- [ ] Behaviour, implementation, `handle_call`, config default; tests pass and
      fail under mutation.
- Docs: none (internal).
- Dependents: C3-T04, C3-T05, C5-T04.
