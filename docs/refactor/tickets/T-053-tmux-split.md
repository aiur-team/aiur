# T-053: tmux: split command layer

**Phase:** 4
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3`

## Problem / context

`src/lib/aiur/tmux.ex` is a 1,005-line single GenServer that is the sole
serialization point for every tmux operation from eight caller modules
(pane_manager, claude/repl_agent, opencode/{slot,hidden_window,attach_pool},
orchestrator, process_reaper, agent_list/app). It bundles five unrelated
concerns behind one file: the exec/transport layer (socket-flag injection,
binary resolution + `:persistent_term` cache, exec-logging policy, exit-status
handling, command-string → argv splitting), the test mock transport, keystroke/
paste input injection, pane/window layout mutations, read-only queries, and pane
decoration (including the secret-safe border path that carries the Remote Control
session URL).

The decomposition contract is `docs/refactor/research-arch/giant-tmux.md` — its
§2 is the **binding name map** (the seven module names and file paths below are
copied from it verbatim and must not be altered) and its §4 names the
concurrency, timing, error, secret, and byte-exact-argv semantics that must
survive the move unchanged. This ticket performs the whole split in one pass:
extract `Aiur.Tmux.Exec`, `Aiur.Tmux.MockTransport`, `Aiur.Tmux.Input`,
`Aiur.Tmux.Layout`, `Aiur.Tmux.Query`, and `Aiur.Tmux.Style` under
`src/lib/aiur/tmux/`, and slim `Aiur.Tmux` to the GenServer facade whose
`handle_call` clauses delegate to them. Behavior-preserving only: every public
function signature, return value, emitted command string, log-level policy, and
timing semantic is unchanged, so all eight callers and the existing tests are
untouched. `Aiur.Tmux.Protocol` (`src/lib/aiur/tmux/protocol.ex`, 183 lines) is
**not** part of this ticket and is not edited.

## Scope (exact)

Line numbers below refer to `src/lib/aiur/tmux.ex` at the current tip of the `v2`
base (1,005 lines; verify with `wc -l src/lib/aiur/tmux.ex` before starting — if
the count differs by more than a handful of lines, stop and comment on the
issue). Do the steps in order; `mix compile --warnings-as-errors` and `mix test`
from `src/` must be green before starting the next step. Remove `alias` entries
in `tmux.ex` that the compiler flags as unused after each move.

General rules for every step (no exceptions, no improvisation):

- Move function bodies **verbatim** — copy/paste including every inline comment
  (the race/incident/version comments are part of the contract). Do not rewrite,
  reorder args, rename log fields, collapse clauses, or "simplify".
- Extracted modules are **plain function modules**: no `use GenServer`, no
  `Agent`, no new processes/Tasks. The only new state passed around is the exec
  context map `%{transport: transport, session: session}` — the four op modules
  (`Input`, `Layout`, `Query`, `Style`) take it as their first argument and
  return a plain result (`:ok | {:ok, _} | {:error, _}`), exactly what the
  corresponding `handle_call` body returns today.
- Dependency direction (strict, one-way, from giant-tmux.md §2):
  `Aiur.Tmux` → {`Input`, `Layout`, `Query`, `Style`} → `Exec` → `MockTransport`.
  Extracted modules never call `Aiur.Tmux` (no `GenServer.call`, no reference to
  the facade). The op modules call only `Exec`; only `Exec` calls
  `MockTransport`. `Aiur.Tmux.Protocol` gets no new edges.
- Every extracted function that today runs inside the GenServer process keeps
  running inside it: the facade's `handle_call` invokes the op function as a
  plain in-process call. Do **not** introduce a `Task`, `spawn`, `cast`, or any
  process hop — keystroke sequencing (paste → Enter) depends on FIFO handling in
  the one server process (giant-tmux.md §4, "#373 paste" race).
- Every new module gets `@moduledoc` and an `@spec` on every public `def`.
- The client stubs in the facade (lines 27–412) keep their per-function
  `catch :exit` wrappers **verbatim**. Do NOT consolidate them into a shared
  `call/3` helper: the wrappers differ deliberately (`session/1` at 334–335 has
  no `catch`; `subscribe_events/1` at 58–63 catches only `:noproc`, not
  `:timeout`), and a shared helper risks flipping those (giant-tmux.md §4, error/
  degradation semantics). The `call/3` dedup is explicitly out of scope for this
  ticket.

### Step 1 — create `Aiur.Tmux.MockTransport` (`src/lib/aiur/tmux/mock_transport.ex`)

The test seam. Public API (all `@spec`ed):

1. `request(pid, command)` — new function collapsing the two mock clauses
   (`run_command/2` at 777–780 and `run_args/2` at 802–805): body is
   `send(pid, {:tmux_mock_out, command})` followed by `receive_mock_response()`.
   Its `@doc` must state: "Runs the blocking selective receive in the caller's
   process (the `Aiur.Tmux` GenServer); tests inject `{:tmux_mock_data, chunk}`
   to that pid" (giant-tmux.md §4, mock concurrency risk).
2. Move `receive_mock_response/0` (931–937, keeps the 1s timeout →
   `{:error, :no_mock_response}`) and `parse_mock_response/1` (939–958, the
   `%begin`/`%end`/`%error` framing) verbatim; both stay `defp`.

### Step 2 — create `Aiur.Tmux.Exec` (`src/lib/aiur/tmux/exec.ex`)

One source of truth for how a tmux command is executed. Move verbatim, adding
`require Logger` and `alias Aiur.Tmux.MockTransport`:

1. `run_command(state, cmd)` — from 777–784. The mock clause
   (`%{transport: {:mock, pid}}`) becomes `MockTransport.request(pid, cmd)`; the
   `:shell` clause stays `run_args(state, split_command(cmd))`. Public.
2. `run_args(state, args)` — from 802–827. The mock clause becomes
   `MockTransport.request(pid, Enum.join(args, " "))`; the `:shell` clause moves
   verbatim (socket prepend, debug log, `tmux_executable/0` resolution,
   `System.cmd(..., stderr_to_stdout: true)`, exit handling). Public.
3. `run_args_silent(state, args)` — from 833–853 (mock clause at 833 delegates to
   `run_args/2`; `:shell` clause never logs args, on error logs only
   `redact_subcommand/1` + status). Public.
4. Move `defp` verbatim: `tmux_executable/0` (790–800, incl. the
   `:persistent_term` cache — the cache key's module prefix changes to
   `Aiur.Tmux.Exec`, a private/invisible change), `prepend_socket/1` (908–913,
   reads `AIUR_TMUX_SOCKET` **per invocation** — keep uncached),
   `handle_tmux_exit/3` (891–904, "no server running" → debug else warning),
   `redact_subcommand/1` (857–859), and the command-splitter family
   `split_command/1` (960–967), `split_command_step/2` (969–977),
   `start_quoted/2` (979–987), `continue_quoted/3` (989–997).
5. In `tmux.ex`: delete the moved functions; the `{:command, cmd}` `handle_call`
   (430–433) becomes `{:reply, Exec.run_command(state, cmd), state}`. Add
   `alias Aiur.Tmux.Exec`.

### Step 3 — create `Aiur.Tmux.Query` (`src/lib/aiur/tmux/query.ex`)

Read-only inspection. Add `alias Aiur.Tmux.Exec`. Each function takes `state`
first and returns the exact tuple the current `handle_call` body returns. Move
the bodies verbatim:

1. `capture_pane(state, pane_id)` — from 626–631.
2. `pane_pid(state, pane_id)` — from 633–647 (inline `Integer.parse`,
   `{:error, :no_pane_pid}` on miss).
3. `list_windows(state)` — from 550–564; move `parse_window_line/1` (770–775) as
   a `defp` in this module.
4. `list_panes(state, window_target)` — from 566–574.
5. `window_size(state, pane_id)` — from 514–534; move `parse_dims/1` (915–929) as
   a `defp` in this module.
6. `window_for(state, pane_id)` — from 536–548.
7. `resolve_self_pane(state)` — from 479–499 (reads `TMUX_PANE`, validates
   against the live server; keep the issue-#34 anchor rationale).

In `tmux.ex`, rewrite the seven matching `handle_call` clauses to one-line
delegations, e.g. `{:reply, Query.capture_pane(state, pane_id), state}` and
`{:reply, Query.resolve_self_pane(state), state}`. Add `alias Aiur.Tmux.Query`.

### Step 4 — create `Aiur.Tmux.Style` (`src/lib/aiur/tmux/style.ex`)

Pane decoration, including the secret-safe border path. Add
`alias Aiur.Tmux.Exec`.

1. `set_pane_border(state, pane_id, nil)` — from 435–439. Both `set-option -pu`
   calls go through `Exec.run_args_silent/2`; results discarded with `_ =`;
   returns `:ok`.
2. `set_pane_border(state, pane_id, text) when is_binary(text)` — from 441–445.
   Both `set-option -p` calls go through `Exec.run_args_silent/2`; results
   discarded with `_ =`; returns `:ok` **unconditionally** even when tmux errors
   (callers depend on this — giant-tmux.md §4, secrets + set_pane_border reply).
   Move the "why silent" rationale (the `@doc` at 40–47 stays on the public stub
   in the facade; put a short module-level note here that the border text carries
   the RC capability-token URL and must only ever flow through
   `run_args_silent`).
3. `set_pane_title(state, pane_id, title)` — from 716–721, through
   `Exec.run_args/2` (args-based so titles with spaces survive).

In `tmux.ex`, rewrite the three matching `handle_call` clauses to delegations,
e.g. `{:reply, Style.set_pane_border(state, pane_id, text), state}`. Add
`alias Aiur.Tmux.Style`.

### Step 5 — create `Aiur.Tmux.Layout` (`src/lib/aiur/tmux/layout.ex`)

Pane/window creation, movement, destruction, and layout. Add `require Logger`
and `alias Aiur.Tmux.Exec`. Move the bodies verbatim, each taking `state` first
and returning the current tuple:

1. `split_pane(state, target_pane, direction, percent, command_to_run, silent?)`
   — from 447–477. Preserve the `-l N%` sizing, the `-d` + skipped follow-up
   `select-pane` only when `silent?` (focus-stealing guard), and the
   `Logger.warning` on failure — all byte-exact (giant-tmux.md §4, version-
   sensitive argv).
2. `respawn_pane(state, pane_id, command_to_run)` — from 576–585 (`respawn-pane
   -k`).
3. `new_hidden_window(state, window_name, command_to_run)` — from 665–689; move
   `bootstrap_window/3` (749–768) and `no_server?/1` (740–744) as `defp` in this
   module. The fallback stays keyed on the exact `"no server running"` substring
   (giant-tmux.md §4, standalone/`--bg` first-spawn path).
4. `join_pane(state, source_pane, target_window)` — from 691–698.
5. `move_pane_hidden(state, source_pane, target_window)` — from 700–707 (`-d`).
6. `move_pane_visible(state, source_pane, target_window)` — from 709–714 (no
   `-d`).
7. `kill_pane(state, pane_id)` — from 649–663. Keep the idempotent
   `"can't find pane"` → `:ok` branch verbatim (giant-tmux.md §4, reaper friendly-
   fire).
8. `select_layout(state, window_target, layout_string)` — from 501–512 (with its
   `Logger.warning` on failure).

In `tmux.ex`, rewrite the eight matching `handle_call` clauses to delegations,
e.g. `{:reply, Layout.split_pane(state, target_pane, direction, percent,
command_to_run, silent?), state}`. Add `alias Aiur.Tmux.Layout`.

### Step 6 — create `Aiur.Tmux.Input` (`src/lib/aiur/tmux/input.ex`)

Keystroke and paste delivery. Add `alias Aiur.Tmux.Exec`. Move the bodies
verbatim, each taking `state` first:

1. `send_keys_literal(state, pane_id, text)` — from 587–592 (`send-keys -l`).
2. `paste_text(state, pane_id, text)` — from 594–596; move `paste_via_buffer/3`
   (874–889) as a `defp` in this module **with its full comment block** (861–873,
   the "why `-p` is load-bearing" rationale — bracketed paste, RC submit). Keep
   the unique buffer name, the temp-file `after File.rm` cleanup, and the exact
   `load-buffer` / `paste-buffer -p -d` argv.
3. `send_enter(state, pane_id)` — from 598–603 (named `Enter`).
4. `clear_input(state, pane_id)` — from 605–610 (`C-u`).
5. `send_interrupt(state, pane_id)` — from 612–617 (`C-c`).
6. `send_escape(state, pane_id)` — from 619–624 (`Escape`).

In `tmux.ex`, rewrite the six matching `handle_call` clauses to delegations,
e.g. `{:reply, Input.paste_text(state, pane_id, text), state}`. Add
`alias Aiur.Tmux.Input`.

### Step 7 — confirm the slimmed facade (`src/lib/aiur/tmux.ex`)

After steps 1–6, `tmux.ex` keeps, unchanged in name and signature: the
`@moduledoc`, all module attributes (`@default_session_env`,
`@default_session_fallback`, `@type command_response`), all 27 public client
functions (lines 27–412) **with their `@doc`/`@spec` and verbatim `catch :exit`
wrappers**, `init/1` (417–428), the `{:subscribe, pid}` (723–726) and `:session`
(728) `handle_call` clauses (stay inline — subscriber bookkeeping / config
read), all `handle_info` clauses (730–736), and `default_session/0` (999–1004).
Add the alias line
`alias Aiur.Tmux.{Exec, Input, Layout, MockTransport, Query, Style}` (drop any
that end up unused per the compiler). Every other `handle_call` body is now a
one-line delegation as specified in steps 2–6. No public API, no behavior, no
log-line, and no emitted-string change.

### Step 8 — tests for every extracted module (same ticket; new modules are NOT coverage-exempt)

Drive each extracted module directly through the `{:mock, pid}` transport, using
the **exact harness already in `src/test/aiur/tmux_test.exs`** (`Task.async` the
op call, `assert_receive {:tmux_mock_out, cmd}`, then `send(task.pid,
{:tmux_mock_data, "%begin 1 1 0\\n...\\n%end 1 1 0\\n"})`, then `Task.await`).
The op modules take the state map, so the state is
`%{transport: {:mock, self()}, session: "test"}` and the injected
`{:tmux_mock_data, _}` goes to **`task.pid`** (the process running the op call),
not a named server. Every test module is `async: false` (the mock transport uses
process-inbox messaging). Create exactly these files:

1. `src/test/aiur/tmux/mock_transport_test.exs` — `request/2` emits
   `{:tmux_mock_out, command}`; injected `%begin/%end` → `{:ok, body}`,
   `%begin/%error` → `{:error, body}`; no injection within 1s →
   `{:error, :no_mock_response}`.
2. `src/test/aiur/tmux/exec_test.exs` — via `Exec.run_command(state, cmd)` with a
   `{:mock, self()}` state: a plain command splits on whitespace
   (`"list-panes -t x"` → `{:tmux_mock_out, "list-panes -t x"}`) and a
   double-quoted span rejoins into one token that survives in the emitted string
   (pins `split_command` quote-grouping, FI-TUI-002); `Exec.run_args(state,
   args)` emits `Enum.join(args, " ")`; a `%error`-framed injection surfaces as
   `{:error, body}`. (The `:shell` path — `prepend_socket`, `:persistent_term`,
   `handle_tmux_exit` — is exercised by the live suite; do not shell out here.)
3. `src/test/aiur/tmux/input_test.exs` — exact emitted strings for
   `send_keys_literal` (`send-keys -t %42 -l <text>`), `send_enter`
   (`send-keys -t %42 Enter`), `clear_input` (`send-keys -t %42 C-u`),
   `send_interrupt` (`send-keys -t %42 C-c`), `send_escape`
   (`send-keys -t %42 Escape`); and `paste_text` writes the temp file with the
   given contents, emits `load-buffer -b aiur-paste-<n> <tmp>` then
   `paste-buffer -p -d -b <same> -t %42`, and removes the temp file afterward
   (mirror the `paste_text/3` test at `tmux_test.exs:257`).
4. `src/test/aiur/tmux/layout_test.exs` — `split_pane` non-silent emits
   `split-window -t %1 -h -l 30% -P -F #{pane_id} <cmd>` then, after a pane-id
   reply, a follow-up `select-pane -t <new>`; `split_pane` with `silent: true`
   emits `split-window -d ...` and **no** `select-pane`; `respawn_pane`
   (`respawn-pane -k -t %1 <cmd>`); `new_hidden_window` happy path returns the
   pane id, and on an injected `%error "no server running ..."` falls back to
   `new-session -d -s test -n <name> -P -F #{pane_id} <cmd>` (mirror
   `tmux_test.exs:193`); `join_pane`, `move_pane_hidden` (`-d`),
   `move_pane_visible` (no `-d`); `kill_pane` returns `:ok` on success and `:ok`
   on an injected `"can't find pane"` error, `{:error, _}` on any other error;
   `select_layout` returns `:ok`.
5. `src/test/aiur/tmux/query_test.exs` — `capture_pane` returns injected lines;
   `pane_pid` parses an integer and returns `{:error, :no_pane_pid}` on empty/
   non-integer; `list_windows` tab-splits `name\tpane` lines and drops malformed
   (no-tab) lines; `list_panes` trims ids; `window_size` parses `WxH` and returns
   `{:error, {:bad_dims, _}}` on garbage; `window_for` returns the trimmed
   target; `resolve_self_pane` returns `{:error, :no_tmux_pane_env}` when
   `TMUX_PANE` is unset (use `System.delete_env`/restore in `on_exit`) and
   `{:ok, id}` when it is set and the server replies.
6. `src/test/aiur/tmux/style_test.exs` — `set_pane_border` with text emits
   `set-option -p -t %9 pane-border-status top` then a `pane-border-format` arg
   containing the URL, and returns `:ok` **even when both injected responses are
   `%error`** (unconditional `:ok`, secret path); `set_pane_border` with `nil`
   emits the two `set-option -pu` unsets; `set_pane_title` emits
   `select-pane -t %42 -T <title>` with a spaced title surviving as one argv
   element (mirror `tmux_test.exs:141`).

Do NOT add any of the six new modules to `ignore_modules` in `src/mix.exs` (the
exemption list only shrinks). `Aiur.Tmux` itself stays listed at `mix.exs:71` —
do not remove or add entries.

## Files

- Create: `src/lib/aiur/tmux/exec.ex`, `src/lib/aiur/tmux/mock_transport.ex`, `src/lib/aiur/tmux/input.ex`, `src/lib/aiur/tmux/layout.ex`, `src/lib/aiur/tmux/query.ex`, `src/lib/aiur/tmux/style.ex`
- Modify: `src/lib/aiur/tmux.ex`
- Test: `src/test/aiur/tmux/exec_test.exs`, `src/test/aiur/tmux/mock_transport_test.exs`, `src/test/aiur/tmux/input_test.exs`, `src/test/aiur/tmux/layout_test.exs`, `src/test/aiur/tmux/query_test.exs`, `src/test/aiur/tmux/style_test.exs`

## Out of scope

- `src/lib/aiur/tmux/protocol.ex` and `src/test/aiur/tmux/protocol_test.exs` —
  the control-mode wire parser is standalone and gets no new edges; do not edit.
- Raw tmux command strings elsewhere that bypass the typed API
  (`pane_manager.ex`, `opencode/slot.ex`, `opencode/attach_pool.ex` build
  `"kill-pane -t ..."` / `"capture-pane -p -t ..."` strings — dup-infra.md
  cluster #5). Routing those through the typed wrappers, adding new typed
  wrappers, or demoting `Tmux.command/3` is a **separate ticket**. This ticket
  splits the module only; `command/3` and its `Exec.split_command` path stay.
- The write-only `subscribers` MapSet and the duplicated `%begin/%end/%error`
  framing between `MockTransport` and `Aiur.Tmux.Protocol` (giant-tmux.md §4,
  "flagged for later tickets") — behavior-preserving pass keeps both; do not
  remove or unify them.
- Do NOT consolidate the per-stub `catch :exit` wrappers into a shared `call/3`
  helper (see General rules).
- No behavior, API, log-line, log-level, emitted-command-string, or return-shape
  changes; no new config options; no new processes/Tasks/casts.
- Escaping/quoting stays as-is: this ticket does not adopt the T-018
  `shell_escape` helper (Phase 2 baseline) at any new site; `Exec.split_command`
  moves verbatim.
- The eight caller modules, `src/test/aiur/tmux_test.exs`,
  `src/test/aiur/application_test.exs`, `src/test/aiur/claude/repl_agent_test.exs`,
  `src/test/aiur/pane_manager_live_test.exs`, `src/mix.exs` (including
  `ignore_modules`), CI workflows, docs, and website.

## Inventory-IDs

Files in this ticket implement/touch these FI-TUI entries (from
`docs/refactor/feature-inventory/tui.md`); shapes unchanged, code relocated:

- FI-TUI-001 — Tmux shell-out command bus (socket prepend read per-call,
  `AIUR_TMUX_SESSION` targeting, `:persistent_term` binary cache, `{:error,
  :no_tmux}`/`{:error, :timeout}` degradation): exec/socket/cache move to
  `Aiur.Tmux.Exec`; the `catch :exit` degradation stays on the facade stubs.
- FI-TUI-002 — `command/3` whitespace splitting with quoted tokens:
  `split_command` family moves to `Aiur.Tmux.Exec`.
- FI-TUI-003 — mock transport seam + control-mode framing:
  `receive_mock_response`/`parse_mock_response` move to `Aiur.Tmux.MockTransport`.
- FI-TUI-004 — dead-tmux-server log demotion (`handle_tmux_exit`): moves to
  `Aiur.Tmux.Exec`.
- FI-TUI-005 — `split_pane` `-l N%` sizing + `:silent`: moves to
  `Aiur.Tmux.Layout`.
- FI-TUI-006 — `respawn_pane` preserves pane id: moves to `Aiur.Tmux.Layout`.
- FI-TUI-007 — `new_hidden_window` no-server bootstrap fallback: moves to
  `Aiur.Tmux.Layout` (with `bootstrap_window`/`no_server?`).
- FI-TUI-008 — pane move primitives (join / move hidden / move visible): move to
  `Aiur.Tmux.Layout`.
- FI-TUI-009 — `set_pane_title` via `select-pane -T`: moves to `Aiur.Tmux.Style`.
- FI-TUI-010 — silent pane-border set for the RC session URL (secret hygiene):
  `set_pane_border` moves to `Aiur.Tmux.Style`; `run_args_silent`/
  `redact_subcommand` move to `Aiur.Tmux.Exec`.
- FI-TUI-011 — text injection primitives (literal keys, bracketed paste, Enter,
  C-u, C-c, Escape): move to `Aiur.Tmux.Input` (with `paste_via_buffer`).
- FI-TUI-012 — introspection helpers (capture, pane_pid, list_windows,
  list_panes, window_size, window_for, resolve_self_pane, select_layout): queries
  move to `Aiur.Tmux.Query`; `select_layout` to `Aiur.Tmux.Layout`; `session/1`
  stays on the facade.
- FI-TUI-013 — `kill_pane` idempotent on already-dead panes: moves to
  `Aiur.Tmux.Layout`.

## Characterization-tests

**None under `src/test/aiur/regression/`** — that suite pins higher-level
pane/slot/warm-marker behavior (`warm_*`, `multi_pane_open`, `event_flow_e2e`,
etc.) that reaches tmux only through the `{:mock, pid}` seam or live flows, not
the command-layer argv. The binding pin for this area is the unit suite
`src/test/aiur/tmux_test.exs` (375 lines, 17 tests: command framing + error
surfacing, session, move_pane hidden/visible, border set/unset incl. RC-URL
delivery, pane-title argv, list_panes, new_hidden_window + no-server bootstrap,
capture_pane, paste_text buffer lifecycle, kill_pane incl. idempotent,
send_interrupt, pane_pid ok/error) — **treat it exactly like a regression test:
it must pass byte-identical, and must not be edited** (the delegations preserve
every emitted string and return value it asserts). `src/test/aiur/tmux/
protocol_test.exs`, `src/test/aiur/application_test.exs` (supervision membership),
`src/test/aiur/claude/repl_agent_test.exs`, and
`src/test/aiur/pane_manager_live_test.exs` (real socket) also drive `Aiur.Tmux`
and must stay green unmodified.

## Acceptance criteria

- All six new lib files and all six new test files exist at the exact paths in
  Files.
- `grep -q "defmodule Aiur.Tmux.Exec" src/lib/aiur/tmux/exec.ex` (and the
  analogous grep for `MockTransport`, `Input`, `Layout`, `Query`, `Style` in
  their files) all succeed.
- `wc -l src/lib/aiur/tmux.ex` ≤ 560 (from 1,005).
- Each new lib file ≤ 200 lines by `awk '!/^[[:space:]]*(#|$)/' <file> | wc -l`;
  every function in the new modules and every rewritten `handle_call` delegation
  in `tmux.ex` ≤ 20 logic lines (a multi-line literal/keyword-list argument
  counts as one).
- `grep -c "defp receive_mock_response\|defp parse_mock_response" src/lib/aiur/tmux.ex`
  == 0; both appear only in `src/lib/aiur/tmux/mock_transport.ex`.
- `grep -c "defp run_args\|defp run_command\|defp run_args_silent\|defp split_command\|defp tmux_executable\|defp prepend_socket\|defp handle_tmux_exit\|defp redact_subcommand" src/lib/aiur/tmux.ex`
  == 0 (all moved to `Exec`); `grep -q "persistent_term" src/lib/aiur/tmux/exec.ex`
  succeeds and `grep -c "persistent_term" src/lib/aiur/tmux.ex` == 0.
- `grep -q 'run_args_silent' src/lib/aiur/tmux/style.ex` succeeds and
  `grep -c 'run_args_silent' src/lib/aiur/tmux.ex` == 0 (secret path lives in
  `Style` over `Exec`).
- `grep -q "no server running" src/lib/aiur/tmux/layout.ex` and
  `grep -q "can't find pane" src/lib/aiur/tmux/layout.ex` both succeed (bootstrap
  fallback + kill-pane idempotency moved verbatim).
- `grep -q 'paste-buffer' src/lib/aiur/tmux/input.ex` succeeds and
  `grep -c 'paste-buffer\|paste_via_buffer' src/lib/aiur/tmux.ex` == 0.
- `grep -rn "use GenServer\|use Agent\|GenServer.call\|GenServer.start\|Task.async\|Task.start\|spawn" src/lib/aiur/tmux/exec.ex src/lib/aiur/tmux/mock_transport.ex src/lib/aiur/tmux/input.ex src/lib/aiur/tmux/layout.ex src/lib/aiur/tmux/query.ex src/lib/aiur/tmux/style.ex`
  has no matches (pure function modules, no process hops).
- `grep -L "@moduledoc" src/lib/aiur/tmux/exec.ex src/lib/aiur/tmux/mock_transport.ex src/lib/aiur/tmux/input.ex src/lib/aiur/tmux/layout.ex src/lib/aiur/tmux/query.ex src/lib/aiur/tmux/style.ex`
  prints nothing; every public `def` in the six new modules has an adjacent
  `@spec`.
- `grep -rn "Slot\|PaneManager\|Aiur.Tmux\." src/lib/aiur/tmux/input.ex src/lib/aiur/tmux/layout.ex src/lib/aiur/tmux/query.ex src/lib/aiur/tmux/style.ex`
  shows the op modules referencing only `Aiur.Tmux.Exec` (via alias `Exec.`) —
  no call back into the `Aiur.Tmux` facade.
- `grep -n "Aiur.Tmux.Exec\|Aiur.Tmux.MockTransport\|Aiur.Tmux.Input\|Aiur.Tmux.Layout\|Aiur.Tmux.Query\|Aiur.Tmux.Style" src/mix.exs`
  has no matches (new modules are NOT coverage-exempt); `grep -c "Aiur.Tmux,"
  src/mix.exs` == 1 (the parent facade stays listed).
- `git diff --name-only` contains only the files listed under Files (in
  particular: `src/test/aiur/tmux_test.exs`, `src/test/aiur/tmux/protocol_test.exs`,
  and `src/mix.exs` unmodified; nothing under `src/test/aiur/regression/`).
- `mix test test/aiur/tmux_test.exs test/aiur/tmux` (from `src/`) green; full
  `mix test` green.

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

- Diff review: every extracted body is a verbatim move (compare side-by-side);
  every inline race/version/incident comment survived next to its code — the
  `-l N%` tmux-3.5 note, the `-d`/skip-`select-pane` focus-steal guard, the
  `"no server running"` bootstrap comment, the `kill-pane` idempotency comment,
  the `paste-buffer -p` "load-bearing / RC submit" block, the `prepend_socket`
  per-invocation-read comment, and the `handle_tmux_exit` log-flood comment.
- Confirm the facade's `handle_call` clauses are one-line delegations returning
  `{:reply, <Module>.fun(state, ...), state}` and that the client stubs (27
  functions) retain their `catch :exit` wrappers unchanged (`session/1` still has
  none; `subscribe_events/1` still catches only `:noproc`).
- Live `aiurdev` smoke on `v2` (executors cannot run this; reviewer does):
  - Open a chat pane, then paste a multi-line prompt into a claude REPL — Check
    (FI-TUI-011): the prompt lands as one `[Pasted text]` chip and a single Enter
    submits it (RC turn starts; no expanded newlines).
  - Toggle Remote Control on an agent — Check (FI-TUI-010): the session URL shows
    in the pane top border AND `grep -ri "claude.ai/code/session" ~/.aiur/logs`
    for the run finds nothing (the token never reaches logs via the silent path).
  - In a standalone/`--bg` first spawn — Check (FI-TUI-007): the first REPL pane
    bootstraps the session (`new-session`) instead of failing headless.
  - `tmux -L "$AIUR_TMUX_SOCKET" kill-pane` a live pane, then trigger a teardown
    path — Check (FI-TUI-013): `kill_pane` on the already-gone pane returns `:ok`
    (no crash, idempotent).
- Check: after killing the tmux server mid-run, the operator BEAM's log shows the
  `no server running` exec lines at **debug**, not warning (no 2s-tick flood).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
