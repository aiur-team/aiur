# T-046: opencode slot: State, Events, AttachPane, ServeLifecycle, Sessions; slim

**Phase:** 4
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/opencode/slot.ex` is a 1,392-line GenServer that mixes six concerns:
GenServer shell (client API, callbacks, timers, pending-drain coordination), pure state
transitions, serve-generation lifecycle (boot/rebuild/terminate/writer-reap), the tmux
attach-pane surface (spawn/respawn/probe/forensics), session ensure/replay, and PubSub
broadcasts with an ETS mirror. The decomposition contract is
`docs/refactor/research-arch/giant-slot.md` (the binding name map, §2) and its risks
section (§4) names concurrency/timing invariants that must survive byte-for-byte.

This ticket performs the whole decomposition in a single wave: extract
`Aiur.Opencode.Slot.State`, `.Events`, `.AttachPane`, `.ServeLifecycle`, and `.Sessions`
under `src/lib/aiur/opencode/slot/`, and slim the `Aiur.Opencode.Slot` GenServer to a
shell that delegates to them. Behavior-preserving only: public function signatures,
return values, broadcast shapes/ordering, and all timing semantics are unchanged. The
characterization suite under `src/test/aiur/regression/` (warm markers, attach fan-out,
FD/shutdown census) must pass unmodified.

## Scope (exact)

Line numbers below refer to `src/lib/aiur/opencode/slot.ex` at the current tip of the
`v2` base (1,392 lines; verify with `wc -l` before starting — if the line count differs
by more than a handful of lines, stop and comment on the issue).

General rules for every step (no exceptions, no improvisation):

- Move function bodies **verbatim** — copy/paste including every inline comment
  (the race/incident comments are part of the contract). Do not rewrite, reorder
  keyword lists, rename log fields, or "simplify".
- Extracted modules are **plain function modules**: no `use GenServer`, no `Agent`, no
  new Tasks, no processes. The only `Task.start` allowed in `src/lib/aiur/opencode/slot/`
  is the one moved verbatim inside `maybe_run_session_gc/1`.
- Dependency direction (strict): `Slot` → {`State`, `Events`, `AttachPane`,
  `ServeLifecycle`, `Sessions`}. Extracted modules never call `Slot` or each other,
  with exactly one allowed edge: `ServeLifecycle` → `AttachPane.kill/2`.
- Every new module gets `@moduledoc` and `@spec` on every public `def`.
- Timer semantics: `State` transitions set `poll_ref: nil` and NEVER touch timers. The
  shell (`slot.ex`) calls `cancel_poll/1` on the old ref **before** applying any State
  transition that clears `poll_ref` — otherwise stacked `Process.send_after` timers
  defeat the poll-death debounce (giant-slot.md §4 risk 2).
- `Process.put`/`Process.get(:slot_serve_span)`, `Process.send_after(self(), ...)`,
  `send(self(), :rebuild_now)`, and `Events.visible_changed/3` must keep executing in
  the slot worker process. All extracted calls are plain in-process function calls, so
  this holds automatically — do not introduce any process hop.
- After each numbered step: `mix compile --warnings-as-errors` and `mix test` from
  `src/` must be green before starting the next step. Remove `alias` entries in
  `slot.ex` that the compiler flags as unused after each move.

### Step 1 — create `Aiur.Opencode.Slot.Events` (`src/lib/aiur/opencode/slot/events.ex`)

1. Move `@slots_topic "opencode:slots"` (line 80) into `Events`. Public
   `def slots_topic, do: @slots_topic`.
2. Move these four private helpers (lines 1300–1338) verbatim, renamed to public defs:
   - `broadcast_session_changed/2` → `session_changed/2`
   - `broadcast_attach_added/2` → `attach_added/2`
   - `broadcast_attach_removed/2` → `attach_removed/2`
   - `broadcast_visible_changed/3` → `visible_changed/3` — this one INCLUDES the
     `SlotRegistry.update_pane_state(slot_index, identifier_or_nil, pane_id_or_nil)`
     mirror write (line 1331). Its `@doc` must state: "Must be called from the slot
     worker process — `Registry.update_value/2` only succeeds for the registrant."
3. Add `slot_ready/1`: body is exactly
   `Phoenix.PubSub.broadcast(Aiur.PubSub, @slots_topic, {:slot_ready, slot_index})`
   followed by `Aiur.Perf.event(:slot_ready, slot: slot_index)`. Replace the three
   inline broadcast+perf pairs in `slot.ex` (lines 413–414, 438–439, 648–649) with
   `Events.slot_ready(state.slot_index)`.
4. In `slot.ex`: add `alias Aiur.Opencode.Slot.Events`, add
   `defdelegate slots_topic, to: Events`, delete `@slots_topic`, and rename every
   remaining `broadcast_*` call site to `Events.session_changed/attach_added/`
   `attach_removed/visible_changed` (call sites are in the `handle_call` clauses,
   `:poll_session`, `do_set_visible_call/3`, and `drain_pending_select/1`).

### Step 2 — create `Aiur.Opencode.Slot.AttachPane` (`src/lib/aiur/opencode/slot/attach_pane.ex`)

Move `@hidden_split_percent 50` (line 81) here. Public API (all `@spec`ed):

1. `terminate_pane_command/1` — move lines 792–799 verbatim (comment, `@spec`, both
   clauses; stays `def`). In `slot.ex` keep
   `defdelegate terminate_pane_command(state), to: AttachPane` so
   `src/test/aiur/opencode/slot_test.exs` passes untouched.
2. `spawn(slot_index, base_url)` — the tmux half of `mark_ready_with_attach_pane/1`
   (lines 422–433 plus the `Aiur.ProcessReaper.register(:agent, {:pane, pane_id})` at
   436): `hidden_window_target()` → `reflow_hidden_window(keep_alive_pane)` →
   `attach_cmd = Protocol.attach_command(base_url)` → `Tmux.split_pane(Tmux,
   keep_alive_pane, :horizontal, @hidden_split_percent, attach_cmd, silent: true)` →
   `ProcessReaper.register` → `{:ok, pane_id}`. On any `with` miss, return the failing
   term unchanged (the shell logs it).
3. `respawn_with_session(state, session_id, attach_cmd)` — move `respawn_attach_with_session/2`
   (lines 1068–1116) verbatim EXCEPT: the
   `attach_cmd = Protocol.attach_command(state.base_url, session_id)` line (1084) does
   NOT move — `attach_cmd` becomes the third parameter. Accesses only `state.slot_index`
   and `state.pane_id` (plain map access; works for any map with those keys). Keeps the
   perf span, the kill-old-pane block (with `ProcessReaper.unregister`), reflow, split,
   register, pipe-pane, and the `{:error, :respawn_failed}` mapping — all verbatim.
   Reason: `src/test/aiur/regression/chat_pane_loads_session_test.exs` pins the literal
   source pattern `Protocol.attach_command(state.base_url, session_id)` **inside
   slot.ex** — that call must stay in the shell (see Step 6.4).
4. `kill(pane_id, opts \\ [])` — new small function:
   when `Keyword.get(opts, :unregister, true)` is true, call
   `Aiur.ProcessReaper.unregister({:pane, pane_id})` first; then
   `_ = Tmux.command(Tmux, "kill-pane -t #{pane_id}")`; returns `:ok`.
5. `probe(pane_id)` — the liveness probe from `:poll_session` (line 683 + case head):
   `Tmux.command(Tmux, "display-message -p -t #{pane_id} \#{pane_id}")`; returns
   `:alive` on `{:ok, [^pane_id | _]}`, else `{:missing, raw_result}`. Move the
   tmux-returns-empty-under-load comment (677–682) with it.
6. Move verbatim, public: `capture_pane_dump/1` (480–485), `dump_pipe_tail/1`
   (497–511), `maybe_start_pipe_pane/2` (458–478, both clauses + comment),
   `pipe_pane_path/1` (487–488), `debug_mode?/0` (490–495),
   `reflow_hidden_window/1` (1118–1131, with its pane-budget comment),
   `hidden_window_target/0` (1361–1380 — preserve the `:sys.get_state(HiddenWindow,
   1_000)` introspection verbatim; giant-slot.md §4 risk 11). These two realize the
   name map's `capture_death_evidence/2` as two functions so the shell preserves the
   exact log-line ordering of the death path.

### Step 3 — create `Aiur.Opencode.Slot.ServeLifecycle` (`src/lib/aiur/opencode/slot/serve_lifecycle.ex`)

Public API:

1. `boot(state, agent_ids, display_opt)` — the effectful body of
   `handle_continue(:start_serve, ...)` (lines 319–321 and 356–377, plus the failure
   `Logger.warning` at 391): perf `span_begin(:slot_start_serve, ...)` +
   `Process.put(:slot_serve_span, ...)`, `bridge_url` construction, `File.mkdir_p`,
   `WorkspaceSetup.materialize_slot(state.workspace_path, bridge_url, agent_ids,
   state.slot_index, state.generation, display_opt)`, `Server.start_link(%{identifier:
   "_slot-#{state.slot_index}", workspace: state.workspace_path})`,
   `Server.await_ready(server_pid)`, the `phase=serve_ready` log and span_end/delete —
   all verbatim. Returns `{:ok, server_pid, base_url, token}` on success; on any `with`
   miss, emit the `phase=serve_failed` warning verbatim and return `{:error, reason}`
   with the failing term. Reads only `state.workspace_path`, `state.slot_index`,
   `state.generation` (map access).
2. Move `@orchestrator_wait_budget_ms 3_000`, `@orchestrator_poll_interval_ms 100`, and
   `safely_list_active_identifiers/0` + `do_wait_for_active_identifiers/1` +
   `fetch_active_identifiers/0` (lines 1137–1172) verbatim, with the comment block;
   `safely_list_active_identifiers/0` becomes public, the other two stay `defp`. The
   busy-wait stays synchronous (giant-slot.md §4 risk 7 — do NOT make it async).
3. `teardown_generation(state)` — the teardown half of `do_schedule_serve_rebuild/3`
   (lines 1253–1278), preserving this exact order and every comment (#372; giant-slot.md
   §4 risk 3): `reap_writers_for_base_url(state.base_url)` → stop server
   (`GenServer.stop(state.server_pid, :normal, 1_000)` guarded by
   `is_pid/Process.alive?`) → `if is_binary(state.pane_id), do: AttachPane.kill(state.pane_id, unregister: false)`
   (this is the rebuild-path kill at 1274–1276, which today does NOT unregister the
   reaper entry — `unregister: false` preserves that) → `if is_binary(state.token), do:
   TokenRegistry.delete(state.token)`. Returns `:ok`. The `send(self(), :rebuild_now)`
   does NOT move — it stays in the shell (mailbox ordering).
4. `terminate_cleanup(state)` — the body of `terminate/2` (lines 761–789) verbatim:
   token delete → `reap_writers_for_base_url(state.base_url)` → noproc-tolerant
   `try do GenServer.stop(state.server_pid) catch :exit, _ -> :ok end` →
   `if is_binary(state.pane_id), do: AttachPane.kill(state.pane_id)` (unregister
   defaults true — identical to today's unregister + `kill-pane -t`). Returns `:ok`.
5. Move verbatim: `reap_writers_for_base_url/1` (801–815, `defp`, with comment),
   `writers_for_base_url/2` (817–827, stays public `def` with its `@doc`/`@spec`),
   `reap_session_writer/2` (829–837, `defp`), `maybe_run_session_gc/1` (513–518, both
   clauses, becomes public — the shell calls it on ready), `workspace_path_for/1`
   (1382–1385, becomes public — the shell calls it in `init/1`).
6. In `slot.ex` keep
   `defdelegate writers_for_base_url(entries, base_url), to: ServeLifecycle` so
   `slot_test.exs`'s `#372` reap-selection tests pass untouched.

### Step 4 — create `Aiur.Opencode.Slot.Sessions` (`src/lib/aiur/opencode/slot/sessions.ex`)

Module attribute `@replay_timeout_ms 10_000`. Public API:

1. `ensure(identifier, base_url)` — from `ensure_session_for/2` (912–923) verbatim,
   with `state.base_url` replaced by the `base_url` parameter and the `10_000` literal
   replaced by `@replay_timeout_ms`. Returns `{:ok, session_id} | {:error, reason}`.
2. `ensure_with_replay_span(identifier, base_url, slot_index)` — the writer/replay half
   of `do_select/2` (lines 968–1018, everything except the `:slot_do_select` span and
   the `select_with_respawn` call): `SessionWriterRegistry.ensure(identifier,
   base_url)`; on `{:ok, %{session_id: session_id, writer_pid: writer_pid}}` begin the
   `:session_writer_await_replay` span (kwlist verbatim, `slot: slot_index`), call
   `SessionWriter.await_replay(writer_pid, @replay_timeout_ms)`;
   - `:ok` → end the replay span (success kwlist verbatim) and return `{:ok, session_id}`;
   - `{:error, reason}` → end the replay span with the `result: :failed` kwlist verbatim
     (keep the 2026-05-22 wedge comment: replay failure surfaces as a plain error, never
     a MatchError) and return `{:replay_failed, reason}`;
   - registry `{:error, _} = err` → return `{:writer_failed, err}`.

### Step 5 — create `Aiur.Opencode.Slot.State` (`src/lib/aiur/opencode/slot/state.ex`)

All functions pure (no side effects, no logging, no PubSub, no timers). Move
`@poll_death_threshold 3` (line 83) here.

1. Move the `defstruct` (85–124, with every field comment) and
   `@type status` (126) verbatim; add `@type t :: %__MODULE__{}`.
2. `new(slot_index, workspace_path)` → `%__MODULE__{slot_index: slot_index, status:
   :booting, workspace_path: workspace_path}` (from `init/1` lines 302–306).
3. `snapshot(state)` → the reply map from lines 660–671 verbatim.
4. `identifier_known?(state, identifier)` → move 1133–1135 verbatim, public.
5. `rebuild_seed_identifiers(state)` → from the `cond` at 333–343 (keep the pre-seed
   comment 323–332): returns `{:known, MapSet.to_list(state.known_identifiers)}` when
   `state.pending_select != nil` OR `MapSet.size(state.known_identifiers) > 0`;
   otherwise `:poll_orchestrator` (the shell then calls
   `ServeLifecycle.safely_list_active_identifiers/0`).
6. `display_opt(state)` → the `case` at 350–354 verbatim (keep comment 345–349).
7. `serve_ready(state, server_pid, base_url, token, agent_ids)` → the struct update at
   379–386 verbatim (status `:attach_spawning`, `known_identifiers: MapSet.new(agent_ids)`).
8. `attach_pane_ready(state, pane_id)` → `%{state | status: :ready, pane_id: pane_id}`
   (from 417 and 448; `pane_id` may be nil on the pending_select fast path).
9. `select_applied(state, identifier, session_id, pane_id)` → the struct update at
   1042–1052 verbatim (status `:active`, visible/active fields, `attached_identifiers`
   put, `pane_id`).
10. `queue_pending_attach(state, identifier)` → the update at 544–548 verbatim
    (`known_identifiers` put + `pending_attaches` put).
11. `clear_visible(state)` → the update at 584–592 with `poll_ref: nil` instead of
    `poll_ref: cancel_poll(...)` (the shell cancels the timer first — see Step 6).
12. `detach(state, identifier)` → from 600–622: returns `:not_attached` when
    `identifier` is not in `attached_identifiers`; otherwise
    `{clears_visible? :: boolean(), new_state}` where `new_state` has the identifier
    removed from `attached_identifiers` and, when it was the `visible_identifier`, also
    the visible/active fields nil'd, `status: :ready`, `poll_ref: nil`.
13. `deselect(state)` → the update at 636–644 with `poll_ref: nil`.
14. `record_poll(state, probe_result)` — owns the debounce (giant-slot.md §4 risk 2):
    - `record_poll(state, :alive)` → `{:alive, %{state | poll_death_count: 0}}`
    - `record_poll(state, {:missing, raw})` → `bumped = state.poll_death_count + 1`;
      if `bumped >= @poll_death_threshold` → `{:dead, bumped, raw, state}` (count NOT
      persisted; the shell applies `pane_died/1` after forensics), else
      `{:retry, bumped, raw, %{state | poll_death_count: bumped}}`.
15. `pane_died(state)` → the reset at 720–730 verbatim (status `:attach_spawning`, all
    pane/visible/active fields nil, `poll_ref: nil`, `poll_death_count: 0`).
16. `rebuild_reset(state, pending, next_known)` → the struct update at 1284–1297 with
    `poll_ref: nil` instead of the inline `cancel_poll` (shell cancels first): status
    `:booting`, `generation: state.generation + 1`, `known_identifiers: next_known`,
    `pending_select: pending`, server/base_url/token/pane/active fields nil.
17. `poll_death_threshold/0` → `@poll_death_threshold` (the shell's
    `phase=poll_pane_missing` log line interpolates it).

### Step 6 — slim the `Aiur.Opencode.Slot` shell (`src/lib/aiur/opencode/slot.ex`)

Keep in the shell, unchanged in name and signature: the moduledoc, `start_link/1`,
`process_name/1`, the entire public client API with its `catch :exit` mappings
(`select/3`, `deselect/1`, `snapshot/1`, `attach/3`, `attach_many/3` — stays
sequential, PR #83 —, `set_visible/3`, `clear_visible/1`, `detach/2`), `init/1`,
`drain_pending_select/1`, `drain_pending_attaches/1`, `retry_pending_attach/2`,
`schedule_poll/1` + `cancel_poll/1` + `@default_poll_interval_ms` + `poll_interval_ms/0`,
`terminate/2`, and the three defdelegates (`slots_topic/0`, `terminate_pane_command/1`,
`writers_for_base_url/2`). Add
`alias Aiur.Opencode.Slot.{AttachPane, Events, ServeLifecycle, Sessions, State}`.

Rewrite the callback clauses as thin decide→effect→announce sequences, preserving
every log line, perf event, broadcast, and their relative order:

1. `init/1`: build the struct via `%State{slot_index: slot_index, status: :booting,
   workspace_path: ServeLifecycle.workspace_path_for(slot_index)}` (or `State.new/2`);
   `trap_exit`, `SlotRegistry.register_self/1`, duplicate → `:ignore` — all unchanged.
2. `handle_continue(:start_serve, state)`:
   `agent_ids = case State.rebuild_seed_identifiers(state) do {:known, ids} -> ids;
   :poll_orchestrator -> ServeLifecycle.safely_list_active_identifiers() end`;
   `display_opt = State.display_opt(state)`;
   `case ServeLifecycle.boot(state, agent_ids, display_opt)`:
   `{:ok, server_pid, base_url, token}` → `{:noreply, State.serve_ready(state,
   server_pid, base_url, token, agent_ids), {:continue, :spawn_attach}}`;
   `{:error, _}` → `{:noreply, %{state | status: :failed}}`.
3. `handle_continue(:spawn_attach, state)` and `mark_ready_pending_select/1` unchanged
   except `Events.slot_ready/1`, `ServeLifecycle.maybe_run_session_gc/1`, and
   `State.attach_pane_ready(state, nil)` replace the inlines.
   `mark_ready_with_attach_pane/1` becomes:
   `case AttachPane.spawn(state.slot_index, state.base_url)`:
   `{:ok, pane_id}` → `phase=ready` log (verbatim) → `Events.slot_ready` →
   `AttachPane.maybe_start_pipe_pane(state.slot_index, pane_id)` →
   `ServeLifecycle.maybe_run_session_gc(state)` (keep the boot-GC comment 443–445) →
   `ready_state = State.attach_pane_ready(state, pane_id)` →
   `{:noreply, ready_state |> drain_pending_select() |> drain_pending_attaches()}`;
   error → `phase=attach_failed` warning (verbatim) → `{:noreply, %{state | status: :failed}}`.
4. `select_with_respawn/4` stays in the shell. Its first line MUST be
   `attach_cmd = Protocol.attach_command(state.base_url, session_id)` (literal — pinned
   by `chat_pane_loads_session_test.exs`), then
   `case AttachPane.respawn_with_session(state, session_id, attach_cmd)`; success arm:
   `phase=select` log + `span_end` kwlists verbatim, return
   `{:ok, session_id, State.select_applied(state, identifier, session_id, new_pane_id)}`;
   error arm verbatim. Keep the `/tui/select-session` prohibition comment block
   (1022–1029) attached to this function — and never add any code path calling
   `ApiClient.select_session` or `/tui/select-session` anywhere (FI-OC-049).
5. `do_select/2` stays: begin `:slot_do_select` span; `case
   Sessions.ensure_with_replay_span(identifier, state.base_url, state.slot_index)`:
   `{:ok, session_id}` → `select_with_respawn(state, identifier, session_id,
   do_select_span)`; `{:replay_failed, reason}` → `span_end` with the
   `result: :replay_failed` kwlist (verbatim from 1001–1006), return `{:error, reason}`;
   `{:writer_failed, err}` → `span_end` with the `result: :writer_failed` kwlist
   (verbatim from 1012–1016), return `err`.
6. `do_attach/2` and `do_attach_known/2` stay; `ensure_session_for/2` is deleted and
   its call site becomes `Sessions.ensure(identifier, state.base_url)`. Keep the
   NO-leadoff-render comment block (881–889) exactly where it is (giant-slot.md §4
   risk 9 — the absence of the side effect is the feature).
7. `do_set_visible_call/3` stays (broadcast trio via `Events.*`,
   `State.identifier_known?/2`, `schedule_serve_rebuild/2` on miss with the
   `phase=identifier_miss` log + perf event verbatim). The `set_visible` fast-path
   clause (566–573) stays byte-identical (giant-slot.md §4 risk 6).
8. `handle_call(:clear_visible, ...)`: when `state.visible_identifier` is set →
   `Events.visible_changed(state.slot_index, nil, state.pane_id)`, then
   `_ = cancel_poll(state.poll_ref)`, then `State.clear_visible(state)`; else `state`.
   Reply `:ok`.
9. `handle_call({:detach, identifier}, ...)`: `case State.detach(state, identifier)`:
   `:not_attached` → `{:reply, :ok, state}`; `{clears_visible?, new_state}` → when
   `clears_visible?`, `Events.visible_changed(new_state.slot_index, nil,
   new_state.pane_id)` and `_ = cancel_poll(state.poll_ref)`; then
   `Events.attach_removed(state.slot_index, identifier)`, the `phase=detach` log and
   `:slot_attach_removed` perf event verbatim, `{:reply, :ok, new_state}`.
10. `handle_call(:deselect, ...)` (`:active` clause): `_ = cancel_poll(state.poll_ref)`;
    `new_state = State.deselect(state)`; then `Events.session_changed(state.slot_index,
    nil)`, `Events.visible_changed(state.slot_index, nil, state.pane_id)`,
    `Events.slot_ready(state.slot_index)`, the `phase=deselect` log; reply `:ok`.
    Non-active clause unchanged.
11. `handle_call(:snapshot, ...)` → `{:reply, State.snapshot(state), state}`.
12. `handle_call({:attach, identifier}, ...)` `:identifier_unknown` branch: `new_state =
    State.queue_pending_attach(state, identifier)`; keep the comment (538–543), the
    `:slot_attach_rebuild_scheduled` perf event, and the
    `schedule_serve_rebuild(new_state, state.pending_select)` reply line verbatim.
13. `handle_info(:poll_session, %{status: :active, pane_id: pane_id} = state) when
    is_binary(pane_id)`:
    `case State.record_poll(state, AttachPane.probe(pane_id))`:
    - `{:alive, new_state}` → `{:noreply, schedule_poll(new_state)}`
    - `{:retry, bumped, raw, new_state}` → the `phase=poll_pane_missing` log verbatim
      (interpolating `bumped` and `State.poll_death_threshold()`, `poll_result=#{inspect(raw)}`)
      → `{:noreply, schedule_poll(new_state)}`
    - `{:dead, bumped, raw, _state}` → the `phase=poll_pane_missing` log first (as
      today, every failed attempt logs it), then in this exact order:
      `capture_dump = AttachPane.capture_pane_dump(pane_id)` → `phase=pane_died`
      warning (verbatim kwlist incl. `capture_at_death`) → `Aiur.Perf.event(:slot_poll_pane_died, ...)`
      (verbatim) → `AttachPane.dump_pipe_tail(state.slot_index)` →
      `Aiur.ProcessReaper.unregister({:pane, pane_id})` (keep the respawn comment
      711–713) → `Events.session_changed(state.slot_index, nil)` →
      `Events.visible_changed(state.slot_index, nil, nil)` (keep the pane-dead comment)
      → `{:noreply, State.pane_died(state), {:continue, :spawn_attach}}`.
    The stale-timer clause (739–743), `:rebuild_now` (745–749), both `{:EXIT, ...}`
    clauses (751–757), and the catch-all stay verbatim.
14. `schedule_serve_rebuild/2` (both clauses, 1240–1251) stays; `do_schedule_serve_rebuild/3`
    becomes: `ServeLifecycle.teardown_generation(state)` → `_ = cancel_poll(state.poll_ref)`
    → `send(self(), :rebuild_now)` (keep the mailbox-ordering comment 1280–1281) →
    `State.rebuild_reset(state, pending, next_known)`.
15. `terminate/2` → `def terminate(_reason, state), do: ServeLifecycle.terminate_cleanup(state)`.
16. Update `drain_pending_select/1` / `retry_pending_attach/2` broadcast calls to
    `Events.*`; their structure, `GenServer.reply/2`, and fire-and-forget semantics are
    unchanged (giant-slot.md §4 risk 5 — do NOT unify the two pending mechanisms).
17. Delete every moved function/attribute from `slot.ex`; remove unused aliases.

### Step 7 — tests for every extracted module (same ticket; new modules are NOT coverage-exempt)

Create exactly these files:

1. `src/test/aiur/opencode/slot/state_test.exs` (`async: true`) — pin:
   `record_poll/2` debounce (alive resets count; missing → retry 1, retry 2, dead at 3;
   alive after 2 misses resets to 0); `rebuild_reset/3` (generation bump, all reset
   fields nil, `pending_select`/`known_identifiers` stored, `poll_ref: nil`);
   `detach/2` (`:not_attached`; detach of non-visible attached id → `{false, _}` keeps
   visible fields; detach of the visible id → `{true, _}` clears visible/active +
   `status: :ready`); `clear_visible/1` and `deselect/1` field sets;
   `select_applied/4` field set (status `:active`, MapSet put, pane_id);
   `queue_pending_attach/2`; `attach_pane_ready/2` (with pane id and with nil);
   `serve_ready/5` (known_identifiers from agent_ids); `snapshot/1` exact key set;
   `identifier_known?/2`; `rebuild_seed_identifiers/1` decision table (pending_select
   set → `{:known, ...}`; known non-empty → `{:known, ...}`; both empty →
   `:poll_orchestrator`); `display_opt/1` (pending → `[display_identifier: id]`, nil →
   `[]`).
2. `src/test/aiur/opencode/slot/events_test.exs` (`async: false`) — subscribe to
   `Events.slots_topic()`; assert `session_changed/2`, `attach_added/2`,
   `attach_removed/2`, `slot_ready/1` produce exactly `{:slot_session_changed, i, id}`,
   `{:slot_attach_added, i, id}`, `{:slot_attach_removed, i, id}`, `{:slot_ready, i}`.
   For `visible_changed/3`: call `SlotRegistry.register_self(97)` from the test process
   (unused high index), call `Events.visible_changed(97, "issue-x", "%5")`, assert the
   `{:slot_visible_changed, 97, "issue-x"}` broadcast AND that
   `SlotRegistry.pane_state(97)` reflects identifier `"issue-x"` and pane `"%5"` (read
   `src/lib/aiur/opencode/slot_registry.ex:52-81` for the exact return shape).
3. `src/test/aiur/opencode/slot/attach_pane_test.exs` (`async: false`, env mutation) —
   `terminate_pane_command/1` (both clauses, same cases as `slot_test.exs`);
   `pipe_pane_path/1` returns `"/tmp/aiur-debug/slot-<n>-attach.log"`; `debug_mode?/0`
   for `AIUR_DEBUG` in `"1"/"true"/"yes"/"0"/unset` (restore env in `on_exit`).
4. `src/test/aiur/opencode/slot/serve_lifecycle_test.exs` (`async: true`) —
   `writers_for_base_url/2` (same two cases as `slot_test.exs`, in the new home);
   `workspace_path_for/1` ends with `".local/share/aiur/opencode-slot-<n>"`;
   `maybe_run_session_gc/1` returns `:ok` for a non-slot-1 state (no Task fired).
5. `src/test/aiur/opencode/slot/sessions_test.exs` (`async: false`) — `ensure/2` and
   `ensure_with_replay_span/3` against an unreachable serve
   (`"http://127.0.0.1:1"`) return an error tuple (`{:error, _}` /
   `{:writer_failed, {:error, _}}`) and do not raise.

Do NOT add any of the five new modules to `ignore_modules` in `src/mix.exs`
(the exemption list only shrinks; `Aiur.Opencode.Slot` itself stays listed — do not
remove or add entries).

## Files

- Create: `src/lib/aiur/opencode/slot/state.ex`, `src/lib/aiur/opencode/slot/events.ex`, `src/lib/aiur/opencode/slot/attach_pane.ex`, `src/lib/aiur/opencode/slot/serve_lifecycle.ex`, `src/lib/aiur/opencode/slot/sessions.ex`
- Modify: `src/lib/aiur/opencode/slot.ex`
- Test: `src/test/aiur/opencode/slot/state_test.exs`, `src/test/aiur/opencode/slot/events_test.exs`, `src/test/aiur/opencode/slot/attach_pane_test.exs`, `src/test/aiur/opencode/slot/serve_lifecycle_test.exs`, `src/test/aiur/opencode/slot/sessions_test.exs`

## Out of scope

- Peer modules stay untouched: `slot_policy.ex`, `slot_registry.ex`,
  `slot_supervisor.ex`, `attach_pool.ex`, `hidden_window.ex`, `token_registry.ex`,
  `server.ex`, `workspace_setup.ex`, `protocol.ex`, `session_writer*.ex`,
  `session_gc.ex`, `api_client.ex`, `chat_completions.ex`, `pane_manager.ex`, `tmux.ex`.
- `src/test/aiur/opencode/slot_test.exs` — must pass byte-identical (the defdelegates
  exist for it). Every file under `src/test/aiur/regression/` — never edited.
- No behavior, API, log-line, perf-event, or broadcast-shape changes; no renaming of
  the `opencode:slots` topic or event tuples; no new config options.
- No new processes/GenServers/Tasks; no async-ifying the orchestrator pre-seed wait;
  no replacing the `:sys.get_state(HiddenWindow, 1_000)` introspection; no reintroducing
  `/tui/select-session`; no parallelizing `attach_many/3`.
- `src/mix.exs` (including `ignore_modules`), CI workflows, docs, website.

## Inventory-IDs

- FI-EVT-110 — PubSub topic `opencode:slots` and its event tuples (moves to `Slot.Events`; shapes unchanged).
- FI-OC-049 — `/tui/select-session` prohibition; every swap = kill-pane + respawn `attach --session` (respawn moves to `Slot.AttachPane`; the `Protocol.attach_command(state.base_url, session_id)` call stays in `slot.ex`).
- FI-OC-051 — boot-time SessionGC fired by the first slot to reach `:ready` (moves to `Slot.ServeLifecycle.maybe_run_session_gc/1`).
- FI-OC-006 — token generation-overlap restart ordering (the slot-side put→boot→attach-ready→delete order is preserved across `ServeLifecycle.boot/teardown_generation` and `State.rebuild_reset`).
- FI-ART-024 — slot workspace materialization + token registration per `{slot, generation}` (call site moves into `ServeLifecycle.boot/3`; `workspace_path_for/1` moves to `ServeLifecycle`).
- FI-ART-031 — AIUR_DEBUG pipe-pane capture to `/tmp/aiur-debug/slot-<n>-attach.log` (moves to `Slot.AttachPane`).

## Characterization-tests

- `src/test/aiur/regression/chat_pane_loads_session_test.exs` — pins that `slot.ex` source retains `Protocol.attach_command(state.base_url, session_id)` and never calls `/tui/select-session` / `ApiClient.select_session`.
- `src/test/aiur/regression/warm_marker_semantics_test.exs`
- `src/test/aiur/regression/warm_state_transitions_test.exs`
- `src/test/aiur/regression/warm_attach_open_test.exs`
- `src/test/aiur/regression/attach_fanout_cap_test.exs` — FD-budget/fan-out census.
- `src/test/aiur/regression/shutdown_cleanup_test.exs` — teardown/reap census.
- `src/test/aiur/regression/shared_prewarm_e2e_test.exs`
- `src/test/aiur/regression/parallel_pre_warm_test.exs`
- `src/test/aiur/regression/enter_opens_new_pane_test.exs`
- `src/test/aiur/regression/done_agent_detach_test.exs`
- `src/test/aiur/regression/prewarm_complete_time_test.exs`
- `src/test/aiur/regression/pane_attach_queue_test.exs`

Plus the API-pinning unit suite `src/test/aiur/opencode/slot_test.exs` (not in
regression/, but treat it the same: pass unmodified).

## Acceptance criteria

- All five new lib files and all five new test files exist at the exact paths in Files.
- `grep -q "defmodule Aiur.Opencode.Slot.State" src/lib/aiur/opencode/slot/state.ex` (and the analogous grep for Events, AttachPane, ServeLifecycle, Sessions in their files) all succeed.
- `wc -l src/lib/aiur/opencode/slot.ex` ≤ 550 (from 1,392).
- Each new lib file ≤ 200 lines by `awk '!/^[[:space:]]*(#|$)/' <file> | wc -l`; every function in the new modules and every rewritten callback clause in `slot.ex` ≤ 20 logic lines (a multi-line literal/keyword-list argument counts as one).
- `grep -q 'Protocol\.attach_command(state\.base_url, session_id)' src/lib/aiur/opencode/slot.ex` succeeds.
- `grep -rn "select_session\|tui/select-session" src/lib/aiur/opencode/slot.ex src/lib/aiur/opencode/slot/` matches only comments (no code path).
- `grep -c "defdelegate" src/lib/aiur/opencode/slot.ex` == 3 (`slots_topic`, `terminate_pane_command`, `writers_for_base_url`).
- `grep -c "Phoenix.PubSub.broadcast" src/lib/aiur/opencode/slot.ex` == 0; `grep -rln "update_pane_state" src/lib/aiur/opencode/ | grep -v slot_registry.ex` prints exactly `src/lib/aiur/opencode/slot/events.ex`.
- `grep -rn "use GenServer\|use Agent\|GenServer.start" src/lib/aiur/opencode/slot/` has no matches; `grep -rn "Task.start\|Task.async" src/lib/aiur/opencode/slot/` matches only inside `maybe_run_session_gc` in `serve_lifecycle.ex`.
- `grep -L "@moduledoc" src/lib/aiur/opencode/slot/*.ex` prints nothing; every public `def` in the five new modules has an adjacent `@spec`.
- `grep -rn "Slot.State\|Slot.Events\|Slot.AttachPane\|Slot.ServeLifecycle\|Slot.Sessions" src/mix.exs` has no matches (new modules are NOT coverage-exempt).
- `git diff --name-only` contains only the files listed under Files (in particular: nothing under `src/test/aiur/regression/`, and `src/test/aiur/opencode/slot_test.exs` and `src/mix.exs` unmodified).
- `mix test test/aiur/regression test/aiur/opencode` (from `src/`) green; full `mix test` green.

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

- Diff review: extracted bodies are verbatim moves (compare side-by-side); every inline race/incident comment (#372 teardown order, PR #83 sequential attach_many, no-leadoff-render, stacked-timer debounce, `/tui/select-session` prohibition, 2026-05-22 replay wedge) survived next to its code.
- Live `aiurdev` smoke on `v2` (executors cannot run this; reviewer does): open a warm agent's chat pane — Check: opens sub-second via the `set_visible` fast path (perf log shows no `placeholder_spawn`); swap a different identifier onto the same slot — Check: `phase=identifier_miss` rebuild completes and the pane rebinds (generation bump in logs, caller unblocked); `tmux kill-pane` the visible attach pane — Check: `phase=poll_pane_missing attempt=1/3 … 3/3` then `phase=pane_died` and the pane respawns (no false teardown on a single missed poll); quit aiur — Check: `pgrep -af 'opencode serve'` shows no orphan serves (FI-OC-050 probe).
- Check: `grep aiur_perf` on the run's logs still shows `slot_start_serve`, `slot_ready`, `slot_do_select`, `session_writer_await_replay`, `slot_respawn_attach` spans/events.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
