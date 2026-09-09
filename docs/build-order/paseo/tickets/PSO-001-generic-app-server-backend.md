# PSO-001 — Generic app-server backend module

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Parameterize the existing Claude app-server adapter so any registry entry can launch an app-server sidecar; behaviour of `claude` must not change.

**Risk:** medium

**Phase hint:** 1

**Depends on:** none

**Serializes with:** PSO-007 — both edit `src/lib/aiur/app_server/generic_backend.ex`

**External gates:** none

**Requirements:** R5, R6, R14

**Decisions:** DEC-002, DEC-003, DEC-012

**Design evidence:** 00-design.md sections 3, 5, 6, 8, 9; 01-spike-report.md section 2

**Researched at:** 8199f5373

**Suggested labels:** `complexity:3`, `model:claude`, `phase:1`, `build-lane:paseo-core`; never `agent:todo`

## Outcome

`Aiur.AppServer.GenericBackend` exists and drives any stdio app-server sidecar whose launch command, permission mode, and model come from the registry entry and `agent.backend_configs.<backend>` rather than from `Aiur.Claude.Config`. `Aiur.Claude.CodingAgent` keeps its module name and its test suite passes unchanged. The `paseo-claude` and `paseo-codex` registry entries (PSO-002) point `adapter:` at this module and need nothing else in core.

## Context and evidence

`src/lib/aiur/claude/coding_agent.ex` implements both `Aiur.CodingAgent.Backend` and `Aiur.AppServer.Adapter` over the shared skeleton in `src/lib/aiur/app_server/adapter.ex`. It is generic except for three reads of `Aiur.Claude.Config`:

- `start_port/3` (lines 158-173) passes `Aiur.Claude.Config.command()` to `Adapter.start_port/4`.
- `start_thread/2` (lines 224-245) sends `"permissionMode" => Aiur.Claude.Config.permission_mode()` on `thread/start`.
- `maybe_put_model/2` (line 484) falls back to `Aiur.Claude.Config.model()`.

Two other hard-coded facts: `ProcessReaper.register/3` in `start_session/2` (line 40) uses `comm: "claude"` and `backend: "claude"`, and `backend_label/0` (line 285) returns `"Claude"`.

The decomposition research (`docs/planning/decompose-packages/04-other-slices.md`, V5) named `AppServer.Adapter` the real runtime contract and asked for the behaviour to be extracted, not the backends. This ticket is the smallest form of that verdict: one module that takes launch facts as data.

`Aiur.AgentRunner.SessionLifecycle.start_agent_session/3` (`src/lib/aiur/agent_runner/session_lifecycle.ex:907`) already passes `backend:` in the opts it hands to `CodingAgent.start_session/2`, and `tag_session/3` (line 963) stamps `:backend` and `:model` on the returned session. The generic module reads `opts[:backend]` at start and stores it; nothing upstream changes.

## Scope

- Create `src/lib/aiur/app_server/generic_backend.ex` (`Aiur.AppServer.GenericBackend`) with `@behaviour Aiur.CodingAgent.Backend` and `@behaviour Aiur.AppServer.Adapter`.
- Move the body of `Aiur.Claude.CodingAgent` into `GenericBackend` behind one hook, `resolve_launch/2`, that returns `%{command, permission_mode, model, reaper_comm, label}` for a backend key. `Aiur.Claude.CodingAgent` becomes a thin wrapper that delegates every callback to `GenericBackend` with `backend: "claude"` and a `resolve_launch/2` that returns the three `Aiur.Claude.Config` values, `reaper_comm: "claude"`, `label: "Claude"`.
- `GenericBackend.resolve_launch/2` for any other backend: `command = Aiur.Config.backend_config(backend)["command"] || get_in(CodingAgent.backends(), [backend, :default_command])`; `permission_mode = backend_config["permission_mode"] || get_in(backends, [backend, :permission_mode]) || family_default(backend)`; `model = opts[:model] || backend_config["model"]`. `family_default/1` returns `Aiur.Claude.Config.permission_mode()` for family `claude` and `"full-access"` for family `codex`.
- Store `backend` on the session at `start_session/2`. `ProcessReaper.register/3` uses `comm: reaper_comm` and `backend: backend`.
- `backend_label/0` is replaced by `backend_label/1` inside the module for logging; the `Aiur.AppServer.Adapter` callback `backend_label/0` stays and returns the registry `presentation.label` when the module is used directly, and `"Claude"` through the wrapper.
- If the `thread/start` result carries `thread.surface`, store it as `session.surface` (map with string keys converted to `%{kind, label, url}`) and `session.session_url = surface.url`. Do not render it; PSO-003 owns the surface plumbing beyond the session map.
- Keep `resumable` behaviour as today (no `thread/resume`); PSO-007 adds it.
- `mix specs.check` passes: every public function has an adjacent `@spec`.

## Non-goals

- Changing `Aiur.Codex.CodingAgent`, `Aiur.AppServer.Adapter`, `TurnLoop`, `TurnState`, or the interrupt handshake.
- Adding the `paseo-*` registry entries (PSO-002).
- Rendering the surface anywhere (PSO-003).
- Resume by thread id (PSO-007).
- Any change to `Aiur.Claude.Config` or to `agent.claude.*` semantics.

## Existing owner and reuse target

Extend `src/lib/aiur/claude/coding_agent.ex` by extraction; reuse `Aiur.AppServer.Adapter.run_turn/5` and `start_port/4`, `Aiur.AppServer.Messages`, `Aiur.Codex.DynamicTool.tool_specs/0`, `Aiur.Claude.AccountGeneration`, `Aiur.Claude.AccountMeters`, `Aiur.Claude.NotificationPolicy`. The fake app-server bash scripts in `src/test/aiur/claude/coding_agent_test.exs` (`fake_app_server/1` at line 405 and siblings) are the test harness to copy.

## Contract and invariants

- `Aiur.AppServer.GenericBackend.start_session(workspace, opts)` requires `opts[:backend]` to be a registry key; a missing key returns `{:error, :missing_backend}` rather than defaulting (mirrors issue #1621).
- `resolve_launch(backend, opts)` is pure and total: it never raises on a backend without `backend_configs`, and it returns `{:error, {:missing_command, backend}}` when neither config nor registry names a command.
- The JSON-RPC frames sent for `claude` are byte-identical to today's, verified by the recorded frames in the existing tests.
- The session map keeps every key `Aiur.Claude.CodingAgent.session/0` has today, plus `:backend`, `:surface`, `:session_url`.
- `thread/start` params are exactly `%{"permissionMode", "cwd", "dynamicTools"}`; nothing Paseo-specific is added in core.

### Requirements

- PSO-001-R1. A registry entry with `adapter: Aiur.AppServer.GenericBackend` and a `default_command` starts a session with no other core edit.
- PSO-001-R2. Command precedence is `agent.backend_configs.<backend>.command`, then registry `default_command`, then error.
- PSO-001-R3. Permission mode precedence is `backend_configs.<backend>.permission_mode`, then registry `permission_mode`, then the family default.
- PSO-001-R4. Model precedence is `opts[:model]`, then `backend_configs.<backend>.model`, then absent (the sidecar picks).
- PSO-001-R5. `thread.surface` in the `thread/start` result lands on the session as `surface` and `session_url`; absence leaves both `nil`.
- PSO-001-R6. Every existing `Aiur.Claude.CodingAgent` test passes without modification.
- PSO-001-R7. `Aiur.ProcessReaper` entries carry the real backend key.

## Refreshable implementation notes

- Read `src/lib/aiur/claude/coding_agent.ex` in full first; it is 506 lines and every line moves.
- Suggested shape:

  ```elixir
  defmodule Aiur.AppServer.GenericBackend do
    @behaviour Aiur.CodingAgent.Backend
    @behaviour Aiur.AppServer.Adapter

    @type launch :: %{command: String.t(), permission_mode: String.t(), model: String.t() | nil, reaper_comm: String.t(), label: String.t()}

    @spec resolve_launch(String.t(), keyword()) :: {:ok, launch()} | {:error, term()}
    @spec start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
    # run_turn/4, stop_session/1, send_operator_message/2, normalize_event/1 unchanged in shape
  end
  ```

  and

  ```elixir
  defmodule Aiur.Claude.CodingAgent do
    @behaviour Aiur.CodingAgent.Backend
    @behaviour Aiur.AppServer.Adapter
    alias Aiur.AppServer.GenericBackend
    def start_session(workspace, opts \\ []), do: GenericBackend.start_session(workspace, Keyword.put_new(opts, :backend, "claude"))
    defdelegate run_turn(session, prompt, issue, opts \\ []), to: GenericBackend
    # ... one delegate per callback
  end
  ```

  `GenericBackend.resolve_launch("claude", _)` returns the `Aiur.Claude.Config` values so the wrapper needs no override hook; keep that special case in one function clause with a comment pointing at this ticket.
- `Adapter.run_turn/5` takes the adapter module as its first argument and calls `backend.start_turn/3`, `backend.handle_method/5`, and `backend.backend_label/0` on it. Pass `GenericBackend` from the wrapper so the loop state's `backend:` field is the generic module; the label comes from `loop_state_extras/1` or from the session, not from the module name.
- `send_operator_message/2` builds a second `turn/start` frame with `maybe_put_model/2`; route it through the stored `session.model` and the resolved launch model so the Paseo sidecar receives the same model on every turn.
- `AccountMeters.handle_notification/2` and `AccountGeneration` are Claude-family telemetry; keep them and guard on `family == "claude"` where the registry family is `codex` (the `paseo-codex` sidecar will not emit `rate_limit/update`).

### Key technical decisions

- KTD-1. Extract by moving the body, not by copying it. Two 500-line adapters would drift; one module with a `resolve_launch/2` hook cannot.
- KTD-2. The backend key is data on the session, never inferred from the module. `Aiur.AgentRunner` already tags it; the module stores it at start so `stop_session/1` and the reaper see the same value.
- KTD-3. Family default permission modes are decided in core (`bypassPermissions` for claude, `full-access` for codex) because they are the modes aiur runs under today; the sidecar receives them as a string and translates.
- KTD-4. The `surface` result field is stored but not interpreted here, so PSO-001 and PSO-003 can land in either order.

## Acceptance and verification

### Agent gate

- New `src/test/aiur/app_server/generic_backend_test.exs` using a fake app-server bash script in the style of `fake_app_server/1` (`src/test/aiur/claude/coding_agent_test.exs:405`) and a registry entry injected through `Aiur.Config` backend_configs. Scenarios:
  1. Command resolution: `backend_configs.<b>.command` wins over registry `default_command`; registry default used when config absent; neither present returns `{:error, {:missing_command, b}}`.
  2. `thread/start` frame carries `permissionMode` from `backend_configs`, then registry `permission_mode`, then family default (three tests).
  3. `turn/start` frame carries `model` from `opts[:model]`, then `backend_configs.model`, and omits the key when neither is set.
  4. `thread/start` result with `"surface" => %{"kind" => "paseo", "label" => "Paseo", "url" => "paseo://h/s/agent/a"}` sets `session.surface` and `session.session_url`; result without it leaves both `nil`.
  5. `item/tool/call` request from the fake is answered on the same id with `success: true` and the tool executor receives the tool name.
  6. `turn/completed` yields `{:ok, %{result: :turn_completed}}`.
  7. Fake exits after `turn/start`: `run_turn/4` returns `{:error, {:port_exit, _}}`.
  8. `opts` without `:backend` returns `{:error, :missing_backend}`.
  9. `ProcessReaper` registration carries `backend: "<b>"`.
- `src/test/aiur/claude/coding_agent_test.exs` passes without edits.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo`, `mix specs.check`, `mix dialyzer` green.

### At-merge gate

- `make all` in `src/` green on the exact head; CI required check `ci / required` green.
- `scripts/guard-pr-deletions main` reports zero untouched deletions.

### Human/manual evidence

- None separately; PSO-012 proves the module against the real `aiur-paseo` sidecar. A quick `scripts/aiurdev --test --force --allow-remote` with a `claude` agent confirms the wrapper is behaviour-preserving.

## Failure, security, migration, and accessibility cases

- A sidecar that never answers `initialize` times out through `Rpc.with_timeout_response/5` with `Config.agent_read_timeout_ms/0`; keep that path and its error shape.
- Never log the `surface.url`; treat it like `repl_rc_session_url` (see `src/lib/aiur/agent_list/rc_pane_borders.ex` moduledoc and `Aiur.SecretRedactor`).
- The command string is spliced into `bash -c` through `AgentEnvironment.scrub_shell_command/2`; a `backend_configs.<b>.command` is operator-owned config, the same trust level as `agent.claude.command` today.
- No config migration: no key is renamed.

## Surfaces

- Reads: registry entries, `Aiur.Config.backend_config/1`, `Aiur.Claude.Config` (claude only).
- Writes: `src/lib/aiur/app_server/generic_backend.ex` (new), `src/lib/aiur/claude/coding_agent.ex` (wrapper), tests.
- Contracts: `Aiur.CodingAgent.Backend`, `Aiur.AppServer.Adapter`, the session map in 00-design.md section 9.

## Sibling boundaries and open gates

PSO-002 owns the registry entries that select this module. PSO-003 owns everything that reads `session.surface` beyond the session map. PSO-007 owns `thread/resume`. PSO-005 (sidecar) implements the server side of the same protocol; the frame shapes in 00-design.md section 6 are the shared contract and must not be changed by either side alone.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the approved planning commit linked in this issue's preamble):

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
