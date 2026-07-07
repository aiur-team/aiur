# T-037: codex wave 1: AppServerPort, Rpc, Frames, Handshake

**Phase:** 3
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:3` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/codex/coding_agent.ex` is the largest single module in the tree
(1,997 lines at commit `8712a32f`). `docs/refactor/research-arch/giant-coding_agent.md`
maps it to 14 focused modules under `Aiur.Codex.*`, extracted in strictly
serialized waves. This ticket is **wave 1 of 3** (the later waves are T-038 and
T-039) and extracts the four modules the name map calls
`Aiur.Codex.AppServerPort`, `Aiur.Codex.Rpc`, `Aiur.Codex.Frames`, and
`Aiur.Codex.Handshake`.

**Reconcile with T-014 first (binding).** T-014 ("Extract Aiur.AppServer shared
adapter core", Phase 2) lands before any Phase-3 ticket and has already moved
the *shared* JSON-RPC machinery out of this file into `Aiur.AppServer.*`:

- `Aiur.AppServer.Rpc` — the wire transport (`send_line/2`,
  `with_timeout_response/5`, `handle_response/5`, `log_non_json_stream_line/3`).
- `Aiur.AppServer.Messages` — `initialize_frame/0`, `initialized_frame/0`,
  `initialize_id/0`, `emit_message/4`, `issue_context/1`, `issue_identifier/1`,
  `normalize_tool_result/1`, `tool_call_name/1`, `tool_call_arguments/1`.
- `Aiur.AppServer.Interrupts` — owns the `turn/interrupt` frame builder
  (`interrupt_turn/3`).
- `Aiur.AppServer.TurnLoop` / `TurnState` / `OperatorDelivery`, plus
  `Aiur.TokenUsage` and `Aiur.Protocol.MapAccess`.

T-014 also refit the codex facade onto that core: `run_turn/4` delegates to
`Aiur.AppServer.Adapter.run_turn/5`; local `start_port` delegates to
`Aiur.AppServer.Adapter.start_port/2`; the codex facade gained
`@behaviour Aiur.AppServer.Adapter` with `@impl` callbacks (`backend_label/0`,
`send_frame/2`, `metadata_from_message/2`, `start_turn/3`, `loop_state_extras/1`,
`handle_interrupt_error/2`, `handle_method/5`, `handle_malformed/3`). The
handshake, port-lifecycle, cold-start-timeout, and codex-frame code that T-014
listed as **"Untouched"** (its Step 9.9) is exactly what this ticket now
extracts. **Because of T-014, three of the name map's declared frame builders
are already elsewhere and are NOT re-created here** (see Scope §0). This ticket
adds zero behaviour: it is a verbatim relocation of codex-specific code into
four new modules with the facade delegating down.

## Scope (exact)

**Wave rules (binding for every step).** Move code **verbatim** where possible —
extract, do not rewrite. Public function signatures and observable behaviour are
unchanged; the facade `Aiur.Codex.CodingAgent` delegates to the extracted
modules so every existing caller keeps working. Every new module gets a
`@moduledoc` and an `@spec` on every public `def` (`mix specs.check` enforces
this inside the `mix lint`/`mix credo` gate). Every new module gets its own test
file; new modules are NOT coverage-exempt — do NOT touch `ignore_modules` in
`src/mix.exs` (the 85% threshold enforces the tests). Preserve every semantic
listed under "Semantics to preserve verbatim" below. After this ticket the repo
compiles and the full suite passes.

Line numbers below are the pre-T-014 numbers (commit `8712a32f`) and are
**locators only** — T-014 will have shifted them. The function names are the
contract; find the named function in the current file.

### §0 — Reconciliation with T-014 (do this mentally before editing)

These name-map items are ALREADY extracted by T-014 and are **out of scope for
this ticket** — do not duplicate them into the new codex modules:

- `initialize_frame/0`, `initialized_frame/0`, `initialize_id/0` → live in
  `Aiur.AppServer.Messages`. `Aiur.Codex.Frames` does NOT redefine them; the
  `@initialize_id 1` attribute is gone from the facade. Codex code that needs
  them calls `Aiur.AppServer.Messages.*`.
- the `turn/interrupt` frame → built by `Aiur.AppServer.Interrupts.interrupt_turn/3`.
  `Aiur.Codex.Frames` does NOT define a `turn_interrupt_frame`.
- the shared wire transport (`send_line`, `with_timeout_response`,
  `handle_response`, `log_non_json_stream_line`) → `Aiur.AppServer.Rpc`.
  `Aiur.Codex.Rpc` is a THIN codex-specific layer ON TOP of it (§2), not a
  second copy.
- the approval-decision / tool-result / requestUserInput answer reply frames
  (name-map `approval_result_frame`/`tool_result_frame`/`answers_frame`) stay
  inline in the facade's approvals section (pre-T-014 lines 1087–1449) for now;
  they move into `Aiur.Codex.Frames` in **T-039** together with the approval
  handlers, so that section is edited exactly once. Do NOT touch the approvals
  section in this ticket.

### §1 — Create `Aiur.Codex.AppServerPort` (`src/lib/aiur/codex/app_server_port.ex`)

Owns the codex app-server OS process lifecycle. Move these **verbatim** and make
them public with `@spec` (they are private in the facade today):

| Move | From (pre-T-014) | New public name/arity |
|---|---|---|
| `validate_workspace_cwd/2` (both clauses: local canonicalize + root-containment + symlink-escape; remote empty/newline/CR/NUL guard) | 212–252 | `validate_workspace_cwd/2` |
| `start_port/4` (local clause delegating to `Aiur.AppServer.Adapter.start_port/2`; remote SSH clause) | 254–280 | `start_port/4` |
| `port_metadata/2` (`codex_app_server_pid` + `worker_host`) | 311–325 | `port_metadata/2` |
| `stop_port/1` (unregister + `graceful_kill_tree` BEFORE `Port.close`) | 1523–1551 | `stop_port/1` |

Move these as **private** helpers of the new module (their only callers move with
them): `remote_launch_command/3` (282–290), `codex_command/2` (299–303),
`append_config/3` (305–309).

`shell_escape/1` (1553–1555): T-018 (Phase 2) may already have replaced the
private codex `shell_escape/1` with `Aiur.Shell.escape/1`. Handle whichever state
you find:
- If a private `shell_escape/1` still exists in the facade, move it verbatim into
  `Aiur.Codex.AppServerPort` (it is the only remaining caller after
  `codex_command`/`remote_launch_command` move).
- If codex already calls `Aiur.Shell.escape/1`, do NOT recreate `shell_escape` —
  call `Aiur.Shell.escape/1` from `AppServerPort`.
Either way, do not change shell-escaping behaviour.

Wiring in the module:
- the local `start_port` clause body is
  `Aiur.AppServer.Adapter.start_port(workspace, codex_command(model, effort))`.
- the remote `start_port` clause uses
  `SSH.start_port(worker_host, remote_launch_command(workspace, model, effort), line: Aiur.AppServer.Adapter.port_line_bytes())`.
- aliases the module needs: `Aiur.{AgentEnvironment, Config, PathSafety, SSH,
  ProcessReaper}`, `Aiur.Claude.RemoteControl`, `Aiur.Codex.Config`,
  `Aiur.AppServer.Adapter`, `Aiur.Codex.DynamicTool` is NOT needed here.

`ProcessReaper.register/3` stays in the facade's `start_session/2` (it needs the
freshly-built `metadata[:codex_app_server_pid]`); only the `unregister` inside
`stop_port/1` moves with `stop_port`.

### §2 — Create `Aiur.Codex.Rpc` (`src/lib/aiur/codex/rpc.ex`)

The codex-specific RPC layer over `Aiur.AppServer.Rpc`. Public with `@spec`:

- `send_message(port(), map()) :: true` — one-line delegate to
  `Aiur.AppServer.Rpc.send_line/2`. It RAISES `ArgumentError` on a closed port —
  do NOT wrap it in a rescue and do NOT add a `jsonrpc` field (see "Semantics",
  item 3).
- `await_startup_response(port(), integer()) :: {:ok, map()} | {:error, term()}`
  — verbatim from facade `await_startup_response/2` (pre-T-014 1451–1453); body
  becomes
  `Aiur.AppServer.Rpc.with_timeout_response(port, request_id, startup_response_timeout_ms(), "", "Codex")`.
- `startup_response_timeout_ms(non_neg_integer()) :: non_neg_integer()` with the
  same default arg `read_timeout_ms \\ Config.agent_read_timeout_ms()` — verbatim
  from 1455–1457; keeps `max(read_timeout_ms, @cold_start_response_timeout_ms)`.
  Move the module attribute `@cold_start_response_timeout_ms 30_000` here.

Alias `Aiur.{AppServer.Rpc, Config}` (reference `Aiur.AppServer.Rpc` — see the
alias-collision note in §5).

### §3 — Create `Aiur.Codex.Frames` (`src/lib/aiur/codex/frames.ex`)

Single source of truth for the codex-specific request frames extracted in this
wave (initialize/initialized/turn-interrupt frames are shared — §0). Public with
`@spec`, each returning the exact map built today:

- `thread_start_id/0 :: 2`, `turn_start_id/0 :: 2`... — expose the fixed ids as
  functions. Move `@thread_start_id 2` and `@turn_start_id 3` here; expose
  `thread_start_id/0` (returns 2) and `turn_start_id/0` (returns 3).
- `thread_init_frame(resume_thread_id, workspace, session_policies)` — **both
  clauses verbatim** from 446–471: the `nil` (fresh `thread/start`, carrying
  `"dynamicTools" => DynamicTool.tool_specs()`) and the `is_binary` resume
  (`thread/resume`, NO `dynamicTools`) clauses. Uses id `thread_start_id()`.
- `turn_start_frame(thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy)`
  — the parent `turn/start` map verbatim from `start_turn/7`'s frame body
  (478–494), id `turn_start_id()`, title `"#{issue.identifier}: #{issue.title}"`.
- `operator_turn_frame(session, request_id, text)` — the operator `turn/start`
  map verbatim from `send_operator_message/2`'s frame body (192–202): `threadId`,
  single text input, `cwd`, `approvalPolicy`/`sandboxPolicy` from the session,
  id `request_id` (the caller still computes the fresh
  `:erlang.unique_integer([:positive])`).

Alias `Aiur.Codex.DynamicTool` (for `tool_specs/0`).

### §4 — Create `Aiur.Codex.Handshake` (`src/lib/aiur/codex/handshake.ex`)

Session-establishment sequencing. Move **verbatim** and make public with `@spec`:

| Move | From (pre-T-014) | New public name/arity |
|---|---|---|
| `do_start_session/4` | 365–370 | `establish/4` (name-map rename; body verbatim) |
| `start_or_resume_thread/4` (both clauses, incl. the `:codex_resume_fallback` Perf event and all three log lines) | 373–407 | `start_or_resume_thread/4` |
| `resume_outcome/2` (already `@doc false` public) | 409–419 | `resume_outcome/2` |
| `start_thread/3`, `resume_thread/4` | 421–427 | `start_thread/3`, `resume_thread/4` |
| `send_thread_init/2` (incl. its `rescue ArgumentError -> {:error, :port_closed}` and comment) | 429–439 | `send_thread_init/2` |
| `parse_thread_response/1` | 473–475 | `parse_thread_response/1` |
| `send_initialize/1` (incl. its `rescue ArgumentError -> {:error, :port_closed}` and comment) | 327–355 | `send_initialize/1` |
| `start_turn/3` (the T-014 `@impl` callback body; pre-T-014 `start_turn/7` at 477–500) | — | `start_turn/3` |

Rewiring inside these moved bodies:
- `send_initialize/1` builds `Aiur.AppServer.Messages.initialize_frame()` and
  `initialized_frame()`, sends via `Aiur.Codex.Rpc.send_message/2`, and awaits on
  `Aiur.AppServer.Messages.initialize_id()` via
  `Aiur.Codex.Rpc.await_startup_response/2`. Control flow and the rescue are
  unchanged.
- `start_thread/3` and `resume_thread/4` build frames via
  `Aiur.Codex.Frames.thread_init_frame/3`.
- `send_thread_init/2` sends via `Aiur.Codex.Rpc.send_message/2` and awaits on
  `Aiur.Codex.Frames.thread_start_id()` via `Aiur.Codex.Rpc.await_startup_response/2`.
- `start_turn/3` destructures `%{port: port, thread_id: thread_id,
  workspace: workspace, approval_policy: approval_policy,
  turn_sandbox_policy: turn_sandbox_policy} = session`, builds the frame via
  `Aiur.Codex.Frames.turn_start_frame(thread_id, prompt, issue, workspace,
  approval_policy, turn_sandbox_policy)`, sends via `Aiur.Codex.Rpc.send_message/2`,
  and awaits on `Aiur.Codex.Frames.turn_start_id()` via
  `Aiur.Codex.Rpc.await_startup_response/2` — turn-id extraction
  (`%{"turn" => %{"id" => turn_id}}`) unchanged.

Alias `Aiur.{Config, Perf}`, `Aiur.AppServer.Messages`, `Aiur.Codex.{Rpc, Frames}`,
`require Logger`.

### §5 — Refit the facade `Aiur.Codex.CodingAgent` (`src/lib/aiur/codex/coding_agent.ex`)

Delete every function moved in §1–§4 from the facade and rewire the remainder:

1. `start_session/2` (51–90): replace the private calls with the new modules —
   `AppServerPort.validate_workspace_cwd/2`, `AppServerPort.start_port/4`,
   `AppServerPort.port_metadata/2`, and `Handshake.establish/4` (was
   `do_start_session/4`). Keep the `ProcessReaper.register(:agent, …)` call and
   the whole `with … else {:error, reason} -> AppServerPort.stop_port(port)` shape
   verbatim. `session_policies/2` (357–363) STAYS in the facade unchanged.
2. `stop_session/1` (178–181): body becomes `AppServerPort.stop_port(port)`.
3. `send_operator_message/2` (183–208): replace the inline `frame = %{…}` map
   with `frame = Frames.operator_turn_frame(session, request_id, text)`. Keep the
   `request_id = :erlang.unique_integer([:positive])`, the `send_message(port, frame)`
   call, and the `rescue ArgumentError -> {:error, :port_closed}` exactly as they
   are.
4. The `@impl Aiur.AppServer.Adapter start_turn/3` callback: its body becomes the
   one-line delegate `Aiur.Codex.Handshake.start_turn(session, prompt, issue)`.
   Keep `@impl`, `@spec`, and the head unchanged.
5. Keep a private `defp send_message(port, message), do: Aiur.Codex.Rpc.send_message(port, message)`
   in the facade so EVERY remaining raising call site (the approvals /
   requestUserInput / tool-result replies in the pre-T-014 1087–1449 section, and
   `send_operator_message/2`) is untouched. Delete the facade's
   `await_startup_response/2`, `startup_response_timeout_ms/1`, and the
   `@cold_start_response_timeout_ms` attribute (moved to `Aiur.Codex.Rpc`).
6. Test-seam delegates (KEEP the pinning tests green with zero edits): every
   `@doc false` `*_for_test` seam and public test-only function on the facade that
   names a moved function stays on the facade as a **one-line delegate** to the
   new module. Specifically:
   - `resume_outcome/2` → `Aiur.Codex.Handshake.resume_outcome/2`
   - `parse_thread_response_for_test/1` → `Aiur.Codex.Handshake.parse_thread_response/1`
   - `thread_init_frame_for_test/3` → `Aiur.Codex.Frames.thread_init_frame/3`
   - `send_thread_init_for_test/2` → `Aiur.Codex.Handshake.send_thread_init/2`
   - `await_startup_response_for_test/3` → `Aiur.Codex.Rpc.await_startup_response/2`
     with the timeout from `Aiur.Codex.Rpc.startup_response_timeout_ms/1`
   - `startup_response_timeout_ms_for_test/…` → `Aiur.Codex.Rpc.startup_response_timeout_ms/1`
   - `codex_command_for_test/…` → `Aiur.Codex.AppServerPort` (move
     `codex_command_for_test` alongside `codex_command`, or keep the seam on the
     facade delegating — whichever keeps `src/test/aiur/coding_agent_test.exs`
     unmodified). Match the existing seam's exact name/arity.
   Do NOT delete any seam in this ticket (the final slim + seam deletion is T-039).
7. **Alias-collision note:** T-014 aliased `Aiur.AppServer.Rpc` as `Rpc` in the
   facade. This ticket introduces `Aiur.Codex.Rpc`. In the facade, keep the
   existing `alias Aiur.AppServer.Rpc` (used by the `send_frame/2` `@impl`) and
   reference the new module **fully qualified** as `Aiur.Codex.Rpc` — do NOT add a
   second `Rpc` alias. Alias `Aiur.Codex.{AppServerPort, Frames, Handshake}`.
8. Remove only the facade aliases your extraction orphaned (e.g. `SSH`,
   `PathSafety` if nothing else in the facade uses them after the moves). Leave
   every alias still in use.

Do NOT touch, in this ticket: `run/4`, `run_turn/4` (the T-014 delegate), the
other `@impl` callbacks (`backend_label/0`, `send_frame/2`,
`metadata_from_message/2`, `loop_state_extras/1`, `handle_interrupt_error/2`,
`handle_method/5`, `handle_malformed/3`), `handle_notification_outcome/4`, the
approvals/requestUserInput section (1087–1449), the quota/error classification
(1802–1996), and the `normalize_event`/rate-limit section (1557–1744). Those are
T-038 / T-039.

### §6 — Semantics to preserve verbatim (from giant-coding_agent.md §4)

- **`stop_port/1` ordering (risk 4, FI-CDX-042).** `ProcessReaper.unregister` +
  `RemoteControl.graceful_kill_tree(os_pid)` MUST run BEFORE `Port.close(port)`;
  already-closed ports (`:erlang.port_info(port) == :undefined`) return `:ok`.
  Closing first orphans the node→rust grandchild holding `~/.codex/state_5.sqlite`.
- **`:port_closed` rescue asymmetry (risk 3).** The
  `rescue ArgumentError -> {:error, :port_closed}` exists at `send_initialize`,
  `send_thread_init`, and `send_operator_message` — and NOWHERE else. Keep those
  three; do NOT add a rescue to `start_turn` or to `Aiur.Codex.Rpc.send_message`,
  and do NOT make `send_message` return tuples.
- **Cold-start floor (risk 5, FI-CDX-024).** Startup waits use
  `max(agent_read_timeout_ms, 30_000)`; the floor never shortens a longer
  configured timeout. Preserve.
- **Resume, issue #378 (risk 8, FI-CDX-023).** `resume_outcome/2`: same id →
  `{:resumed}`; different id → `{:fresh}` (clean start, `resumed?: false`); error
  → `{:fallback}` → clean `thread/start`. `thread/resume` frame carries NO
  `dynamicTools`; `thread/start` DOES. Both share request id 2. Preserve the
  `:codex_resume_fallback` Perf event and all three log lines.
- **Fixed request ids (FI-CDX-021/022/025).** initialize = 1 (in
  `Aiur.AppServer.Messages`), thread start/resume = 2, first turn = 3. Operator
  `turn/start` uses a fresh positive unique integer id, not 3.
- **Workspace cwd validation (FI-CDX-019).** Keep the codex canonicalizing local
  clause (rejects `:workspace_root`, `:outside_workspace_root`, `:symlink_escape`,
  `:path_unreadable`) and the remote clause (`:empty_remote_workspace`,
  `:invalid_remote_workspace` on newline/CR/NUL). Do NOT weaken it and do NOT copy
  it to the claude adapter.
- **Model/effort splice order (FI-CDX-020).** `codex_command/2` appends
  `--config model="…"` THEN `--config model_reasoning_effort="…"`, each a single
  shell-escaped argument, `nil` leaves the command untouched. Preserve order.

### §7 — Tests for every new module

Create the four test files under Files. Model port-driven tests on the existing
fake-app-server harness (`src/test/aiur/coding_agent_checkpoint_test.exs` and
`src/test/aiur/codex/coding_agent_test.exs` spawn scripted fake binaries).
Minimum coverage per module:

- `app_server_port_test.exs`: local `validate_workspace_cwd/2` rejects
  `:workspace_root`, `:outside_workspace_root`, and a `:symlink_escape` (symlink a
  path inside the root out of it), accepts a genuine sub-path; remote clause
  rejects empty and newline/CR/NUL workspaces; `codex_command` `--config` appends
  for model then effort (nil → untouched) with shell escaping; `port_metadata`
  carries `codex_app_server_pid` and adds `worker_host` only when remote;
  `stop_port` on an already-closed port returns `:ok`.
- `rpc_test.exs`: `startup_response_timeout_ms` floors at 30_000 and never
  shortens a larger configured timeout; `await_startup_response` id-matches a
  result, skips unrelated JSON, and times out to `{:error, :response_timeout}`
  (drive a fake port); `send_message` raises on a closed port (do NOT rescue).
- `frames_test.exs`: `thread_init_frame(nil, …)` is `thread/start` WITH
  `dynamicTools` and id 2; `thread_init_frame(id, …)` is `thread/resume` WITHOUT
  `dynamicTools`, id 2; `turn_start_frame` id 3 with the `"identifier: title"`
  title; `operator_turn_frame` carries the passed request id and session policies;
  `thread_start_id/0 == 2`, `turn_start_id/0 == 3`.
- `handshake_test.exs`: `resume_outcome/2` all three arms (same/different/error);
  `parse_thread_response/1` for `{:ok, %{"thread" => %{"id" => id}}}`,
  invalid-payload, and passthrough; `send_thread_init/2` and `send_initialize/1`
  degrade to `{:error, :port_closed}` on a closed port; a fake-app-server
  `thread/resume`-fallback path that classifies a different returned id as a clean
  start.

## Files

- Create: `src/lib/aiur/codex/app_server_port.ex`, `src/lib/aiur/codex/rpc.ex`,
  `src/lib/aiur/codex/frames.ex`, `src/lib/aiur/codex/handshake.ex`
- Create (tests): `src/test/aiur/codex/app_server_port_test.exs`,
  `src/test/aiur/codex/rpc_test.exs`, `src/test/aiur/codex/frames_test.exs`,
  `src/test/aiur/codex/handshake_test.exs`
- Modify: `src/lib/aiur/codex/coding_agent.ex`
- Test (existing, must pass with ZERO edits):
  `src/test/aiur/app_server_test.exs`,
  `src/test/aiur/coding_agent_checkpoint_test.exs`,
  `src/test/aiur/coding_agent_test.exs`,
  `src/test/aiur/codex/coding_agent_test.exs`

## Out of scope

- Everything T-014 already extracted into `Aiur.AppServer.*`, `Aiur.TokenUsage`,
  `Aiur.Protocol.MapAccess` — do NOT duplicate or re-home any of it.
- The facade's approvals / requestUserInput / tool-result section (pre-T-014
  1087–1449) and its inline reply frames — that is T-039; do not touch it, and do
  not add `approval_result_frame`/`tool_result_frame`/`answers_frame` to
  `Aiur.Codex.Frames` in this ticket.
- `handle_notification_outcome/4`, `handle_turn_method/5`,
  `handle_unhandled_method/7`, `emit_turn_event/6` (T-038).
- The quota/error classification (pre-T-014 1802–1996) → `NotificationPolicy`
  (T-039); the `normalize_event`/usage/rate-limit section (1557–1744) →
  `EventNormalizer` (T-039).
- `src/lib/aiur/claude/coding_agent.ex` and `Aiur.Claude.*` — untouched.
- `shell_escape` dedup itself (T-018): call whatever the current escape function
  is; do not change its behaviour.
- `src/mix.exs` — do NOT touch; new modules must NOT be added to `ignore_modules`.
- Anything under `src/test/aiur/regression/` and the existing pinning test files
  listed under Test — they must pass UNMODIFIED (facade delegates keep them green).

## Inventory-IDs

Features implemented by the moved/refit code — behaviour for every one must be
identical after the extraction (all in `docs/refactor/feature-inventory/cdx.md`):

- **AppServerPort:** FI-CDX-018 (local + remote spawn), FI-CDX-019 (workspace cwd
  validation — canonicalizing codex variant), FI-CDX-020 (model/effort `--config`
  splice), FI-CDX-042 (`stop_port` reap-tree-before-`Port.close`), FI-CDX-059
  (remote-worker `port_metadata` `worker_host`).
- **Rpc (codex):** FI-CDX-024 (cold-start startup-response timeout floor).
- **Frames:** FI-CDX-022 (`thread/start` registers `dynamicTools`, `thread/resume`
  must not), FI-CDX-025 (`turn/start` frame with issue title), FI-CDX-032
  (`send_operator_message` operator `turn/start` frame).
- **Handshake:** FI-CDX-021 (initialize handshake + `initialized` notify,
  port-closed rescue), FI-CDX-023 (session resume with graceful degradation #378),
  and the sequencing halves of FI-CDX-022 / FI-CDX-025.

## Characterization-tests

Everything under `src/test/aiur/regression/` must pass UNMODIFIED — in particular
the suites added by **T-009** (engine identity, reap & control RPC — exercises
ProcessReaper interplay through `stop_port`) and **T-013** (agent_runner
drain/resume & digest — drives session start/resume and operator delivery through
this adapter). Additionally, the pre-existing fake-app-server harnesses that pin
this exact code drive the unchanged public facade and must pass with zero edits:
`src/test/aiur/app_server_test.exs` (cwd guards incl. symlink escape, SSH remote
launch), `src/test/aiur/coding_agent_checkpoint_test.exs` (handshake + turn
start), `src/test/aiur/coding_agent_test.exs` (`--config` splice, operator frame,
port-closed send), `src/test/aiur/codex/coding_agent_test.exs` (stop-session tree
reap, thread-init frames, `resume_outcome`, `parse_thread_response`,
startup-timeout floor, `send_thread_init` port-closed degradation).

## Acceptance criteria

All commands run from the repo root unless noted.

- The four modules exist at their exact paths, one `defmodule` each:
  `grep -l "defmodule Aiur.Codex.AppServerPort do" src/lib/aiur/codex/app_server_port.ex`,
  `grep -l "defmodule Aiur.Codex.Rpc do" src/lib/aiur/codex/rpc.ex`,
  `grep -l "defmodule Aiur.Codex.Frames do" src/lib/aiur/codex/frames.ex`,
  `grep -l "defmodule Aiur.Codex.Handshake do" src/lib/aiur/codex/handshake.ex`
  — all four match.
- Each new lib file is <= 200 lines (`wc -l` on each of the four Create paths);
  each new public function <= 20 logic lines EXCEPT clauses the Scope marks as
  verbatim moves (`Handshake.start_or_resume_thread`, `AppServerPort.validate_workspace_cwd`)
  — never rewrite a moved body to satisfy the limit.
- The facade shrank: `wc -l src/lib/aiur/codex/coding_agent.ex` <= 1450.
- The port-lifecycle concern left the facade:
  `grep -c "graceful_kill_tree" src/lib/aiur/codex/coding_agent.ex` → 0 and
  `grep -c "graceful_kill_tree" src/lib/aiur/codex/app_server_port.ex` >= 1;
  `grep -c "PathSafety.canonicalize" src/lib/aiur/codex/coding_agent.ex` → 0 and
  `grep -c "PathSafety.canonicalize" src/lib/aiur/codex/app_server_port.ex` >= 1;
  `grep -c "SSH.start_port" src/lib/aiur/codex/coding_agent.ex` → 0.
- The cold-start floor left the facade:
  `grep -c "@cold_start_response_timeout_ms" src/lib/aiur/codex/coding_agent.ex` → 0 and
  `grep -c "@cold_start_response_timeout_ms" src/lib/aiur/codex/rpc.ex` >= 1.
- The codex frames left the facade and are not duplicated:
  `grep -c "thread/resume" src/lib/aiur/codex/coding_agent.ex` → 0 and
  `grep -c "thread/resume" src/lib/aiur/codex/frames.ex` >= 1;
  `grep -c "DynamicTool.tool_specs" src/lib/aiur/codex/coding_agent.ex` → 0 and
  `grep -c "DynamicTool.tool_specs" src/lib/aiur/codex/frames.ex` >= 1;
  `grep -c "@initialize_id\|@thread_start_id\|@turn_start_id" src/lib/aiur/codex/coding_agent.ex` → 0.
- The handshake left the facade:
  `grep -cE "defp? (do_start_session|start_or_resume_thread|start_thread|resume_thread|send_thread_init|send_initialize)\(" src/lib/aiur/codex/coding_agent.ex` → 0
  (test-seam one-line delegates that merely NAME these via the new module are allowed).
- Shared T-014 machinery is NOT re-created in the codex modules:
  `grep -c "with_timeout_response\|def handle_response\|log_non_json_stream_line" src/lib/aiur/codex/rpc.ex` → 0
  (the codex Rpc only delegates to `Aiur.AppServer.Rpc`);
  `grep -c "turn_interrupt_frame\|initialize_frame\|initialized_frame" src/lib/aiur/codex/frames.ex` → 0.
- Each new module has a `@moduledoc` (`grep -c "@moduledoc" <file>` >= 1 for all
  four) and its named test file exists (the four test paths under Files).
- Coverage exemptions unchanged: `git diff origin/v2 -- src/mix.exs` is empty;
  `grep -c "Codex.AppServerPort\|Codex.Rpc\|Codex.Frames\|Codex.Handshake" src/mix.exs` → 0.
- `cd src && mix specs.check` passes (every new public def has `@spec`).
- `git diff --name-only origin/v2...HEAD` lists exactly the Create + Modify files
  above — nothing else, and NOTHING under `src/test/aiur/regression/` or the
  existing pinning test files listed under Test.

## Verification
### Agent gate (run all, from src/)
```
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix credo --strict
mix dialyzer
```
### At-merge (reviewer)

- Check (FI-CDX-042): after stopping a codex agent, `pgrep -f codex` shows no
  orphaned app-server and a subsequent codex agent starts without "database is
  locked".
- Check (FI-CDX-023): with a persisted session handle, restart aiur and confirm
  the codex agent resumes its prior thread (log line "Codex resumed prior thread")
  with no cold-start prompt; corrupt/stale the rollout and confirm it degrades to
  a clean `thread/start` (Perf `:codex_resume_fallback`) rather than stranding the
  issue.
- Check (FI-CDX-020): run a codex agent with a `model:` override and a
  `complexity:` effort and grep the launch command for the two trailing
  `--config model=…` / `--config model_reasoning_effort=…` arguments in that
  order.
- Diff review: confirm the three `:port_closed` rescues live only at
  `send_initialize`, `send_thread_init`, and `send_operator_message`, and that
  `Aiur.Codex.Rpc.send_message` and `Handshake.start_turn` still raise (no added
  rescue); confirm `initialize`/`initialized`/`turn-interrupt` frames were NOT
  duplicated into the new codex modules.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
