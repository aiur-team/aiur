# Decomposition proposal: `src/lib/aiur/agent_list/renderer.ex` (2139 lines)

Behavior-preserving refactor plan for `Aiur.AgentList.Renderer`. Repo root: `/home/orangekid/github/aiur`.

**Key structural fact discovered up front:** the module's public API is exactly one function — `render/1`. Every one of its ~110 helper heads (257 `def`/`defp` clause lines) is `defp`, and the only production call site is `Aiur.AgentList.App.render/1` (app.ex:1491). All four test files (`renderer_test.exs`, `debug_events_ticker_test.exs`, `prewarm_render_test.exs`, `regression/warm_marker_semantics_test.exs`) exercise the module exclusively through `Renderer.render/1` and assert on the emitted iodata. That means every extraction below is observable-behavior-checkable through the existing suite, and the facade (`Aiur.AgentList.Renderer`) can keep its name, path, and API forever — downstream call sites never change.

House-style conformance: the repo already uses the facade-file + subdirectory convention (`orchestrator.ex` + `orchestrator/`, `config.ex` + `config/`), so the split lands as `renderer.ex` + `renderer/*.ex` under `Aiur.AgentList.Renderer.*`. `visual_width`/`strip_ansi`/OSC-8 helpers exist **nowhere else in src/lib** (grep-verified), so the Text/Links extractions create the single source of truth rather than duplicating one.

---

## 1. Function / responsibility census

Line numbers refer to the current file. Sizes are logic lines (excluding comments).

### A. Module constants & types — lines 1–136 (~135 lines)
- Cell-width constants: `@state_cell_width` (22), `@attention_cell_width` (29), `@rc_cell_width` (35), `@max_latest_width`/`@min_latest_width` (40–41), `@progress_bar_width`/`@progress_cell_width` (48–49), `@runtime_cell_width` (54), `@min_id_width`/`@min_title_width`/`@title_constrained_cap` (56–62), `@model_base_width` (69)
- ANSI palette: `@ansi_*` (72–83), `@model_truecolor`/`@model_ansi` (96–97)
- Work-state policy sets: `@finished_work_states` (104), `@state_emoji_work_states` (112–119) — derived, one from the other (deliberate single-fact design, #425/#418)
- `@empty_progress_track` (126), `@type state` (128–136)

### B. Frame orchestration — `render/1` 139–242 (~85), `lines_emitted/3` 1484–1488 (~5), `clear_remaining/2` 2125–2138 (~10)
- `render/1`: geometry, help-overlay branch, **layout-map fan-in** (151–164: 12 `Map.put`s copying render-state keys onto the layout map — the regression seam), marker computation, footer split, events budget, frame assembly with DEC-2026 synchronized update + cursor hide/no-blink/park escape discipline (193–239).
- `clear_remaining/2`: absolute-position `\e[<row>;1H` + `\e[J` clear-below (the duplicate-footer fix).

### C. Help overlay — 247–339 (~80)
`render_help/2` (247–271), `help_body_rows/1` (273–313), `help_heading_row/2`, `help_line_row/2`, `help_blank_row/1`, `help_footer_row/1` (315–339).

### D. Box chrome & metadata — 343–568 (~180)
- `title_row/1` 343–353; `metadata_rows/2` 355–371; `agents_row/6` (3 clauses) 373–385; `project_row/2` (3) 387–394; `dashboard_row/2` (3) 396–403; `metadata_row_iolist/4` 405–412; `agents_row_iolist/6` 414–450 (max-agents focus/alert/drain styling)
- `separator_row/1` 452–461; `bottom_border/1` 463–502 ("newest" label injection)
- Footer: keybind constants 507–511; `footer_split/2` 518–536; `footer_keybinds_split/1` 538–552; `rc_footer_text/1` 558–563; `left_only_row/2` 565–568

### E. Table structure & row assembly — 572–636, 642–653, 655–734 (~140)
- `table_header_row/2` 572–596; `table_separator_row/2` 598–612
- `render_rows/6` (2 clauses) 614–636; `empty_body_text/1` 642–648 + `prewarm_label/1` 650–653 (prewarm loading line)
- `render_row/5` 655–734: column concatenation, exact visual-width arithmetic (706–713), selected-row `strip_csi`-then-`reverse` highlight preserving OSC 8 links (#366)

### F. Per-column cells — 744–937, 1050–1053 (~150)
- `id_cell_with_link/2` 744–752 + `ticket_url/2` 754–761 (OSC 8 issue link, #414)
- `attention_cell/2` 767–779 (`❗`/`❗N`/`❗9+`, fixed width)
- `rc_cell/1` 787–797 (📲/📱/❌ remote-control indicator)
- `progress_cell/2` 812–827 (ProgressTracker.estimate/bar; 100% green tint; dotted empty track #425)
- `runtime_cell/1` 837–840 + `format_runtime/1` (5 clauses) 842–859 + `pad2/1` 861–862
- `latest_cell/3` 869–881 + `latest_event_message/1` 1050–1053
- `@spinner_frames`/`spinner_frame/1` 888–894 (10 fps braille off `:now_ms`)
- `phase_placeholder/3` 900–920 (queued/warming/starting state machine; #425 suppression) + `starting_phrase/1` 925–930 + `engine_word/1` 932–937

### G. MODEL column — 946–1048 (~85)
`model_cell_block/2` 946–965; `model_text/3` 972–984; `model_natural_width/1` 989–996; `model_family/1` 1002–1010; `family_from_backend/1` 1012–1018; `model_base/1` (6 clauses) 1020–1025; `model_full_name/3` 1031–1042; `model_color/2` 1047–1048.

### H. Warm markers & state emoji — 1075–1167 (~70)
`compute_markers/2` 1075–1089; `marker_for_identifier/4` 1091–1097; `marker_from_attach/2` (3 clauses) 1099–1101; `summary_emoji/3` (4 clauses) 1108–1136 (⏳→🔘→⚪→🟢 progression, AgentEvents.state_emoji routing for finished/paused/sleeping, phase override #68); `phase_emoji/1` (5 clauses) 1138–1147; `emoji_cell/2` 1149–1167 (2-col leading-grapheme width rule).

### I. Column-width solver — `compute_layout/2` 1173–1274 (~85)
Natural widths, progress/model show-drop cascade, id cap, title constrained cap, latest residual, opportunistic model-version expansion. Pure function of `(summaries, inner_width)` → layout map.

### J. Text metrics / ANSI / truncation primitives — 1278–1481 (~160)
`cell/2` 1278–1288; `truncate/2` 1290–1296; `pad_with_ansi/4` 1298–1309; `padding_for/2` 1311–1324; `visual_width/1` 1331–1336; `grapheme_width/1` 1338–1343; `codepoint_width/1` (~25 clauses) 1346–1374; CSI/OSC regexes 1376–1380; `truncate_visual/2` 1389–1395; `take_visible/5` 1397–1406; `take_grapheme/5` 1408–1417; `split_escape/1` 1422–1427; `split_csi/1` 1429–1434; `osc_kind/1` 1436–1438; `drop_prefix/2` 1440–1443; `clip_and_pad/2` 1448–1455; `strip_csi/1` 1461–1463; `strip_ansi/1` 1465–1473; `eol/0` 1475.

### K. Events block geometry — 1518–1632 (~90)
`events_block/3` 1518–1526 (collapse rules: budget<2 or inner_width<4); `render_events_block/4` 1528–1562 (capacity = budget−1; suppress-then-take newest; bottom-anchored padding); `selected_identifier/1` 1564–1572; `events_divider_row/1` 1574–1605 ("oldest" label); `event_box_inner_row/2` 1608–1612; `empty_event_row/1` 1616–1619.

### L. Event-line formatting (DebugLog entry → operator text) — 1635–1954 (~230)
`format_event_line/3` 1635–1658; `event_glyph/1` 1663–1666; `event_source_ticket_id/1` 1668–1675; `ticker_self_echo?/3` 1682–1690; `comment_topic?/1` 1692–1694; `event_subject_id/4` (6 clauses) 1698–1718; `topic_suffix/1` 1720–1728; `describe_event/5` (8 clauses) 1736–1777; `publish_event_phrase/2` (~18 clauses) 1785–1840; `progress_phrase/2` 1845–1859; `progress_percent_from/1` 1861–1869; `progress_label_from/1` 1871–1876; `pr_event_phrase/2` 1878–1883; `branch_push_phrase/1` 1885–1902; `commits_word/1` 1904–1905; `commit_message/1` 1907–1911; `cross_receive_verb/1` (11 clauses) 1913–1923; `cross_receive_summary/2` (4 clauses) 1925–1944; `phrase_for_phase/1` (9 clauses) 1946–1954.

### M. Event-body extraction — 1958–2024 (~55)
`@summary_keys` 1958; `inline_summary/1` 1960–1967; `comment_body_summary/1` 1969–1979; `pr_title/1` 1981–1989; `extract_event_text/2` 1991–1999; `clip_summary/1` 2001–2012; `get_in_safe/2` 2014–2024.

### N. OSC 8 hyperlink construction — 2033–2123 (~75)
`repo_identity/1` 2033–2038; `osc8/2` 2040–2042; `link_ticket_id/2` 2044–2048; `issue_url/2`/`pr_url/2` 2050–2051; `link_verb_phrase/6` 2055–2070; `pr_linkable?/1` 2072–2075; `pr_link_target/3` 2077–2081; `pr_html_url/1` 2083–2086; `pr_number_url/2` 2088–2094; `comment_link_target/3` 2096–2107; `wrap_token/3` 2109–2123. Plus `issue_url_for/2` 1660–1661 and `ticket_url/2` (F above).

External deps: `Aiur.AgentEvents.state_emoji/1`, `Aiur.ProgressTracker.estimate/2` + `bar/2`, `IO.ANSI`. Nothing else. No process state, no ETS, no messaging — the whole file is pure `state map → iodata`.

---

## 2. Proposed module split (NAME MAP — the downstream contract)

All new files under `src/lib/aiur/agent_list/renderer/`. The facade keeps its current name and path. Dependency direction is strictly downward through the tiers; no module ever imports upward.

| # | Module | File path | Responsibility (one sentence) | ~LOC | Key functions that move there |
|---|--------|-----------|-------------------------------|------|-------------------------------|
| 0 | `Aiur.AgentList.Renderer` *(existing facade, slimmed)* | `src/lib/aiur/agent_list/renderer.ex` | Assemble one frame: geometry, layout fan-in, DEC-2026 sync-update + cursor escape discipline, section ordering, line budget, and clear-below. | ~170 | `render/1`, `lines_emitted/3`, `clear_remaining/2`, `@type state` |
| 1 | `Aiur.AgentList.Renderer.Style` | `src/lib/aiur/agent_list/renderer/style.ex` | Single source of truth for the renderer's ANSI palette (reset/bold/dim/cyan/gray/green/red/reverse + magenta/blue fallbacks), exposed as zero-arity functions. | ~45 | `reset/0`, `bold/0`, `dim/0`, `cyan/0`, `gray/0`, `green/0`, `red/0`, `reverse/0`, `magenta/0`, `blue/0` (from `@ansi_*`) |
| 2 | `Aiur.AgentList.Renderer.Text` | `src/lib/aiur/agent_list/renderer/text.ex` | Terminal text metrics and ANSI/OSC-8-safe truncation, padding, and stripping (the "never split an escape, never over-pad an emoji" primitives). | ~210 | `cell/2`, `truncate/2`, `visual_width/1`, `grapheme_width/1`, `codepoint_width/1`, `truncate_visual/2`, `take_visible/5`, `take_grapheme/5`, `split_escape/1`, `split_csi/1`, `osc_kind/1`, `drop_prefix/2`, `clip_and_pad/2`, `strip_csi/1`, `strip_ansi/1`, `pad_with_ansi/4`, `padding_for/2`, `emoji_cell/2`, `eol/0`, the CSI/OSC regexes |
| 3 | `Aiur.AgentList.Renderer.Links` | `src/lib/aiur/agent_list/renderer/links.ex` | OSC 8 hyperlink construction: issue/PR/comment URL targets and wrapping visible tokens in clickable escapes. | ~115 | `osc8/2`, `ticket_url/2`, `issue_url/2`, `issue_url_for/2`, `pr_url/2`, `link_ticket_id/2`, `link_verb_phrase/6`, `pr_linkable?/1`, `pr_link_target/3`, `pr_html_url/1`, `pr_number_url/2`, `comment_link_target/3`, `wrap_token/3`, `repo_identity/1` |
| 4 | `Aiur.AgentList.Renderer.EventPhrases` | `src/lib/aiur/agent_list/renderer/event_phrases.ex` | Topic-suffix → verb-phrase vocabulary plus event-payload body extraction (publish verbs, progress/PR/push phrasing, comment/title/summary digging). | ~190 | `publish_event_phrase/2`, `progress_phrase/2`, `progress_percent_from/1`, `progress_label_from/1`, `pr_event_phrase/2`, `branch_push_phrase/1`, `commits_word/1`, `commit_message/1`, `phrase_for_phase/1`, `inline_summary/1`, `comment_body_summary/1`, `pr_title/1`, `extract_event_text/2`, `clip_summary/1`, `get_in_safe/2`, `@summary_keys` |
| 5 | `Aiur.AgentList.Renderer.EventLine` | `src/lib/aiur/agent_list/renderer/event_line.ex` | Turn one DebugLog entry into one operator-facing line: self-echo suppression, subject/source resolution, kind dispatch, and link decoration. | ~175 | `format_event_line/3`, `event_glyph/1`, `event_source_ticket_id/1`, `ticker_self_echo?/3`, `comment_topic?/1`, `event_subject_id/4`, `topic_suffix/1`, `describe_event/5`, `cross_receive_verb/1`, `cross_receive_summary/2` |
| 6 | `Aiur.AgentList.Renderer.EventsBlock` | `src/lib/aiur/agent_list/renderer/events_block.ex` | Bottom-anchored events log inside the box: budget collapse rules, divider with "oldest" label, newest-at-bottom padding geometry. | ~130 | `events_block/3` (public entry), `render_events_block/4`, `selected_identifier/1`, `events_divider_row/1`, `event_box_inner_row/2`, `empty_event_row/1` |
| 7 | `Aiur.AgentList.Renderer.Model` | `src/lib/aiur/agent_list/renderer/model.ex` | MODEL column policy: family/base/full-version resolution, website-parity truecolor + ANSI fallback colors, natural width, and the cell block. | ~125 | `model_cell_block/2`, `model_text/3`, `model_natural_width/1`, `model_family/1`, `family_from_backend/1`, `engine_word/1`, `model_base/1`, `model_full_name/2`, `model_color/2`, `@model_truecolor`, `@model_ansi`, `@model_base_width` |
| 8 | `Aiur.AgentList.Renderer.Markers` | `src/lib/aiur/agent_list/renderer/markers.ex` | Warm-marker and state/phase emoji policy: the ⏳→🔘→⚪→🟢 progression, finished-state routing to `AgentEvents.state_emoji`, and phase-emoji overrides. | ~115 | `compute_markers/2`, `marker_for_identifier/4`, `marker_from_attach/2`, `summary_emoji/3`, `phase_emoji/1`, `@finished_work_states`, `@state_emoji_work_states`, public `finished_work_state?/1` predicate (consumed by `Cells.phase_placeholder`) |
| 9 | `Aiur.AgentList.Renderer.Layout` | `src/lib/aiur/agent_list/renderer/layout.ex` | Per-frame column-width solver and owner of every fixed cell-width constant (exposed as functions so Table/Cells/Chrome share one fact). | ~150 | `compute/2` (was `compute_layout/2`), width-constant accessors: `state_cell_width/0`, `attention_cell_width/0`, `rc_cell_width/0`, `progress_cell_width/0`, `progress_bar_width/0`, `runtime_cell_width/0`, `min_id_width/0`, `min_title_width/0`, `max_latest_width/0`, `title_constrained_cap/0`, `model_base_width/0` (delegating to `Model`) |
| 10 | `Aiur.AgentList.Renderer.Cells` | `src/lib/aiur/agent_list/renderer/cells.ex` | Per-column cell content for one agent row: linked ID, attention badge, RC indicator, progress bar, runtime ticker, and the LATEST message/placeholder with spinner. | ~190 | `id_cell_with_link/2`, `attention_cell/2`, `rc_cell/1`, `progress_cell/2`, `runtime_cell/1`, `format_runtime/1`, `pad2/1`, `latest_cell/3`, `latest_event_message/1`, `spinner_frame/1`, `@spinner_frames`, `phase_placeholder/3`, `starting_phrase/1`, `@empty_progress_track` |
| 11 | `Aiur.AgentList.Renderer.Table` | `src/lib/aiur/agent_list/renderer/table.ex` | The agent table: header/separator rows, per-row column assembly with exact width arithmetic, selected-row reverse highlight, and the empty/prewarm body line. | ~170 | `table_header_row/2`, `table_separator_row/2`, `render_rows/6`, `render_row/5`, `empty_body_text/1`, `prewarm_label/1` |
| 12 | `Aiur.AgentList.Renderer.Chrome` | `src/lib/aiur/agent_list/renderer/chrome.ex` | Box chrome outside the table: title row, metadata rows (Agents/Project/Dashboard incl. max-agents focus/alert/drain styling), section separators, "newest" bottom border, and the keybind/RC footer. | ~200 | `title_row/1`, `metadata_rows/2`, `agents_row/6`, `agents_row_iolist/6`, `project_row/2`, `dashboard_row/2`, `metadata_row_iolist/4`, `separator_row/1`, `bottom_border/1`, `footer_split/2`, `footer_keybinds_split/1`, `rc_footer_text/1`, `left_only_row/2`, keybind constants |
| 13 | `Aiur.AgentList.Renderer.Help` | `src/lib/aiur/agent_list/renderer/help.ex` | The `?` help overlay: keybind list, state-circle legend, tips, and its footer, reusing the shared box chrome. | ~95 | `render_help/2`, `help_body_rows/1`, `help_heading_row/2`, `help_line_row/2`, `help_blank_row/1`, `help_footer_row/1` |

Total ≈ 2080 LOC across 14 files (avg ~150), leaving the facade at ~170. Two files (Text ~210, Chrome ~200) sit at/just over the 200-line guiding target; both are cohesive single concerns and further splitting would manufacture seams (judgment call per the norms).

**Dependency tiers (one direction, enforced by review):**

```
Tier 0 (leaves):  Style, Text
Tier 1:           Links, EventPhrases, Model, Markers            → Style/Text
Tier 2:           EventLine (→ EventPhrases, Links), Layout (→ Model), Cells (→ Markers, Model, Links, Layout, ProgressTracker)
Tier 3:           Table (→ Cells, Model, Markers, Layout), EventsBlock (→ EventLine), Chrome, Help (→ Chrome for shared rows or Text directly)
Tier 4 (facade):  Renderer (→ Chrome, Help, Table, EventsBlock, Markers, Layout)
```

`Markers` becomes the single owner of the finished-work-state fact (`@finished_work_states`), which today is read by both `summary_emoji/3` and `phase_placeholder/3` — post-split, `Cells` calls `Markers.finished_work_state?/1` instead of holding a copy (ETS-registry-over-copied-state principle applied at module scale: one fact, one owner).

The layout map remains the intra-frame data carrier: the facade builds it once per frame (`Layout.compute/2` + the state-key fan-in) and threads it down. No module reaches back into the raw render-state map except the facade, `Chrome` (metadata/footer keys), and `EventsBlock` (`:debug_events`, selection) — matching today's exact key flows.

---

## 3. Extraction sequencing (strictly serialized waves; repo compiles + `mix test` green after each)

Every wave is one reviewable ticket, ≤400 lines moved, and touches `renderer.ex` (so waves must not run in parallel). Mechanics per wave: create the new module(s) with `def` (public) versions of the moved `defp`s, delete the originals from `renderer.ex`, rewrite call sites to `Alias.fun(...)`, run `mix test test/aiur/agent_list test/aiur/regression/warm_marker_semantics_test.exs` plus the full suite.

- **Wave 0 — characterization first, no code moved.** (a) Add full-frame snapshot tests for `Renderer.render/1` through the existing `test/support/snapshot_support.exs` harness (currently used only by the status dashboard): one rich fixture (multiple agents: queued/warming/warm/open/paused/sleeping/deactivated, RC on/launching/failed, attention counts, progress 0/55/100, pinned+unpinned models, events block populated, selection on row 2) at two widths (wide ≥170 cols, narrow 80 cols) and one help-overlay frame. (b) Add the hotspot-recommended key-census test: assert the set of state keys `App.render/1` puts on `render_state` ⊇ the keys `Renderer` consumes (pins the #414/#473/#730 seam). ~0 lines moved; gives byte-level pinning the per-feature tests don't.
- **Wave 1 — Tier-0 leaves: `Style` + `Text`** (~255 lines moved). Pure primitives with no renderer-domain knowledge; highest fan-in, so extracting them first lets every later wave move code without dragging helpers along. Byte-identical `codepoint_width` table and escape regexes.
- **Wave 2 — `Links` + `EventPhrases`** (~305 lines). Pure vocabulary + URL construction; consumed only by event formatting and the ID cell. `ticket_url/2` moves here; `id_cell_with_link` (still in renderer.ex) calls `Links.ticket_url/2`.
- **Wave 3 — `EventLine` + `EventsBlock`** (~305 lines). Completes the events pipeline; the facade's call becomes `EventsBlock.events_block(state, inner_width, budget)`. Pinned by `debug_events_ticker_test.exs` (26 tests).
- **Wave 4 — `Model` + `Markers`** (~240 lines). Moves the work-state constant sets into `Markers` as the single owner; `renderer.ex`'s remaining `phase_placeholder` switches to `Markers.finished_work_state?/1`. Pinned by the MODEL-column describe block, marker-progression tests, and `warm_marker_semantics_test.exs`.
- **Wave 5 — `Layout` + `Cells`** (~340 lines). `Layout` takes `compute_layout/2` plus all width constants (as functions); `Cells` takes the per-column renderers, consuming `Layout` widths, `Markers`, `Model`, `Links`, `ProgressTracker`. Largest-risk wave (width arithmetic); wave-0 snapshots at two widths are the guard.
- **Wave 6 — `Table` + `Help`** (~265 lines). Row assembly with the strip-CSI-then-reverse selected-row highlight moves verbatim; help overlay extracted alongside.
- **Wave 7 — `Chrome` + facade slim-down** (~230 lines). Metadata/footer/border rows move; `renderer.ex` ends at ~170 lines holding only `render/1`, `lines_emitted/3`, `clear_remaining/2`, and the frame escape discipline. Final pass deletes now-unused aliases and re-runs the snapshot fixtures unchanged (`UPDATE_SNAPSHOTS` must NOT be needed — a fixture rewrite in any wave is a red flag, not a chore).

Rationale for the order: leaves-first means each subsequent wave's moved code compiles against already-extracted dependencies, so no wave ever needs a temporary re-export shim, and the facade shrinks monotonically. Waves 2–3 and 4–5 pair a Tier-1 module with its Tier-2/3 consumer so no wave leaves a public function with zero callers.

---

## 4. Risks: semantics to preserve verbatim, existing pins, missing coverage

### 4.1 The render-state threading seam (hotspot map, cited)
`docs/refactor/research-history-hotspots.md` rows 29, 107, 125 name this exact file: *"Render-state not threaded into layout (`Map.take` pipeline class: #414/#473)… renderer desync from correct backend lifecycle (#425/#428)… new fields must be threaded through the render-state `Map.take`/`Map.put` pipeline (#414/PR #473, #425/PR #428, #730). Mechanical seam; ideal for a characterization test that diffs backend state keys against rendered layout keys."* The seam is three hops: `App.render/1` `Map.take`+21 `Map.put`s (app.ex:1458–1489) → `Renderer.render/1` layout fan-in (renderer.ex:151–164, 12 more `Map.put`s) → `Map.get(layout, key, default)` reads scattered through cells/markers. Every read has a permissive default (`%{}`, `MapSet.new()`, `false`), so a dropped key degrades silently — the historical failure mode. The decomposition **keeps the layout map shape and every default byte-identical**; the wave-0 key-census test turns future drops into failures. Do not "improve" this into structs mid-refactor — that's a follow-up ticket after the split.

### 4.2 Frame/terminal escape discipline (must move nowhere, change never)
- DEC 2026 synchronized-update bracket `\e[?2026h … \e[?2026l` around the whole frame (partial-frame "??????" flicker fix), and the cursor hide/no-blink/park triplet (`\e[?25l \e[?12l \e[H`) emitted **both** at frame start and end (line 193–239 comments) — order and duplication are load-bearing.
- `\e[H` + per-line `\e[K` instead of `\e[2J` (no full-screen blank; pinned by "skips the screen clear escape" test).
- Final-column reservation `inner_width = cols - 1` (Termius/SSH autowrap; pinned by "reserves the final terminal column" test).
- `clear_remaining/2`: absolute `\e[<lines_drawn+1>;1H` + `\e[J`, no `\r\n` (duplicate-footer bug fix; pinned).
- `lines_emitted/3`'s fixed-row count (8 + footer + body) must stay in lockstep with what the facade actually emits — it and the frame assembly stay in the same module (facade) precisely so a row added to one is visibly adjacent to the other.

### 4.3 Time semantics
`:now_ms` is captured **once** per frame (App-side or defaulted at renderer.ex:160) so the braille spinner shows the same frame on every row within a single render (comment 883–887). The `Map.get(..., System.monotonic_time(:millisecond))` fallbacks (lines 814, 891) must move verbatim into `Cells` — do not re-capture time per cell, and do not "simplify" the fallback away (tests inject `:now_ms`; production threads it from App).

### 4.4 State-policy invariants (regression-numbered)
- `@finished_work_states` / `@state_emoji_work_states` derivation (one derived from the other, lines 99–119) is the #425 fix ("finished agent never freezes on Warming up…/⏳") and #418 (💤). It is read from **two** places (`summary_emoji/3`, `phase_placeholder/3`); post-split both must consult `Markers` — a copied list in `Cells` recreates the exact "lone surface out of sync" bug #425 fixed.
- Marker precedence: opened-pane 🟢 beats attach-state; ⚪ requires slot-painted AND content; phase emoji overrides marker **only when marker ≠ ⏳** (lines 1108–1131, #68). Pinned by the ⏳→🔘→⚪→🟢 transition test and `warm_marker_semantics_test.exs`.
- Selected-row highlight: `strip_csi/1` (CSI only, OSC 8 survives) **before** wrapping in `reverse`, right border un-inverted (#366). Pinned by two tests including "preserves the ticket link on the selected row".
- Events block: collapse when `budget < 2` or `inner_width < 4`; capacity = budget − 1; self-echo suppression happens **before** `Enum.take(capacity)` (Stream pipeline, lines 1541–1547) so suppressed entries don't eat budget; newest-at-bottom with pad rows **above**. All pinned by `debug_events_ticker_test.exs`.
- Width math: `emoji_cell/2`'s "leading grapheme = 2 columns" rule, `phase_emoji(:work)`'s U+1F528-not-U+1F6E0 choice (Termius column math, comment 1140–1144), `codepoint_width`'s deliberate overcount policy for U+2600–27BF, and `truncate_visual`'s never-split-an-escape + close-open-OSC8 behavior. Extraction to `Text` must be a byte-identical move.
- `compute_layout/2` drop cascade: PROGRESS drops before MODEL considerations; MODEL drops only after TITLE/LATEST hit minimums; model version expansion is all-or-nothing into leftover pad. Pinned by the MODEL describe block (wide/medium/narrow) and "title column flexes".

### 4.5 Existing tests pinning this file (all via `render/1` — zero private-API coupling)
- `src/test/aiur/agent_list/renderer_test.exs` — 1257 lines, ~73 tests: chrome, metadata, max-agents styling, OSC 8 ID links (#414), marker progression, phase emoji (#68), engine-named placeholders, runtime ticker, footer wrap, attention/Latest (#R5/U21), progress column (#425), finished agents (#425), RC indicator (U5), MODEL column, truecolor fallback.
- `src/test/aiur/agent_list/debug_events_ticker_test.exs` — 426 lines, 26 tests: events block geometry, phrase vocabulary, suppression, OSC-8-aware truncation, App→Renderer piping.
- `src/test/aiur/agent_list/prewarm_render_test.exs` — 27 lines, 3 tests: prewarm loading line.
- `src/test/aiur/regression/warm_marker_semantics_test.exs` — 285 lines: renderer sections assert ⏳-not-🟢 for unwarm running agents, 💤 for `:sleeping` (#339), no legacy warm glyphs.

### 4.6 Missing characterization coverage (wave 0 fills the starred items)
- ★ No full-frame snapshot fixtures for the agent list (`snapshot_support.exs` currently serves only `status_dashboard_snapshot_test.exs`) — per-feature `String.contains?` assertions won't catch column-drift or escape-ordering regressions.
- ★ No key-census test across the App→Renderer→layout threading (the hotspot map's explicit recommendation).
- `format_runtime/1` ≥10h rollover to `Nh`, and negative-seconds clamp — untested.
- `truncate_visual/2` edge cases (limit ≤ 0, escape at exact boundary, BEL-terminated OSC 8) — only indirectly covered by one ticker test.
- `clear_remaining/2` at the exact `lines_drawn >= rows` boundary — untested.
- `compute_layout/2` extreme-narrow branches (id cap engaged, `latest_width == 0` short-circuit in `latest_cell/3`) — untested directly.
- Help overlay body content beyond two `contains` checks — no snapshot.
- `bottom_border/1` / `events_divider_row/1` narrow (<14 col) fallback branches — untested.

### 4.7 Adjacent duplication (flag, don't touch)
`Aiur.EventHumanizer` (+`event_humanizer_helpers.ex`, 115 lines) humanizes backend event payloads for the status dashboard — conceptually adjacent to `EventPhrases` but a different vocabulary for a different surface. Per house rules (surface conflicts, don't blend): note the overlap for a possible later consolidation ticket; do **not** merge during this behavior-preserving split.
