# T-042: app wave 1: State, Summaries, Selection, Roster, EventIntake, RenderState

**Phase:** 4
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3` `model:claude`

## Problem / context

`src/lib/aiur/agent_list/app.ex` is a 1,587-line GenServer mixing public keybind API, PubSub intake for 19 message families, pure fold/policy logic, and render assembly. The decomposition contract is `docs/refactor/research-arch/giant-app.md` §2 (the binding name map). This ticket is wave 1 of 2 on this file: extract the pure/leaf modules `Aiur.AgentList.State`, `Summaries`, `Selection`, `Roster`, `EventIntake`, and `RenderState`. Wave 2 (T-043) extracts `PerfIntake`, `WarmthIntake`, `RcPaneBorders`, `Activation`, `Controls` and slims the shell — do not touch those concerns here.

`RenderState` concentrates the file's documented regression class: the curated `Map.take`/`Map.put` pipeline in `render/1` (app.ex:1452-1493) through which every state field must be threaded or the renderer silently never sees it (#414/PR #473, #425/PR #428, #730 — FI-TUI-051). T-012's characterization tests pin that seam; the extraction must keep the pipeline explicit, in exactly one module, with no dynamic key forwarding.

## Scope (exact)

Move code verbatim (extract, do not rewrite). Public function signatures and observable behavior are unchanged. `Aiur.AgentList.App` keeps its whole public API and all GenServer callbacks; extracted logic is called from delegating clause bodies. Every new module gets `@moduledoc`, `@spec` on every public `def`, and its own test file (new modules are NOT coverage-exempt — do not add them to `ignore_modules` in `src/mix.exs`). All line numbers below refer to `src/lib/aiur/agent_list/app.ex` at the start of this ticket.

1. **Create `src/lib/aiur/agent_list/summaries.ex` — module `Aiur.AgentList.Summaries`** (pure, no process calls). Move from app.ex, verbatim, with these public names:
   - `visible_summaries/1` (lines 1377-1393, keep name), with private `emoji_sort_key/1` (1398-1420) and `identifier_sort_key/1` (1426-1435).
   - `paused?/1` — body of `paused_summary?/1` (1189-1191).
   - `deactivated?/1` — body of `deactivated_summary?/1` (1193-1195).
   - `remote_control_on?/1` — bodies of `remote_control_on_summary?/1` (1313-1317).
   - `active_agent_count/1` (1521-1526); its internal `paused_summary?` call becomes `paused?/1`.
   - New `id_sets/1`: takes the summaries list, returns `%{visible_ids: [...], slot_ids: [...], retain_ids: [...]}` where the three lists are produced by moving the three filter/map chains at lines 646-670 verbatim (visible_ids = every `:running` summary's non-nil identifier; slot_ids = running and not `paused?/1` and not `deactivated?/1`; retain_ids = running and `paused?/1` and not `deactivated?/1`). Move the explanatory comment block at 632-645 onto `id_sets/1`. Keep list order exactly as the current chains produce it.
2. **Create `src/lib/aiur/agent_list/selection.ex` — module `Aiur.AgentList.Selection`** (pure). Move verbatim, public: `move_selection/2` (1335-1352) and `clamp_selection/1` (1364-1372); private: `chip_entry_index/2` (1355-1356), `at_edge?/3` (1360-1362). Move the ring-invariant comment (1328-1334) onto `move_selection/2` and the chip/edge comments with their functions.
3. **Create `src/lib/aiur/agent_list/event_intake.ex` — module `Aiur.AgentList.EventIntake`** (pure fold of `{:event_debug, entry}`). Public entry point `fold/2` (`fold(state, entry) :: map()`) containing the body of `handle_info({:event_debug, entry}, state)` (lines 888-900: the `record_latest_event |> record_progress_sample |> record_phase` pipe plus the `state.debug_mode?`-gated debug-ring append) — everything except `render/1` and the `{:noreply, ...}` return. Move `@debug_event_cap 200` (line 43, with its comment 40-42) into this module. Move as private, verbatim: `record_latest_event/2` (1040-1057), `extract_ticket_id/1` (1059-1066), `event_message/2` (1071-1079), `topic_verb/1` (1081-1086), `record_progress_sample/2` (947-957), `parse_progress_topic/1` (998-1005), `maybe_push_progress/4` (1007-1017), `accept_progress?/3` (1019-1021), `head_percent/1` (1023-1024), `progress_percent/1` (1026-1032), `record_phase/2` (964-981), `parse_phase_topic/1` (983-988), `phase_atom/1` (990-993), `edge_atom/1` (995-996). Move the ratchet comment (938-946) and Latest-column comment (1034-1039) with their functions. Preserve exactly: checkin always records (may lower); phase/bare topics record only when `percent >= head`; a late `phase.end` for a superseded phase must not clear a newer `.start` (giant-app.md risk 7).
4. **Create `src/lib/aiur/agent_list/render_state.ex` — module `Aiur.AgentList.RenderState`**. Public:
   - `build/1` — the body of `render/1` (1452-1489) from the geometry re-probe through the final `Map.put(:truecolor?, ...)`, returning the assembled map. It must NOT call the renderer or `write_fun`. Keep the pipeline as literal `Map.take([...5 keys...])` plus per-key `Map.put` calls — do not convert to `Map.merge`, comprehensions, or key lists (the explicitness IS the seam; FI-TUI-051). Keep the geometry re-probe as the first line of `build/1` with its comment (1453-1455) — giant-app.md risk 5.
   - `terminal_geometry/0` (1559-1573) — public with `@doc false` (App's `:geometry_tick` clause and `State.new/1` call it).
   - `safe_call/1` (1543-1550) — public with `@doc false` (App's `:toggle_layout_orientation` clause at 372 and `log_reactivate_result/2` at 424 still call it until T-043).
   - Private, verbatim: `project_label/0` (1495-1500), `dashboard_url/0` (1502-1512), `agent_kind/0` (1514-1519), `max_agents_from_state/1` (1532-1535) **including the do-NOT-reintroduce-a-blocking-Orchestrator-call comment at 1528-1531 and 1537-1541** (giant-app.md risk 1), `truecolor_supported?/0` (1555-1557), `parse_int/2` (1575-1582).
   - `build/1` computes `:agent_count` via `Summaries.active_agent_count(state.summaries)`.
   - If `mix dialyzer` newly warns on `build/1`, add `@dialyzer {:nowarn_function, build: 1}` to this module; make no other dialyzer changes.
5. **Create `src/lib/aiur/agent_list/state.ex` — module `Aiur.AgentList.State`**. Public:
   - `@type t :: %{...}` — move the `@type state` body (50-62) verbatim, renamed to `t`.
   - `new/1` (`new(keyword()) :: map()`): performs the `Keyword.get` resolution currently at init lines 137-141 and 144 (`:write_fun`, `:pane_manager`, `:orchestrator`, `:tmux`, `:debug?` with `debug_env?()` default), reads `Keyword.fetch!(opts, :command_template)`, obtains `{cols, rows}` via `RenderState.terminal_geometry()`, calls `initial_prewarm_state/0`, and returns the state map literal from lines 167-278 verbatim, including every load-bearing field comment. Same keys, same defaults, same flat-map shape (`snapshot/1` tests assert on it; no struct — giant-app.md naming notes).
   - Private, verbatim: `debug_env?/0` (1149-1157), `warm_status_dark_mode_default/0` (1135-1137), `initial_prewarm_state/0` (1439-1444), `prewarm_status/0` (1446-1450).
   - Leave `@warmth_event_cap` (line 39) in app.ex — it moves to `PerfIntake` in T-043, not here.
6. **Create `src/lib/aiur/agent_list/roster.ex` — module `Aiur.AgentList.Roster`**. Public entry point `fold/2` (`fold(state, summaries) :: {map(), [term()], [term()]}` returning `{new_state, slot_ids, retain_ids}`) containing the body of `handle_info({:running_changed, summaries}, state)` (628-713) minus three things that stay in App: the `safely_seed_attach_pool/2` call (672), the `reconcile_rc_pane_borders/1` call (715), and `render/1`. Inside `fold/2`, in this exact order: `Summaries.visible_summaries(summaries)` → the selection_focus flip (629) → `Selection.clamp_selection/1` (630) → `Summaries.id_sets/1` → `visible_set` construction (674) → the progress seed (685-689) → the state-update map (691-713 with all comments). Split into private helpers if any function would exceed 20 logic lines. Move as private, verbatim: `refresh_open_attentions/1` (918-925), `attention_count_for/1` (927-934, keep the rescue-to-0), `seed_deactivated_progress_samples/2` (1201-1207 with comment 1197-1200), `maybe_seed_deactivated_sample/3` (1209-1227), `head_at_100?/1` (1229-1230). Internal `paused_summary?`/`deactivated_summary?` calls become `Summaries.paused?/1` / `Summaries.deactivated?/1`. `slot_ids`/`retain_ids` set semantics are pinned by giant-app.md risk 6 — do not "simplify" the three-way filter.
7. **Rewire `src/lib/aiur/agent_list/app.ex`** (add `alias Aiur.AgentList.{EventIntake, RenderState, Roster, Selection, State, Summaries}` alongside the existing `Renderer` alias):
   - `init/1`: keep the phase=init log line; then `opts = Keyword.put_new(opts, :command_template, default_command_template())`; then `state = State.new(opts)`; then the existing `if Keyword.get(opts, :subscribe?, true) do ... end` subscription block unchanged except `debug_mode?` reads `state.debug_mode?` (this reorders subscription after state construction — safe because no messages are processed until `init/1` returns; keep all subscription lines and comments verbatim); then `schedule_refresh_tick()`, `schedule_geometry_tick()`, `render(state)`, the elapsed/ready log, `Aiur.Perf.event(:agent_list_ready, ...)`, `{:ok, state}` as today. Delete the now-moved state literal, `@type state`, `debug_env?/0`, `warm_status_dark_mode_default/0`, `initial_prewarm_state/0`, `prewarm_status/0`. Change `@spec snapshot(GenServer.server()) :: state()` to `:: State.t()`.
   - `handle_cast(:select_previous, ...)` / `(:select_next, ...)`: body calls `Selection.move_selection(state, -1 | 1)`.
   - `handle_info({:running_changed, summaries}, state)` becomes exactly: `{new_state, slot_ids, retain_ids} = Roster.fold(state, summaries)`, then `_ = safely_seed_attach_pool(slot_ids, retain_ids)` (function stays in App, 1139-1147, error-swallowing intact), then `new_state = reconcile_rc_pane_borders(new_state)`, then `render(new_state)`, `{:noreply, new_state}`.
   - `handle_info({:event_debug, entry}, state)` becomes: `state = EventIntake.fold(state, entry)`, `render(state)`, `{:noreply, state}`.
   - `render/1` becomes glue only: re-probe nothing itself — `state.write_fun.(Renderer.render(RenderState.build(state)))` then `:ok`. Keep the module-scope `@dialyzer` attributes (35-36) unchanged.
   - `handle_info(:geometry_tick, ...)` calls `RenderState.terminal_geometry()`; the two remaining `safe_call/1` sites (372, 424) call `RenderState.safe_call/1`; the remaining `paused_summary?`/`deactivated_summary?`/`remote_control_on_summary?` call sites (395, 1242, 1247, 1278) call `Summaries.deactivated?/1` / `Summaries.paused?/1` / `Summaries.remote_control_on?/1`; delete the moved private functions from App. Everything else in App — public API, activation/open/attach block (383-530), RC border block (532-606) including public `rc_border_changes/3`, all other `handle_info` clauses, `{:aiur_perf, ...}` handling with `update_perf_summary`/`absorb_warmth_event`/`@warmth_event_cap`, pause/RC/max-adjust internals (1161-1326), `terminate/2`, tick schedulers, `default_command_template/0` — stays byte-identical (T-043's scope).
8. **Write the six test files** (plain ExUnit, `async: true`, pure-function tests — no GenServer, no PubSub):
   - `src/test/aiur/agent_list/summaries_test.exs`: `visible_summaries/1` rejects `agent:cancelled`/`agent:canceled`/`agent:done` tags; sorts working(0) before paused/sleeping(1) before error/deactivated(2) before other-running(3) before queued(4), numeric identifiers ascending within a bucket ("5" before "10"), non-numeric ids grouped after numeric; `paused?/1` and `deactivated?/1` accept atom and string `work_state`; `remote_control_on?/1` true for `:launching` and `:on`, false otherwise; `active_agent_count/1` counts running non-paused only; `id_sets/1` — deactivated row appears in `visible_ids` but neither `slot_ids` nor `retain_ids`; paused row in `visible_ids` and `retain_ids` but not `slot_ids`; nil identifiers dropped.
   - `src/test/aiur/agent_list/selection_test.exs`: empty list parks focus on `:max_agents` at index 0; leaving the chip with +1 lands row 0, with -1 lands the last row; up from row 0 and down from the last row focus the chip; interior moves wrap with `rem/2`; `clamp_selection/1` clamps index to `count - 1` and to 0 for an empty list.
   - `src/test/aiur/agent_list/event_intake_test.exs` (build a minimal state map with `latest_event_by_id`, `progress_by_id`, `phase_by_identifier`, `debug_events`, `debug_mode?` keys): only `kind: :publish` entries on `ticket.<id>.*` topics update `latest_event_by_id` (`:receive`/`:read` ignored); message prefers body `:message`/`"message"`, else humanized topic verb; `agent.progress.checkin` records a lower percent; `agent.progress.phase` and bare `agent.progress` record only `>=` head; `phase.<p>.start` sets, matching `.end` clears, non-matching `.end` leaves a newer phase intact; with `debug_mode?: true` the ring caps at 200 newest-first, with `debug_mode?: false` it stays empty.
   - `src/test/aiur/agent_list/state_test.exs`: `State.new/1` (pass `:command_template`) returns a map whose key set includes every key of the current literal — assert membership of all of: `summaries selection_index selection_focus columns rows help_visible? max_agents_alert? prewarm_active? prewarm_phase remote_control_hint write_fun pane_manager orchestrator tmux command_template rc_pane_borders visible_sessions poll_state debug_mode? attach_state started_slots fully_warmed_slots opened_panes agents_with_content latest_event_by_id open_attentions_by_id progress_by_id phase_by_identifier warm_status_dark_mode? warmth_events perf_summary debug_events`; defaults: `selection_index == 0`, `selection_focus == :agents`, `poll_state == %{checking?: false, next_poll_due_at_ms: nil, max_concurrent_agents: nil}`; opts `:write_fun`/`:pane_manager`/`:orchestrator`/`:tmux`/`:debug?` land on the corresponding keys.
   - `src/test/aiur/agent_list/render_state_test.exs`: `build/1` on a `State.new/1`-produced state returns a map containing every renderer-consumed key: `summaries selection_index selection_focus help_visible? max_agents_alert? columns rows project_label dashboard_url agent_kind agent_count max_agents visible_sessions debug_mode? perf_summary warmth_events debug_events attach_state started_slots fully_warmed_slots opened_panes agents_with_content latest_event_by_id phase_by_identifier open_attentions_by_id progress_by_id warm_status_dark_mode? remote_control_hint prewarm_active? prewarm_phase truecolor?` (the #414/#473/#730 key-threading pin, complementing T-012's characterization); `max_agents` is `n` when `poll_state.max_concurrent_agents` is a positive integer and `nil` otherwise (no Orchestrator call — pass a raising `:orchestrator` sentinel in state and assert no exit).
   - `src/test/aiur/agent_list/roster_test.exs` (state from `State.new/1`): `fold/2` returns `{state, slot_ids, retain_ids}` with the set semantics of the `summaries_test` cases; `selection_focus` flips to `:agents` when summaries first arrive on an empty list; `selection_index` clamps when the list shrinks; `latest_event_by_id`/`phase_by_identifier`/`progress_by_id` compact to visible ids while a `:deactivated` row's entries survive; `agents_with_content` intersects with the visible set; a `:deactivated` summary without a 100-head gets a synthetic `{100, _}` head sample, one that already has it gets no duplicate; `open_attentions_by_id` is rebuilt (0 counts when `SubscriptionStore` has no data — `attention_count_for/1` rescues).
9. Run the Agent gate from `src/`. Existing test files (including `app_test.exs` and everything under `src/test/aiur/regression/`) must pass **unmodified** — giant-app.md pins wave 1 as requiring zero test edits. If any existing test fails, your extraction changed behavior: fix the extraction, never the test.

## Files

- Create: src/lib/aiur/agent_list/summaries.ex, src/lib/aiur/agent_list/selection.ex, src/lib/aiur/agent_list/event_intake.ex, src/lib/aiur/agent_list/render_state.ex, src/lib/aiur/agent_list/state.ex, src/lib/aiur/agent_list/roster.ex
- Modify: src/lib/aiur/agent_list/app.ex
- Test: src/test/aiur/agent_list/summaries_test.exs, src/test/aiur/agent_list/selection_test.exs, src/test/aiur/agent_list/event_intake_test.exs, src/test/aiur/agent_list/render_state_test.exs, src/test/aiur/agent_list/state_test.exs, src/test/aiur/agent_list/roster_test.exs

## Out of scope

- T-043's modules: `PerfIntake`, `WarmthIntake`, `RcPaneBorders`, `Activation`, `Controls` — the `{:aiur_perf, ...}` clauses, warmth/slot/attach `handle_info` clauses, RC border block, activation/open/attach block, and pause/RC/max-adjust internals stay in app.ex byte-identical.
- `src/lib/aiur/agent_list/input.ex` and `renderer.ex` (renderer decomposition is T-040/T-041); the App public-function surface Input dispatches to must not move or change arity.
- Converting the state map to a struct, renaming state keys, or changing `snapshot/1`'s flat-map return (tests assert on its keys).
- Making the `Map.take`/`Map.put` pipeline "DRY" (loops, key lists, `Map.merge`) — explicitness is the contract.
- `src/mix.exs` — do not touch `ignore_modules` (App/Input/Renderer entries stay; new modules are never added).
- Any file under `src/test/aiur/regression/` and all existing test files — read-only.
- Reordering `:running_changed` fold steps, changing `slot_ids`/`retain_ids` semantics, or moving the `safely_seed_attach_pool`/`reconcile_rc_pane_borders` effects out of App.

## Inventory-IDs

From `docs/refactor/feature-inventory/tui.md`:

- Behavior moved by this ticket: FI-TUI-038 (selection ring → Selection), FI-TUI-042 (running_changed intake pipeline → Roster/Summaries), FI-TUI-044 (phase tracking → EventIntake), FI-TUI-045 (progress ratchet → EventIntake), FI-TUI-046 (Latest column store → EventIntake), FI-TUI-051 (render_state Map.take/Map.put pipeline → RenderState), FI-TUI-052 (poll_state cache keeps render non-blocking → RenderState), FI-TUI-053 (pre-warm loading-bar state → State), FI-TUI-055 (geometry + truecolor detection → RenderState), FI-TUI-056 (warm_status_dark_mode env → State/RenderState), FI-TUI-054 (debug buffers — event ring cap moves to EventIntake; warmth/perf parts stay for T-043).
- Behavior that stays in app.ex but whose file this ticket modifies (must remain intact): FI-TUI-017, FI-TUI-029, FI-TUI-035, FI-TUI-036, FI-TUI-037, FI-TUI-039, FI-TUI-040, FI-TUI-041, FI-TUI-043, FI-TUI-047, FI-TUI-048, FI-TUI-049, FI-TUI-050, FI-TUI-057.

## Characterization-tests

- `src/test/aiur/regression/agent_list_sort_test.exs` — drives `visible_summaries/1` ordering through the live App (numeric-id + emoji-bucket order).
- `src/test/aiur/regression/enter_opens_new_pane_test.exs` — Enter and Shift+Enter both dispatch `:new_pane`.
- `src/test/aiur/regression/warm_marker_semantics_test.exs`, `src/test/aiur/regression/warm_state_transitions_test.exs` — glyph/work-state semantics over the fold pipeline.
- The T-012 render-state/snapshot characterization tests under `src/test/aiur/regression/` (created in Phase 1; pin the render-state key threading and the `:running_changed` → `AttachPool.seed/3` derivation) — must pass unchanged against `RenderState.build/1` and `Roster.fold/2`.

## Acceptance criteria

- All six Create files and all six Test files exist; `grep -l "defmodule Aiur.AgentList.\(State\|Summaries\|Selection\|Roster\|EventIntake\|RenderState\) do" src/lib/aiur/agent_list/*.ex | wc -l` prints `6`.
- Every new lib file is <=200 lines (`wc -l` each) and no function in them exceeds 20 logic lines (blank/comment/`@doc`/`@spec` lines excluded).
- `wc -l src/lib/aiur/agent_list/app.ex` prints <= 1000.
- Each new lib file: `grep -c "@moduledoc" <file>` prints `1`, and every `def ` (public) has a preceding `@spec` (`grep -c "@spec" <file>` >= `grep -c "^  def " <file>`).
- Moved code is gone from App: `grep -cE "defp (visible_summaries|emoji_sort_key|identifier_sort_key|paused_summary\?|deactivated_summary\?|remote_control_on_summary\?|active_agent_count|move_selection|chip_entry_index|at_edge\?|clamp_selection|record_latest_event|record_progress_sample|record_phase|parse_progress_topic|parse_phase_topic|maybe_push_progress|accept_progress\?|head_percent|progress_percent|extract_ticket_id|event_message|topic_verb|phase_atom|edge_atom|refresh_open_attentions|attention_count_for|seed_deactivated_progress_samples|maybe_seed_deactivated_sample|head_at_100\?|project_label|dashboard_url|agent_kind|max_agents_from_state|safe_call|truecolor_supported\?|terminal_geometry|parse_int|debug_env\?|warm_status_dark_mode_default|initial_prewarm_state|prewarm_status)\b" src/lib/aiur/agent_list/app.ex` prints `0`.
- Kept code is still in App: `grep -cE "def (start_link|select_previous|select_next|activate|activate_new_pane|attach_selected|toggle_pause|toggle_remote_control|adjust_max_concurrent_agents|quit|toggle_help|toggle_layout_orientation|snapshot|rc_border_changes)\b" src/lib/aiur/agent_list/app.ex` prints `14`; `grep -c "defp safely_seed_attach_pool" src/lib/aiur/agent_list/app.ex` prints `2`; `grep -c "defp reconcile_rc_pane_borders" src/lib/aiur/agent_list/app.ex` prints `1`; `grep -c "@warmth_event_cap" src/lib/aiur/agent_list/app.ex` prints >= 1.
- The pipeline stays explicit and single-home: `grep -c "Map.put" src/lib/aiur/agent_list/render_state.ex` prints >= 24, `grep -c "Map.take" src/lib/aiur/agent_list/render_state.ex` prints `1`, and `grep -rc "Renderer.render" src/lib/aiur/agent_list/app.ex` prints `1` (the glue call).
- `grep -c "@debug_event_cap" src/lib/aiur/agent_list/event_intake.ex` prints `2` (attribute + use) and `grep -c "@debug_event_cap" src/lib/aiur/agent_list/app.ex` prints `0`.
- The blocking-call prohibition survives: `grep -c "Do NOT reintroduce" src/lib/aiur/agent_list/render_state.ex` prints `1`.
- `grep -n "Aiur.AgentList" src/mix.exs` shows only the pre-existing `App`, `Input`, `Renderer` entries (ignore_modules unchanged).
- `git diff --name-only origin/v2...HEAD` lists exactly the 13 files in Files (1 modify + 6 lib + 6 test) — in particular no file under `src/test/aiur/regression/` and no pre-existing test file.
- Tests exist for every extracted module: each of the six test files contains >= 3 `test "` blocks and `mix test test/aiur/agent_list/` passes from `src/`.

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

- Diff review: every removed app.ex hunk reappears verbatim (modulo the renames `paused_summary?`→`paused?`, `deactivated_summary?`→`deactivated?`, `remote_control_on_summary?`→`remote_control_on?`) in exactly one new module; load-bearing comments (state-field docs, ratchet rules, blocking-call prohibition, geometry re-probe) moved with their code.
- Run the acceptance-criteria greps above verbatim; all must match.
- From `src/`: `mix test test/aiur/regression/ --seed 0` and `--seed 1` — both green, zero regression files in the diff.
- Check: FI-TUI-051 — in the phase's live `v2` fleet, the agent list renders with populated Latest, progress bars, phase emoji, and warm markers (no silently-missing column = keys still threaded).
- Check: FI-TUI-038/FI-TUI-042 — live spot-check: arrow keys wrap through the max-agents chip and back; the row order groups working agents first with numeric ids ascending; Enter on a warm row still opens its pane.
- Check: FI-TUI-052 — arrow-key navigation stays instant while the orchestrator is mid-poll (no reintroduced blocking call in render).

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
