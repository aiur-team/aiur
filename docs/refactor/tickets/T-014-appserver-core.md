# T-014: Extract Aiur.AppServer shared adapter core

**Phase:** 2
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:2` `complexity:3`

## Problem / context

`src/lib/aiur/codex/coding_agent.ex` (1,997 lines) and
`src/lib/aiur/claude/coding_agent.ex` (992 lines) are structural twins: 753 of
the claude module's 992 lines are byte-identical to codex lines
(`docs/refactor/research-arch/dup-backends.md`, Clusters 1–4). Both hand-maintain
the same JSON-RPC 2.0 app-server client: port spawn, initialize handshake, fixed
request-id bookkeeping, line reassembly, the turn receive loop with its
pause/queue-update control-message vocabulary, nested operator-turn accounting,
safe-checkpoint delivery, response awaits, usage/token normalization (spelled
out ~3.5 times across three modules), and transcript-walker scaffolding. Every
protocol fix must be applied twice — and has already drifted six documented
times (dup-backends.md Cluster 1, "Observed drift").

This ticket extracts the shared core into new `Aiur.AppServer.*` modules (plus
`Aiur.TokenUsage` and `Aiur.Protocol.MapAccess`, named verbatim by
dup-backends.md Clusters 3–4) and refits BOTH adapters onto it. `Aiur.AppServer.Adapter`
is the module name dup-backends.md Cluster 1 proposes; the six sibling
`Aiur.AppServer.*` module names below are derived from that cluster's concern
list because one module cannot hold ~750 lines under the 200-line file cap.
**No behavior change on either backend; both protocol wire shapes unchanged**
(claude frames carry `"jsonrpc" => "2.0"`, codex frames do not — this
difference is preserved). The six drift items are preserved as backend-specific
code, NOT fixed here. Phase-3 tickets T-037..T-039 later decompose the
codex-specific residue.

## Scope (exact)

Wave rules (binding for every step): move code **verbatim** where possible —
extract, do not rewrite. Public function signatures and observable behavior are
unchanged; the parent modules delegate to the extracted modules so all existing
callers keep working. Every extracted module gets `@moduledoc` and `@spec` on
every public `def` (`mix specs.check` enforces this — it runs inside the
`mix lint` alias). Every extracted module gets its own test file; new modules
are NOT coverage-exempt (do not touch `ignore_modules` in `src/mix.exs` — the
85% threshold enforces tests). Preserve the concurrency/timing semantics listed
under "Semantics to preserve verbatim" below. After this ticket the repo
compiles and the full suite passes.

Line numbers below refer to the current files on `v2` (verified at commit
`8712a32f`). If they have shifted, locate the named function — the function
names are the contract.

### Step 1 — Create `Aiur.TokenUsage` (`src/lib/aiur/token_usage.ex`)

Public API (each with `@spec`):

- `canonicalize(term()) :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer(), total_tokens: non_neg_integer()} | nil`
  — move verbatim from `Aiur.Codex.CodingAgent.canonicalize_usage/1`
  (codex/coding_agent.ex:1632–1654), keeping the `nil -> nil` clause and the
  exact key lists in the exact order (`~w(...)a ++ ~w(...)` — atom forms first,
  then string forms). ADD one catch-all clause `def canonicalize(_), do: nil`
  (this reproduces the claude adapter's `if is_map(raw)` guard,
  claude/coding_agent.ex:871, so non-map input returns nil instead of raising).
- `token_field?(term()) :: boolean()` — move verbatim from
  `has_token_field?/1` + private `token_like_value?/1`
  (codex/coding_agent.ex:1673–1696), renamed to `token_field?`.
- `format_counts(term()) :: String.t() | nil` — move verbatim from
  `Aiur.Codex.EventHumanizer.format_usage_counts/1` + `append_usage_part/3`
  (codex/event_humanizer.ex:276–332), renamed to `format_counts`. Its helpers
  `map_value/2`, `parse_integer/1`, `format_count/1` are already public in
  `Aiur.EventHumanizerHelpers` — call them fully qualified (or via alias). Do
  NOT reimplement `format_counts` on top of `canonicalize/1` (that would
  zero-fill missing parts and change humanizer output).

Private helpers moved verbatim: `token_value/2` and `parse_token_value/1`
(codex/coding_agent.ex:1656–1671; byte-identical copy at
claude/coding_agent.ex:901–916 is deleted in Step 8).

### Step 2 — Create `Aiur.Protocol.MapAccess` (`src/lib/aiur/protocol/map_access.ex`)

Public API (each with `@spec`), moved verbatim from
`src/lib/aiur/codex/transcript.ex:233–272` (byte-identical twin at
`src/lib/aiur/claude/transcript.ex:367–406`):

- `get(term(), atom()) :: term()` — the two-clause atom-or-string `Map.get`
  helper, including its comment ("Tolerate both atom- and binary-keyed maps…").
- `dig(term(), [term()]) :: term()` — move verbatim from
  `Aiur.Codex.CodingAgent.dig/2` (codex/coding_agent.ex:1735–1744).
- `notification_method(map()) :: term()` — from `notification_method/1`.
- `notification_item(map()) :: term()` — from `notification_item/1`.
- `params_turn_id(map(), atom()) :: String.t() | nil` — generalize
  `codex_turn_id/1` (key `:turnId`) / `claude_turn_id/1` (key `:turn_id`):
  identical body, the params key becomes the second argument.
- `message_timestamp(map()) :: DateTime.t()` — from `timestamp_for/1`
  (the `%DateTime{}`-or-`DateTime.utc_now()` clause pair).

### Step 3 — Refit the four satellite files onto Steps 1–2

1. `src/lib/aiur/codex/transcript.ex`: delete the private
   `notification_method/1`, `notification_item/1`, `codex_turn_id/1`,
   `timestamp_for/1`, `get/2` (lines 233–272) and replace each with a one-line
   private delegate to `Aiur.Protocol.MapAccess` (`codex_turn_id(message)` →
   `MapAccess.params_turn_id(message, :turnId)`). Keep the private wrapper
   names so no other line in the file changes.
2. `src/lib/aiur/claude/transcript.ex`: same treatment for lines 367–406
   (`claude_turn_id(message)` → `MapAccess.params_turn_id(message, :turn_id)`).
3. `src/lib/aiur/agent_runner.ex`: replace the two `get/2` clauses at lines
   594–601 with a single delegate `defp get(map, key), do: Aiur.Protocol.MapAccess.get(map, key)`
   (MapAccess.get already returns nil for non-map/non-atom input). Keep the
   comment. Touch nothing else in this file — its `timestamp_for/1` and
   everything below stays exactly as is.
4. `src/lib/aiur/codex/event_humanizer.ex`: replace the bodies of
   `format_usage_counts/2` clauses (lines 276–329) with
   `defp format_usage_counts(usage), do: Aiur.TokenUsage.format_counts(usage)`
   and delete `append_usage_part/3` (lines 331–332). All three call sites
   (lines 35, 86, 506) keep working unchanged.

Do NOT touch `src/lib/aiur/opencode/event_row.ex`: its `get_path/2` looks
similar but additionally does a reverse binary→atom lookup
(`safe_atom_lookup`); it is NOT the same helper and is out of scope.

### Step 4 — Create `Aiur.AppServer.Rpc` (`src/lib/aiur/app_server/rpc.ex`)

Wire transport shared by both adapters. Public API (each with `@spec`):

- `send_line(port(), map()) :: true` — verbatim from codex `send_message/2`
  (codex/coding_agent.ex:1790–1793): `Jason.encode!(message) <> "\n"` then
  `Port.command/2`. It RAISES `ArgumentError` on a closed port — do NOT wrap
  it in a rescue or make it return tuples (see "Semantics to preserve", item 3).
- `with_timeout_response(port(), integer(), non_neg_integer(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}`
  — verbatim from codex/coding_agent.ex:1459–1474 (== claude 775–790), with a
  fifth `backend_label` argument threaded through to `handle_response`.
- `handle_response(port(), integer(), binary(), non_neg_integer(), String.t()) :: {:ok, map()} | {:error, term()}`
  — verbatim from codex/coding_agent.ex:1476–1497 (== claude 792–813), passing
  `backend_label` into `log_non_json_stream_line` and its recursive
  `with_timeout_response` calls.
- `log_non_json_stream_line(binary(), String.t(), String.t()) :: :ok | nil`
  — verbatim from codex/coding_agent.ex:1499–1513 (== claude 815–829 except the
  hardcoded "Codex"/"Claude" prefix), the third argument `backend_label`
  replacing the hardcoded prefix: `"#{backend_label} #{stream_label} output: …"`.
  Move `@max_stream_log_bytes 1_000` here.

### Step 5 — Create `Aiur.AppServer.Messages` (`src/lib/aiur/app_server/messages.ex`)

Shared pure helpers and protocol constants. Public API (each with `@spec`),
each moved verbatim (byte-identical in both adapters):

- `emit_message/4` — from claude 918–921 / codex 1746–1749.
- `default_on_message/1` — from claude 950 / codex 1767.
- `normalize_tool_result/1` — from claude 762–769 / codex 1242–1249.
- `tool_call_name/1`, `tool_call_arguments/1` — from claude 952–971 / codex 1769–1788.
- `issue_context/1`, `issue_identifier/1` — from claude 831–837 / codex 1515–1521.
- `initialize_id/0` (returns 1, from the `@initialize_id 1` attr both modules
  carry), `initialize_frame/0` (the `"initialize"` payload map, verbatim from
  claude 233–246 / codex 328–341, with `@version Mix.Project.config()[:version]`
  moved here), and `initialized_frame/0`
  (`%{"method" => "initialized", "params" => %{}}`).

### Step 6 — Create the shared turn machinery (four modules)

All loop-state maps in these modules gain one new key, `:backend` — the adapter
facade module (`Aiur.Codex.CodingAgent` or `Aiur.Claude.CodingAgent`) — used
for the per-backend hooks defined in Step 7. Everything else in the state map
is unchanged.

**6a. `Aiur.AppServer.TurnState`** (`src/lib/aiur/app_server/turn_state.ex`) —
pure completion/interrupt algebra, all byte-identical between the adapters,
moved verbatim and made public with `@spec`:

| Function | From claude/coding_agent.ex | From codex/coding_agent.ex |
|---|---|---|
| `fail_pending_operator_requests/2` | 563–567 | 868–872 |
| `continue_after_turn_completion/1` | 569–583 | 874–888 |
| `continue_after_turn_interrupted/2` | 585–611 | 897–923 |
| `maybe_finish_after_pending_response/1` | 671–677 | 983–989 |
| `turn_completion_status/1` | 744–748 | 1069–1073 |
| `safe_invoke_success_callback/2`, `safe_invoke_failure_callback/2` | 750–760 | 1075–1085 |

**6b. `Aiur.AppServer.OperatorDelivery`** (`src/lib/aiur/app_server/operator_delivery.ex`)
— safe-checkpoint delivery and operator-response tracking, moved verbatim with
two mechanical substitutions: `send_operator_message(session, …)` becomes
`state.backend.send_operator_message(session, …)` (both facades already export
it as the `Aiur.CodingAgent` behaviour callback), and `metadata_from_message(port, payload)`
becomes `state.backend.metadata_from_message(port, payload)` (made public in
Step 7). Public with `@spec`:

| Function | From claude | From codex |
|---|---|---|
| `handle_pending_operator_response/5` | 507–536 | 809–838 |
| `maybe_process_safe_checkpoint/3` | 538–561 | 843–866 |
| `handle_claimed_operator_response/8` (private, 3 clauses; called only from `handle_pending_operator_response`) | 613–669 | 925–981 |

`fail…`/`safe_invoke…` calls inside these bodies retarget to
`Aiur.AppServer.TurnState`.

**6c. `Aiur.AppServer.Interrupts`** (`src/lib/aiur/app_server/interrupts.ex`) —
pause/queue-update interrupt state machine, moved verbatim. Public with `@spec`:

| Function | From claude | From codex |
|---|---|---|
| `handle_pause_request/3` (3 clauses, dedupe order preserved) | 679–703 | 991–1015 |
| `handle_operator_queue_update/2` (2 clauses) | 705–723 | 1017–1035 |
| `interrupt_turn/3` | 725–742 | 1037–1055 |

`interrupt_turn(backend, session, turn_id)` builds the exact `turn/interrupt`
frame (`%{"method" => "turn/interrupt", "id" => request_id, "params" => %{"threadId" => …, "turnId" => …}}`,
fresh `:erlang.unique_integer([:positive])` id) and sends it via
`backend.send_frame(port, frame)` (Step 7), returning `{:ok, request_id}` on
`:ok` and `{:error, reason}` on `{:error, reason}`; keep the
`{:error, :invalid_session}` fallback clause. `handle_pause_request` /
`handle_operator_queue_update` call it as
`interrupt_turn(state.backend, session, state.current_turn_id)`.

**6d. `Aiur.AppServer.TurnLoop`** (`src/lib/aiur/app_server/turn_loop.ex`) —
the blocking per-turn receive loop, running in the caller's process (NOT a
GenServer). Public: `receive_loop(map(), map())` with `@spec`.

- `receive_loop/2` — verbatim from codex/coding_agent.ex:529–575
  (byte-identical to claude 332–378): the `{^port, {:data, {:eol|:noeol, …}}}`
  clauses, `{^port, {:exit_status, status}}`, `{:pause_agent, request_id} when is_integer` →
  `Aiur.AppServer.Interrupts.handle_pause_request`, the five
  `{:agent_queue_updated, …}` clauses in their EXACT current order
  (current-issue deliver-now → `Interrupts.handle_operator_queue_update`;
  current-issue non-deliver-now ignored; current-issue 3-tuple ignored;
  other-issue 4-tuple ignored; other-issue 3-tuple ignored), and the
  `after state.timeout_ms -> {:error, :turn_timeout}` idle timeout.
- `handle_incoming/3` (private) — verbatim from codex 577–588 (== claude
  380–391); the malformed branch calls
  `state.backend.handle_malformed(state, payload_string, port)`.
- `handle_decoded_incoming/6` (private) — exactly these clauses, in exactly
  this order:
  1. `%{"id" => request_id, "result" => _}` when
     `request_id == state.pending_interrupt_request_id` →
     `{:continue, %{state | pending_interrupt_request_id: nil}}` (verbatim,
     codex 590–593 == claude 393–396).
  2. `%{"id" => request_id, "error" => error}` when
     `request_id == state.pending_interrupt_request_id` →
     `state.backend.handle_interrupt_error(state, error)` (bodies differ per
     backend — Step 7; do NOT unify them).
  3. `%{"id" => request_id, "result" => _} = payload` when
     `is_integer(request_id)` →
     `Aiur.AppServer.OperatorDelivery.handle_pending_operator_response(session, state, payload, payload_string, request_id)`.
  4. Same for `%{"id" => request_id, "error" => _}`.
  5. `%{"method" => method} = payload` when `is_binary(method)` →
     `state.backend.handle_method(session, state, payload, payload_string, method)`.
  6. Fallback → emit `:other_message` verbatim (codex 661–673 == claude
     483–492), using `Aiur.AppServer.Messages.emit_message` and
     `state.backend.metadata_from_message(port, payload)`, then `{:continue, state}`.

  Clauses 1–2 MUST stay ahead of 3–4 (a misordered interrupt ack would be
  misrouted as an unknown operator request).

### Step 7 — Create `Aiur.AppServer.Adapter` (`src/lib/aiur/app_server/adapter.ex`)

The behaviour every app-server backend implements, plus the shared `run_turn`
skeleton and port spawn.

Behaviour callbacks (define with `@callback`; do NOT re-declare
`send_operator_message/2` — it already belongs to the `Aiur.CodingAgent`
behaviour and duplicating it across behaviours triggers a compile warning,
which `--warnings-as-errors` turns fatal):

```elixir
@callback backend_label() :: String.t()
@callback send_frame(port(), map()) :: :ok | {:error, :port_closed}
@callback metadata_from_message(port(), term()) :: map()
@callback start_turn(session :: map(), prompt :: String.t(), issue :: map()) ::
            {:ok, String.t()} | {:error, term()}
@callback loop_state_extras(session :: map()) :: map()
@callback handle_interrupt_error(state :: map(), error :: term()) ::
            {:continue, map()} | {:error, term()}
@callback handle_method(session :: map(), state :: map(), payload :: map(),
            payload_string :: String.t(), method :: String.t()) :: term()
@callback handle_malformed(state :: map(), payload_string :: String.t(), port()) ::
            {:continue, map()}
```

Public functions (each with `@spec`):

- `run_turn(module(), map(), String.t(), map(), keyword()) :: {:ok, map()} | {:paused, map()} | {:error, term()}`
  — the shared turn skeleton, verbatim from codex/coding_agent.ex:92–176
  (== claude 60–142) with exactly these substitutions: the hardcoded
  "Codex"/"Claude" log prefixes become `backend.backend_label()` interpolation
  (log text otherwise byte-identical); `start_turn(...)` becomes
  `backend.start_turn(session, prompt, issue)`; `issue_context`/`issue_identifier`/
  `emit_message`/`default_on_message` come from `Aiur.AppServer.Messages`; and
  `await_turn_completion(...)` is replaced by building the loop state and
  calling `Aiur.AppServer.TurnLoop.receive_loop(session, state)` with:

  ```elixir
  state =
    Map.merge(
      %{
        backend: backend,
        on_message: on_message,
        on_safe_checkpoint: on_safe_checkpoint,
        tool_executor: tool_executor,
        timeout_ms: Config.agent_turn_timeout_ms(),
        pending_line: "",
        outstanding_turns: 1,
        pending_operator_requests: %{},
        current_turn_id: turn_id,
        issue_identifier: Messages.issue_identifier(issue),
        pause_request_id: nil,
        pending_interrupt_request_id: nil,
        interrupt_action: nil
      },
      backend.loop_state_extras(session)
    )
  ```

  The `tool_executor` default stays `fn tool, arguments -> DynamicTool.execute(tool, arguments) end`
  (alias `Aiur.Codex.DynamicTool` — both backends use it today). If
  `run_turn/5` exceeds 20 logic lines (it will), split its success/paused/error
  case arms into private helpers within this module; the emitted messages, log
  lines, and return values must be byte-identical to today's.
- `start_port(Path.t(), String.t()) :: {:ok, port()} | {:error, :bash_not_found}`
  — verbatim from claude/coding_agent.ex:198–220 (== codex local clause
  254–276) with the launch command as the second argument instead of being
  computed inline. Move `@port_line_bytes 1_048_576` here and expose
  `port_line_bytes/0` (`@doc false`) for the codex remote-SSH spawn clause.

### Step 8 — Refit `Aiur.Claude.CodingAgent` (`src/lib/aiur/claude/coding_agent.ex`)

Add `@behaviour Aiur.AppServer.Adapter` (keep `@behaviour Aiur.CodingAgent`).
Delete every function that moved in Steps 1–7 and wire the remainder:

1. `run_turn/4` keeps its EXACT current head pattern
   (`%{port: _, metadata: _, thread_id: _, workspace: _} = session` and default
   `opts \\ []`) and its body becomes
   `Aiur.AppServer.Adapter.run_turn(__MODULE__, session, prompt, issue, opts)`.
   Delete `await_turn_completion/6`, `receive_loop/2`, `handle_incoming/3`,
   all `handle_decoded_incoming/6` clauses, `handle_pending_operator_response/5`,
   `maybe_process_safe_checkpoint/3`, `fail_pending_operator_requests/2`,
   `continue_after_turn_completion/1`, `continue_after_turn_interrupted/2`,
   `handle_claimed_operator_response/8`, `maybe_finish_after_pending_response/1`,
   `handle_pause_request/3`, `handle_operator_queue_update/2`,
   `interrupt_turn/2`, `turn_completion_status/1`, `safe_invoke_*_callback/2`,
   `normalize_tool_result/1`, `with_timeout_response/4`, `handle_response/4`,
   `log_non_json_stream_line/2`, `issue_context/1`, `issue_identifier/1`,
   `token_value/2`, `parse_token_value/1`, `emit_message/4`,
   `default_on_message/1`, `tool_call_name/1`, `tool_call_arguments/1`, and the
   attrs `@initialize_id`, `@port_line_bytes`, `@max_stream_log_bytes`,
   `@version`.
2. Implement the eight callbacks (`@impl Aiur.AppServer.Adapter`, `@doc false`,
   `@spec` each):
   - `backend_label/0` → `"Claude"`.
   - `send_frame/2` → the current private `send_message/2` (lines 980–991)
     renamed and made public, VERBATIM including the
     `Map.put("jsonrpc", "2.0")`, the central `rescue ArgumentError -> {:error, :port_closed}`,
     and its comment. Every in-module `send_message(` call site becomes
     `send_frame(`. The encode+`Port.command` line may delegate to
     `Aiur.AppServer.Rpc.send_line(port, message_with_jsonrpc)` — wire bytes
     identical.
   - `metadata_from_message/2` → current private (lines 923–924) made public;
     KEEP its private helpers `maybe_set_usage/2` (claude lifts `cost_usd` and
     checks `params` — codex does not; preserve), `find_in/4`, `put_if_map/3`,
     `put_if_number/3` here unchanged.
   - `start_turn/3` → current `start_turn/6` (lines 286–313) reshaped to
     `start_turn(%{port: port, thread_id: thread_id, workspace: workspace} = session, prompt, issue)`
     with `model = Map.get(session, :model)`; frame body (incl.
     `maybe_put_model`) byte-identical; awaits via `await_response`.
   - `loop_state_extras/1` → `def loop_state_extras(_session), do: %{}`.
   - `handle_interrupt_error/2` → verbatim body of current lines 398–401:
     `def handle_interrupt_error(_state, error), do: {:error, {:turn_interrupt_failed, error}}`.
     Claude does NOT tolerate `-32600` today — do not add tolerance.
   - `handle_method/5` → exactly the current claude-specific
     `handle_decoded_incoming` clauses moved verbatim as ordered clauses on the
     new function: `turn/completed` (413–425, note: emits WITHOUT a `:details`
     key — preserve), `turn/failed` (427–437), `item/tool/call` (439–468, using
     `Messages.normalize_tool_result`, `Messages.tool_call_name/arguments`,
     `send_frame`, `OperatorDelivery.maybe_process_safe_checkpoint`), and the
     generic notification clause (470–481, keeping
     `Logger.debug("Claude notification: …")`). State transitions retarget to
     `Aiur.AppServer.TurnState`.
   - `handle_malformed/3` → verbatim from lines 494–505: claude ALWAYS emits
     `:malformed` (no JSON-lookalike gating — preserve; codex gates, claude
     does not). Uses `Rpc.log_non_json_stream_line(payload_string, "turn stream", "Claude")`.
3. `start_port/1` → body becomes
   `Aiur.AppServer.Adapter.start_port(workspace, Aiur.Claude.Config.command())`.
4. `send_initialize/1` → sends `Messages.initialize_frame()` and
   `Messages.initialized_frame()` via `send_frame/2`, awaiting on
   `Messages.initialize_id()`; control flow otherwise unchanged (claude has NO
   `rescue` here today — do not add one).
5. `await_response/2` → one-liner:
   `Rpc.with_timeout_response(port, request_id, Config.agent_read_timeout_ms(), "", "Claude")`.
   Claude keeps the RAW read timeout — do NOT add the codex 30s floor.
6. `normalize_usage/1` → `Map.put(event, :usage, Aiur.TokenUsage.canonicalize(raw))`
   where `raw = event[:usage] || Map.get(event, "usage")`; `normalize_event/1`
   and `normalize_rate_limits/1` unchanged.
7. Untouched (stays verbatim): `start_session/2`, `stop_session/1`,
   `send_operator_message/2` (frame incl. `maybe_put_model` — wire unchanged),
   `validate_workspace_cwd/1` (the WEAKER prefix-only check — do NOT adopt the
   codex symlink-escape version), `do_start_session/2`, `start_thread/2`,
   `port_metadata/1` (key `claude_app_server_pid`), `stop_port/1` (no
   kill-tree — preserve), `maybe_put_model/2`.

### Step 9 — Refit `Aiur.Codex.CodingAgent` (`src/lib/aiur/codex/coding_agent.ex`)

Add `@behaviour Aiur.AppServer.Adapter`. Delete the same shared-function set as
Step 8 item 1 (codex line ranges: 502–575, 577–588, 590–673 shared clauses,
675–691 body, 809–838, 843–888, 897–1035, 1037–1073, 1075–1085, 1242–1249,
1459–1513, 1515–1521, 1523 keeps stop_port — see below — 1632–1696, 1735–1744,
1746–1749, 1767, 1769–1793) plus attrs `@initialize_id`, `@port_line_bytes`,
`@max_stream_log_bytes`, `@version`. Then:

1. `run_turn/4` keeps its full current head pattern (port, metadata,
   approval_policy, auto_approve_requests, turn_sandbox_policy, thread_id,
   workspace) and delegates to
   `Aiur.AppServer.Adapter.run_turn(__MODULE__, session, prompt, issue, opts)`.
2. Callbacks (`@impl`, `@doc false`, `@spec`):
   - `backend_label/0` → `"Codex"`.
   - `send_frame/2` → new 4-line wrapper:
     `Rpc.send_line(port, frame); :ok rescue ArgumentError -> {:error, :port_closed}`.
     Codex frames get NO `jsonrpc` field — do not add one.
   - Keep a private `defp send_message(port, message), do: Aiur.AppServer.Rpc.send_line(port, message)`
     so every RAISING call site (`send_initialize`, `send_thread_init`,
     `start_turn`, `send_operator_message`, approval/tool/answers replies in
     `maybe_handle_approval_request` and friends) is untouched — the
     `rescue ArgumentError` blocks stay exactly at the four sites that have
     them today and NOWHERE else.
   - `metadata_from_message/2` → current private (1751–1752) made public;
     keep `maybe_set_usage/2` (codex lifts only top-level `usage` — preserve;
     no `cost_usd`).
   - `start_turn/3` → current `start_turn/7` (477–500) reshaped to destructure
     `%{port: …, thread_id: …, workspace: …, approval_policy: …, turn_sandbox_policy: …}`
     from the session; frame byte-identical; awaits via `await_startup_response`.
   - `loop_state_extras/1` →
     `def loop_state_extras(session), do: %{auto_approve_requests: session.auto_approve_requests, turn_started?: false}`.
   - `handle_interrupt_error/2` → verbatim body of current lines 595–613
     (`no_active_turn_error?` tolerance treating `-32600`/"no active turn" as
     success, INCLUDING the long explanatory comment). `no_active_turn_error?/1`
     (1057–1067) stays private in this module.
   - `handle_method/5` → ordered clauses moved verbatim: `turn/completed`
     (625–632, via `emit_turn_event` which stays private here — codex emits
     WITH `:details`; preserve), `turn/failed` (634–638), `turn/cancelled`
     (640–654 — claude has no such clause; do not add one there), and the
     generic clause (656–659) calling the existing `handle_turn_method/5`.
     State transitions retarget to `TurnState`; checkpoint calls to
     `OperatorDelivery.maybe_process_safe_checkpoint`.
   - `handle_malformed/3` → verbatim from 675–691 INCLUDING the
     `protocol_message_candidate?/1` gating (693–698 stays private here).
3. `start_port/4` local clause → delegates to
   `Adapter.start_port(workspace, codex_command(model, effort))`; the remote
   SSH clause (278–280) stays, using `Adapter.port_line_bytes()` for the
   `line:` option. `remote_launch_command/3`, `codex_command/2`,
   `append_config/3`, `shell_escape/1` untouched (T-018 owns shell_escape).
4. `send_initialize/1` → sends `Messages.initialize_frame()` /
   `Messages.initialized_frame()` via the raising private `send_message`,
   awaiting on `Messages.initialize_id()`; KEEP its
   `rescue ArgumentError -> {:error, :port_closed}` and comment.
5. `await_startup_response/2` + `startup_response_timeout_ms/1` (30s cold-start
   floor, `@cold_start_response_timeout_ms` attr) stay, the former becoming
   `Rpc.with_timeout_response(port, request_id, startup_response_timeout_ms(), "", "Codex")`.
6. `handle_notification_outcome/4` (777–807) stays; its
   `continue_after_turn_completion` / `maybe_process_safe_checkpoint` calls
   retarget to `TurnState` / `OperatorDelivery`; the quota/unretryable cond
   ORDER is untouched.
7. `normalize_event/1` section: `normalize_usage/1` ends in
   `Map.put(event, :usage, Aiur.TokenUsage.canonicalize(usage))`;
   `absolute_token_usage/1`, `turn_completed_usage/1`, `direct_token_map/1` use
   `Aiur.TokenUsage.token_field?/1` and `Aiur.Protocol.MapAccess.dig/2`;
   `normalize_rate_limits`/`find_rate_limits`/`search_rate_limits`/`rate_limits_map?`
   stay verbatim (T-039 moves them later).
8. `@doc false` test seams (1841–1900) ALL stay; only
   `await_startup_response_for_test/3` changes body to
   `Rpc.with_timeout_response(port, request_id, startup_response_timeout_ms(read_timeout_ms), "", "Codex")`.
   No test file needs edits.
9. Untouched: `run/4` (with its `try/after stop_session`), `start_session/2`,
   `stop_session/1`, `send_operator_message/2` (incl. its own rescue),
   `validate_workspace_cwd/2` (canonicalizing version — do NOT copy to claude),
   `session_policies/2`, `do_start_session/4`, `start_or_resume_thread/4`,
   `resume_outcome/2`, `start_thread/3`, `resume_thread/4`, `send_thread_init/2`,
   `thread_init_frame/3`, `parse_thread_response/1`, `port_metadata/2` (key
   `codex_app_server_pid` + `worker_host`), `stop_port/1` (unregister +
   `graceful_kill_tree` BEFORE `Port.close` — sqlite-lock ordering, verbatim),
   the entire approvals/requestUserInput section (1087–1449), and the
   quota/error classification section (1802–1996).

### Step 10 — Tests for every new module

Create the nine test files listed under Files. Model the port-driven tests on
the existing fake-app-server pattern (`src/test/aiur/coding_agent_checkpoint_test.exs`
spawns a scripted fake binary). Minimum coverage per module:

- `turn_state_test.exs`: completion algebra — `outstanding_turns` starts at 1,
  decrement with 0 floor, `{:ok, :turn_completed}` only at 0 outstanding AND
  empty pending registry, pending requests failed with `:parent_turn_completed`;
  `continue_after_turn_interrupted` routing for `pause_request_id` set /
  `interrupt_action: :operator_message` / neither; `turn_completion_status`
  default `"completed"`; `safe_invoke_*` swallow raising callbacks.
- `interrupts_test.exs`: pause dedupe (same id, different id while pending),
  queue-update dedupe on in-flight interrupt, `interrupt_turn` frame contents
  and `{:error, :invalid_session}` fallback (use a stub backend module whose
  `send_frame` captures the frame).
- `turn_loop_test.exs`: eol/noeol reassembly, port exit → `{:error, {:port_exit, s}}`,
  idle timeout → `{:error, :turn_timeout}`, pause_agent and the five
  agent_queue_updated shapes (own-issue deliver-now interrupts; own-issue
  non-deliver-now, 3-tuples, and other-issue updates are drained and ignored),
  interrupt-ack clause ordering ahead of operator-response clauses.
- `operator_delivery_test.exs`: `:noop` checkpoint, `{:deliver_text, …}` happy
  path registers the pending request via the stub backend's
  `send_operator_message`, send failure invokes `on_failure`; unclaimed
  response emits `:other_message`; claimed turn-started response increments
  `outstanding_turns`.
- `rpc_test.exs`: `send_line` wire bytes (`Jason` line + newline) and raise on
  closed port; `with_timeout_response` id matching, unrelated-JSON skip,
  non-JSON skip, timeout, port exit.
- `adapter_test.exs`: `run_turn` via a stub backend + fake port — success,
  `{:paused, …}` pass-through with `:session_id` added, error emits
  `:turn_ended_with_error`, start_turn failure emits `:startup_failed` and
  returns `{:error, {:turn_start_failed, reason}}`; `start_port` bash spawn.
- `messages_test.exs`: emit envelope (`:event` + `:timestamp` set, metadata
  merged), `normalize_tool_result` output lifting, `tool_call_name` blank/nil
  handling, `initialize_frame` contents (id 1, experimentalApi, clientInfo).
- `token_usage_test.exs`: snake/camel, atom/string, int/numeric-string
  spellings; zero-fill only when at least one field present; nil for none/non-map;
  `token_field?`; `format_counts` "in N, out N, total N" and nil for empty.
- `map_access_test.exs`: atom/string tolerance, `dig` nil-on-missing,
  `params_turn_id` blank-string rejection and key parametrization
  (`:turnId` vs `:turn_id`), `message_timestamp` utc_now fallback.

## Files

- Create: `src/lib/aiur/app_server/adapter.ex`,
  `src/lib/aiur/app_server/rpc.ex`, `src/lib/aiur/app_server/turn_loop.ex`,
  `src/lib/aiur/app_server/turn_state.ex`,
  `src/lib/aiur/app_server/operator_delivery.ex`,
  `src/lib/aiur/app_server/interrupts.ex`,
  `src/lib/aiur/app_server/messages.ex`, `src/lib/aiur/token_usage.ex`,
  `src/lib/aiur/protocol/map_access.ex`
- Create (tests): `src/test/aiur/app_server/adapter_test.exs`,
  `src/test/aiur/app_server/rpc_test.exs`,
  `src/test/aiur/app_server/turn_loop_test.exs`,
  `src/test/aiur/app_server/turn_state_test.exs`,
  `src/test/aiur/app_server/operator_delivery_test.exs`,
  `src/test/aiur/app_server/interrupts_test.exs`,
  `src/test/aiur/app_server/messages_test.exs`,
  `src/test/aiur/token_usage_test.exs`,
  `src/test/aiur/protocol/map_access_test.exs`
- Modify: `src/lib/aiur/codex/coding_agent.ex`,
  `src/lib/aiur/claude/coding_agent.ex`, `src/lib/aiur/codex/transcript.ex`,
  `src/lib/aiur/claude/transcript.ex`, `src/lib/aiur/codex/event_humanizer.ex`,
  `src/lib/aiur/agent_runner.ex` (the `get/2` delegate ONLY)
- Test (existing, must pass with ZERO edits):
  `src/test/aiur/app_server_test.exs`,
  `src/test/aiur/coding_agent_checkpoint_test.exs`,
  `src/test/aiur/coding_agent_test.exs`,
  `src/test/aiur/coding_agent_claude_test.exs`,
  `src/test/aiur/codex/coding_agent_test.exs`,
  `src/test/aiur/claude/coding_agent_test.exs`,
  `src/test/aiur/codex/transcript_test.exs`,
  `src/test/aiur/claude/transcript_test.exs`,
  `src/test/aiur/orchestrator_status_test.exs`

## Out of scope

- The six documented drift items (dup-backends.md Cluster 1): do NOT add
  symlink-escape validation to claude, do NOT add `-32600` interrupt tolerance
  to claude, do NOT add `turn/cancelled` handling to claude, do NOT add the
  30s startup floor to claude, do NOT add `jsonrpc` to codex frames or
  centralize its rescues, do NOT change either `maybe_set_usage`. Each backend
  keeps its current behavior bit-for-bit; drift closure is explicit follow-up
  work with its own tests.
- `src/lib/aiur/claude/repl_agent.ex` — its two receive loops duplicate the
  pause/queue grammar but are T-050's territory; no `Aiur.CodingAgent.TurnControl`
  classifier is created here (its only remaining consumers would be those repl
  loops).
- `src/lib/aiur/opencode/event_row.ex` — its `get_path/2` does an extra
  binary→atom reverse lookup; it is NOT the shared `get/2` and must not be
  refit.
- `src/lib/aiur/event_humanizer_helpers.ex` (`fetch_map_key` included) — read
  from, never modified.
- `src/lib/aiur/coding_agent.ex` (backend registry/behaviour) — T-015/T-016.
- Codex-specific decomposition (approvals, quota classification, event
  normalizer internals, handshake/resume, SSH spawn) — T-037..T-039.
- `shell_escape` dedup (T-018), sanitization dedup (T-019), `$VAR`/validator
  dedup (T-021), config section accessors, `Aiur.Claude.EventHumanizer`.
- `src/mix.exs` — do not touch (new modules must NOT be added to
  `ignore_modules`; the existing list only ever shrinks).
- Anything under `src/test/aiur/regression/` and all existing test files.
- `Aiur.Claude.ReplAgent.normalize_event/1` (repl_agent.ex:446-450) keeps
  delegating to `Aiur.Claude.CodingAgent.normalize_event/1` unchanged.

## Inventory-IDs

Features implemented by the moved/refit code — behavior for every one of these
must be identical after the extraction:

- **Codex adapter (cdx.md):** FI-CDX-018 (spawn, local+remote), FI-CDX-019
  (cwd validation — codex canonicalizing variant preserved), FI-CDX-020
  (model/effort splice), FI-CDX-021 (initialize handshake, ids 1/2/3),
  FI-CDX-022 (thread start vs resume dynamicTools), FI-CDX-023 (resume
  degradation #378), FI-CDX-024 (30s startup floor — codex-only), FI-CDX-025
  (turn/start frame), FI-CDX-026 (composite session id), FI-CDX-027
  (receive-loop outcomes + outstanding_turns algebra), FI-CDX-028/029/030
  (approvals, requestUserInput, tool calls — bodies stay in codex; tool-result
  normalization now shared), FI-CDX-031 (safe checkpoints + `{:deliver_text, …}`),
  FI-CDX-032 (send_operator_message), FI-CDX-033 (pause protocol), FI-CDX-034
  (deliver-now interrupt), FI-CDX-035 (`-32600` tolerance — codex-only),
  FI-CDX-036/037/038 (quota pause, unretryable, error surfacing + non-JSON
  triage), FI-CDX-039 (idle-as-completion gated on turn_started?), FI-CDX-040
  (input-required), FI-CDX-041 (normalize_event → TokenUsage/MapAccess),
  FI-CDX-042 (stop_port reap ordering — NOT shared), FI-CDX-043 (message
  envelope), FI-CDX-056 (humanizer usage counts → TokenUsage.format_counts),
  FI-CDX-057/058 (codex transcript extraction + turn-id precedence →
  MapAccess), FI-CDX-059 (remote metadata/policies), FI-CDX-060 (run/4).
- **Claude adapter (cld.md):** FI-CLD-001 (spawn + handshake), FI-CLD-002
  (weaker cwd validation preserved), FI-CLD-003 (reaper register/unregister),
  FI-CLD-004 (thread/start permissionMode + tool_specs), FI-CLD-005
  (maybe_put_model on turn + operator frames), FI-CLD-006 (event stream incl.
  cost_usd lifting — claude-only), FI-CLD-007 (tool call servicing), FI-CLD-008
  (safe-checkpoint delivery), FI-CLD-009 (pause via turn/interrupt, hard-fail
  on interrupt error — claude-only), FI-CLD-010 (deliver-now interrupt),
  FI-CLD-011 (timeout backstops, raw read timeout), FI-CLD-012 (partial-line
  reassembly, `:malformed` ungated — claude-only), FI-CLD-013 (port-closed
  rescue in send_frame), FI-CLD-014 (normalize_event → TokenUsage; ReplAgent
  delegation unchanged), FI-CLD-055 (transcript mapping), FI-CLD-060
  (atom/string tolerance → MapAccess).

## Characterization-tests

Everything under `src/test/aiur/regression/` must pass UNMODIFIED — in
particular the suites added by T-013 (agent_runner drain/resume & digest —
exercises operator-queue drain and checkpoint delivery through these adapters)
and T-009 (engine identity, reap & control RPC — exercises ProcessReaper
interplay). Additionally, the pre-existing characterization harnesses that pin
this exact code must pass with zero edits (they drive the public facades, which
keep their signatures): `src/test/aiur/app_server_test.exs` (16 fake-codex e2e
tests: cwd guards incl. symlink escape, approvals, requestUserInput, dynamic
tools, partial-JSON buffering, side-output logging, malformed gating, SSH
launch), `src/test/aiur/coding_agent_checkpoint_test.exs` (checkpoint follow-up
without interrupt; deliver-now triggers turn/interrupt; idle-as-completion both
cases), `src/test/aiur/coding_agent_test.exs` (operator frames, `--config`
splice, quota/unretryable/reason/reset-hint helpers),
`src/test/aiur/codex/coding_agent_test.exs` (stop-session tree reap,
thread-init frames, resume_outcome, startup-timeout floor, port-closed
degradation), `src/test/aiur/coding_agent_claude_test.exs` +
`src/test/aiur/claude/coding_agent_test.exs` (claude cwd validation, model
threading, tool calls, timeouts, port-closed send),
`src/test/aiur/orchestrator_status_test.exs` (normalize_event usage/rate-limit
paths).

## Acceptance criteria

All commands run from the repo root unless noted.

- Modules exist at the exact paths, one `defmodule` each:
  `grep -l "defmodule Aiur.AppServer.Adapter do" src/lib/aiur/app_server/adapter.ex`,
  `grep -l "defmodule Aiur.AppServer.Rpc do" src/lib/aiur/app_server/rpc.ex`,
  `grep -l "defmodule Aiur.AppServer.TurnLoop do" src/lib/aiur/app_server/turn_loop.ex`,
  `grep -l "defmodule Aiur.AppServer.TurnState do" src/lib/aiur/app_server/turn_state.ex`,
  `grep -l "defmodule Aiur.AppServer.OperatorDelivery do" src/lib/aiur/app_server/operator_delivery.ex`,
  `grep -l "defmodule Aiur.AppServer.Interrupts do" src/lib/aiur/app_server/interrupts.ex`,
  `grep -l "defmodule Aiur.AppServer.Messages do" src/lib/aiur/app_server/messages.ex`,
  `grep -l "defmodule Aiur.TokenUsage do" src/lib/aiur/token_usage.ex`,
  `grep -l "defmodule Aiur.Protocol.MapAccess do" src/lib/aiur/protocol/map_access.ex`
  — all nine match.
- Every new lib file is <= 200 lines (`wc -l` on each of the nine Create
  paths). Functions <= 20 logic lines, EXCEPT clauses the Scope marks as
  verbatim moves (`Adapter.run_turn` helpers, `TurnLoop.receive_loop`,
  `OperatorDelivery.handle_claimed_operator_response`,
  `TurnState.continue_after_turn_interrupted`) — never rewrite a moved body to
  satisfy the limit.
- Parent files shrank: `wc -l src/lib/aiur/codex/coding_agent.ex` <= 1650
  (from 1997); `wc -l src/lib/aiur/claude/coding_agent.ex` <= 650 (from 992).
- The turn loop lives in exactly one place:
  `grep -c "receive do" src/lib/aiur/codex/coding_agent.ex src/lib/aiur/claude/coding_agent.ex`
  → 0 for both files;
  `grep -c "agent_queue_updated" src/lib/aiur/codex/coding_agent.ex src/lib/aiur/claude/coding_agent.ex`
  → 0 for both;
  `grep -c "outstanding_turns" src/lib/aiur/codex/coding_agent.ex src/lib/aiur/claude/coding_agent.ex`
  → 0 for both (loop-state init and algebra are fully extracted).
- No shared machinery re-defined in the facades:
  `grep -En "defp (receive_loop|handle_incoming|with_timeout_response|handle_response|log_non_json_stream_line|handle_pause_request|handle_operator_queue_update|interrupt_turn|continue_after_turn_completion|continue_after_turn_interrupted|maybe_finish_after_pending_response|fail_pending_operator_requests|maybe_process_safe_checkpoint|handle_pending_operator_response|handle_claimed_operator_response|safe_invoke|normalize_tool_result|tool_call_name|tool_call_arguments|emit_message|default_on_message|token_value|parse_token_value)\(" src/lib/aiur/codex/coding_agent.ex src/lib/aiur/claude/coding_agent.ex`
  → no matches.
- Token vocabulary has one home:
  `grep -c "canonicalize_usage\|has_token_field\|token_like_value" src/lib/aiur/codex/coding_agent.ex`
  → 0; `grep -c "promptTokens" src/lib/aiur/claude/coding_agent.ex` → 0;
  `grep -c "append_usage_part" src/lib/aiur/codex/event_humanizer.ex` → 0.
- Map tolerance has one home:
  `grep -c "Atom.to_string(key)" src/lib/aiur/codex/transcript.ex src/lib/aiur/claude/transcript.ex src/lib/aiur/agent_runner.ex`
  → 0 for all three.
- Wire-shape drift preserved:
  `grep -c "jsonrpc" src/lib/aiur/claude/coding_agent.ex` >= 1 and
  `grep -c "jsonrpc" src/lib/aiur/codex/coding_agent.ex src/lib/aiur/app_server/rpc.ex`
  → 0 for both; `grep -c "no_active_turn_error" src/lib/aiur/codex/coding_agent.ex` >= 2
  and `grep -c "no_active_turn" src/lib/aiur/claude/coding_agent.ex` → 0;
  `grep -c "graceful_kill_tree" src/lib/aiur/codex/coding_agent.ex` >= 1 and
  `grep -c "graceful_kill_tree" src/lib/aiur/claude/coding_agent.ex src/lib/aiur/app_server/adapter.ex` → 0.
- Both facades implement the new behaviour:
  `grep -c "@behaviour Aiur.AppServer.Adapter" src/lib/aiur/codex/coding_agent.ex src/lib/aiur/claude/coding_agent.ex`
  → 1 each; `@behaviour Aiur.CodingAgent` still present in both.
- Every new module has `@moduledoc` (`grep -c "@moduledoc" <file>` >= 1 for all
  nine) and a test file exists for each (the nine test paths under Files exist).
- Coverage exemptions only shrink: `git diff origin/v2 -- src/mix.exs` is
  empty; `grep -c "AppServer\|TokenUsage\|MapAccess" src/mix.exs` → 0.
- `cd src && mix specs.check` passes (every new public def has `@spec`).
- `git diff --name-only origin/v2...HEAD` lists exactly the Create + Modify
  files above — nothing else, and NOTHING under `src/test/aiur/regression/` or
  the existing test files listed under Test.

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

- Check (FI-CDX-028): run a codex agent with approval_policy "never" on a
  prompt that executes a shell command and grep the session log for
  `approval_auto_approved` (no stalled `:approval_required`).
- Check (FI-CDX-033): pause a live codex agent mid-turn from the agent list and
  confirm it lands paused without a crash, then resumes cleanly.
- Check (FI-CDX-035): queue a deliver-now operator message at a fresh codex
  agent before its first turn starts — no Task crash, no `system:` dump in the
  chat pane.
- Check (FI-CLD-010): queue a deliver-now operator message at a live headless
  claude agent — turn ends as interrupted-for-operator-message (clean), message
  delivers on the next turn.
- Check (FI-CDX-042): after stopping a codex agent, `pgrep -f codex` shows no
  orphaned app-server and later codex agents start without "database is locked".
- Spot-check token accounting: a completed codex turn still shows non-zero
  in/out token counts in `aiurdev watch` status output AND the watch CLI's
  humanized "in N, out N, total N" line (TokenUsage now feeds both paths).
- Diff review: confirm the six drift items (claude prefix-only cwd check,
  claude interrupt hard-fail, claude ungated `:malformed`, claude-only
  `jsonrpc`/`cost_usd`, codex-only `turn/cancelled` + 30s floor) each still
  live on exactly their original backend.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
