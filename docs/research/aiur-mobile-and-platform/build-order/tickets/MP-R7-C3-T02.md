---
ticket_id: MP-R7-C3-T02
feature_id: MP-R7
chunk_id: MP-R7-C3
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Classify checkpoint-delivery failures through the registry, not Aiur.Codex.SessionRecovery
status: ready
blocked_by: [DESIGN-R7, MP-R7-C1-T01, MP-R7-C1-T04]
prior_units: [U4]
prior_boundaries: [RUN (18), CDX (21), CA (20)]
prior_features: []
prior_findings: []
size_owner: n/a (checkpoint_delivery.ex is 235 lines)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C3-T02 — Checkpoint-delivery failure classification via the registry

## Identity and outcome

- Bucket 1, MP-R7, chunk C3. **User value:** none directly; removes the
  runner's direct dependency on a Codex internal, so the runner treats every
  harness through `Aiur.CodingAgent` only.
- **Deliverable:** `Aiur.AgentRunner.CheckpointDelivery` stops aliasing
  `Aiur.Codex.SessionRecovery` and stops pattern-matching the literal backend
  `"codex"`; it asks `CodingAgent.recoverable_session_error?/2`, the registry
  facade that `agent_runner.ex:98`, `queue_drain.ex:775` and
  `turn_loop.ex:219` already use for the same purpose.
- **Non-goals:** no change to which errors are recoverable for any harness;
  no change to `Aiur.Muse.SessionRecovery`.

## Dependencies and blockers

- DESIGN-R7. MP-R7-C1-T01 (registry contract test) and MP-R7-C1-T04
  (single-writer/checkpoint guard) merge first.
- Concurrency: parallel with C3-T01, -T03, -T04 (disjoint files).

## Verified starting point (base `45a290e3`)

- `src/lib/aiur/agent_runner/checkpoint_delivery.ex:13` aliases
  `Aiur.Codex.SessionRecovery`. Clause at :189-199
  `handle_checkpoint_delivery_failure(issue, orchestrator, item_id, "codex", reason)`
  restores the item to pending when `SessionRecovery.recoverable?(reason)`,
  else marks it failed; the generic clause at :201 marks failed. Earlier
  clauses (:152-187) handle `:parent_turn_completed`, interrupts,
  cancellations, retired turns and `-32_003` for every backend and stay first.
- Registry facade `CodingAgent.recoverable_session_error?/2`
  (`coding_agent.ex:972-978`) returns the provider classifier's result, or
  `false` when the entry has no `:recoverable_session_error` key.
- Entries with the key: `codex` → `Aiur.Codex.SessionRecovery.recoverable?/1`
  (`providers/codex.ex:31`); `muse` → `Aiur.Muse.SessionRecovery.recoverable?/1`
  (`providers/muse.ex:32`, a different, narrower classifier). Claude,
  claude-repl, OpenAI-compat and fake have none.
- Who reaches this function: the safe-checkpoint handler is installed for every
  backend (`agent_runner/turn_callbacks.ex:43-50`), but only the app-server
  core (`app_server/operator_delivery.ex:54`, used by codex and claude) and
  OpenAI-compat (`open_ai_compat/checkpoint.ex:6,40`) invoke
  `on_safe_checkpoint`. `git grep on_safe_checkpoint -- src/lib/aiur/muse`
  returns nothing, so Muse never reaches this code.
- Tests: `src/test/aiur/agent_runner/checkpoint_delivery_test.exs`.

## Chosen design

Replace the `"codex"` clause with a backend-agnostic clause:

```elixir
defp handle_checkpoint_delivery_failure(issue, orchestrator, item_id, backend, reason) do
  if CodingAgent.recoverable_session_error?(backend, reason) do
    # log line unchanged except backend=#{backend}
    Aiur.Orchestrator.restore_queue_item_pending(orchestrator, item_id)
  else
    mark_checkpoint_item_failed(issue, orchestrator, item_id, reason)
  end
end
```

Behaviour proof per backend reaching the function: `codex` → same classifier
(identical); `claude`, OpenAI-compat → no key → `false` → mark failed
(identical to today's generic clause); `muse` → unreachable (see above).
Rationale for not adding a new registry key: the existing key has exactly the
documented meaning ("errors that can safely restore claimed work and replace
the stale session", `backend.ex:77-78`), and three runner call sites already
use it.

**Invariant:** a backend that later adds `on_safe_checkpoint` support and a
`recoverable_session_error` classifier gets restore-on-recoverable behaviour
automatically. That is intended and is stated in the moduledoc.

The log message today says "recoverable Codex transport loss"; keep the text
but add `backend=<key>` so the line stays greppable. (Log text is not a
rendered operator surface.)

## Implementation steps

1. Remove `alias Aiur.Codex.SessionRecovery` (:13); add `alias Aiur.CodingAgent`
   if not present.
2. Replace the clause at :189-199 with the one above; delete nothing else.
3. Update the comment block at :180-188 to say "a provider-classified
   recoverable transport loss (today: Codex)".

## Non-happy paths

- **Clause order:** the new clause must stay after the five specific clauses
  (:152-187) and replace, not precede, the generic clause at :201, which is
  then unreachable and must be deleted (compiler warns otherwise; the build
  uses `--warnings-as-errors`).
- **Unknown backend string** (stale session): `recoverable_session_error?/2`
  returns `false` on `Map.fetch` error → mark failed, as today.
- **Exactly-once delivery** (#1238 comment): restore-to-pending path unchanged.

## Compatibility and rollout

No config, flag or user-visible change. Rollback: revert.

## Verification

New tests in `src/test/aiur/agent_runner/checkpoint_delivery_test.exs`:

1. `test "codex recoverable transport loss restores the checkpoint item"` —
   backend `"codex"`, reason `{:turn_start_failed, :port_closed}` → the fake
   orchestrator receives `restore_queue_item_pending`. Guard (passes on main);
   named as a regression guard.
2. `test "classification comes from the registry entry, not the backend name"`
   — call the handler path with backend `"muse"` and reason
   `{:turn_start_failed, :port_closed}` (which `Aiur.Muse.SessionRecovery`
   classifies as recoverable, `muse/session_recovery.ex:11`) → item restored.
   **Fails on main** (main restores only for the literal `"codex"`). Muse never
   reaches this function in production (see Verified starting point), so the
   test exercises the dispatch rule without changing a reachable path; the
   `Providers.Fake` entry has no override hook (`providers/fake.ex`), which is
   why Muse is used. Mutation check: restore the `"codex"` literal clause and
   confirm this test fails.
3. `test "claude recoverable-looking reason still marks the item failed"` —
   backend `"claude"`, reason `:port_closed` → `mark_queue_item_failed`.
   Guard; fails if someone maps every `:port_closed` to restore.

Commands (isolated `HOME`, GitHub tokens unset):

```text
env -C src mise exec -- mix test test/aiur/agent_runner/checkpoint_delivery_test.exs test/aiur/agent_runner/
env -C src mise exec -- mix compile --warnings-as-errors
mise exec -- rg -n 'Codex.SessionRecovery' src/lib/aiur/agent_runner/
```

The last command must print nothing. C1 characterization suite passes unchanged.

## Completion and handoff

- [ ] `agent_runner/` has no `Aiur.Codex.*` alias for session recovery.
- [ ] Test 2 fails with the production hunk reverted (PR body states the command).
- Docs: none (internal).
- Dependents: MP-R7-C3-T05 removes this edge from the allowlist.
