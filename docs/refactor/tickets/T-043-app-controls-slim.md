# T-043: app wave 2: PerfIntake, WarmthIntake, RcPaneBorders, Activation, Controls; slim

**Phase:** 4
**Depends-on:** T-042
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/agent_list/app.ex` is the agent-list TUI GenServer (1,587 lines
before this refactor). T-042 extracted `Aiur.AgentList.{State, Summaries,
Selection, Roster, EventIntake, RenderState}`. This ticket is the second and
FINAL decomposition wave on this file, per the binding name map in
`docs/refactor/research-arch/giant-app.md` §2: extract
`Aiur.AgentList.{PerfIntake, WarmthIntake, RcPaneBorders, Activation,
Controls}` and slim `Aiur.AgentList.App` down to the GenServer shell (public
API, subscription wiring, ≤5-line delegating callback clauses, tick
scheduling, and the `render/1` glue).

This is a behavior-preserving move-only wave. Move code verbatim wherever
possible — extract, do not rewrite. Public function signatures on `App` and
all observable behavior stay unchanged; `App` delegates to the extracted
modules so `Aiur.AgentList.Input` and every existing test keeps working. This
file is a serialized sub-wave: do not start until T-042's PR is merged into
`v2`.

Line ranges below cite `app.ex` as of the planning snapshot (pre-T-042,
branch `refactor-planning-prompt`). T-042 will have shifted line numbers —
the function NAMES are authoritative; the ranges pin which code is meant.

## Scope (exact)

1. **Create `src/lib/aiur/agent_list/perf_intake.ex`** defining
   `Aiur.AgentList.PerfIntake`:
   - Move the module attribute `@warmth_event_cap 500` here from `app.ex`
     (was line 39), with its comment.
   - Public `fold(state, event) :: {map(), boolean()}` — body moved verbatim
     from the `handle_info({:aiur_perf, event}, %{debug_mode?: true} = state)`
     clause (was lines 873–883): compute `new_summary =
     update_perf_summary(state.perf_summary, event)` and `new_warmth =
     absorb_warmth_event(state.warmth_events, event)`, put both into state,
     and return `{new_state, new_summary != state.perf_summary}`. The boolean
     is the render gate: render ONLY when the footer summary changed (this
     gate prevents render storms in debug mode — preserve it exactly).
   - Move verbatim as private: `update_perf_summary/2` (all 4 clauses, was
     lines 1091–1103, with the "compact 3-row footer" comment) and
     `absorb_warmth_event/2` (both clauses, was lines 1105–1125).
   - `@moduledoc` describing the fold + render gate; `@spec` on `fold/2`.

2. **Create `src/lib/aiur/agent_list/warmth_intake.ex`** defining
   `Aiur.AgentList.WarmthIntake` — one home for the glyph-state
   (⏳/🔘/⚪/🟢) message folds currently smeared across ten `handle_info`
   clauses. Public `fold(state, message) :: {map(), boolean()}` with one
   clause per message tuple, each body moved verbatim from the corresponding
   `handle_info` clause; the boolean says whether App should render:
   - `fold(state, {:agent_chat_active, identifier}) when is_binary(identifier)`
     (was 724–732): returns `{state, false}` when `identifier` is already in
     `state.agents_with_content`, else puts it and returns `{state, true}`.
     Keep the MapSet-dedup comment.
   - `fold(state, {:status_changed, %{identifier: id, status: :pane_opened}})`
     (was 741–749): puts `to_string(id)` into `opened_panes`, returns
     `{state, true}`. Do NOT fold the RC-border reconcile in here — App calls
     `RcPaneBorders.reconcile/1` after this fold (step 6). Move the
     🟢-semantics comment block (was 734–740) with this clause.
   - `fold(state, {:status_changed, %{identifier: id, status: :pane_closed}})`
     (was 751–755): deletes from `opened_panes`, `{state, true}`.
   - `fold(state, {:slot_session_changed, slot_index, identifier}) when
     is_integer(slot_index)` (was 759–770) and
     `fold(state, {:slot_visible_changed, slot_index, identifier})` (was
     861–871): the two bodies are byte-identical today — implement ONE private
     helper (name it `put_visible_session/3`) called by both fold heads. This
     dedup is called out in giant-app.md ("two topics, same fold").
   - `fold(state, {:slot_ready, slot_index}) when is_integer(slot_index)`
     (was 772–776) and `fold(state, {:slot_starting, slot_index}) when
     is_integer(slot_index)` (was 780–784): put into `started_slots`,
     `{state, true}`. Non-integer variants (was 778, 786): `{state, false}`.
   - `fold(state, {:attach_state_changed, identifier, attach_count, visible_in})`
     (was 828–833): `{state, true}`.
   - `fold(state, {:slot_fully_warmed, slot_index})` (was 835–839) and
     `fold(state, {:slot_warmth_dropped, slot_index})` (was 841–845):
     add/delete on `fully_warmed_slots`, `{state, true}`.
   - `@moduledoc` naming the marker state machine and the fields it owns
     (`visible_sessions`, `started_slots`, `fully_warmed_slots`,
     `attach_state`, `opened_panes`, `agents_with_content`); `@spec` on
     `fold/2`.

3. **Create `src/lib/aiur/agent_list/rc_pane_borders.ex`** defining
   `Aiur.AgentList.RcPaneBorders` (RC session-URL pane-border surfacing, #13):
   - Public `reconcile(state) :: map()` — verbatim body of
     `reconcile_rc_pane_borders/1` (was 545–554). Move the full comment block
     (was 532–544) as/into the `@moduledoc`.
   - Public `changes(open_panes, summaries, applied)` — verbatim
     `rc_border_changes/3` (was 562–596) INCLUDING its `@spec`; promote its
     `@doc false` comment text to a real `@doc`.
   - Private `safe_list_open_panes/1` (was 556–560, keep the `catch :exit`)
     and `border_text/1` (was `rc_border_text/1`, 598–606, with the
     `#`-doubling comment).
   - Preserve verbatim these documented invariants: the border text holds the
     RC session URL, a capability token — it lives only in memory, is never
     logged and never rendered in the list; `#` is doubled for tmux's format
     expansion; the pure diff keeps the 1 Hz `running_changed` tick from
     re-issuing `set-option`.
   - `@spec` on both public functions.

4. **Create `src/lib/aiur/agent_list/activation.ex`** defining
   `Aiur.AgentList.Activation` (Enter / Shift+Enter / `O` / `a` handling):
   - Public `activate_selected(state, mode) :: :ok` — verbatim body of
     `activate_selected_agent/2` (was 383–391), dispatching to private
     `activate_selected_agent_if_warm/4` (verbatim, was 393–413).
   - Public `attach_selected(state) :: :ok` — verbatim body of
     `attach_selected_agent/1` (was 497–514), with its parking-concern
     comment.
   - Public `default_command_template/0` — verbatim (was 1584–1586), returns
     `"__aiur_opencode__"`.
   - Move verbatim as private: `reactivate_and_open/4` (415–421),
     `log_reactivate_result/2` (423–428), `open_selected_agent/4` (430–444),
     both `do_open/5` clauses (446–464), `has_parallel_headroom?/2` (466–488
     including its comment), `warm_identifier?/2` (490–495),
     `attempt_attach_then_open/4` (516–530).
   - Replace the `deactivated_summary?(summary)` call with
     `Summaries.deactivated?(summary)` (the T-042 module; alias it).
   - Add a private `safe_call/1` — verbatim copy of the rescue/catch wrapper
     (was 1543–1550) — used by `log_reactivate_result/2`. This small private
     helper is deliberately duplicated (App, RenderState, here) to keep the
     dependency graph one-way; do not consolidate it in this ticket.
   - `@moduledoc` MUST state (risk §4.2 of giant-app.md, preserve verbatim):
     every PaneManager open/attach runs inside `Task.start` —
     `attach_conversation` carries a 65 s timeout with an open-fallback
     chain, and running it inline would park the App process (pinned by the
     F1-regression test). Capture `pane_manager`/`command`/`title` into
     locals BEFORE spawning the Task, exactly as the moved code does.
   - `@spec` on the three public functions.

5. **Create `src/lib/aiur/agent_list/controls.ex`** defining
   `Aiur.AgentList.Controls` (Space / `r` / ←→ agent-control actions):
   - Public `toggle_pause(state) :: map()` — verbatim body of
     `toggle_selected_agent_pause/1` (both clauses, was 1232–1238),
     dispatching to private `toggle_agent_pause/2` (all 3 clauses, verbatim,
     was 1240–1263, with the RC-on no-op comment).
   - Public `toggle_remote_control(state) :: map()` — verbatim body of
     `toggle_selected_agent_remote_control/1` (both clauses, was 1265–1271),
     dispatching to private `toggle_agent_remote_control/2` (both clauses,
     verbatim, was 1273–1287 with its gating comment).
   - Public `adjust_max_concurrent_agents(state, delta) :: map()` — the body
     of the `handle_cast({:adjust_max_concurrent_agents, delta}, state)`
     clause minus the `render`/`{:noreply, …}` lines (was 352–361): the two
     `[user-action]` log lines, the
     `Orchestrator.adjust_max_concurrent_agents(state.orchestrator, delta)`
     call, and `handle_max_adjust_result/2`. Keep the focus-gating comment.
   - Move verbatim as private: `handle_resume_result/2` (1161–1174 with its
     reason-taxonomy comment), `handle_max_adjust_result/2` (1176–1178),
     all 6 `handle_remote_control_result/2` clauses (1289–1311),
     `rc_hint/2` (1319–1322), `ring_bell/1` (1180–1183),
     `schedule_max_agents_alert_clear/0` (1185–1187),
     `schedule_remote_control_hint_clear/0` (1324–1326).
   - Replace `paused_summary?/1` → `Summaries.paused?/1` and
     `remote_control_on_summary?/1` → `Summaries.remote_control_on?/1`
     (T-042 module; alias it).
   - `@moduledoc` MUST state (risk §4.3 of giant-app.md, preserve verbatim):
     these functions use `Process.send_after(self(), …)` and therefore MUST
     run in the App GenServer process (they are called from `handle_cast`
     context) — never call them from inside a Task or the hint/alert clears
     would target the wrong process.
   - `@spec` on the three public functions.

6. **Slim `src/lib/aiur/agent_list/app.ex`** to the GenServer shell:
   - Add `alias Aiur.AgentList.{Activation, Controls, PerfIntake,
     RcPaneBorders, WarmthIntake}` alongside the T-042 aliases.
   - Public API (`start_link/1` through `snapshot/1`) stays byte-identical —
     including `quit/1` calling `Aiur.Shutdown.shutdown(0)` directly with its
     restart-`:permanent` comment (risk §4.4: do NOT "clean this up" into a
     cast), and `snapshot/1` still returning the flat state map.
   - `handle_cast(:activate, …)` / `handle_cast(:activate_new_pane, …)`:
     keep the `state.selection_focus == :agents` guard and the
     Enter/Shift+Enter comment; the call becomes
     `Activation.activate_selected(state, :new_pane)`.
   - `handle_cast(:attach_selected, …)`: guard kept; call becomes
     `Activation.attach_selected(state)`.
   - `handle_cast(:toggle_pause, …)`: `state = Controls.toggle_pause(state)`,
     then render, `{:noreply, state}`.
   - `handle_cast(:toggle_remote_control, …)`: same shape via
     `Controls.toggle_remote_control(state)`.
   - `handle_cast({:adjust_max_concurrent_agents, delta}, …)`:
     `state = Controls.adjust_max_concurrent_agents(state, delta)`, then
     render, `{:noreply, state}`.
   - Every `handle_info` clause moved into `WarmthIntake` becomes (clause
     head and guards unchanged):
     `{new_state, render?} = WarmthIntake.fold(state, <the message tuple>);
     if render?, do: render(new_state); {:noreply, new_state}`.
     EXCEPTION — the `:pane_opened` clause preserves today's order:
     fold, then `new_state = RcPaneBorders.reconcile(new_state)`, then
     render, then `{:noreply, new_state}`.
   - `handle_info({:aiur_perf, event}, %{debug_mode?: true} = state)`
     delegates to `PerfIntake.fold(state, event)` with the same
     render-if-changed shape. The non-debug clause
     `handle_info({:aiur_perf, _event}, state), do: {:noreply, state}` stays
     verbatim in App.
   - The `:running_changed` clause (post-T-042: Roster fold + AttachPool
     seed) now ends with `RcPaneBorders.reconcile/1` in place of the old
     private `reconcile_rc_pane_borders/1`, preserving today's order:
     roster fold → seed → reconcile → render.
   - Clauses that stay verbatim in App (do not move): `{:prewarm_phase, _}`,
     `{:status_changed, _}` catch-all, `{:poll_state_changed, _}`,
     `{:alert, %{}}`, `:clear_max_agents_alert`,
     `:clear_remote_control_hint`, `:refresh_tick`, `:geometry_tick`, the
     four ignore clauses (`:attach_failed`, `:attach_consumed`,
     `:slot_attach_added`, `:slot_attach_removed`), the `_other` catch-all,
     plus `terminate/2`, `schedule_refresh_tick/0`, `schedule_geometry_tick/0`
     and the `render/1` glue.
   - Ensure App retains a private `safe_call/1` (verbatim, was 1543–1550) for
     the `:toggle_layout_orientation` clause (re-add it if T-042 moved it
     wholesale into RenderState).
   - Delete from App every function moved in steps 1–5, and the
     `@warmth_event_cap` attribute (now in PerfIntake).
   - **Slimmed line ceiling: `app.ex` must be ≤ 420 lines after this wave**
     (`grep -c ""`). It stays above the 200-line per-file target because 19
     `handle_info` clause heads plus 13 public API functions are irreducible
     for a single GenServer — each clause body must be ≤ 5 delegating lines.

7. **Update `src/lib/aiur/agent_list/state.ex`** (T-042 module): replace its
   local `default_command_template/0` (or the inlined `"__aiur_opencode__"`
   default for `:command_template`) with a call to
   `Activation.default_command_template()`, deleting the local copy. If the
   default still lives in `App.init/1` instead, make the equivalent one-line
   change there.

8. **Test file moves/additions** (new modules are NOT coverage-exempt — do
   not touch `ignore_modules` in `src/mix.exs`):
   - `src/test/aiur/agent_list/app_test.exs`: move the `rc_border_changes/3`
     describe block (direct pure-function calls) OUT of this file and into
     the new `rc_pane_borders_test.exs`, changing ONLY the call target to
     `RcPaneBorders.changes/3` — every assertion unchanged. This is the only
     edit to any existing test file in this ticket.
   - Create `src/test/aiur/agent_list/perf_intake_test.exs`: `fold/2` maps
     each of the three milestones (`:agent_list_ready`,
     `:placeholder_spawn_done`, `:convo_first_paint`) onto its
     `perf_summary` slot with newest-wins; returns `render? == false` when
     the summary is unchanged (e.g. a warmth-only event); warmth ring
     accepts `:slot_attach_added`/`:slot_attach_removed`/
     `:slot_visible_changed` and caps at 500 entries.
   - Create `src/test/aiur/agent_list/warmth_intake_test.exs`: one test per
     fold head — `:agent_chat_active` dedup returns `render? == false` on
     repeat; `:slot_session_changed` and `:slot_visible_changed` produce
     identical `visible_sessions` updates and `nil` identifier deletes the
     slot entry; non-integer `:slot_ready`/`:slot_starting` return
     `{state, false}`; `:slot_fully_warmed`/`:slot_warmth_dropped`
     add/remove on `fully_warmed_slots`; `:pane_opened`/`:pane_closed`
     add/remove the stringified id on `opened_panes`.
   - Create `src/test/aiur/agent_list/rc_pane_borders_test.exs`: hosts the
     moved `changes/3` describe block; adds — `changes/3` emits a
     `{pane_id, nil}` clear when RC turns off; unchanged text produces no
     change entry (the 1 Hz no-re-issue guarantee); `reconcile/1` with a
     dead/unregistered `pane_manager` name returns state with
     `rc_pane_borders` untouched and calls no tmux (the `catch :exit`
     path).
   - Create `src/test/aiur/agent_list/activation_test.exs`: use the same
     stub-GenServer pattern as `app_test.exs` (a test process registered as
     `:pane_manager`/`:orchestrator` that forwards received calls to the
     test pid). Cover: not-warm identifier → no PaneManager message
     (blocked, reason=not_warm path); `:new_pane` with no headroom → no
     PaneManager message; warm + headroom → `open_conversation` received
     with command `"<template> <identifier>"`; deactivated summary →
     `resume_agent` received AND `open_conversation` received;
     `attach_selected` → `attach_conversation` received, and on
     `{:error, :no_focused_pane}` → `open_conversation` received (fallback
     chain).
   - Create `src/test/aiur/agent_list/controls_test.exs` (run assertions in
     the test process — `Process.send_after(self(), …)` lands there): Space
     semantics — running → `pause_agent` called; paused → `resume_agent`;
     queued → `resume_agent`; RC-on summary → no orchestrator call and
     `remote_control_hint` set to the "press `r` to return" text; resume
     `{:error, reason}` → `max_agents_alert?` true and `write_fun` received
     `"\a"`; `toggle_remote_control` maps each of the six
     `set_remote_control` results to its exact hint string; non-running row
     → "Remote Control requires a local Claude agent".

9. **Semantics to preserve verbatim** (giant-app.md §4 risks — re-read them
   before moving code): render never blocks (no new synchronous
   Orchestrator/Tracker calls anywhere in this wave); all PaneManager
   opens/attaches stay inside `Task.start` with args captured before spawn;
   `Process.send_after(self(), …)` call sites stay in code executed by the
   App process; `quit/1` keeps bypassing the GenServer; RC border text stays
   a never-logged capability token with `#` doubled and diff-gated
   `set-option`; ring caps (`@warmth_event_cap 500`) and the aiur_perf
   changed-only render gate stay intact; the test seams (`:write_fun`,
   `:pane_manager`, `:orchestrator`, `:subscribe?`, `:command_template`,
   `:tmux`, `:debug?`, flat `snapshot/1` map) are API and must not change.

10. From `src/`: `mix format`, then run the full Agent gate below. The repo
    must compile and the full suite must pass at the end of this wave.

## Files

- Create: `src/lib/aiur/agent_list/perf_intake.ex`,
  `src/lib/aiur/agent_list/warmth_intake.ex`,
  `src/lib/aiur/agent_list/rc_pane_borders.ex`,
  `src/lib/aiur/agent_list/activation.ex`,
  `src/lib/aiur/agent_list/controls.ex`
- Modify: `src/lib/aiur/agent_list/app.ex`,
  `src/lib/aiur/agent_list/state.ex` (single call-site change, step 7),
  `src/test/aiur/agent_list/app_test.exs` (describe-block move only, step 8)
- Test: `src/test/aiur/agent_list/perf_intake_test.exs`,
  `src/test/aiur/agent_list/warmth_intake_test.exs`,
  `src/test/aiur/agent_list/rc_pane_borders_test.exs`,
  `src/test/aiur/agent_list/activation_test.exs`,
  `src/test/aiur/agent_list/controls_test.exs`

## Out of scope

- `src/lib/aiur/agent_list/input.ex` and `src/lib/aiur/agent_list/renderer.ex`
  — untouched; the Input→App public-function surface is pinned by
  `input_test.exs` and must not move.
- The T-042 modules (`state.ex` beyond step 7's one call site, `summaries.ex`,
  `selection.ex`, `roster.ex`, `event_intake.ex`, `render_state.ex`) — call
  them, do not edit them.
- `src/lib/aiur/pane_manager.ex` / `src/lib/aiur/tmux.ex` (T-044/T-045/T-053
  own those).
- Converting `snapshot/1`'s flat state map to a struct — explicitly deferred
  by giant-app.md.
- Consolidating the duplicated private `safe_call/1` helpers.
- `src/mix.exs` — especially the coverage `ignore_modules` list: it only ever
  shrinks; adding any new module to it is forbidden.
- Everything under `src/test/aiur/regression/` — read-only.
- Any behavior change: no renamed public App functions, no new PubSub topics,
  no altered log lines or `[user-action]` strings, no hint-text edits.

## Inventory-IDs

From `docs/refactor/feature-inventory/tui.md` — features implemented by the
files this ticket touches; all must behave identically after the move:

- FI-TUI-029 — pane_opened/pane_closed → `opened_panes` mirror (WarmthIntake)
- FI-TUI-035 — AgentList PubSub subscription set (App init, unchanged)
- FI-TUI-036 — agent-list keybind command surface (App public API, unchanged)
- FI-TUI-037 — `q` quits via full shutdown, never a GenServer cast (App)
- FI-TUI-039 — Enter/Shift+Enter both open in a new pane (Activation)
- FI-TUI-040 — open gating: reactivation, warmth, parallel headroom
  (Activation)
- FI-TUI-041 — attach_selected: attach then fall back to open (Activation)
- FI-TUI-043 — warm-marker state machine ⏳→🔘→⚪→🟢, App-side fields
  (WarmthIntake)
- FI-TUI-047 — RC pane-border reconcile, session URL secrecy (RcPaneBorders)
- FI-TUI-048 — remote-control toggle results and transient hints (Controls)
- FI-TUI-049 — pause/resume/start via Space with bell + red-flash alert
  (Controls)
- FI-TUI-050 — 1 s refresh + 250 ms geometry ticks (App, unchanged)
- FI-TUI-052 — poll_state cache keeps render non-blocking (App/RenderState,
  unchanged — do not reintroduce a blocking call)
- FI-TUI-054 — debug buffers: warmth-event ring, 3-slot perf summary
  (PerfIntake)
- FI-TUI-057 — boot perf event and lifecycle logs (App, unchanged)

## Characterization-tests

Protecting regression files under `src/test/aiur/regression/` (read-only —
if any fails, your change is wrong):

- `enter_opens_new_pane_test.exs` — Enter and Shift+Enter both dispatch
  `:new_pane` (pins Activation).
- `warm_marker_semantics_test.exs`, `warm_state_transitions_test.exs` —
  💤/warming glyph behavior (pins WarmthIntake; note some describes are
  `@describetag :skip` — leave them exactly as they are).
- `agent_list_sort_test.exs` — visible ordering through the live App.

Also load-bearing (under `src/test/aiur/agent_list/`, not regression, still
must pass with only the step-8 describe-block move as an edit):
`app_test.exs` (F1 responsiveness, pause/resume/queued, RC hint taxonomy,
activation gating), `app_progress_ratchet_test.exs`,
`app_phase_tracking_test.exs`, `app_debug_events_persistence_test.exs`,
`debug_events_ticker_test.exs`, `prewarm_render_test.exs`, `input_test.exs`.

## Acceptance criteria

- The five new files exist; each is ≤ 200 lines
  (`grep -c "" src/lib/aiur/agent_list/<file>.ex` ≤ 200 for `perf_intake`,
  `warmth_intake`, `rc_pane_borders`, `activation`, `controls`).
- `grep -c "" src/lib/aiur/agent_list/app.ex` ≤ 420 (the slimmed shell
  ceiling); every callback clause body in `app.ex` is ≤ 5 delegating lines;
  all functions ≤ 20 logic lines.
- Each new file: exactly one `defmodule`, a `@moduledoc`
  (`grep -L "@moduledoc" <the five new files>` prints nothing), and `@spec`
  on every public `def`.
- `grep -n "defp update_perf_summary\|defp absorb_warmth_event\|defp reconcile_rc_pane_borders\|def rc_border_changes\|defp rc_border_text\|defp activate_selected_agent\|defp open_selected_agent\|defp do_open\|defp attempt_attach_then_open\|defp toggle_agent_pause\|defp toggle_agent_remote_control\|defp handle_remote_control_result\|defp rc_hint" src/lib/aiur/agent_list/app.ex`
  prints nothing (moved code deleted from App).
- `grep -n "@warmth_event_cap" src/lib/aiur/agent_list/app.ex` prints
  nothing; `grep -n "@warmth_event_cap 500" src/lib/aiur/agent_list/perf_intake.ex`
  matches.
- App public surface intact:
  `grep -c "def quit\|def snapshot\|def activate\|def attach_selected\|def toggle_pause\|def toggle_remote_control\|def adjust_max_concurrent_agents\|def toggle_help\|def toggle_layout_orientation\|def select_previous\|def select_next" src/lib/aiur/agent_list/app.ex` ≥ 11;
  `grep -F "Aiur.Shutdown.shutdown(0)" src/lib/aiur/agent_list/app.ex` matches.
- `grep -F "Task.start" src/lib/aiur/agent_list/activation.ex` matches ≥ 3
  times (reactivate, open, attach paths);
  `grep -F "Process.send_after(self()" src/lib/aiur/agent_list/controls.ex`
  matches ≥ 2 times (alert + hint clears).
- The five new test files exist under `src/test/aiur/agent_list/`, each with
  ≥ 1 `test` block, and every extracted module is exercised (new modules are
  NOT coverage-exempt).
- `git diff --name-only origin/v2...HEAD` lists ONLY the files in the Files
  section — in particular no `src/mix.exs` and nothing under
  `src/test/aiur/regression/`.
- `git diff origin/v2...HEAD -- src/test/aiur/agent_list/app_test.exs` shows
  only the removal of the `rc_border_changes/3` describe block (no assertion
  edits elsewhere).
- Full Agent gate passes (below).

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

- Check: in a live `v2` session, press Enter on a warm (⚪) agent row — the
  chat pane appears sub-second and arrow keys stay responsive while it opens
  (FI-TUI-019/040 probe; F1 regression stays fixed).
- Check: Enter on a not-warm (⏳) row does nothing visible and the log shows
  `open_blocked … reason=not_warm`.
- Check: Space on a running agent pauses it (⏸️), Space again resumes; `r`
  on a running claude agent shows the "Switching to remote…" hint that
  auto-clears in ~4 s; Space on an RC-on agent does NOT pause and hints
  "press `r` to return" (FI-TUI-048/049).
- Check: with RC on and the agent's pane open, the pane TOP BORDER shows
  " 📱 <session url>"; the URL appears nowhere in the agent-list footer and
  `grep` of the session log for the URL finds nothing (FI-TUI-047,
  FI-TUI-010).
- Check: run with `AIUR_DEBUG=1` — the 3-row debug footer populates
  (agent list ready / chat pane visible / opencode render) and the event
  ticker still scrolls (FI-TUI-054).
- Check: `git log --oneline origin/v2..HEAD -- src/test/aiur/regression/`
  is empty.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
