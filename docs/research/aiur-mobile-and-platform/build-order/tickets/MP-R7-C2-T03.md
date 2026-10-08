---
ticket_id: MP-R7-C2-T03
feature_id: MP-R7
chunk_id: MP-R7-C2
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Running-agent harness delivery read model (next to, not inside, control capabilities)
status: ready
blocked_by: [DESIGN-R7, MP-R7-C2-T01, MP-R7-C2-T02, MP-R7-C1-T02]
prior_units: [U4, U6]
prior_boundaries: [MSG (16), CA (20)]
prior_features: [MP-E7]
prior_findings: [R7-C1-F1 (control flags follow the dispatched backend)]
size_owner: "Ticket lifecycle and dispatch (operator_messages/capabilities.ex, 125 lines)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C2-T03 — Running-agent harness delivery read model

## Identity and outcome

- Bucket 1, MP-R7, chunk C2, ticket T03.
- **User value:** none visible. MP-E7-C2 computes an agent's *effective*
  listener mode from what the **running** transport can do; this ticket gives
  it that fact without touching the existing control map that the CLI and
  dashboard render.
- **Deliverable:** `Capabilities.harness_delivery/2,3` returning, for a
  running entry, the harness id actually running, where that fact came from,
  and the C2-T01/T02 descriptors. `issue_control_capabilities/3` output stays
  byte-identical.
- **Non-goals:** no change to `:control` flags or delivery (R7-C1-F1 stays as
  pinned; MP-E7-C2-T04 owns recompute-on-transport-change); no GenServer call,
  HTTP field or UI.

## Dependencies and blockers

- **DESIGN-R7**; C2-T01 (primitives), C2-T02 (callback support), C1-T02
  (matrix profiles reused for the byte-identical check).
- Dependent: MP-E7-C2-T02 (`Aiur.Listener.Effective.compute/2`).

## Verified starting point (base `45a290e3`)

- `issue_control_capabilities/3`: `orchestrator/operator_messages/capabilities.ex:42-64`;
  returned to clients by `operator_messages.ex:356` and used for normalization
  at :792. Exact-map assertions exist in `capabilities_test.exs:11-21,36-46`.
- Running transport fact: `running_entry.session_execution.backend`, set from
  the runner's `{:session_execution_info, …}` (`agent_runner/session_lifecycle.ex:33-47`
  → `orchestrator.ex:135-137` → `orchestrator/state.ex:441-461,487-493`).
  It is the tagged session backend after fallback (`session_lifecycle.ex:981`)
  and after RC promotion (`session_lifecycle.ex:661`). It is absent between
  dispatch and session start.
- Dispatched backend: `CodingAgent.backend_for(issue)` (`coding_agent.ex:508-511`),
  used for `:control` at `dispatcher.ex:2660-2672`.

## Chosen design

```elixir
@spec harness_delivery(State.t(), String.t(), map() | nil) ::
        nil | %{harness_id: String.t(), source: :session | :dispatch,
                primitives: map(), callbacks: map()}
```

- `nil` when there is no running entry (no guess).
- `source: :session` and `harness_id = session_execution.backend` when that
  is a registered key; else `source: :dispatch` and
  `harness_id = CodingAgent.backend_for(running_entry.issue)`.
- If the chosen key is unknown to the registry (for example the runner's
  `@unknown_backend` label, `session_lifecycle.ex:1123`), return
  `%{harness_id: key, source: …, primitives: :unknown, callbacks: :unknown}` —
  an explicit unknown, never the dispatch profile (AGENTS.md collapsed-cause
  rule).
- Lives beside `issue_control_capabilities/3` in the same module; the old
  function is not edited.

Invariant: `source` lets MP-E7 show "pending session start" honestly instead
of presenting a dispatch-time guess as fact.

## Implementation steps

1. Add `harness_delivery/2` (looks up the running entry like :34-39) and
   `harness_delivery/3` to `operator_messages/capabilities.ex` (≈ 35 lines;
   file stays < 200).
2. Delegate from `operator_messages.ex` next to :1161-1166 only if MP-E7 needs
   the facade; otherwise leave it module-local (prefer local; fewer edits to
   a 1,167-line file owned by U8 "Ticket lifecycle and dispatch").
3. Tests in `capabilities_test.exs` (extend; < 250 lines after).

## Non-happy paths

- Entry with `session_execution: nil` → `:dispatch` source.
- Fallback: entry dispatched `claude-repl`, `session_execution.backend = "claude"`
  → `harness_id "claude"`, `source :session`, claude primitives.
- RC promotion: dispatched `claude`, session `claude-repl` → repl primitives.
- Unknown label → explicit `:unknown` primitives.
- Stale entry after teardown: the function only reads state; callers that
  cache it own staleness (MP-E7-C2).

## Compatibility and rollout

Pure read addition; no wire, config or UI change. Rollback: revert.

## Verification

Tests (extend `src/test/aiur/orchestrator/operator_messages/capabilities_test.exs`):

- `harness delivery follows the running session after a REPL fallback` — new behaviour.
- `harness delivery follows the running session after RC promotion`.
- `harness delivery falls back to the dispatched backend before session start, marked :dispatch`.
- `an unregistered session backend is reported unknown, not defaulted`.
- `harness delivery is nil without a running agent`.
- `issue_control_capabilities is byte-identical for every C1 matrix profile`
  — runs the C1-T02 profiles and compares each result with a checked-in
  Elixir-term fixture (`src/test/fixtures/harness_frames/control_capabilities_profiles.exs`,
  PROPOSED, read with `Code.eval_file/1`; generated once at the merge base and
  reviewed in the PR).

Command (from `src/`):
`mise exec -- mix test test/aiur/orchestrator/operator_messages/capabilities_test.exs`
and `mise exec -- mix test --only r7_characterization`.

Mutation witnesses: prefer `backend_for(issue)` over `session_execution`
→ the fallback and RC tests fail; replace the unknown branch with the
dispatch profile → the unknown test fails; add a `harness:` key into
`issue_control_capabilities/3` → the byte-identical test fails.

## Completion and handoff

- [ ] Function + 6 tests green; old map unchanged (fixture equal).
- [ ] PR body links R7-C1-F1 and states this ticket does not fix it.
- Docs: none.
- Dependents: MP-E7-C2-T02, MP-E7-C2-T04.
