# Decomposition proposal: `src/lib/aiur/opencode/slot.ex` (1392 lines)

Behavior-preserving refactor plan for the Slot lifecycle GenServer. Follows the in-repo
decomposition house style (SlotPolicy extraction precedent; prewarm/attach simplification):
one source of truth per fact, pure policy functions over synchronous call chains, no fan-out,
the GenServer shell owns cross-cutting coordination while extracted modules stay thin, one
dependency direction (`Slot` → `Slot.*` leaf modules → existing collaborators; never back).

---

## 1. Function / responsibility census

Line ranges refer to the file as of branch `refactor-planning-prompt` (1392 lines total,
~330 of which are moduledoc/`@doc`/comments).

### A. Moduledoc, aliases, struct, types — lines 1–126 (~126 lines)
- Moduledoc state-machine narrative (1–56)
- Aliases + module attributes `@slots_topic`, `@hidden_split_percent`, `@default_poll_interval_ms 500`, `@poll_death_threshold 3` (58–83)
- `defstruct` — 17 fields incl. `generation`, `attached_identifiers`, `visible_identifier`, `poll_death_count`, `known_identifiers`, `pending_select`, `pending_attaches` (85–124)
- `@type status` (126)

### B. Public client API — lines 128–289 (~160 lines, mostly docs)
- `start_link/1` (131–134), `slots_topic/0` (138)
- `select/3` (156–162), `deselect/1` (169–173), `snapshot/1` (177–181)
- `attach/3` (202–207), `attach_many/3` (221–223, deliberately sequential — PR #83 SQLite contention)
- `set_visible/3` (247–252), `clear_visible/1` (265–270), `detach/2` (285–289)
- Every call wraps `GenServer.call` with `catch :exit` → `{:error, :no_slot}` / `{:error, :timeout}` / `:ok` mappings (pinned by `slot_test.exs`).

### C. Boot / ready continuations — lines 293–518 (~225 lines)
- `init/1` (294–315): `trap_exit`, `SlotRegistry.register_self/1`, `:ignore` on duplicate, `{:continue, :start_serve}`
- `handle_continue(:start_serve)` (318–395, ~78 lines): perf span in process dictionary (`Process.put(:slot_serve_span)`), identifier pre-seed `cond` (rebuild keeps `known_identifiers`, first boot polls orchestrator), `display_opt` derivation from `pending_select`, `File.mkdir_p` + `WorkspaceSetup.materialize_slot` + `Server.start_link/await_ready`, → `:attach_spawning` or `:failed`
- `handle_continue(:spawn_attach)` (397–408): fast path skips the throwaway no-session attach when `pending_select` is queued
- `mark_ready_pending_select/1` (410–419), `mark_ready_with_attach_pane/1` (421–456): hidden-window split, `ProcessReaper.register`, `{:slot_ready, _}` broadcast, GC kick, drain pendings
- Debug/pipe-pane capture: `maybe_start_pipe_pane/2` (462–478), `capture_pane_dump/1` (480–485), `pipe_pane_path/1` (487–488), `debug_mode?/0` (490–495), `dump_pipe_tail/1` (497–511) — AIUR_DEBUG-gated death forensics
- `maybe_run_session_gc/1` (513–518): slot 1 only, `Task.start(SessionGC.run/1)`

### D. `handle_call` clauses — lines 520–672 (~150 lines)
- `{:select, id}` ready/active + not-ready clauses (521–528)
- `{:attach, id}` (530–564): `:identifier_unknown` → reply error now, queue `pending_attaches`, `schedule_serve_rebuild`
- `{:set_visible, id}` (566–577): **fast path** — no-op returning existing `pane_id` when already visible-bound (warm-open hot path)
- `:clear_visible` (579–598), `{:detach, id}` (600–633, clears visibility if detaching the visible id), `:deselect` (635–656), `:snapshot` (658–672)

### E. `handle_info` — lines 674–758 (~85 lines)
- `:poll_session` active clause (675–737, ~62 lines): pane-death watchdog. `tmux display-message` probe; `@poll_death_threshold` consecutive-failure debounce; on death: capture dump, pipe tail, `ProcessReaper.unregister`, broadcast nil session/visible, → `:attach_spawning` respawn
- `:poll_session` stale-timer clause (739–743), `:rebuild_now` → `{:continue, :start_serve}` (745–749)
- `{:EXIT, server_pid, _}` → `:failed` (751–755); catch-alls (757–758)

### F. Terminate + writer reaping — lines 760–837 (~78 lines)
- `terminate/2` (761–790): `TokenRegistry.delete`, reap writers for `base_url`, stop server (noproc-tolerant), kill pane
- `terminate_pane_command/1` (795–799) — **public, test-pinned pure fn**
- `reap_writers_for_base_url/1` (807–815), `writers_for_base_url/2` (825–827) — **public, test-pinned pure fn (#372)**, `reap_session_writer/2` (829–837)

### G. Attach/select engine — lines 839–1131 (~290 lines)
- `do_attach/2` (841–859): already-attached / known / unknown cond
- `do_attach_known/2` (861–910): perf spans, `ensure_session_for`, state update, explicit NO leadoff render (race comment, 881–889)
- `ensure_session_for/2` (912–923): `SessionWriterRegistry.ensure` + `SessionWriter.await_replay(pid, 10_000)`
- `do_set_visible_call/3` (925–959): known → `do_select` + 3 broadcasts + `schedule_poll`; miss → `{:noreply, schedule_serve_rebuild(state, {from, id})}` (**deferred reply**)
- `do_select/2` (961–1020): ensure + replay with spans; replay failure surfaces as plain error (2026-05-22 wedge fix comment)
- `select_with_respawn/4` (1030–1063): respawn + full state transition to `:active`
- `respawn_attach_with_session/2` (1068–1116): kill old pane, `ProcessReaper` unregister/register, hidden-window split with `--session`
- `reflow_hidden_window/1` (1124–1131): `even-horizontal` layout, error-tolerant (pane-budget exhaustion fix)

### H. Identifier discovery + rebuild machinery — lines 1133–1298 (~165 lines)
- `identifier_known?/2` (1133–1135)
- `safely_list_active_identifiers/0` + `do_wait_for_active_identifiers/1` + `fetch_active_identifiers/0` (1144–1172): busy-wait up to 3 s (100 ms steps) for orchestrator agent list; rescue/catch → `[]`
- `drain_pending_select/1` (1178–1197): `do_select` + broadcasts + **`GenServer.reply(from, ...)`**
- `drain_pending_attaches/1` + `retry_pending_attach/2` (1205–1234): fire-and-forget retries
- `schedule_serve_rebuild/2` + `do_schedule_serve_rebuild/3` (1240–1298): reap writers on OLD base_url first (#372) → stop server → kill pane → delete token → `send(self(), :rebuild_now)` → state reset with `generation + 1`

### I. PubSub broadcasts — lines 1300–1338 (~40 lines)
- `broadcast_session_changed/2`, `broadcast_attach_added/2`, `broadcast_attach_removed/2` (1300–1322)
- `broadcast_visible_changed/3` (1330–1338): **also writes `SlotRegistry.update_pane_state` — must run inside the slot process** (Registry ownership; lock-free read path for PaneManager warm-open)

### J. Poll scheduling + misc — lines 1340–1392 (~52 lines)
- `schedule_poll/1` (1340–1352): cancels prior timer first (stacked-timer debounce-defeat fix), `cancel_poll/1` (1354–1359)
- `hidden_window_target/0` (1361–1380): `HiddenWindow.status()` + `:sys.get_state(HiddenWindow, 1_000)` introspection
- `workspace_path_for/1` (1382–1385), `process_name/1` (1387), `poll_interval_ms/0` (1389–1391, `Application.get_env(:aiur, :slot_poll_interval_ms, 500)`)

### Concern grouping summary

| Concern | Functions | Approx logic lines |
|---|---|---:|
| GenServer shell (API, callbacks, drains, timers) | B, D, E dispatch, `drain_*`, `schedule_poll`/`cancel_poll` | ~330 |
| Pure state transitions & decisions | struct, snapshot, `identifier_known?`, clear/detach/deselect/select transitions, poll-death counting, rebuild reset | ~170 |
| Serve-generation lifecycle | `start_serve` body, identifier pre-seed wait loop, rebuild teardown, terminate, writer reap, session GC | ~200 |
| tmux attach-pane surface | pane spawn/respawn, reflow, hidden-window target, probe, pipe-pane debug, `terminate_pane_command` | ~220 |
| Session ensure/replay | `ensure_session_for`, `do_select` writer half, spans | ~80 |
| Broadcasts + ETS mirror | I | ~40 |

---

## 2. Proposed module split (NAME MAP — contract for downstream tickets)

New submodules live under `src/lib/aiur/opencode/slot/` (namespace pattern
`Aiur.Opencode.Slot.*`, matching the repo's dir-per-namespace convention:
`aiur/agent_list/`, `aiur/opencode/`). Peer processes (`SlotPolicy`, `SlotRegistry`,
`SlotSupervisor`) stay flat siblings; only the Slot worker's own internals nest.
All extracted modules are **plain function modules — no new processes, no new GenServers,
no Tasks**. Every function documented "must run in the slot worker process" where
process identity matters.

| # | Module | Path | Responsibility | ~LOC | Key functions moving there |
|---|---|---|---|---:|---|
| 1 | `Aiur.Opencode.Slot` (stays, thinned) | `src/lib/aiur/opencode/slot.ex` | GenServer shell: public client API with exit-mapping, callback dispatch, deferred-reply + pending-drain coordination, `:rebuild_now` self-message, poll timers. | ~380 (≈200 logic) | `start_link/1`, all client API, `init/1`, thin `handle_call`/`handle_info`/`handle_continue` clauses, `drain_pending_select/1`, `drain_pending_attaches/1`, `retry_pending_attach/2`, `schedule_poll/1`, `cancel_poll/1`, `terminate/2`, `process_name/1`, `poll_interval_ms/0`; `defdelegate slots_topic/0` (→ Events), `terminate_pane_command/1` (→ AttachPane), `writers_for_base_url/2` (→ ServeLifecycle) for API/test stability |
| 2 | `Aiur.Opencode.Slot.State` | `src/lib/aiur/opencode/slot/state.ex` | The slot state struct plus pure transitions and queries — every state change is a pure function returning the new struct (+ event list where useful); no side effects. | ~170 | `defstruct` + `@type status`; `snapshot/1`; `identifier_known?/2`; transitions: `serve_ready/4`, `attach_pane_ready/2`, `select_applied/4` (from `select_with_respawn`'s state update), `clear_visible/1`, `detach/2`, `deselect/1`, `pane_died/1`, `record_poll/2` (→ `:alive` \| `{:retry, n}` \| `:dead`, owns `@poll_death_threshold`), `rebuild_reset/3` (generation bump + field reset from `do_schedule_serve_rebuild`), `queue_pending_attach/2`, pre-seed identifier decision `rebuild_seed_identifiers/1` + `display_opt/1` |
| 3 | `Aiur.Opencode.Slot.Events` | `src/lib/aiur/opencode/slot/events.ex` | Single point of truth for slot PubSub broadcasts and the SlotRegistry pane-state ETS mirror; owns `@slots_topic`. In-process contract: `visible_changed/3` MUST be called from the slot worker (Registry ownership). | ~70 | `slots_topic/0`, `session_changed/2`, `attach_added/2`, `attach_removed/2`, `visible_changed/3` (incl. `SlotRegistry.update_pane_state/3` mirror), `slot_ready/1` (broadcast + `Aiur.Perf.event(:slot_ready, ...)`) |
| 4 | `Aiur.Opencode.Slot.AttachPane` | `src/lib/aiur/opencode/slot/attach_pane.ex` | The slot's tmux attach-pane surface: spawn/respawn opencode-attach panes in the hidden window, reaper bookkeeping, liveness probe, and death forensics. | ~220 | `spawn/2` (from `mark_ready_with_attach_pane`'s tmux half), `respawn_with_session/3` (from `respawn_attach_with_session`), `kill/1`, `probe/1` (the `display-message` liveness check from `:poll_session`), `capture_death_evidence/2` (`capture_pane_dump` + `dump_pipe_tail`), `reflow_hidden_window/1`, `hidden_window_target/0`, `maybe_start_pipe_pane/2`, `pipe_pane_path/1`, `debug_mode?/0`, `terminate_pane_command/1` (pure, stays `def`) |
| 5 | `Aiur.Opencode.Slot.ServeLifecycle` | `src/lib/aiur/opencode/slot/serve_lifecycle.ex` | Boot, rebuild-teardown, and terminate of one opencode-serve *generation*: workspace materialization, Server start/await, orchestrator identifier pre-seed wait, token bookkeeping, SessionWriter reaping, boot-time session GC. | ~210 | `boot/3` (workspace mkdir + `WorkspaceSetup.materialize_slot` + `Server.start_link`/`await_ready`, perf span), `safely_list_active_identifiers/0` + `do_wait_for_active_identifiers/1` + `fetch_active_identifiers/0`, `teardown_generation/1` (ordered: reap writers → stop server → kill pane → delete token; from `do_schedule_serve_rebuild`), `terminate_cleanup/1` (from `terminate/2` body), `reap_writers_for_base_url/1`, `writers_for_base_url/2` (pure, stays `def`), `reap_session_writer/2`, `maybe_run_session_gc/1`, `workspace_path_for/1` |
| 6 | `Aiur.Opencode.Slot.Sessions` | `src/lib/aiur/opencode/slot/sessions.ex` | Ensure + replay an identifier's opencode session against this slot's serve — the SessionWriterRegistry/SessionWriter wrapper with its perf spans and replay-failure error mapping. | ~80 | `ensure/2` (from `ensure_session_for/2`), `ensure_with_replay_span/3` (the writer/replay half of `do_select/2` incl. the 2026-05-22 "surface as plain error" contract; 10 s replay timeout constant) |

Dependency direction (strict): `Slot` → {`State`, `Events`, `AttachPane`, `ServeLifecycle`, `Sessions`};
extracted modules never call `Slot` or each other, except `ServeLifecycle.teardown_generation/1`
→ `AttachPane.kill/1` (one edge, downward). `AttachPool`/`PaneManager`/`SlotPolicy` keep calling
only `Slot`'s public API and `Slot.slots_topic/0` — zero consumer changes.

What deliberately stays in the shell: `drain_pending_select` / `drain_pending_attaches`
(they sequence `Sessions` + `AttachPane` + `Events` + `GenServer.reply` — cross-cutting
coordination belongs to the base per house style), timer scheduling (`Process.send_after`
against `self()`), and the `send(self(), :rebuild_now)` re-entry.

Norm-target note: `slot.ex` lands at ~380 file lines, above the 200-line guide; ~180 of
those are `@doc`/moduledoc that constitute the public contract for AttachPool/PaneManager.
Logic lines land under 200 with every callback clause ≤ ~15 lines. Judged acceptable;
splitting the client API from the GenServer would fight Elixir/OTP convention.

---

## 3. Extraction sequencing (strictly serialized waves on this file)

Each wave: compile green + `mix test` green at the end; ≤400 lines moved; one reviewable
ticket. Waves 1→4 are ordered leaf-effects-first so each of waves 1–3 moves function
bodies verbatim, and the callback restructure (wave 4) happens only once the effect seams
are stable.

**Wave 0 — characterization (no production-code movement).**
Add tests pinning what `slot_test.exs` misses and is cheap to pin today:
`{:error, {:slot_not_ready, status}}` mapping for all calls in non-ready states (start a
Slot with an unreachable HiddenWindow so it parks in `:failed`), `snapshot/1` key set,
detach-idempotence, and the `set_visible` fast-path contract at the API-shape level.
Document (in the test module doc) the timing seams that CANNOT be pinned without a Tmux
injection seam (see risks). ~120 test lines. Verify: `mix test src/test/aiur/opencode/`.

**Wave 1 — extract `Slot.Events` (~70 lines moved).**
Move the four `broadcast_*` helpers + `@slots_topic` + the `{:slot_ready, _}` broadcast/perf
pair; `Slot.slots_topic/0` becomes a defdelegate. Purely mechanical; every call site inside
`slot.ex` renamed. Verify: full suite; `slot_test.exs` "PubSub event topology" and
`slots_topic/0` tests pass unchanged; grep confirms `SlotRegistry.update_pane_state` is
called only from `Events.visible_changed/3`.

**Wave 2 — extract `Slot.AttachPane` (~240 lines moved).**
Move pane spawn/respawn/kill/reflow/probe/pipe-pane/`hidden_window_target`/
`terminate_pane_command` verbatim; `slot.ex` keeps `terminate_pane_command/1` as
defdelegate so `slot_test.exs` is untouched. `mark_ready_with_attach_pane` and
`respawn_attach_with_session` in `slot.ex` shrink to `AttachPane.spawn/respawn_with_session`
calls plus state/broadcast handling. Add unit tests for `terminate_pane_command/1` (in new
home), `pipe_pane_path/1`, `debug_mode?/0`. Verify: full suite + a manual `aiurdev` open/
swap/Ctrl-C smoke per the manual-CLI-verification norm.

**Wave 3 — extract `Slot.ServeLifecycle` + `Slot.Sessions` (~290 lines moved).**
Move serve boot body, orchestrator wait loop, writer reaping (with `writers_for_base_url/2`
defdelegate kept on `Slot`), `teardown_generation/1` (preserving the exact reap→stop→
kill-pane→delete-token order), `terminate_cleanup/1`, session GC, and the session
ensure/replay wrapper. `handle_continue(:start_serve)`, `do_schedule_serve_rebuild`, and
`terminate/2` become thin. Add unit tests: `writers_for_base_url/2` (moved copy),
pre-seed decision table (rebuild keeps known ids; empty first boot polls), teardown
ordering via a call-recording seam if cheap. Verify: full suite + `slot_test.exs`
`writers_for_base_url` tests pass via delegate.

**Wave 4 — extract `Slot.State` and thin the callbacks (~200 lines moved/rewritten).**
Move the struct + all pure transitions; rewrite each `handle_call`/`handle_info` clause as
decide (`State.*`) → effect (`AttachPane`/`Sessions`/`ServeLifecycle`) → announce
(`Events`) → reply. Land the new `state_test.exs` in the same ticket pinning:
poll-death `record_poll/2` debounce (0→1→2→dead at 3; reset on success), `rebuild_reset/3`
generation bump + field-reset table, detach-clears-visible, deselect/clear_visible
equivalence, `select_applied` field set, pre-seed/`display_opt` decisions. This is the
highest-risk wave and goes last, when it is the only change in flight on the file.
Verify: full suite + manual dogfood smoke (open, swap identifiers on one slot to force an
identifier-miss rebuild, kill an attach pane to exercise the watchdog respawn).

Total moved ≈ 800 production lines across four serialized tickets, each ≤400.

---

## 4. Risks — semantics to preserve verbatim, and test coverage

### Concurrency / state / timing invariants (must survive byte-for-byte in behavior)

1. **Registry write ownership (single source of truth).** `Events.visible_changed/3` writes
   `SlotRegistry.update_pane_state/3`; `Registry.update_value` requires the calling process
   to be the registrant. All extracted modules must remain plain in-process function calls —
   introducing any Task/GenServer hop here breaks the PaneManager lock-free warm-open path
   silently (writes no-op or raise). Same constraint for `Process.put(:slot_serve_span)`
   perf-span bookkeeping and `Process.send_after(self(), ...)`.
2. **Pane-death watchdog debounce.** `@poll_death_threshold 3` consecutive failures before
   teardown (lines 675–737), AND `schedule_poll/1` cancel-before-reschedule (1340–1352) —
   the comment documents that stacked timers defeat the debounce and false-teardown the
   slot. `State.record_poll/2` must keep both counting and the reset-on-success.
3. **Rebuild teardown ordering (#372).** `do_schedule_serve_rebuild/3` (1253–1298): reap
   writers on the OLD `base_url` first (so `DELETE /session` reaches a still-live serve) →
   stop server → kill pane (bounded hidden-window pane budget; leak = `no space for new
   pane` wedge) → delete token → `send(self(), :rebuild_now)` → reset state with
   `generation + 1`. `ServeLifecycle.teardown_generation/1` must keep this exact order;
   the `:rebuild_now` send stays in the shell so mailbox ordering (reply this dispatch,
   rebuild next dispatch) is unchanged.
4. **Token generation overlap.** Old token deleted at teardown; tokens are keyed
   `{slot_index, generation}` and `delete_stale/2` runs only after the new attach is ready
   (moduledoc 49–56) so chat-completions never observe an empty registry window.
5. **Deferred replies.** Identifier-miss `set_visible`/`select` returns `{:noreply, ...}`
   and stores `{from, identifier}`; `drain_pending_select/1` calls `GenServer.reply/2` after
   the rebuilt slot reaches `:ready`. `pending_attaches` is the opposite contract: caller
   already got `{:error, :identifier_unknown}`, drain is fire-and-forget. Do not unify them.
6. **`set_visible` fast path.** Same-identifier + binary pane_id returns the existing pane
   with no respawn (566–573) — PaneManager's "instant open" depends on it; and the
   `/tui/select-session` HTTP path must NOT be reintroduced (opencode 1.15.6 kills the
   attach seconds after 200 — moduledoc 30–34, comments 925–935).
7. **Blocking init pre-seed.** `safely_list_active_identifiers/0` busy-waits ≤3 s inside
   `handle_continue(:start_serve)`. It is intentionally synchronous (pre-seed eliminates
   the ~6 s identifier-miss rebuild on first open); moving it must not make it async.
8. **`attach_many/3` stays sequential** (SQLite contention under parallel replay, PR #83).
9. **No leadoff render inside `do_attach_known`** — the comment at 881–889 records a real
   multi-slot leadoff race; the AttachPool drives `set_visible` deterministically. Keep the
   absence of the side effect.
10. **Failure containment.** `{:EXIT, server_pid, _}` → `:failed` without crashing;
    replay failure surfaces as a plain error, not a MatchError (2026-05-22 wedge, 987–1008);
    `init` duplicate registration → `:ignore`; `terminate/2` tolerates noproc on server stop
    but must still reap the pane.
11. **`hidden_window_target/0` uses `:sys.get_state(HiddenWindow, 1_000)`** — fragile
    introspection; preserve verbatim in `AttachPane` and flag as a follow-up (out of scope
    for the behavior-preserving pass).

### Hotspot-map context (`docs/refactor/research-history-hotspots.md`)

Row 5 puts `src/lib/aiur/opencode/` at ~17 incidents — warm-marker/attach races under
multi-agent load, `:emfile` fan-out (#409/PR #457), the slot-display TOCTOU chain
(#372 → PR #607 → #608), and the warm-pool fix chain PR #65→#74→#83→#96. Cross-cutting
theme 1 ("timing and submission races — anything that sends then assumes needs an explicit
ack") is exactly this file's watchdog/rebuild/drain seams, and theme 10 warns that
guards/filters (the debounce, the fast path, the known-identifier gate) clip legitimate
cases on first rewrite. The map's characterization priority list names this file explicitly
(item 6: `slot.ex` et al. — "warm-marker lifecycle, attach/reclaim under churn, FD-budget
invariants"). Row 13 (tmux pane management, ~6 incidents, #34→#51→#61→#77 slot-cycling
chain) borders wave 2. Conclusion: waves 2 and 4 are the caution-spend; move bodies
verbatim and keep every inline race comment with its code.

### Existing test pinning and coverage gaps

Pinned today:
- `src/test/aiur/opencode/slot_test.exs` (127 lines) — dead-pid/exit mapping for the whole
  client API, `terminate_pane_command/1`, `writers_for_base_url/2` (#372 reap selection),
  `slots_topic/0` stability, event tuple shapes (broadcast manually, not produced by a
  live slot). API-edge only; **no live slot is ever started**.
- `slot_supervisor_test.exs`, `slot_policy_test.exs`, `attach_pool_test.exs`,
  `slot_registry_test.exs` — pin neighbors (acquire/grow, warm-pool policy, registry
  lookups), not Slot's internals. `no_leaks_test.exs` pins `Protocol.opencode_json/1`, not Slot.

Missing characterization (none of the following is executed by any test):
the `:booting → serve_starting → attach_spawning → ready → active` transitions; the
poll-death debounce and watchdog respawn; identifier-miss rebuild end-to-end (generation
bump, token delete, pending_select reply, pending_attaches retry); detach-clears-visible
broadcast set and ordering; `set_visible` fast path vs cross-identifier respawn; terminate
reap ordering; the orchestrator pre-seed wait. Root cause of the gap: `slot.ex` hardcodes
the `Tmux` GenServer name (calls `Tmux.command(Tmux, ...)`) and the `HiddenWindow`/
`Server`/`WorkspaceSetup` collaborators, so a live-slot test needs the world. The
decomposition itself is the mitigation: after wave 4, the transitions, the debounce
counter, the reap selection, the pre-seed decision, and the teardown ordering are pure or
seam-isolated and unit-testable; wave 0 pins what is reachable today, and each wave lands
its moved-function tests in the same ticket. If the plan wants live-slot characterization
before wave 2, the cheapest seam is threading a tmux server name through Slot opts
(defaulted to `Tmux`) — a 3-line, behavior-neutral change, but it is a production-code
edit and should be its own micro-ticket ahead of wave 2.
