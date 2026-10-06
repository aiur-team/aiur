---
ticket_id: MP-R7-C3-T03
feature_id: MP-R7
chunk_id: MP-R7-C3
bucket: 1-refactor
repo: aiur-team/aiur
wave: 1
title: Put Claude launch telemetry and the RC display tailer behind registry capability keys
status: ready
blocked_by: [DESIGN-R7, MP-R7-C1-T01, MP-R7-C2-T01]
prior_units: [U4]
prior_boundaries: [RUN (18), CLD (22), CA (20)]
prior_features: []
prior_findings: []
size_owner: AGENT_TURN (agent_runner/session_lifecycle.ex, 1,124 lines; split is U8's, not this ticket's)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R7-C3-T03 — Launch telemetry and display tailer via capability keys

## Identity and outcome

- Bucket 1, MP-R7, chunk C3. **User value:** none directly. The runner stops
  naming `Aiur.Claude.Telemetry` and `Aiur.Claude.DisplayTailer` and stops
  hard-coding `["claude", "claude-repl"]`, so a new harness that needs launch
  correlation or a display tailer declares it in its registry entry.
- **Deliverable:** two new optional registry keys and two facade functions in
  `Aiur.CodingAgent`; `agent_runner/session_lifecycle.ex` calls only the
  facades. The `Aiur.Claude.RemoteControl.process_tree/1` call at :646 is
  **not** changed here (it is a generic process helper owned by MP-R1-C5-T2;
  see MP-R7-C3-T05 allowlist).
- **Non-goals:** no split of `session_lifecycle.ex` (U8 `AGENT_TURN`); no
  change to telemetry correlation, revoke timing, fallback behaviour or
  display-tailer start conditions.

## Dependencies and blockers

- DESIGN-R7; MP-R7-C1-T01 (registry contract test must learn the two new
  keys); MP-R7-C2-T01 (the capabilities module where facades are documented).
- Concurrency: parallel with C3-T01/T02/T04. Conflicts with any U4 or U8
  `AGENT_TURN` PR editing `session_lifecycle.ex` — sequence by merge order and
  rebase; this ticket's edit is ~40 lines.

## Verified starting point (base `45a290e3`)

- `src/lib/aiur/agent_runner/session_lifecycle.ex` (1,124 lines):
  - :6 `alias Aiur.Claude.{DisplayTailer, RemoteControl, Telemetry}`.
  - :333-345 `prepare_telemetry_launch/5`:
    `if Keyword.get(session_opts, :backend) in ["claude", "claude-repl"]` →
    `Telemetry.prepare_launch(issue, opts)`, else `{:ok, nil}`.
  - :349-363 fallback launch fun calls `Telemetry.prepare_launch/2` for the
    fallback backend.
  - `Telemetry.revoke/1` at :323, :375, :545 (in `stop_session_with_ownership`
    `after`), :969, :984 (fallback path).
  - `DisplayTailer.current_session/1` :503, :519; `buffer_operator_delivery/3`
    :522; `DisplayTailer.start/1` :714; type `DisplayTailer.source_event()`
    :771. Start is gated by `should_display_tail?/3` (:843:
    `rc? and CodingAgent.rc_display_tail?(backend) and is_binary(identifier)`).
- `Aiur.Claude.Telemetry` (`claude/telemetry.ex`, 666 lines, GenServer):
  `prepare_launch/2` :57-77, `revoke/2` :81-89 (`revoke(_launch, _server)`
  returns `:ok`, so `revoke(nil)` is a no-op).
- Registry: `providers/claude.ex` `headless/0` and `repl/0`; `repl/0` sets
  `rc_display_tail: true` (:114). `CodingAgent.rc_display_tail?/1`
  (`coding_agent.ex:1064-1068`). Capability type `backend.ex:80-115` allows
  `optional(atom()) => term()`.
- Tests: `src/test/aiur/agent_runner/session_lifecycle_test.exs` (992 lines),
  `src/test/aiur/claude/telemetry_test.exs`, `src/test/aiur/claude/display_tailer_test.exs`.

## Chosen design

New optional registry keys (documented in `backend.ex` typedoc):

| Key | Value | Set on |
| --- | --- | --- |
| `:launch_telemetry` | module exporting `prepare_launch/2` and `revoke/1` | `claude` (headless) and `claude-repl` → `Aiur.Claude.Telemetry` |
| `:display_tailer` | module exporting `start/1`, `current_session/1`, `buffer_operator_delivery/3` | `claude-repl` → `Aiur.Claude.DisplayTailer` |

Facades in `Aiur.CodingAgent` (PROPOSED; one-line each, with `@spec`):

```elixir
@spec prepare_launch_telemetry(backend(), Issue.t(), keyword()) :: {:ok, term() | nil} | {:error, term()}
def prepare_launch_telemetry(backend, issue, opts)  # {:ok, nil} when key absent
@spec revoke_launch_telemetry(backend(), term()) :: :ok
def revoke_launch_telemetry(_backend, nil), do: :ok
def revoke_launch_telemetry(backend, launch)        # module.revoke(launch); :ok when key absent
@spec display_tailer(backend()) :: module() | nil
```

**Invariant (correlation safety):** a launch is revoked by the
`:launch_telemetry` module of the backend that prepared it. Call sites already
know that backend: the requested backend for :323/:375, the original backend
for :969, the fallback backend for :984, and `session_backend!(session)` for
:545. `rc_display_tail?/1` stays as is; `display_tailer/1` is only called after
it returned true, and the contract test (C1-T01, extended) asserts
`rc_display_tail: true ⇒ display_tailer` is a module.

Rationale: registry keys are the existing extension mechanism
(`backend.ex:5-15` moduledoc rule: a new backend is an adapter module plus a
registry entry). The `run_telemetry` key named in chunks.md is **not** this
seam — it is a RunTelemetry decoder (`providers/claude.ex:72,111`), unrelated
to launch correlation; chunks.md is corrected accordingly.

## Implementation steps

1. `backend.ex`: document `:launch_telemetry` and `:display_tailer` in the
   typedoc and add `optional(:launch_telemetry) => module()`,
   `optional(:display_tailer) => module()`.
2. `providers/claude.ex`: add the keys to `headless/0` and `repl/0` as in the
   table.
3. `coding_agent.ex`: add the three facades next to `rc_display_tail?/1`.
4. `session_lifecycle.ex`: replace the `in ["claude", "claude-repl"]` test
   with `CodingAgent.prepare_launch_telemetry(backend, issue, opts)`; replace
   each `Telemetry.revoke/1` with `CodingAgent.revoke_launch_telemetry/2`
   passing the backend named above; replace `DisplayTailer.*` calls with the
   module from `CodingAgent.display_tailer(backend)`; replace the
   `DisplayTailer.source_event()` type with `term()` plus a comment, or move the
   type to the facade. Alias becomes `alias Aiur.Claude.RemoteControl` only.
5. Extend MP-R7-C1-T01's registry contract test with the two key rules.

## Non-happy paths

- **Fallback** (`claude-repl` → `claude`, :960-990): the REPL launch is revoked
  with the REPL backend's module and a fresh launch prepared for `claude`
  (comment at :371-374 explains why a REPL capability must never be reused).
  Both resolve to `Aiur.Claude.Telemetry` today; the test below pins the
  revoke-then-prepare order.
- **RC promotion:** `remote_transport: "claude-repl"` — prepare uses the backend
  in `session_opts` at launch time, unchanged.
- **Telemetry server down:** `prepare_launch/2` errors propagate as today
  (`{:error, _} = error -> error`, :327-328).
- **Display tailer exit:** `current_display_source_opts/2` catches `:exit`
  (:510-511); keep the `catch` around the facade call.

## Compatibility and rollout

No config key, flag or rendered change. The new keys are internal registry
data, not `.aiur/config` keys, so `check-config-docs.py` is unaffected.
Rollback: revert.

## Verification

Tests (`src/test/aiur/agent_runner/session_lifecycle_test.exs` unless noted):

1. `test "launch telemetry is prepared only for backends that declare it"` —
   `codex` → `{:ok, nil}` without touching a Telemetry server; `claude` →
   `prepare_launch/2` called on a test double module registered via the
   facade's injectable `:launch_telemetry_registry` option (default
   `CodingAgent.backends/0`). Mutation: replace the facade with
   `{:ok, nil}` → the `claude` case fails.
2. `test "fallback revokes the REPL launch and prepares a new one for claude"`
   — double records `[{:revoke, repl_launch}, {:prepare, "claude"}]` in order.
   Guard for existing behaviour (named so); mutation: swap the revoke backend
   to the fallback's and confirm the recorded module/backend pair differs.
3. `src/test/aiur/coding_agent_test.exs`:
   `test "revoke_launch_telemetry is a no-op for nil and for backends without the key"`.
   Mutation: make the nil clause call the module → test fails with an
   undefined-function or unexpected-call error.
4. C1-T01 contract test: `rc_display_tail: true` without `:display_tailer`
   fails (add a fixture entry to prove the rule).

Commands (isolated `HOME`, GitHub tokens unset):

```text
env -C src mise exec -- mix test test/aiur/agent_runner/session_lifecycle_test.exs test/aiur/coding_agent_test.exs test/aiur/claude/telemetry_test.exs test/aiur/claude/display_tailer_test.exs
env -C src mise exec -- mix aiur.affected_tests
mise exec -- rg -n 'Claude\.(Telemetry|DisplayTailer)' src/lib/aiur/agent_runner/
```

Last command prints nothing. Manual: covered by MP-R7-C4 foreground run (a
`claude-repl` RC agent's pane transcript still mirrors; AGENTS.md "Manual testing").

## Completion and handoff

- [ ] Runner names no Claude module except `RemoteControl` (process helper,
      allowlisted until MP-R1-C5-T2).
- [ ] Tests 1 and 3 fail with their production hunks reverted (PR body).
- Docs: none (internal). C6-T01 lists the two keys for contributors.
- Dependents: MP-R7-C3-T05.
