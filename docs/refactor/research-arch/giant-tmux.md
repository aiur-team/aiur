# Decomposition proposal: `src/lib/aiur/tmux.ex` (1005 lines)

Behavior-preserving refactor plan for aiur's tmux command layer. Repo root: `/home/orangekid/github/aiur`.
House style applied: one source of truth per fact, pure policy functions over synchronous call chains,
no M-x-N fan-out, base owns cross-cutting work, one dependency direction. Norm targets (<=20 logic
lines/function, <=200 lines/file, <=2 nesting levels) applied with judgment — the facade deliberately
exceeds the file norm (see §2, module 1).

Existing namespace precedent: `Aiur.Tmux.Protocol` already lives at `src/lib/aiur/tmux/protocol.ex`
(pure control-mode wire parser, 183 lines, untouched by this plan). New modules follow the same
`Aiur.Tmux.*` / `src/lib/aiur/tmux/*.ex` convention.

---

## 1. Function / responsibility census

`Aiur.Tmux` is a single GenServer: 27 public client functions, 26 `handle_call` clauses, and a private
transport/exec layer. Every public function pairs a client stub (with `catch :exit` noproc/timeout
wrapping) with a `handle_call` clause. Line refs are current file lines.

### A. GenServer shell / lifecycle (~55 lines)
| Function | Lines | Notes |
|---|---|---|
| `start_link/1` | 28–30 | named server, default `__MODULE__` |
| `init/1` | 417–428 | state = `%{transport, session, subscribers}` |
| `subscribe_events/1` + `handle_call({:subscribe,_})` | 58–63, 723–726 | monitors subscriber; **subscribers set is write-only** (no event publication exists) |
| `session/1` + clause | 334–335, 728 | returns configured session name |
| `handle_info` (DOWN, mock data, catch-all) | 731–736 | prunes subscribers on DOWN |
| `default_session/0` | 999–1004 | reads `AIUR_TMUX_SESSION` at init |

### B. Generic string-command exec (~12 lines)
| `command/3` + `handle_call({:command,_})` | 32–38, 430–433 | raw "subcommand args" string, split via `split_command/1`; used heavily by PaneManager/Slot/AttachPool/HiddenWindow for ad-hoc ops (`swap-pane`, `pipe-pane`, `select-pane`, …) |

### C. Input injection into panes (~110 lines)
| Function | Client | Server | Notes |
|---|---|---|---|
| `send_keys_literal/3` | 199–211 | 587–592 | `send-keys -l` (verbatim argv, no split_command mangling) |
| `paste_text/3` | 213–229 | 594–596 | delegates to `paste_via_buffer/3` (874–889): temp file → `load-buffer` → `paste-buffer -p -d`; `-p` bracketed-paste flag is load-bearing (RC prompt submit) |
| `send_enter/2` | 231–242 | 598–603 | named `Enter` key |
| `clear_input/2` | 244–255 | 605–610 | `C-u` |
| `send_interrupt/2` | 257–268 | 612–617 | `C-c` |
| `send_escape/2` | 270–281 | 619–624 | `Escape` |

### D. Pane/window creation, movement, destruction, layout (~230 lines)
| Function | Client | Server | Notes |
|---|---|---|---|
| `split_pane/6` | 65–100 | 447–477 | `-l N%` modern sizing; `:silent` opt skips both `-d` omission and the `select-pane` follow-up (focus-stealing guard) |
| `respawn_pane/3` | 102–114 | 576–585 | `respawn-pane -k`, pane id preserved |
| `new_hidden_window/3` | 116–132 | 665–689 | falls back to `bootstrap_window/3` (749–768, `new-session -d`) when `no_server?/1` (740–744) matches "no server running" — standalone/`--bg` first-spawn path |
| `join_pane/3` | 134–146 | 691–698 | `join-pane -h` |
| `move_pane_hidden/3` | 148–164 | 700–707 | `move-pane -d -h` (no focus shift) |
| `move_pane_visible/3` | 185–197 | 709–714 | `move-pane -h` |
| `kill_pane/2` | 296–306 | 649–663 | **idempotent**: "can't find pane" error → `:ok` |
| `select_layout/3` | 357–370 | 501–512 | applies checksum-prefixed layout string |

### E. Read-only queries / output parsing (~170 lines)
| Function | Client | Server | Parser helper |
|---|---|---|---|
| `capture_pane/2` | 283–294 | 626–631 | — |
| `pane_pid/2` | 308–319 | 633–647 | `Integer.parse` inline |
| `list_windows/1` | 321–332 | 550–564 | `parse_window_line/1` (770–775, tab-split) |
| `list_panes/2` | 399–412 | 566–574 | — |
| `window_size/2` | 372–383 | 514–534 | `parse_dims/1` (915–929) |
| `window_for/2` | 385–397 | 536–548 | — |
| `resolve_self_pane/1` | 337–355 | 479–499 | validates `$TMUX_PANE` against live server (issue #34 anchor guard) |

### F. Pane decoration, incl. secret-safe path (~60 lines)
| Function | Client | Server | Notes |
|---|---|---|---|
| `set_pane_border/3` | 40–56 | 435–445 | two clauses (set / nil-unset); goes through `run_args_silent` because the text carries the RC session URL (capability token, must never hit logs); **replies `:ok` unconditionally** — `run_args_silent` results are discarded with `_ =` |
| `set_pane_title/3` | 166–183 | 716–721 | `select-pane -T`, args-based so titles with spaces survive |

### G. Transport / exec internals (~200 lines)
| Function | Lines | Notes |
|---|---|---|
| `run_command/2` | 777–784 | mock branch + shell branch via `split_command` |
| `tmux_executable/0` | 790–800 | `:persistent_term` cache of `System.find_executable("tmux")` (hot liveness-poll path) |
| `run_args/2` | 802–827 | mock branch; shell branch: `prepend_socket` → debug log → `System.cmd(…, stderr_to_stdout: true)` |
| `run_args_silent/2` | 833–853 | never logs args (secrets); errors log `redact_subcommand/1` (857–859, first two tokens) + status only |
| `handle_tmux_exit/3` | 891–904 | log-level policy: "no server running" demoted to debug (anti-flood), everything else warning; returns `{:error, trimmed}` |
| `prepend_socket/1` | 908–913 | reads `AIUR_TMUX_SOCKET` **per invocation** (deliberate — server may start before wrapper exports var) |
| `receive_mock_response/0` | 931–937 | **selective `receive` inside the GenServer process**, 1s timeout |
| `parse_mock_response/1` | 939–958 | `%begin`/`%end`/`%error` framing (duplicates `Aiur.Tmux.Protocol` framing — flagged, not fixed) |
| `split_command/1` + `split_command_step/2` + `start_quoted/2` + `continue_quoted/3` | 960–997 | whitespace split with naive double-quote grouping |
| `paste_via_buffer/3` | 874–889 | unique buffer name, temp file with `after File.rm` cleanup |

---

## 2. Proposed module split (NAME MAP — contract for downstream tickets)

Dependency direction (strict, one-way):
`Aiur.Tmux` → { `Aiur.Tmux.Input`, `Aiur.Tmux.Layout`, `Aiur.Tmux.Query`, `Aiur.Tmux.Style` } → `Aiur.Tmux.Exec` → `Aiur.Tmux.MockTransport`.
`Aiur.Tmux.Protocol` stays standalone (no new edges).

Calling convention for the four op modules: each function takes the GenServer's state map (the exec
context: `%{transport:, session:}`) as its first arg and returns a plain result (`:ok | {:ok, _} |
{:error, _}`); `Aiur.Tmux.handle_call` clauses become one-line delegations wrapping `{:reply, result,
state}`. Op functions are pure policy over `Exec.run_args/2` — arg-building is unit-testable without a
transport. All op functions still execute **inside the Tmux GenServer process** (load-bearing, see §4).

### 1. `Aiur.Tmux` (facade + GenServer) — stays at `src/lib/aiur/tmux.ex` — ~250 LOC
The single serializing GenServer and the sole public API. Keeps all 27 client functions (so the 8
existing caller modules — pane_manager, claude/repl_agent, opencode/{slot,hidden_window,attach_pool},
orchestrator, process_reaper, agent_list/app — and `tmux_test.exs` are untouched; no M-x-N call-site
fan-out). Cross-cutting work moves into a shared private `call/3` helper owning the
`catch :exit → {:error, :no_tmux} | {:error, :timeout}` wrapper once (currently duplicated 25×).
`init/1`, subscribe/DOWN bookkeeping, `session`, `default_session/0`, and thin `handle_call` dispatch
stay here. **Judgment call on the 200-line file norm**: ~200 of its lines are `@doc`/`@spec` public
contract, near-zero logic lines per function; splitting the API across domain facades would churn 8
caller modules and the characterization tests mid-refactor for no semantic gain.

Key functions kept: `start_link/1`, `command/3`, `session/1`, `subscribe_events/1`, all 24 domain
client stubs, `init/1`, all `handle_call`/`handle_info` heads (bodies become delegations), `call/3`
(new, private), `default_session/0`.

### 2. `Aiur.Tmux.Exec` — `src/lib/aiur/tmux/exec.ex` — ~150 LOC
One source of truth for how a tmux command is executed: socket flag injection, binary resolution +
`:persistent_term` cache, exec logging policy (normal debug-logged path vs the silent/redacted secret
path), exit-status handling incl. the "no server running" log demotion, and command-string → argv
splitting. Dispatches on `state.transport` (`:shell` vs `{:mock, pid}`), delegating the mock branch to
`MockTransport`.

Moves: `run_args/2`, `run_args_silent/2`, `run_command/2`, `tmux_executable/0`, `prepend_socket/1`,
`handle_tmux_exit/3`, `redact_subcommand/1`, `split_command/1` + `split_command_step/2` +
`start_quoted/2` + `continue_quoted/3`.

### 3. `Aiur.Tmux.MockTransport` — `src/lib/aiur/tmux/mock_transport.ex` — ~50 LOC
The test seam: emits `{:tmux_mock_out, command}` to the test pid and performs the blocking selective
receive of `{:tmux_mock_data, chunk}` with the 1s timeout, parsing `%begin`/`%end`/`%error` framing.
Documents (once) that the receive MUST run in the Tmux server process.

Moves: `receive_mock_response/0`, `parse_mock_response/1`, plus the mock clauses of
`run_command/2`/`run_args/2` collapsed into a single `request/2`.

### 4. `Aiur.Tmux.Input` — `src/lib/aiur/tmux/input.ex` — ~90 LOC
Keystroke and paste delivery into panes: literal send-keys, named-key sends (Enter/C-u/C-c/Escape),
and the paste-buffer path with its temp-file lifecycle and bracketed-paste (`-p`) semantics. The
detailed "why `-p` is load-bearing" doc moves here with the logic.

Moves (handle_call bodies): `send_keys_literal/3`, `send_enter/2`, `clear_input/2`,
`send_interrupt/2`, `send_escape/2`, `paste_text/3` (`paste_via_buffer/3`).

### 5. `Aiur.Tmux.Layout` — `src/lib/aiur/tmux/layout.ex` — ~160 LOC
Pane/window creation, movement, destruction, and layout application — including the no-server
`new-session` bootstrap fallback and kill-pane teardown idempotency.

Moves (handle_call bodies): `split_pane/6` (with the silent/select-pane policy), `respawn_pane/3`,
`new_hidden_window/3` + `bootstrap_window/3` + `no_server?/1`, `join_pane/3`, `move_pane_hidden/3`,
`move_pane_visible/3`, `kill_pane/2` (idempotent branch), `select_layout/3`.

### 6. `Aiur.Tmux.Query` — `src/lib/aiur/tmux/query.ex` — ~130 LOC
Read-only inspection of the tmux server: pane capture, pane pid, window/pane enumeration, geometry,
and self-pane resolution — plus their output parsers.

Moves (handle_call bodies): `capture_pane/2`, `pane_pid/2`, `list_windows/1` + `parse_window_line/1`,
`list_panes/2`, `window_size/2` + `parse_dims/1`, `window_for/2`, `resolve_self_pane/1`.

### 7. `Aiur.Tmux.Style` — `src/lib/aiur/tmux/style.ex` — ~50 LOC
Pane decoration: border status/format text (the secret-safe path — border text carries the RC session
URL and must only ever go through `Exec.run_args_silent/2`) and pane titles. Isolating this keeps the
"never log this value" invariant in one 50-line file with its security rationale.

Moves (handle_call bodies): `set_pane_border/3` (both clauses, unconditional-`:ok` semantics
preserved), `set_pane_title/3`.

**Totals:** ~880 LOC across 7 files (vs 1005 today; the delta is deduplicated catch-wrappers and
doc consolidation). `Aiur.Tmux.Protocol` (`src/lib/aiur/tmux/protocol.ex`, 183 LOC) is unchanged.

---

## 3. Extraction sequencing (strictly serialized waves; repo compiles + `mix test` green after each)

**Wave 1 — characterization tests only (0 source lines moved; ~250 test lines added).**
Close the pinning gaps listed in §4 before anything moves: `split_pane` (silent vs non-silent incl.
the `select-pane` follow-up and `-l N%` form), `respawn_pane`, `join_pane`, `select_layout`,
`window_size` + bad-dims errors, `window_for`, `resolve_self_pane` (TMUX_PANE set/unset/dead),
`list_windows` tab parsing incl. malformed lines, `send_keys_literal`/`send_enter`/`clear_input`/
`send_escape`, `command/3` quoted-token splitting, `set_pane_border` unconditional-`:ok` on tmux
error, `subscribe_events` + DOWN pruning. All via the existing `{:mock, pid}` transport pattern in
`src/test/aiur/tmux_test.exs`.

**Wave 2 — bottom layer: `Aiur.Tmux.Exec` + `Aiur.Tmux.MockTransport` (~250 lines moved).**
Move §G verbatim; `handle_call` bodies switch `run_args(state, args)` → `Exec.run_args(state, args)`.
Mechanical; no public API or test changes. The `:persistent_term` key changes module prefix (private
cache — invisible). Verify the mock receive still executes in the server process (it does: `Exec` runs
in the caller).

**Wave 3 — `Aiur.Tmux.Query` + `Aiur.Tmux.Style` (~190 lines moved).**
Move the 9 read-only handle_call bodies + parsers, and the two decoration ops. These have the fewest
timing hazards (no bootstrap fallback, no paste sequencing). Wave-1 tests plus existing border/title/
pane_pid/list_panes tests pin them.

**Wave 4 — `Aiur.Tmux.Layout` + `Aiur.Tmux.Input` (~260 lines moved).**
Move the mutation ops: split/respawn/new-window+bootstrap/join/move/kill/select-layout and the
send-keys/paste family incl. `paste_via_buffer`. Highest-risk wave; the bootstrap, kill-idempotency,
and paste-buffer tests from Wave 1 + existing tests must pass byte-identical on emitted command
strings.

**Wave 5 — facade thinning (~150 lines churned in `tmux.ex` only).**
Introduce the shared `call/3` catch helper across the 25 client stubs, collapse `handle_call` clauses
to one-liners, relocate long op docs next to their moved logic, leave one-line public `@doc`s.
No behavior change; diff is confined to `src/lib/aiur/tmux.ex`.

Every wave is a single reviewable ticket <=400 lines moved, and waves 2–5 each depend on the previous
wave landing (same file — no parallelism).

---

## 4. Risks: semantics that must be preserved verbatim

**Concurrency / ordering.**
- The single GenServer is the serialization point for *all* tmux I/O from 8 caller modules. Keystroke
  sequencing (paste → Enter; literal-keys → Enter) depends on FIFO handling in one process. Do not
  convert calls to casts, do not parallelize ops, do not move execution out of the server process.
  The RC prompt-submit paste race (hotspot row 8, "#373 paste"; `docs/refactor/research-history-hotspots.md`)
  is exactly this class: Enter racing an unlanded paste caused unsubmitted prompts and respawn loops.
- `MockTransport`'s selective `receive` blocks the server for up to 1s per command; tests rely on
  `{:tmux_mock_out, _}` being emitted *before* blocking and on `{:tmux_mock_data, _}` being sent to the
  **GenServer pid**. Extraction must keep the receive in the server process (plain function call, no Task).

**Error / degradation semantics.**
- Every client stub's `catch :exit {:noproc}/{:timeout} → {:error, :no_tmux}/{:error, :timeout}` is
  graceful degradation callers depend on when the tmux server dies mid-session; the shared helper in
  Wave 5 must reproduce it exactly (including `session/1` and `subscribe_events/1` differences —
  `session/1` has *no* catch today; don't add one).
- `kill_pane` "can't find pane" → `:ok` idempotency: teardown/reaper paths (hotspot §4 "tmux & process
  lifecycle orphaning", reaper friendly-fire #431/#495/#498) call it on already-dead panes.
- `new_hidden_window` → `bootstrap_window` fallback keyed on the exact "no server running" substring:
  the standalone/`--bg` first-REPL-spawn path. Hotspot row 13 (pane management, fixed 3× before root
  cause, #34→#51→#61→#77) shows this area regresses subtly; keep the substring match and the
  fallback-only-on-that-error shape.
- `handle_tmux_exit` log-level policy ("no server running" → debug, else warning) is behavior — it
  prevents 2s-tick log floods after the user kills the server.
- `set_pane_border` replies `:ok` even when tmux errors (results discarded). Callers assume this.

**Secrets.**
- The border text carries the RC session URL (capability token). It must only ever flow through
  `run_args_silent` (never `run_args`, whose debug log prints full argv). Keep the silent path a
  separate function — do not "simplify" into a `log?:` flag on `run_args` where a default could flip.
  `redact_subcommand` (first two tokens) is the only thing allowed in its error log.

**Env / config timing (hotspot §5 "env & config bleed", config caches #444/#582).**
- `prepend_socket` reads `AIUR_TMUX_SOCKET` **per invocation** — deliberately uncached (server can
  start before the wrapper exports the var; `pane_manager_live_test.exs:88` pins the comment's claim).
- `default_session` reads `AIUR_TMUX_SESSION` once at init; session name is per-instance identity
  (hotspot §6 identity collisions) — keep init-time capture, don't re-read.
- `tmux_executable`'s `:persistent_term` cache must survive the move (per-command `$PATH` walks would
  regress the hot per-slot liveness poll).

**tmux-version-sensitive argv (byte-exact command strings).**
- `split-window -l N%` (not deprecated `-p N`) for tmux 3.5 detached sessions; `-d` + skipped
  `select-pane` only when `silent: true` (focus stealing into hidden windows); `move-pane -d` vs
  `join-pane`/`move-pane` distinctions; `paste-buffer -p -d` bracketed paste (without `-p`, claude
  renders raw newlines and Enter inserts instead of submits — RC turn never starts). Wave-1 tests must
  assert exact emitted strings, as the existing tests do.

**Existing test pinning.**
- `src/test/aiur/tmux_test.exs` (375 lines, 17 tests): command framing + error surfacing, session,
  move_pane hidden/visible, border set/unset (incl. RC-URL delivery), pane title argv integrity,
  list_panes, new_hidden_window + no-server bootstrap, capture_pane, paste_text buffer lifecycle
  (temp-file content + cleanup + exact paste-buffer argv), kill_pane (incl. idempotent), send_interrupt,
  pane_pid ok/error.
- `src/test/aiur/tmux/protocol_test.exs` (148 lines): pins `Aiur.Tmux.Protocol` — untouched.
- `src/test/aiur/claude/repl_agent_test.exs`: drives a mock-transport Tmux instance; indirectly pins
  input-injection sequencing and window ops.
- `src/test/aiur/pane_manager_live_test.exs`: real tmux socket; pins per-invocation
  `AIUR_TMUX_SOCKET` handling and live split/kill behavior.
- `src/test/aiur/application_test.exs`: pins supervision-tree membership of `Aiur.Tmux`.

**Missing characterization coverage (closed in Wave 1).**
No direct tests exist for: `split_pane` (any variant), `respawn_pane`, `join_pane`, `select_layout`,
`window_size`/`parse_dims`, `window_for`, `resolve_self_pane`, `list_windows`/`parse_window_line`,
`send_keys_literal`, `send_enter`, `clear_input`, `send_escape`, `command/3` quoted-token splitting
(`split_command` quote-spanning edge cases), `set_pane_border` error tolerance, the
`:no_tmux_executable` path, `subscribe_events`/DOWN pruning.

**Flagged for later tickets (NOT this refactor — behavior-preserving pass keeps them).**
- `subscribers` MapSet is write-only: `subscribe_events/1` is called by PaneManager but nothing ever
  publishes to subscribers. Dead-ish state; removing it changes the public API surface — separate ticket.
- `parse_mock_response/1` re-implements `Aiur.Tmux.Protocol`'s `%begin/%end/%error` framing (one
  source-of-truth violation). Unifying changes test-visible timing (Protocol is stateful/line-buffered;
  mock is single-chunk) — separate ticket after decomposition lands.
