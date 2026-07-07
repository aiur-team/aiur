# T-041: renderer wave 2: Model, Markers, Layout, Cells, Table, Chrome, Help; slim

**Phase:** 4
**Depends-on:** T-040
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3`

## Problem / context

`src/lib/aiur/agent_list/renderer.ex` started this refactor at 2,139 lines (~110 private helpers behind a single public `render/1`). T-040 extracted the first six modules per `docs/refactor/research-arch/giant-renderer.md` (`Style`, `Text`, `Links`, `EventPhrases`, `EventLine`, `EventsBlock`). This ticket is the final renderer wave: extract the remaining seven modules — `Aiur.AgentList.Renderer.Model`, `.Markers`, `.Layout`, `.Cells`, `.Table`, `.Chrome`, `.Help` — and slim the parent facade to frame composition only (`render/1`, `lines_emitted/3`, `clear_remaining/2`, the DEC-2026/cursor escape discipline, and the layout-map fan-in).

The module is pure (`state map → iodata`, no processes, no ETS), and every existing test exercises it exclusively through `Renderer.render/1`, so the split is fully observable-behavior-checkable. The facade keeps its name, path, and API; `Aiur.AgentList.App.render/1` (the only production caller) is untouched. Full-frame snapshot fixtures and the App→Renderer key-census test created by T-012 pin the output byte-for-byte — **snapshots must not change**.

## Scope (exact)

**Binding name map:** `docs/refactor/research-arch/giant-renderer.md` §2, rows 7–13 and row 0. Module names, file paths, and function assignments below come from that table and are not negotiable. Line numbers cited below are from the pre-T-040 file (2,139 lines); after T-040 they will have shifted, so **locate every function by name and arity**, not by line number.

**Mechanics for every extraction:** move the function bodies, their doc comments, and their module attributes **verbatim** — do not rewrite, reformat beyond `mix format`, rename variables, or "improve" anything. Moved `defp`s become `def` in their new module. Delete the originals from `renderer.ex` and rewrite call sites to `Alias.fun(...)`. Every new module gets `@moduledoc` (2–4 sentences, derived from the responsibility sentence in the name-map table) and `@spec` on every public `def`. Where moved code referenced helpers already extracted by T-040 (`Style.*`, `Text.*`, `Links.*`), keep the exact calls as they stand in the post-T-040 file.

Execute as four serialized sub-steps in this order (research doc §3 waves 4–7). After each sub-step: `mix compile --warnings-as-errors` and the full `mix test` must pass; commit each sub-step separately.

### Step 1 (wave 4): `Model` + `Markers`

1. Create `src/lib/aiur/agent_list/renderer/model.ex` — `Aiur.AgentList.Renderer.Model`. Move verbatim from `renderer.ex`: `model_cell_block/2` (pre-T-040 lines 946–965), `model_text/3` (972–984), `model_natural_width/1` (989–996), `model_family/1` (1002–1010), `family_from_backend/1` (1012–1018), `model_base/1` (6 clauses, 1020–1025), `model_full_name/2` (1031–1042), `model_color/2` (1047–1048), `engine_word/1` (932–937), and the attributes `@model_truecolor`, `@model_ansi` (96–97, with their comment block), `@model_base_width` (69, with its comment). `@ansi_magenta`/`@ansi_blue`/`@ansi_dim`/`@ansi_reset`/`@ansi_green` references in moved code become the corresponding `Style` functions exactly as T-040 left them. Add one new public accessor: `base_width/0` returning `@model_base_width` (with `@spec base_width() :: pos_integer()`).
2. Create `src/lib/aiur/agent_list/renderer/markers.ex` — `Aiur.AgentList.Renderer.Markers`. Move verbatim: `compute_markers/2` (1075–1089, including the full marker-precedence comment block at 1055–1074), `marker_for_identifier/4` (1091–1097), `marker_from_attach/2` (3 clauses, 1099–1101), `summary_emoji/3` (4 clauses, 1108–1136, with comments), `phase_emoji/1` (5 clauses, 1138–1147, including the U+1F528-hammer comment), and the attributes `@finished_work_states` (104) and `@state_emoji_work_states` (112–119) with their comments — the derivation (`@state_emoji_work_states = [...] ++ @finished_work_states`) must remain exactly one derived from the other (#425/#418 single-fact design). `Markers` aliases `Aiur.AgentEvents`. Add one new public predicate: `finished_work_state?/1` defined as `def finished_work_state?(state), do: state in @finished_work_states` with `@spec finished_work_state?(term()) :: boolean()`.
3. In `renderer.ex`: delete the moved code; `render/1` calls `Markers.compute_markers(state, summaries)`; the still-resident `render_row/5` calls `Markers.summary_emoji/3` and `Model.model_cell_block/2`; the still-resident `phase_placeholder/3` replaces `Map.get(summary, :work_state) in @finished_work_states` with `Markers.finished_work_state?(Map.get(summary, :work_state))`; the still-resident `compute_layout/2` and `starting_phrase/1`/`family_from_backend` call sites use `Model.model_natural_width/1` and `Model.engine_word/1`. Note `summary_emoji/3` keeps its `in @state_emoji_work_states` guard — that works because the attribute now lives in `Markers` where the function is defined.
4. Do NOT move `emoji_cell/2`: the name map assigns it to `Text` (T-040). The census section H of the research doc groups it with markers — the name-map table is the binding source; `Text.emoji_cell/2` already exists after T-040 and callers keep using it.

### Step 2 (wave 5): `Layout` + `Cells`

5. Create `src/lib/aiur/agent_list/renderer/layout.ex` — `Aiur.AgentList.Renderer.Layout`. Move `compute_layout/2` (1173–1274, with all comments) verbatim but **rename it to `compute/2`** — this is the single rename the name map prescribes (`compute/2` (was `compute_layout/2`)). Move the width-constant attributes with their comments: `@state_cell_width` (22), `@attention_cell_width` (29), `@rc_cell_width` (35), `@max_latest_width`/`@min_latest_width` (40–41), `@progress_bar_width`/`@progress_cell_width` (48–49), `@runtime_cell_width` (54), `@min_id_width`/`@min_title_width`/`@title_constrained_cap` (56–62). Expose each as a zero-arity public function with `@spec`: `state_cell_width/0`, `attention_cell_width/0`, `rc_cell_width/0`, `progress_cell_width/0`, `progress_bar_width/0`, `runtime_cell_width/0`, `min_id_width/0`, `min_title_width/0`, `max_latest_width/0`, `title_constrained_cap/0`, plus `model_base_width/0` defined as `def model_base_width, do: Model.base_width()`. Inside `Layout`, `compute/2` keeps using the local attributes directly except `@model_base_width`, which becomes `Model.base_width()` (bind it once to a variable at the top of `compute/2` if needed to keep guard-free arithmetic identical). The returned map shape (`id_width`, `title_width`, `latest_width`, `model_width`, `show_progress?`) must be byte-identical.
6. Create `src/lib/aiur/agent_list/renderer/cells.ex` — `Aiur.AgentList.Renderer.Cells`. Move verbatim: `id_cell_with_link/2` (744–752), `attention_cell/2` (767–779), `rc_cell/1` (787–797), `progress_cell/2` (812–827, with its full comment), `runtime_cell/1` (837–840), `format_runtime/1` (5 clauses, 842–859), `pad2/1` (861–862), `latest_cell/3` (869–881), `latest_event_message/1` (4 clauses, 1050–1053), `@spinner_frames` + `spinner_frame/1` (888–894, with comment), `phase_placeholder/3` (900–920, with comments), `starting_phrase/1` (925–930). Define `@empty_progress_track String.duplicate("·", Layout.progress_bar_width())` with the original comment (121–126). `Cells` aliases `Aiur.ProgressTracker`, `Layout`, `Markers`, `Model`, `Links`, `Text`, `Style`. `id_cell_with_link/2` calls `Links.ticket_url/2` exactly as T-040 left it; `attention_cell/2` and `rc_cell/1` call `Text.emoji_cell/2`; fixed widths come from `Layout` accessors (`Layout.attention_cell_width()`, `Layout.rc_cell_width()`, `Layout.runtime_cell_width()`, `Layout.progress_bar_width()`).
7. **Timing semantics (verbatim, non-negotiable):** the two `Map.get(layout, :now_ms, System.monotonic_time(:millisecond))` fallbacks (pre-T-040 lines 814 in `progress_cell/2` and 891 in `spinner_frame/1`) move into `Cells` exactly as written. Do not re-capture time per cell, do not hoist, do not remove the fallback — `:now_ms` is captured once per frame by the facade's layout fan-in so the spinner shows the same frame on every row; tests inject `:now_ms`.
8. In `renderer.ex`: `render/1`'s pipeline head becomes `summaries |> Layout.compute(inner_width) |> Map.put(...)` — **the twelve `Map.put` calls and every key and default in the fan-in stay byte-identical** (this is the #414/#473/#730 seam pinned by T-012's key-census test; do not convert to structs, do not reorder, do not drop a key). Remaining resident functions (`render_row/5`, `table_header_row/2`, `empty_body_text/1`) call `Cells.*` and `Layout.*` accessors.

### Step 3 (wave 6): `Table` + `Help`

9. Create `src/lib/aiur/agent_list/renderer/table.ex` — `Aiur.AgentList.Renderer.Table`. Move verbatim: `table_header_row/2` (572–596), `table_separator_row/2` (598–612), `render_rows/6` (2 clauses, 614–636), `render_row/5` (655–734, with the full selected-row highlight comment — the `strip_csi`-then-`reverse` order and the un-inverted closing `│` are #366 pins), `empty_body_text/1` (642–648, with comment), `prewarm_label/1` (4 clauses, 650–653). `Table` aliases `Cells`, `Markers`, `Model`, `Layout`, `Text`, `Style`. The visual-width arithmetic in `render_row/5` (pre-T-040 lines 706–713) moves unchanged, with the fixed widths read from `Layout` accessors.
10. Create `src/lib/aiur/agent_list/renderer/help.ex` — `Aiur.AgentList.Renderer.Help`. Move verbatim: `help_body_rows/1` (273–313), `help_heading_row/2` (315–321), `help_line_row/2` (323–329), `help_blank_row/1` (331–334), `help_footer_row/1` (336–339), and the body of `render_help/2` (247–271) as `render/1`: `def render(inner_width)` returns `{drawn, drawn_count}` — the same `drawn` iodata the current function builds (everything up to and including the footer `eol()`) and the same `drawn_count` (`4 + body_count`), WITHOUT the trailing `clear_remaining/2` call. Rationale (decided here, executor does not re-decide): `clear_remaining/2` stays in the facade per name-map row 0, and dependencies point strictly downward, so `Help` cannot call it; the facade composes the clear. `Help` calls `Chrome.title_row/1`, `Chrome.separator_row/1`, `Chrome.bottom_border/1`, which requires `Chrome` to exist first (dependencies point downward only — `Help` must never call the facade). Therefore the actual commit order for Steps 3–4 is: extract `Table` (commit), then `Chrome` (commit), then `Help` (commit), then the facade slim (commit). This reorders the research doc's wave 6/7 pairing but changes nothing else.
11. In `renderer.ex`: `render/1` calls `Table.table_header_row/2`, `Table.table_separator_row/2`, `Table.render_rows/6`; the help branch becomes:
    ```elixir
    {drawn, drawn_count} = Help.render(inner_width)
    drawn ++ [clear_remaining(rows, drawn_count)]
    ```
    and the private `render_help/2` is deleted.

### Step 4 (wave 7): `Chrome` + facade slim

12. Create `src/lib/aiur/agent_list/renderer/chrome.ex` — `Aiur.AgentList.Renderer.Chrome`. Move verbatim: `title_row/1` (343–353), `metadata_rows/2` (355–371), `agents_row/6` (3 clauses, 373–385), `project_row/2` (3 clauses, 387–394), `dashboard_row/2` (3 clauses, 396–403), `metadata_row_iolist/4` (405–412), `agents_row_iolist/6` (414–450), `separator_row/1` (452–461), `bottom_border/1` (463–502, with the "newest"-label comment and the `< 14`-col fallback), the keybind attributes `@keybinds_full`, `@keybinds_primary`, `@keybinds_secondary`, `@footer_left_padding`, `@footer_left_padding_str` (507–511, with comments), `footer_split/2` (518–536), `footer_keybinds_split/1` (538–552), `rc_footer_text/1` (558–563, with comment), `left_only_row/2` (565–568). `Chrome` aliases `Text` and `Style`; `metadata_rows/2` keeps calling `Text.eol()`.
13. Slim `renderer.ex` to composition only. After this step the facade contains exactly: the `@moduledoc`, aliases, the `@type state` (128–136), `@spec render(state()) :: iodata()` + `render/1` (with the layout fan-in, marker call, footer/events budget math, and the full frame-assembly list 184–240 **unchanged** — see risks below), `lines_emitted/3` (1484–1488, with its comment), and `clear_remaining/2` (2125–2138, with its comment). `render/1`'s frame list now reads `Chrome.title_row(...)`, `Chrome.metadata_rows(...)`, `Chrome.separator_row(...)`, `Table.*`, `EventsBlock.*` (from T-040), `Chrome.bottom_border(...)`, `footer_render.iodata` via `Chrome.footer_split(inner_width, Chrome.rc_footer_text(state))`, `Text.eol()`. Delete aliases/attributes your moves orphaned; leave anything else untouched. **Slimmed ceiling: `renderer.ex` must be ≤ 220 physical lines (`wc -l`), target ~170.**

**Escape/frame discipline that must not move and must not change (research doc §4.2):** the DEC 2026 bracket `"\e[?2026h"` … `"\e[?2026l"` around the whole frame; the cursor triplet `"\e[?25l"`, `"\e[?12l"`, `"\e[H"` emitted at BOTH frame start and end (order and duplication are load-bearing); `\e[H` + per-line `\e[K` (never `\e[2J`); `inner_width = max(cols - 1, 1)` final-column reservation; `clear_remaining/2`'s absolute `\e[<lines_drawn+1>;1H` + `\e[J` with no `\r\n`; `lines_emitted/3`'s `8 + footer_lines + body_rows` count. All of these stay in the facade, byte-identical, adjacent to the frame assembly.

### Tests for the new modules (new modules are NOT coverage-exempt)

14. Create one test file per extracted module under `src/test/aiur/agent_list/renderer/` (`async: true`, plain `ExUnit.Case`; every module under test is pure). Required cases per file (add more if trivial, never fewer):
    - `model_test.exs`: `model_family/1` resolves `"opus-4-8"`→`:opus`, `"sonnet-4-6"`→`:sonnet`, `"gpt-5.5"`→`:codex`, backend fallback `%{backend: "claude-repl"}`→`:claude`, `%{}`→`nil`; `model_full_name/2` gives `"Claude Sonnet 4.6"` for `(:sonnet, "sonnet-4-6")` and `"Codex GPT-5.5"` for `(:codex, "gpt-5.5")`, `nil` for `(:claude, nil)`; `model_color/2` returns the 24-bit escape for `(:opus, true)` and the ANSI fallback for `(:opus, false)`, `nil` for `:haiku`; `base_width/0` == 6.
    - `markers_test.exs`: `marker_for_identifier/4` precedence — opened pane →`"🟢"` even with nil attach; painted slot + content →`"⚪"`; painted slot, no content →`"🔘"`; nil attach →`"⏳"`; `finished_work_state?/1` true for `:deactivated`, `"done"`, false for `:running`; `summary_emoji/3` routes `work_state: :sleeping` through `AgentEvents.state_emoji` (💤), returns `"⏳"` ignoring phase when marker is ⏳, and applies `phase_emoji` over a warm marker; `phase_emoji(:work)` == `"🔨"` (U+1F528, not U+1F6E0).
    - `layout_test.exs`: `compute/2` at width ≥ 170 with a pinned-model summary shows progress and expands model to the natural full-name width; at width 80 keeps `show_progress?` per the current algorithm; at extreme narrow width (e.g. 40) drops progress before model and floors `id_width` at `min_id_width/0`; every zero-arity accessor returns its documented constant (3, 4, 3, 10, 10, 7, 4, 6, 60, 25, 6).
    - `cells_test.exs`: `format_runtime/1` — `-5`→`"0:00"`, `59`→`"0:59"`, `3599`→`"59:59"`, `3723`→`"1:02:03"`, `36_000`→`"10h"`, non-integer→`"0:00"`; `attention_cell/2`-equivalent behavior via a layout map — counts 0/1/3/12 give visual width exactly `Layout.attention_cell_width()`; `rc_cell/1` glyphs 📲/📱/❌/blank; `progress_cell/2` renders the dotted `··········` track with no samples and a green-wrapped full bar at 100 (inject `:now_ms`); `phase_placeholder/3` returns `""` for `work_state: :deactivated`, `"Queueing agent…"`-suffixed spinner for `status: :queued`, and `"Starting claude…"` for backend `"claude-repl"` with painted-but-empty attach; `spinner_frame/1` is identical for two calls with the same injected `:now_ms`.
    - `table_test.exs`: `render_row/5` selected row output contains `IO.ANSI.reverse()`, contains no interior CSI color between the reverse and reset (CSI stripped), and preserves an OSC 8 `\e]8;;` link when the layout has a `project_label`; unselected row ends with the gray `│` border; `render_rows/6` empty-list clause renders `"(no agents running)"`; with `prewarm_active?: true` renders `"Pre-warming base ("` and `prewarm_label`-mapped text for `:cloning`/`:fetching`/`:building`.
    - `chrome_test.exs`: `title_row/1` contains `"╭─ AIUR"` and ends the width with `"╮"`; `agents_row_iolist`-driven `metadata_rows/2` shows `"[3]"` brackets + `"← →"` when focused, red-reverse styling when `max_agents_alert?`, `" drain"` when count > max; `project_row/dashboard_row` `"n/a"` fallbacks for nil and `""`; `bottom_border/1` embeds the italic `"newest"` label at width 80 and falls back to the plain border at width 10; `footer_split/2` yields `line_count` 1 at width 120 and 2 at width 60, and +1 with an RC hint string; `rc_footer_text/1` returns the hint string and nil for `""`/absent.
    - `help_test.exs`: `Help.render(120)` returns `{iodata, count}` where the flattened binary contains `"Keybinds"`, `"State circle"`, `"Tips"`, `"? close help   q quit"`, and `count` == 4 + the number of body rows.
15. Do not add any of the seven new modules to `ignore_modules` in `src/mix.exs` — the list only shrinks. Do not remove `Aiur.AgentList.Renderer` from it either (that is not this ticket).

## Files

- Create: `src/lib/aiur/agent_list/renderer/model.ex`, `src/lib/aiur/agent_list/renderer/markers.ex`, `src/lib/aiur/agent_list/renderer/layout.ex`, `src/lib/aiur/agent_list/renderer/cells.ex`, `src/lib/aiur/agent_list/renderer/table.ex`, `src/lib/aiur/agent_list/renderer/chrome.ex`, `src/lib/aiur/agent_list/renderer/help.ex`, `src/test/aiur/agent_list/renderer/model_test.exs`, `src/test/aiur/agent_list/renderer/markers_test.exs`, `src/test/aiur/agent_list/renderer/layout_test.exs`, `src/test/aiur/agent_list/renderer/cells_test.exs`, `src/test/aiur/agent_list/renderer/table_test.exs`, `src/test/aiur/agent_list/renderer/chrome_test.exs`, `src/test/aiur/agent_list/renderer/help_test.exs`
- Modify: `src/lib/aiur/agent_list/renderer.ex`
- Test: the 7 new test files above; existing pins run unchanged: `src/test/aiur/agent_list/renderer_test.exs`, `src/test/aiur/agent_list/debug_events_ticker_test.exs`, `src/test/aiur/agent_list/prewarm_render_test.exs`, `src/test/aiur/regression/warm_marker_semantics_test.exs`, and the T-012 renderer snapshot/key-census characterization tests under `src/test/aiur/regression/`

## Out of scope

- `src/lib/aiur/agent_list/renderer/style.ex`, `text.ex`, `links.ex`, `event_phrases.ex`, `event_line.ex`, `events_block.ex` — T-040's modules; call them, never edit them.
- `src/lib/aiur/agent_list/app.ex` and `input.ex` — the App decomposition is T-042/T-043; the render-state `Map.take`/`Map.put` pipeline on the App side must not be touched.
- `emoji_cell/2` — lives in `Renderer.Text` (T-040 per name-map row 2); do not move or duplicate it into `Markers`/`Cells`.
- Converting the layout map to a struct, renaming layout keys, or changing any `Map.get` default — explicitly deferred by the research doc (§4.1).
- `Aiur.EventHumanizer` / `event_humanizer_helpers.ex` — adjacent duplication flagged for a later ticket; do not consolidate.
- `src/test/aiur/agent_list/renderer_test.exs`, `debug_events_ticker_test.exs`, `prewarm_render_test.exs` — must pass unchanged; do not edit.
- Everything under `src/test/aiur/regression/` and `src/test/fixtures/` — read-only; a needed snapshot update means your change is wrong.
- `src/mix.exs` `ignore_modules` — no additions.
- `Aiur.ProgressTracker`, `Aiur.AgentEvents` — consumed, never modified.

## Inventory-IDs

From `docs/refactor/feature-inventory/tui.md` (entries whose cited lines live in the code this ticket moves or in the facade it slims):

- FI-TUI-043 — warm-marker state machine ⏳→🔘→⚪→🟢 (→ `Markers`)
- FI-TUI-047 — RC hint off-footer / URL never in footer (`rc_footer_text/1` → `Chrome`)
- FI-TUI-051 — render_state Map.take/Map.put pipeline (facade fan-in preserved byte-identical)
- FI-TUI-053 — pre-warm loading bar line (`empty_body_text/1`, `prewarm_label/1` → `Table`)
- FI-TUI-055 — truecolor detection driving MODEL colors (→ `Model.model_color/2`)
- FI-TUI-061 — flicker-free frame protocol (stays in facade, unchanged)
- FI-TUI-062 — final terminal column reserved (facade `inner_width` math, unchanged)
- FI-TUI-063 — box chrome: title, metadata, borders, "newest" label (→ `Chrome`)
- FI-TUI-064 — responsive column-width algorithm (→ `Layout.compute/2`)
- FI-TUI-065 — fixed-width status cells (widths → `Layout` accessors; cells → `Cells`)
- FI-TUI-066 — progress bar + dotted track + green 100% tint (→ `Cells.progress_cell/2`)
- FI-TUI-067 — runtime ticker formats (→ `Cells.format_runtime/1`)
- FI-TUI-068 — LATEST placeholders with spinner + finished-state suppression (→ `Cells`)
- FI-TUI-069 — MODEL column families and website-matched colors (→ `Model`)
- FI-TUI-070 — OSC 8 ticket-ID links (`id_cell_with_link/2` → `Cells`, via T-040 `Links`)
- FI-TUI-071 — theme-aware selected-row highlight, #366 (→ `Table.render_row/5`)
- FI-TUI-072 — help overlay (→ `Help`)
- FI-TUI-075 — visual-width math incl. the U+1F528 `:work` hammer choice (`phase_emoji/1` → `Markers`; width table itself is T-040 `Text`)
- FI-TUI-076 — footer keybind cascade + RC hint line (→ `Chrome`)
- FI-TUI-077 — empty-list body row (→ `Table`)

## Characterization-tests

- T-012's renderer characterization under `src/test/aiur/regression/` (full-frame snapshot fixtures at two widths + help frame, and the App→Renderer key-census test) — the byte-level pin for this wave.
- `src/test/aiur/regression/warm_marker_semantics_test.exs` — ⏳-not-🟢 for unwarm running agents, 💤 for `:sleeping` (#339/#418).
- `src/test/aiur/agent_list/renderer_test.exs` (~73 tests), `debug_events_ticker_test.exs` (26 tests), `prewarm_render_test.exs` (3 tests) — all exercise `Renderer.render/1` only and must pass unchanged.

## Acceptance criteria

- `ls src/lib/aiur/agent_list/renderer/ | sort` includes exactly these seven NEW files in addition to T-040's six: `cells.ex chrome.ex help.ex layout.ex markers.ex model.ex table.ex`.
- `wc -l src/lib/aiur/agent_list/renderer.ex` prints ≤ 220.
- `grep -cE '^  defp? ' src/lib/aiur/agent_list/renderer.ex` prints ≤ 5 (facade holds only `render/1`, `lines_emitted/3`, `clear_remaining/2` plus at most trivial glue).
- Each of these prints `0`: `grep -c "defp compute_layout" src/lib/aiur/agent_list/renderer.ex`; `grep -c "defp summary_emoji" src/lib/aiur/agent_list/renderer.ex`; `grep -c "defp render_row" src/lib/aiur/agent_list/renderer.ex`; `grep -c "defp title_row" src/lib/aiur/agent_list/renderer.ex`; `grep -c "defp help_body_rows" src/lib/aiur/agent_list/renderer.ex`; `grep -c "defp model_family" src/lib/aiur/agent_list/renderer.ex`.
- Frame discipline intact in the facade — each prints ≥ 1: `grep -c '2026h' src/lib/aiur/agent_list/renderer.ex`; `grep -c '2026l' src/lib/aiur/agent_list/renderer.ex`; and `grep -c '"\\e\[?25l"' src/lib/aiur/agent_list/renderer.ex` prints 2 (the emitted triplet at frame start AND frame end; comment mentions don't match this quoted pattern).
- `@finished_work_states` and `@state_emoji_work_states` each appear in exactly one file: `grep -rl "finished_work_states" src/lib/ | sort -u` prints only `src/lib/aiur/agent_list/renderer/markers.ex` (single owner; no copied list in `cells.ex`).
- `grep -c "System.monotonic_time" src/lib/aiur/agent_list/renderer/cells.ex` prints 2 (the two verbatim `:now_ms` fallbacks) and `grep -c "System.monotonic_time" src/lib/aiur/agent_list/renderer.ex` prints 1 (the fan-in default).
- Every new lib file: `grep -c "@moduledoc" <file>` prints 1, and every public `def` has an `@spec` (reviewer spot-check; `grep -c "@spec" <file>` ≥ 1 mechanically).
- New-file size: `wc -l` ≤ 200 for `model.ex`, `markers.ex`, `layout.ex`, `table.ex`, `help.ex`; ≤ 260 for `cells.ex`; ≤ 280 for `chrome.ex` (verbatim comment-bearing moves; the research doc §2 flags Chrome as at-target-limit by design). New code you author (accessors, `finished_work_state?/1`, test helpers) keeps functions ≤ 20 logic lines; moved functions keep their exact current bodies — do not rewrite a moved function to satisfy a line norm.
- Seven new test files exist under `src/test/aiur/agent_list/renderer/` and `mix test test/aiur/agent_list/renderer/` passes; none of the seven new modules appears in `src/mix.exs` (`grep -c "Renderer\." src/mix.exs` prints 0).
- `git diff --name-only origin/v2...HEAD` lists only the Files above — in particular nothing under `src/test/fixtures/` (snapshots byte-identical, no `UPDATE_SNAPSHOTS` run) and nothing under `src/test/aiur/regression/`.
- Full suite green after every sub-step commit (`mix test`, 0 failures, no skips).

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

- Run every grep in Acceptance criteria verbatim; all must match.
- Confirm the diff shows moved bodies verbatim (`git diff --color-moved=dimmed-zebra origin/v2...HEAD -- src/lib/aiur/agent_list/` renders the extractions as moved blocks, not rewrites).
- Confirm the facade's layout fan-in (`Layout.compute` + twelve `Map.put`s) is unchanged except the `compute_layout`→`Layout.compute` call — same keys, same defaults, same order.
- Run from `src/`: `mix test test/aiur/agent_list test/aiur/regression/warm_marker_semantics_test.exs --seed 0` and again with `--seed 1` — green both times.
- Check: FI-TUI-061/062 — T-012's full-frame snapshot tests pass with fixtures untouched in the diff (escape ordering and final-column reservation byte-identical).
- Check: FI-TUI-043 — `warm_marker_semantics_test.exs` green; ⏳/🔘/⚪/🟢 and 💤 assertions unchanged.
- Check: FI-TUI-064 — renderer_test.exs MODEL/width describe blocks (wide/medium/narrow) green.
- Visual spot-check on the phase's live aiur run on `v2`: agent list renders with aligned columns at both a wide and a narrowed tmux pane, selected-row highlight preserves the clickable ticket link, `?` overlay opens and closes cleanly, no flicker while agents stream.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
