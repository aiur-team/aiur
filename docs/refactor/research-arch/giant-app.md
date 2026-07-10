# Decomposition proposal: `src/lib/aiur/agent_list/app.ex` (1587 lines)

Behavior-preserving refactor of the agent-list TUI GenServer. House style applied: pure
policy/fold modules extracted from the GenServer; the GenServer stays the single process
and single owner of state; one dependency direction (`App` → policy modules → leaf
predicates; no module calls back into `App`); no M×N fan-out (each PubSub stream gets one
intake module, not one module per field).

Repo root: `/home/orangekid/github/aiur`. All paths below are repo-relative.

---

## 1. Function / responsibility census

Line ranges from the current file (branch `refactor-planning-prompt`).

| # | Concern | Lines | ~Size | Functions |
|---|---------|-------|------:|-----------|
| A | Module header: moduledoc, aliases, dialyzer suppressions, tick/cap constants, `@type state` | 1–63 | 63 | — |
| B | Public API (client-side; called by `Input` and supervisor) | 66–130 | 65 | `start_link/1`, `select_previous/1`, `select_next/1`, `activate/1`, `activate_new_pane/1`, `attach_selected/1`, `toggle_pause/1`, `toggle_remote_control/1`, `adjust_max_concurrent_agents/2`, `quit/1` (bypasses GenServer → `Aiur.Shutdown.shutdown(0)`), `toggle_help/1`, `toggle_layout_orientation/1`, `snapshot/1` |
| C | `init/1`: PubSub subscription wiring, giant state-map literal (with load-bearing field comments), tick scheduling, first render, boot perf event | 134–293 | 160 | `init/1` |
| D | `handle_call`/`handle_cast` user-action dispatch | 295–381 | 87 | `:snapshot`, `:select_previous`, `:select_next`, `:activate`, `:activate_new_pane`, `:attach_selected`, `:toggle_pause`, `:toggle_remote_control`, `{:adjust_max_concurrent_agents, delta}`, `:toggle_help`, `:toggle_layout_orientation` |
| E | Activation / open / attach orchestration (gates + `Task.start`-wrapped PaneManager effects) | 383–530 | 148 | `activate_selected_agent/2`, `activate_selected_agent_if_warm/4`, `reactivate_and_open/4`, `log_reactivate_result/2`, `open_selected_agent/4`, `do_open/5` (×2), `has_parallel_headroom?/2`, `warm_identifier?/2`, `attach_selected_agent/1`, `attempt_attach_then_open/4` |
| F | RC pane-border reconciliation (#13): pure diff + tmux apply | 532–606 | 75 | `reconcile_rc_pane_borders/1`, `safe_list_open_panes/1`, `rc_border_changes/3` (public, `@doc false`, unit-tested directly), `rc_border_text/1` (×2) |
| G | `handle_info` PubSub intake (19 message families) | 608–906 | 299 | `{:prewarm_phase, _}` 613–625; **`{:running_changed, summaries}` 627–718 (~92, largest single function)**; `{:agent_chat_active, _}` 724–732; `{:status_changed, pane_opened/pane_closed/other}` 741–757; `{:slot_session_changed, _}` 759–770; `{:slot_ready/:slot_starting, _}` 772–786; `{:poll_state_changed, _}` 788–790; `{:alert, _}` 792; `:clear_max_agents_alert` 794–798; `:clear_remote_control_hint` 800–804; `:refresh_tick` 806–810; `:geometry_tick` 812–826; `{:attach_state_changed, _}` 828–833; `{:slot_fully_warmed/:slot_warmth_dropped, _}` 835–845; ignore clauses (`:attach_failed`, `:attach_consumed`, `:slot_attach_added/removed`) 847–859; `{:slot_visible_changed, _}` 861–871; `{:aiur_perf, _}` 873–885; `{:event_debug, _}` 887–904; catch-all 906 |
| H | `terminate/2` | 908–912 | 5 | `terminate/2` |
| I | Event-stream fold helpers (mostly pure) | 918–1125 | 208 | `refresh_open_attentions/1`, `attention_count_for/1` (reads `SubscriptionStore.snapshot/1`); progress ratchet: `record_progress_sample/2`, `parse_progress_topic/1`, `maybe_push_progress/4`, `accept_progress?/3`, `head_percent/1`, `progress_percent/1`; phase tracking: `record_phase/2`, `parse_phase_topic/1`, `phase_atom/1`, `edge_atom/1`; Latest column: `record_latest_event/2`, `extract_ticket_id/1`, `event_message/2`, `topic_verb/1`; debug footer: `update_perf_summary/2` (×4), `absorb_warmth_event/2` (×2) |
| J | Scheduling / env / AttachPool seed guards | 1127–1157 | 31 | `schedule_refresh_tick/0`, `schedule_geometry_tick/0`, `warm_status_dark_mode_default/0`, `safely_seed_attach_pool/2`, `debug_env?/0` |
| K | User-action internals: resume/adjust result handling, pause toggle, RC toggle + hints, deactivated-progress seeding | 1161–1331 | 171 | `handle_resume_result/2`, `handle_max_adjust_result/2`, `ring_bell/1`, `schedule_max_agents_alert_clear/0`, `paused_summary?/1`, `deactivated_summary?/1`, `seed_deactivated_progress_samples/2`, `maybe_seed_deactivated_sample/3`, `head_at_100?/1`, `toggle_selected_agent_pause/1`, `toggle_agent_pause/2` (×3), `toggle_selected_agent_remote_control/1`, `toggle_agent_remote_control/2` (×2), `handle_remote_control_result/2` (×6), `remote_control_on_summary?/1`, `rc_hint/2`, `schedule_remote_control_hint_clear/0` |
| L | Selection ring + visible ordering (pure) | 1335–1435 | 101 | `move_selection/2`, `chip_entry_index/2`, `at_edge?/3`, `clamp_selection/1`, `visible_summaries/1`, `emoji_sort_key/1` (×3), `identifier_sort_key/1` (×3) |
| M | Prewarm boot snapshot | 1439–1450 | 12 | `initial_prewarm_state/0`, `prewarm_status/0` |
| N | `render/1` + render_state assembly (the curated `Map.take`/`Map.put` pipeline) + header queries + terminal probes | 1452–1587 | 136 | `render/1`, `project_label/0`, `dashboard_url/0`, `agent_kind/0`, `active_agent_count/1`, `max_agents_from_state/1` (**comment at 1537–1541: do NOT reintroduce a blocking Orchestrator call**), `safe_call/1`, `truecolor_supported?/0`, `terminal_geometry/0`, `parse_int/2`, `default_command_template/0` |

Cross-cutting observations:

- `paused_summary?/deactivated_summary?/remote_control_on_summary?` are used from four
  concerns (running_changed fold, pause toggle, RC toggle, render count) — they are the
  shared leaf and must be extracted first.
- Every field in the state map has exactly one writer clause, so per-stream fold modules
  can own their fields without overlap — except `visible_sessions`, written identically by
  both `{:slot_session_changed, ...}` and `{:slot_visible_changed, ...}` (two topics, same
  fold; one intake module removes the duplication).
- The only public non-GenServer function is `rc_border_changes/3` (already the house-style
  "pure policy" shape; `app_test.exs:541–601` calls it directly).

---

## 2. Proposed module split (NAME MAP — contract for downstream tickets)

Namespace: everything stays under `Aiur.AgentList.*` in `src/lib/aiur/agent_list/`
(matching `Input`/`Renderer` siblings and the `Aiur.Opencode.SlotPolicy`,
`Aiur.PaneManager.Layout` precedent of policy modules living beside their process module).

Dependency direction (strict, one-way):

```
Input ─► App (GenServer shell)
          ├─► State            (construction only)
          ├─► Selection ────────► Summaries (leaf)
          ├─► Roster ───────────► Summaries
          ├─► EventIntake       (leaf)
          ├─► PerfIntake        (leaf)
          ├─► WarmthIntake      (leaf)
          ├─► RcPaneBorders     (→ PaneManager, Tmux)
          ├─► Activation ───────► Summaries   (→ PaneManager, Orchestrator, Perf via Task)
          ├─► Controls ─────────► Summaries   (→ Orchestrator)
          └─► RenderState ──────► Summaries, Renderer inputs (→ Tracker/Config/HttpServer reads)
```

| Module | File (new) | Responsibility (one sentence) | ~LOC | Key functions that move |
|--------|-----------|-------------------------------|-----:|------------------------|
| `Aiur.AgentList.App` *(retained, slimmed)* | `src/lib/aiur/agent_list/app.ex` | GenServer shell: public API, subscription wiring, message intake with ≤5-line delegating clauses, tick scheduling, and the `render/1` glue (`write_fun.(Renderer.render(RenderState.build(state)))`). | ~380 | census B, C (reduced), D, G (clause heads only), H, J-scheduling |
| `Aiur.AgentList.State` | `src/lib/aiur/agent_list/state.ex` | Owns the state typespec and `new/1` — builds the initial state map (all field defaults + their load-bearing doc comments) from opts, probed geometry, and the boot prewarm snapshot. | ~150 | state literal from `init/1`, `@type state`, `debug_env?/0`, `warm_status_dark_mode_default/0`, `initial_prewarm_state/0`, `prewarm_status/0`, cap constants (`@warmth_event_cap`/`@debug_event_cap` move with their consumers — see PerfIntake/EventIntake) |
| `Aiur.AgentList.Summaries` | `src/lib/aiur/agent_list/summaries.ex` | Pure summary-level policy: visible filtering/ordering, sort keys, work-state predicates, active count, and the visible/slot/retain id-set derivation. | ~130 | `visible_summaries/1`, `emoji_sort_key/1`, `identifier_sort_key/1`, `paused?/1` (was `paused_summary?`), `deactivated?/1`, `remote_control_on?/1` (was `remote_control_on_summary?`), `active_agent_count/1`, new `id_sets/1` extracted from the three filter/map chains in `{:running_changed, ...}` (lines 646–670) |
| `Aiur.AgentList.Selection` | `src/lib/aiur/agent_list/selection.ex` | Pure selection-ring navigation across agent rows and the max-agents chip (the documented ring invariant), plus clamping after roster changes. | ~70 | `move_selection/2`, `chip_entry_index/2`, `at_edge?/3`, `clamp_selection/1` |
| `Aiur.AgentList.Roster` | `src/lib/aiur/agent_list/roster.ex` | Fold of a `:running_changed` broadcast into state: apply visible ordering, clamp selection, compact per-id maps to the visible set, refresh attention counts, seed synthetic 100% samples for `:deactivated` rows; returns `{state, slot_ids, retain_ids}` so App performs the AttachPool seed effect. | ~140 | body of `handle_info({:running_changed, ...})` (627–713), `refresh_open_attentions/1`, `attention_count_for/1`, `seed_deactivated_progress_samples/2`, `maybe_seed_deactivated_sample/3`, `head_at_100?/1` |
| `Aiur.AgentList.EventIntake` | `src/lib/aiur/agent_list/event_intake.ex` | Pure fold of `{:event_debug, entry}` DebugLog broadcasts into per-row display state: Latest column, source-aware progress ratchet, active-phase tracking, and the debug-event ring. | ~200 | `fold/2` (new entry point wrapping the 887–904 body), `record_latest_event/2`, `extract_ticket_id/1`, `event_message/2`, `topic_verb/1`, `record_progress_sample/2`, `parse_progress_topic/1`, `maybe_push_progress/4`, `accept_progress?/3`, `head_percent/1`, `progress_percent/1`, `record_phase/2`, `parse_phase_topic/1`, `phase_atom/1`, `edge_atom/1`, `@debug_event_cap` |
| `Aiur.AgentList.PerfIntake` | `src/lib/aiur/agent_list/perf_intake.ex` | Pure fold of `{:aiur_perf, event}` into the 3-slot debug footer summary and the warmth-event ring, reporting whether the footer changed (render gate). | ~70 | `fold/2` (new, wraps 873–883 body returning `{state, render?}`), `update_perf_summary/2` (×4), `absorb_warmth_event/2` (×2), `@warmth_event_cap` |
| `Aiur.AgentList.WarmthIntake` | `src/lib/aiur/agent_list/warmth_intake.ex` | Pure folds of slot/attach/pane-visibility signals into the glyph-state fields (⏳/🔘/⚪/🟢): `visible_sessions`, `started_slots`, `fully_warmed_slots`, `attach_state`, `opened_panes`, `agents_with_content` — one home for the marker state machine currently smeared across ten `handle_info` clauses. | ~110 | folds for `:slot_session_changed`/`:slot_visible_changed` (deduplicated), `:slot_ready`, `:slot_starting`, `:slot_fully_warmed`, `:slot_warmth_dropped`, `:attach_state_changed`, `:status_changed` pane_opened/pane_closed, `:agent_chat_active` |
| `Aiur.AgentList.RcPaneBorders` | `src/lib/aiur/agent_list/rc_pane_borders.ex` | RC session-URL pane-border surfacing (#13): pure `changes/3` diff (currently `App.rc_border_changes/3`) plus the thin reconcile that lists open panes and applies only changed borders via tmux. | ~90 | `reconcile/1` (was `reconcile_rc_pane_borders/1`), `changes/3` (was `rc_border_changes/3`, keeps its `@spec` and tests), `border_text/1` (was `rc_border_text/1`), `safe_list_open_panes/1` |
| `Aiur.AgentList.Activation` | `src/lib/aiur/agent_list/activation.ex` | Enter/Shift+Enter/O/`a` handling: pure open-decision gates (deactivated→reactivate, warm gate, headroom gate) plus the `Task.start`-wrapped PaneManager open/attach-with-fallback effects — never blocking the App process. | ~170 | `activate_selected/2` (was `activate_selected_agent/2` + `_if_warm/4`), `reactivate_and_open/4`, `log_reactivate_result/2`, `open_selected_agent/4`, `do_open/5`, `has_parallel_headroom?/2`, `warm_identifier?/2`, `attach_selected/1` (was `attach_selected_agent/1`), `attempt_attach_then_open/4`, `default_command_template/0` |
| `Aiur.AgentList.Controls` | `src/lib/aiur/agent_list/controls.ex` | Space/`r`/←→ agent-control actions: pause/resume/start-queued, remote-control toggle with result→hint translation, max-agents adjust, and the bell/alert/hint transient-state helpers (documented as must-run-in-the-App-process because of `Process.send_after(self(), ...)`). | ~170 | `toggle_pause/1` (was `toggle_selected_agent_pause/1` + `toggle_agent_pause/2`), `toggle_remote_control/1` (was `toggle_selected_agent_remote_control/1` + `toggle_agent_remote_control/2`), `handle_resume_result/2`, `handle_max_adjust_result/2`, `handle_remote_control_result/2` (×6), `rc_hint/2`, `ring_bell/1`, `schedule_max_agents_alert_clear/0`, `schedule_remote_control_hint_clear/0` |
| `Aiur.AgentList.RenderState` | `src/lib/aiur/agent_list/render_state.ex` | Assembles the curated renderer input map (the `Map.take`/`Map.put` pipeline — the #414/#473/#730 hotspot seam) plus the non-blocking header queries and terminal probes; the one place a new state field must be threaded to become visible. | ~160 | `build/1` (was the body of `render/1` minus the write), `project_label/0`, `dashboard_url/0`, `agent_kind/0`, `max_agents_from_state/1` (with its do-not-reintroduce-blocking-call comment), `safe_call/1`, `truecolor_supported?/0`, `terminal_geometry/0`, `parse_int/2` |

Total: ~1470 LOC across 11 new files + ~380 LOC retained shell (growth over 1587 is
moduledocs/specs). Every new module is ≤200 lines; `App` stays above the 200-line target
because 19 `handle_info` clause heads plus 13 public API functions are irreducible for a
single GenServer — each clause body shrinks to ≤5 delegating lines, which is the norm that
matters here.

Naming notes: `Input` and `Renderer` are untouched. `quit/1`, `snapshot/1`, and all
Input-dispatched public functions remain on `App` (Input→App surface is pinned by
`input_test.exs` and must not move). `snapshot/1` keeps returning the flat state map —
tests assert on its keys; converting to a struct is explicitly out of scope for the
behavior-preserving pass.

---

## 3. Extraction sequencing (waves; strictly serialized on this file)

Every wave: compile clean, `mix test` green, ≤400 lines moved, one reviewable ticket.
Waves 1–5 each modify `app.ex` and must land in order (no parallel tickets on this file).

- **Wave 0 — characterization (no code moved).** Add the missing pins before touching
  anything (see §4): (a) render-state key-threading test — assert every renderer-consumed
  state field appears in the `render/1` output map (hotspot doc §"Densest characterization
  coverage" item 10 and theme 9); (b) `:running_changed` → `AttachPool.seed/3` derivation
  test via a seedable seam (slot_ids exclude paused+deactivated; retain_ids are paused
  non-deactivated) — currently untested because `safely_seed_attach_pool` rescues into
  `:ok` when AttachPool isn't running; (c) `:geometry_tick` reflow (no-op when unchanged,
  re-render on change). Verify: new tests pass against the unmodified file.
- **Wave 1 — pure leaves: `Summaries` + `Selection` (~210 lines moved).** Move predicates,
  ordering, id-set derivation, and the selection ring; `App` delegates. No test edits —
  `app_test.exs` ring/ordering tests and `regression/agent_list_sort_test.exs` drive via
  the GenServer. Verify: full agent_list + regression suites green.
- **Wave 2 — stream folds: `EventIntake` + `PerfIntake` (~280 moved).** `handle_info`
  clauses for `:event_debug`/`:aiur_perf` become one-line delegations; preserve the
  aiur_perf render gate (render only when the footer summary changed). Pins:
  `app_progress_ratchet_test.exs`, `app_phase_tracking_test.exs`,
  `app_debug_events_persistence_test.exs`, `debug_events_ticker_test.exs`.
- **Wave 3 — `RenderState` + `State` (~310 moved).** `render/1` becomes glue; `init/1`
  becomes subscriptions + `State.new/1` + ticks + first render. The Wave-0 key-threading
  test must pass unchanged against `RenderState.build/1`. Pins: `prewarm_render_test.exs`,
  `renderer_test.exs` (indirect), startup render test.
- **Wave 4 — `Roster` + `WarmthIntake` (~260 moved).** Preserve the exact
  `:running_changed` order: visible ordering → selection clamp → derive id sets → seed
  AttachPool (effect stays in App, fed by Roster's return) → compact per-id maps → RC
  border reconcile → render. Pins: deactivated-visibility describe block, Wave-0 seed test,
  `regression/warm_marker_semantics_test.exs` (non-skipped cases).
- **Wave 5 — `Activation` + `Controls` + `RcPaneBorders` (~380 moved).** Largest wave and
  the only one touching effect timing; keep every `Task.start` boundary and
  `Process.send_after(self(), ...)` call site semantically identical. One mechanical test
  edit: `app_test.exs` `rc_border_changes/3` describe block re-points to
  `RcPaneBorders.changes/3` (pure function, assertions unchanged). Pins: F1
  responsiveness test, pause/resume/queued tests, RC-toggle describe block,
  `regression/enter_opens_new_pane_test.exs`.

Rationale for the order: pure leaves first (zero timing risk, builds the shared
vocabulary), stream folds second (message-driven tests pin them tightly), the hotspot
render seam third under a fresh characterization net, and the effectful/timing-sensitive
action code last, when the rest of the file is already quiet.

---

## 4. Risks

### Concurrency / state / timing semantics to preserve verbatim

1. **Render must never block.** `max_agents_from_state/1` reads only the cached
   `poll_state` broadcast; the previous synchronous `Orchestrator.max_concurrent_agents`
   call froze arrow-key input for up to 5 s during poll cycles (comment at app.ex:1528–1541
   explicitly forbids reintroducing it). Same class for `poll_state` itself (state comment
   at 197–205). `RenderState`'s header queries (`project_label/dashboard_url/agent_kind`)
   are wrapped in `safe_call/1` and must stay tolerant of dead processes.
2. **All PaneManager opens/attaches run in `Task.start`.** `attach_conversation` carries a
   65 s timeout with an open-fallback chain; running it inline would park the App process
   (pinned by `app_test.exs:322` "activate stays responsive when PaneManager parks the
   open (F1 regression)"). `Activation` must capture `pane_manager`/`command`/`title`
   before spawning, exactly as today.
3. **`Process.send_after(self(), ...)` self-addressing.** `rc_hint/2`, the max-agents
   alert clear, and both ticks assume they execute in the App process. `Controls` functions
   are called from `handle_cast` context — they must never be moved into a Task or the
   clears/ticks would target the wrong process. Document on the module.
4. **`quit/1` bypasses the GenServer** and calls `Aiur.Shutdown.shutdown(0)` directly
   because the supervisor's `restart: :permanent` resurrected the pane on a cast (comment
   at 112–120). Do not "clean this up" into a cast.
5. **Geometry is re-probed on every render** (tmux resizes don't update COLUMNS/LINES;
   init values go stale — comment at 1453–1455), and `:geometry_tick` runs at 250 ms
   specifically so pane splits reflow within a quarter-second (comment at 44–48). Keep the
   re-probe inside `RenderState.build/1`.
6. **`:running_changed` fold ordering and set semantics.** `visible_summaries/1` is applied
   on intake so `selection_index` stays aligned with rendered rows (pinned by "activate
   uses the visible-row order"); slot_ids/retain_ids semantics (deactivated releases its
   warm slot, paused retains it) drive `AttachPool.seed/3`; compaction uses `visible_set`
   so `:deactivated` rows keep their Latest/progress/⚪ state. `safely_seed_attach_pool`
   deliberately swallows all errors. This is the seam adjacent to hotspot row 5 (opencode
   attach/warm races, ~17 incidents) — the glyph comments encoding `visible_in` = "leadoff
   painted", not "in window 0" (app.ex:466–471, 216–231) must move intact.
7. **Progress ratchet + phase edge rules.** Checkin samples always record (even lowering);
   phase/bare samples record only ≥ head; a late `phase.end` for a superseded phase must
   not wipe a newer `start`. Pinned by `app_progress_ratchet_test.exs` and
   `app_phase_tracking_test.exs`.
8. **RC border text is a capability token.** The session URL lives only in memory, is
   never logged or rendered in the list, `#` is doubled for tmux's format expansion, and
   the pure diff keeps the 1 Hz `running_changed` tick from re-issuing `set-option`
   (comments at 186–190, 599–601).
9. **Ring caps and render gates.** `@debug_event_cap 200`, `@warmth_event_cap 500`, and
   the aiur_perf "render only if the footer summary changed" gate prevent render storms in
   debug mode; `DebugLog.subscribe/0` is unconditional (Latest column is always-on) while
   the ticker buffer is `debug_mode?`-gated (comment at 154–158).
10. **The `Map.take`/`Map.put` render pipeline is the file's documented regression class**
    — hotspot map row 11 and cross-cutting theme 9 ("Renderer/backend state desync",
    #414/PR #473, #425/PR #428, #730): every new state field must be threaded through
    `render/1` or the renderer never sees it (also captured in project memory). Extracting
    `RenderState` concentrates the seam but also makes Wave 3 the highest-risk wave —
    hence the Wave-0 key-threading characterization test, which the hotspot doc explicitly
    recommends (§"Densest characterization coverage", item 10).
11. **Test seams are API.** `:write_fun`, `:pane_manager`, `:orchestrator`, `:subscribe?`,
    `:command_template`, `:tmux`, `:debug?` opts and the flat map returned by `snapshot/1`
    are load-bearing for every test file listed below; `State.new/1` must accept the same
    opts and produce the same shape.

### Existing tests pinning this file

- `src/test/aiur/agent_list/app_test.exs` (603) — selection ring, activation gating +
  warm/headroom, pause/resume/start-queued, resume-failure bell + alert, max adjust, RC
  toggle + hint taxonomy, `rc_border_changes/3` (direct pure calls — only test edit in the
  plan), deactivated visibility + synthetic 100% seeding, F1 responsiveness, visible-row
  ordering.
- `src/test/aiur/agent_list/app_progress_ratchet_test.exs` (109), `app_phase_tracking_test.exs`
  (91), `app_debug_events_persistence_test.exs` (173), `debug_events_ticker_test.exs`
  (426, partly Renderer), `prewarm_render_test.exs` (27), `input_test.exs` (151 — pins the
  App public-function surface).
- `src/test/aiur/regression/agent_list_sort_test.exs` — drives private
  `visible_summaries/1` through the live App (numeric-id + emoji-bucket ordering).
- `src/test/aiur/regression/enter_opens_new_pane_test.exs` — Enter and Shift+Enter both
  dispatch `:new_pane`.
- `src/test/aiur/regression/warm_marker_semantics_test.exs` / `warm_state_transitions_test.exs`
  — 💤 sleeping row, enter-on-warming blocked; note several describes are `@describetag :skip`
  (stale field names like `warming_identifiers`), so parts of the glyph machine are
  pinned only by comments, not tests.

### Missing characterization coverage (add in Wave 0)

1. Render-state key threading (state field ⇒ `render/1` output key diff) — the #414/#473/#730 class.
2. `:running_changed` → `AttachPool.seed/3` argument derivation (slot/retain sets for
   paused vs deactivated) — currently exercised only via rescue-swallowed calls.
3. `:geometry_tick` reflow (no-op vs resize re-render) and geometry fallback parsing.
4. `attach_selected` (`a` key) attach→open fallback chain — no direct test today.
5. `{:aiur_perf, ...}` fold: footer milestone mapping + changed-only render gate + warmth ring cap.
6. RC border reconcile end-to-end (open-pane listing → tmux `set_pane_border` calls) —
   only the pure diff is tested.
7. Un-skip or rewrite the stale-skipped warm-marker describes against the current field
   names (`attach_state`/`opened_panes`/`agents_with_content`) so the glyph state machine
   is test-pinned before `WarmthIntake` moves it.
