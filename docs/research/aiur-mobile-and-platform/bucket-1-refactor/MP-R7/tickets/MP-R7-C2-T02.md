---
ticket_id: MP-R7-C2-T02
feature_id: MP-R7
chunk_id: MP-R7-C2
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Reserve optional steer and native-question callbacks in the backend behaviour
status: ready
blocked_by: [DESIGN-R7, MP-R7-C1-T01]
prior_units: [U4]
prior_boundaries: [CA (20)]
prior_features: [MP-E7, MP-E2]
prior_findings: [harness-adapter contract §2]
size_owner: "Aiur core / coding agent (backend.ex, 148 lines)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C2-T02 — Reserve optional callbacks

## Identity and outcome

- Bucket 1, MP-R7, chunk C2, ticket T02.
- **User value:** none visible. MP-E7-C4 (steer) and MP-E2-C4/C5 (native
  question hold/reply) implement against a declared, typed contract instead of
  each inventing a function name.
- **Deliverable:** three `@callback` declarations marked
  `@optional_callbacks` in `Aiur.CodingAgent.Backend`; a derived
  "implemented?" accessor; a test that today every adapter reports `:none`.
- **Non-goals:** no implementation in any adapter; no caller.

## Dependencies and blockers

- **DESIGN-R7**; C1-T01 (the contract test is the place that asserts exports).
- Concurrent with C2-T01 (different files). C2-T03 and MP-E7-C4 depend on it.
- Names are fixed by contracts: harness-adapter §2 and
  command-request-and-resolution §10 items 4–5
  (`contracts/command-request-and-resolution.md:269-271`).

## Verified starting point (base `45a290e3`)

- `src/lib/aiur/coding_agent/backend.ex:117-147`; only `interrupt: 1` is
  optional today (:147). Payload type `Aiur.CodingAgent.operator_payload()`
  is used by `send_operator_message/2` (:138).
- Adapters declaring the behaviour: `codex/coding_agent.ex:4`,
  `claude/coding_agent.ex:10`, `claude/repl_agent.ex:21`,
  `muse/coding_agent.ex:3`, `open_ai_compat/coding_agent.ex:7`.
- No existing function named `steer/3`, `reply_native_question/3` or
  `release_native_question/3` in `src/lib` (git grep at base: no match), so
  no adapter accidentally "implements" a reserved callback.

## Chosen design

Add to `backend.ex`, each with a `@doc` naming the owning feature:

```elixir
@callback steer(session(), CodingAgent.operator_payload(), expected_turn_id :: String.t() | nil) ::
            {:ok, reference() | term()} | {:error, :no_active_turn | :turn_mismatch | term()}
@callback reply_native_question(session(), native_ref :: term(), %{String.t() => [String.t()]}) ::
            :ok | {:error, :not_pending | :session_gone | term()}
@callback release_native_question(session(), native_ref :: term(), String.t()) ::
            :ok | {:error, :not_pending | :session_gone | term()}
@optional_callbacks interrupt: 1, steer: 3, reply_native_question: 3, release_native_question: 3
```

Accessor in `Aiur.Harness.Capabilities` (C2-T01 module):
`callback_support(backend_key) :: %{steer: :native | :none, native_question_reply: :native | :none}`
derived only from `function_exported?(adapter, name, arity)` after
`Code.ensure_loaded/1`. Unknown backend → `{:error, :unknown_backend}`.

Rationale for reserving now: MP-E7 and MP-E2 land in different waves and may
touch the behaviour in parallel; one reservation PR avoids two conflicting
edits to `backend.ex` and fixes the shapes the contracts already publish.

## Implementation steps

1. Edit `backend.ex` (callbacks, typedocs, extend `@optional_callbacks`).
   Update the moduledoc "Interrupt policy" paragraph with one sentence: steer
   is non-cancelling and optional (contract §2).
2. Add `callback_support/1` to `src/lib/aiur/harness/capabilities.ex`
   (if C2-T01 has not merged yet, create the module with only this function;
   whichever ticket lands second rebases).
3. Test: `src/test/aiur/harness/callback_support_test.exs` (PROPOSED).

## Non-happy paths

- An adapter that later implements `steer/3` with a different arity is not
  reported (`function_exported?` is arity-exact) and the registry contract
  test (C1-T01) gains an assertion: an adapter exporting `steer/2` or
  `steer/4` fails ("reserved name with wrong arity").
- Modules not yet loaded in a release: always `Code.ensure_loaded/1` first.

## Compatibility and rollout

Additive optional callbacks; existing adapters compile without warnings
(optional callbacks need no `@impl`). No config or user surface.

## Verification

- `every registered adapter reports steer and native-question reply as :none` —
  passes after the change; **fails before** because `callback_support/1`
  does not exist (new code, not a guard).
- `a test adapter implementing steer/3 is reported :native` — define a module
  in the test with `@behaviour Aiur.CodingAgent.Backend` and the required
  callbacks stubbed plus `steer/3`; assert `:native` via
  `Capabilities.callback_support_for_module/1` (the module-level helper the
  key-based function delegates to).
- Registry contract test addition: `reserved callback names are exported only with their reserved arity`.
- Command (from `src/`):
  `mise exec -- mix test test/aiur/harness/callback_support_test.exs test/aiur/coding_agent/registry_contract_test.exs`;
  then `mise exec -- mix test --only r7_characterization` (unchanged) and
  `mise exec -- mix compile --warnings-as-errors`.
- Mutation witness: make `callback_support` return `:native` unconditionally
  → first test fails; check `steer/2` instead of `steer/3` → second test fails.

## Completion and handoff

- [ ] Callbacks reserved with types and docs; accessor and tests green.
- [ ] Compiles with `--warnings-as-errors`; C1 suite unchanged.
- Docs: none user-facing; contract §2 already describes the callbacks.
- Dependents: C2-T03, MP-E7-C4 steer tickets, MP-E2-C4/C5 (native questions).
