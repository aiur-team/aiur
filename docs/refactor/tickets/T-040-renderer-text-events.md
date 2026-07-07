# T-040: renderer wave 1: Style, Text, Links, EventPhrases, EventLine, EventsBlock

**Phase:** 4
**Depends-on:** None
**Labels:** `agent:todo` `refactor` `phase:4` `complexity:3`

## Problem / context

`src/lib/aiur/agent_list/renderer.ex` is a 2,139-line module whose public API is exactly one function, `render/1`; its ~110 private helpers span ANSI styling, terminal width math, OSC 8 hyperlinks, event phrasing, and events-block geometry. The decomposition plan is `docs/refactor/research-arch/giant-renderer.md` — its name map (§2) is the **binding contract** for module and file names. This ticket is wave 1 of 2: extract the six leaf/event-pipeline modules (`Style`, `Text`, `Links`, `EventPhrases`, `EventLine`, `EventsBlock`). T-041 extracts the rest and slims the facade.

This is a **behavior-preserving move, not a rewrite**. Move code verbatim; the only permitted edits to moved code are `defp` → `def`, adding `@spec`/`@moduledoc`, and rewriting references to moved siblings (e.g. `@ansi_gray` → `Style.gray()`). The facade `Aiur.AgentList.Renderer` keeps its name, path, and sole public `render/1`; `Aiur.AgentList.App.render/1` (src/lib/aiur/agent_list/app.ex:1491) and all existing tests keep working unchanged. The ANSI snapshot goldens added by T-012 must pass **byte-identical** — never regenerate goldens in this ticket; a golden mismatch means your change is wrong.

## Scope (exact)

All new modules live under `src/lib/aiur/agent_list/renderer/`. Line numbers refer to `src/lib/aiur/agent_list/renderer.ex` at the start of this ticket. Every moved function becomes a public `def` (with `@spec`) in its new module — no exceptions, no judgment calls. Every new module gets a `@moduledoc` (move the adjacent explanatory comments from renderer.ex into it verbatim where they exist). Extract in the order below: each step compiles against the previous ones and the repo must compile with the full suite green after step 8.

1. **Create `Aiur.AgentList.Renderer.Style`** in `src/lib/aiur/agent_list/renderer/style.ex`. Ten zero-arity public functions replacing the `@ansi_*` module attributes (lines 72–83), returning exactly the same values:
   - `reset/0` → `IO.ANSI.reset()`
   - `bold/0` → `IO.ANSI.bright()`
   - `dim/0` → `IO.ANSI.faint()`
   - `cyan/0` → `IO.ANSI.cyan()`
   - `gray/0` → `IO.ANSI.light_black()`
   - `green/0` → `IO.ANSI.green()`
   - `red/0` → `IO.ANSI.red()`
   - `reverse/0` → `IO.ANSI.reverse()`
   - `magenta/0` → `IO.ANSI.magenta()`
   - `blue/0` → `IO.ANSI.blue()`
   No other content. This module depends on nothing but `IO.ANSI`.

2. **Create `Aiur.AgentList.Renderer.Text`** in `src/lib/aiur/agent_list/renderer/text.ex`. Move verbatim from renderer.ex: `cell/2` (1278–1288), `truncate/2` (1290–1296), `pad_with_ansi/4` (1298–1309, **keep the `right_border \\ "│"` default argument**), `padding_for/2` (1311–1324), `visual_width/1` (1331–1336), `grapheme_width/1` (1338–1343), `codepoint_width/1` (all clauses, 1346–1374 — the width table is **byte-identical**, including the deliberate 2-column overcount for U+2600–27BF and U+2B00–2BFF and the `cp >= 0x1F000` catch-all), the `@csi_re`/`@osc8_re`/`@osc8_close_re` regexes (1376–1380), `truncate_visual/2` (1389–1395), `take_visible/5` (1397–1406), `take_grapheme/5` (1408–1417), `split_escape/1` (1422–1427), `split_csi/1` (1429–1434), `osc_kind/1` (1436–1438), `drop_prefix/2` (1440–1443), `clip_and_pad/2` (1448–1455), `strip_csi/1` (1461–1463), `strip_ansi/1` (1465–1473), `eol/0` (1475), and `emoji_cell/2` (1149–1167, including its leading-grapheme-counts-as-2-columns rule). Inside `Text`, replace `@ansi_reset` with `Style.reset()` and `@ansi_gray` with `Style.gray()` (alias `Aiur.AgentList.Renderer.Style`). No other changes to moved bodies.

3. **Create `Aiur.AgentList.Renderer.EventPhrases`** in `src/lib/aiur/agent_list/renderer/event_phrases.ex`. Move verbatim: `publish_event_phrase/2` (all clauses, 1785–1840), `progress_phrase/2` (1845–1859), `progress_percent_from/1` (1861–1869), `progress_label_from/1` (1871–1876), `pr_event_phrase/2` (1878–1883), `branch_push_phrase/1` (1885–1902), `commits_word/1` (1904–1905), `commit_message/1` (1907–1911), `phrase_for_phase/1` (1946–1954), the `@summary_keys` attribute (1958), `inline_summary/1` (1960–1967), `comment_body_summary/1` (1969–1979), `pr_title/1` (1981–1989), `extract_event_text/2` (1991–1999), `clip_summary/1` (2001–2012), `get_in_safe/2` (2014–2024). This module depends on nothing in the renderer tree (pure vocabulary + payload digging).

4. **Create `Aiur.AgentList.Renderer.Links`** in `src/lib/aiur/agent_list/renderer/links.ex`. Move verbatim: `ticket_url/2` (754–761), `issue_url_for/2` (1660–1661), `repo_identity/1` (2033–2038), `osc8/2` (2040–2042), `link_ticket_id/2` (2044–2048), `issue_url/2` (2050), `pr_url/2` (2051), `link_verb_phrase/6` (2055–2070), `pr_linkable?/1` (2072–2075), `pr_link_target/3` (2077–2081), `pr_html_url/1` (2083–2086), `pr_number_url/2` (2088–2094), `comment_link_target/3` (2096–2107), `wrap_token/3` (2109–2123). Inside `Links`, calls to `get_in_safe/2` become `EventPhrases.get_in_safe(...)` (alias `Aiur.AgentList.Renderer.EventPhrases`) — this is why step 3 precedes step 4.

5. **Create `Aiur.AgentList.Renderer.EventLine`** in `src/lib/aiur/agent_list/renderer/event_line.ex`. Move verbatim: `format_event_line/3` (both clauses, 1635–1658), `event_glyph/1` (1663–1666), `event_source_ticket_id/1` (1668–1675), `ticker_self_echo?/3` (1682–1690), `comment_topic?/1` (1692–1694), `event_subject_id/4` (all 6 clauses, 1698–1718), `topic_suffix/1` (1720–1728), `describe_event/5` (all 8 clauses, 1736–1777), `cross_receive_verb/1` (all 11 clauses, 1913–1923), `cross_receive_summary/2` (all 4 clauses, 1925–1944). Rewrite internal references: `publish_event_phrase`/`comment_body_summary`/`inline_summary`/`pr_title`/`clip_summary`/`branch_push_phrase` → `EventPhrases.…`; `link_ticket_id`/`issue_url_for`/`link_verb_phrase` → `Links.…`. Do NOT alter the self-echo suppression predicate or the `subject_id == source_id` guards.

6. **Create `Aiur.AgentList.Renderer.EventsBlock`** in `src/lib/aiur/agent_list/renderer/events_block.ex`. Move verbatim: `events_block/3` (1518–1526), `render_events_block/4` (1528–1562), `selected_identifier/1` (1564–1572), `events_divider_row/1` (1574–1605), `event_box_inner_row/2` (1608–1612), `empty_event_row/1` (1616–1619). Move the explanatory comment block at lines 1499–1516 into this module's `@moduledoc` verbatim. Rewrite internal references: `format_event_line` → `EventLine.format_event_line`; `repo_identity` → `Links.repo_identity`; `clip_and_pad`/`eol` → `Text.…`; `@ansi_gray`/`@ansi_reset` → `Style.gray()`/`Style.reset()`. The direct `IO.ANSI.italic()`/`IO.ANSI.faint()`/`IO.ANSI.reset()` calls in `events_divider_row/1` and `event_box_inner_row/2` stay as direct `IO.ANSI` calls. Preserve exactly: the collapse rules (`budget < 2` or `inner_width < 4` → `{[], 0}`), `capacity = max(budget - 1, 0)`, self-echo suppression happening **before** `Enum.take(capacity)` (keep the `Stream.map |> Stream.reject |> Enum.take` pipeline), pad rows **above** the events, and the `{iodata, 1 + capacity}` return.

7. **Rewrite `src/lib/aiur/agent_list/renderer.ex` (the facade)**:
   - Delete every function and attribute moved in steps 1–6 (including the `@ansi_*` attributes at 72–83 and the regex attributes at 1376–1380). Keep everything else — in particular `render/1`, `render_help/*`, all chrome/table/cell/marker/layout helpers, `lines_emitted/3`, `clear_remaining/2`, `@type state`, and all width/policy constants (`@state_cell_width` … `@model_base_width`, `@finished_work_states`, `@state_emoji_work_states`, `@empty_progress_track`, `@keybinds_*`, `@footer_left_padding*`, `@model_truecolor`, `@spinner_frames`).
   - Add aliases: `alias Aiur.AgentList.Renderer.{EventsBlock, Links, Style, Text}` (the facade does not call `EventPhrases` or `EventLine` directly).
   - Rewrite `@model_ansi` (line 97) to `%{opus: Style.magenta(), sonnet: Style.blue(), codex: Style.green()}` (compile-time remote calls; values are identical strings). `@model_truecolor` is unchanged.
   - Rewrite every remaining call site of a moved function using this exact rename map — `cell/2`, `truncate/2`, `pad_with_ansi/3,4`, `padding_for/2`, `visual_width/1`, `truncate_visual/2`, `clip_and_pad/2`, `strip_csi/1`, `strip_ansi/1`, `emoji_cell/2`, `eol/0` → `Text.<same name>`; `ticket_url/2` → `Links.ticket_url`; `events_block/3` → `EventsBlock.events_block`; every `@ansi_<x>` → `Style.<x>()` (`@ansi_bold` → `Style.bold()`, `@ansi_dim` → `Style.dim()`, etc.). Find call sites mechanically: after deleting the moved code, `mix compile` reports every undefined function/attribute — fix each with the map above. No other edits.
   - The frame protocol in `render/1` (DEC 2026 `\e[?2026h`/`\e[?2026l` bracket, the `\e[?25l \e[?12l \e[H` triplet at both frame start and end, per-line `\e[K`, `inner_width = cols - 1`) and `clear_remaining/2` move nowhere and change never.

8. **Write one test file per extracted module** (paths in Files). Plain ExUnit, `async: true`, calling the new public functions directly. Required minimum cases:
   - `style_test.exs`: each of the ten functions returns its exact `IO.ANSI` counterpart (e.g. `assert Style.gray() == IO.ANSI.light_black()`).
   - `text_test.exs`: `visual_width/1` scores ASCII 1, emoji 2, CJK 2, variation selector/ZWJ 0, and ignores ANSI escapes; `emoji_cell/2` pads `""` to full width and renders `"❗9+"` at exactly 4 columns; `truncate_visual/2` returns `""` for `limit <= 0`, never splits a CSI escape at the boundary, closes an open ST-terminated OSC 8 hyperlink when truncating inside it, and passes a BEL-terminated OSC 8 sequence at zero width; `cell/2` collapses internal whitespace and pads to width; `clip_and_pad/2` pads exact-fit text and truncates with `…` when over; `strip_csi/1` removes colors but preserves OSC 8; `strip_ansi/1` removes both.
   - `links_test.exs`: `ticket_url/2` builds the issue URL for numeric ids and returns `nil` for non-numeric ids or `nil` project; `osc8/2` produces `\e]8;;<url>\e\\<text>\e]8;;\e\\`; `link_ticket_id/2` returns plain id without a repo; `wrap_token/3` wraps only the first occurrence and is a no-op for `nil`/`""` target or no match; `pr_link_target/3` prefers `html_url` over number-derived URL over fallback; `comment_link_target/3` prefers the comment `html_url`, then PR `html_url` for `"pr.review_comment"`, then fallback.
   - `event_phrases_test.exs`: `phrase_for_phase/1` for all eight phase steps plus the `"phase " <> other` fallback; `publish_event_phrase/2` for `"agent.phase.work.start"`, a progress body with percent + label (renders `N% done` + quoted label), `"branch.push"` with commits (count + last message), `"pr.opened"` with a PR title, `"issue.commented"` with a nested comment body, and an unknown topic; `clip_summary/1` collapses embedded newlines to single spaces; `get_in_safe/2` returns `nil` on `nil` body and missing keys.
   - `event_line_test.exs`: a `:receive` of the agent's own `agent.*` echo returns `nil` (suppressed) while a self `issue.commented` receive survives as `new Issue comment:`; a cross-ticket receive renders `← <source>: pushed`; a `:publish` renders `💬 <id> <verb>`; a `:read` from another ticket renders `ingested <source>:`; an entry with no ids resolves the subject to `"?"`.
   - `events_block_test.exs`: `events_block/3` returns `{[], 0}` when `budget < 2` and when `inner_width < 4`; with budget B ≥ 2 it returns line count `1 + (B - 1)` and pads empty `│ … │` rows above the events (newest flush at bottom); suppressed self-echo entries do not consume capacity (a newer suppressed entry + older visible entries still shows the visible ones); `events_divider_row/1` contains the `oldest` label at `inner_width` 40 and falls back to the plain `├─…─┤` divider at `inner_width` 10.

9. Run the full Agent gate (below) from `src/`. Every command must pass. Do not add any new module to `ignore_modules` in `src/mix.exs` — new modules are NOT coverage-exempt (and do not remove the existing `Aiur.AgentList.Renderer` entry; T-041 handles that).

## Files

- Create: `src/lib/aiur/agent_list/renderer/style.ex`, `src/lib/aiur/agent_list/renderer/text.ex`, `src/lib/aiur/agent_list/renderer/links.ex`, `src/lib/aiur/agent_list/renderer/event_phrases.ex`, `src/lib/aiur/agent_list/renderer/event_line.ex`, `src/lib/aiur/agent_list/renderer/events_block.ex`
- Modify: `src/lib/aiur/agent_list/renderer.ex`
- Test: `src/test/aiur/agent_list/renderer/style_test.exs`, `src/test/aiur/agent_list/renderer/text_test.exs`, `src/test/aiur/agent_list/renderer/links_test.exs`, `src/test/aiur/agent_list/renderer/event_phrases_test.exs`, `src/test/aiur/agent_list/renderer/event_line_test.exs`, `src/test/aiur/agent_list/renderer/events_block_test.exs`

## Out of scope

- The T-041 modules: `Model`, `Markers`, `Layout`, `Cells`, `Table`, `Chrome`, `Help` — do not extract them, do not move any function not named in Scope.
- `src/lib/aiur/agent_list/app.ex` and the render-state `Map.take`/`Map.put` pipeline (FI-TUI-051) — untouched.
- The layout-map shape, its keys, and its permissive defaults — do not convert to structs, do not rename keys, do not change any `Map.get(..., default)`.
- The frame escape discipline and `lines_emitted/3`/`clear_remaining/2` — they stay in the facade, byte-identical.
- `Aiur.EventHumanizer` / `event_humanizer_helpers.ex` — conceptually adjacent to `EventPhrases` but a different surface; do not consolidate (flagged for a possible later ticket in giant-renderer.md §4.7).
- Existing tests: `renderer_test.exs`, `debug_events_ticker_test.exs`, `prewarm_render_test.exs`, everything under `src/test/aiur/regression/`, and all snapshot goldens — no edits, no regeneration, no `UPDATE_SNAPSHOTS`.
- `src/mix.exs` (including `ignore_modules`) and any config/CI file.

## Inventory-IDs

From `docs/refactor/feature-inventory/tui.md`:

- FI-TUI-062 — final-column autowrap guard / visual-width padding (`padding_for/2` moves to `Text`)
- FI-TUI-063 — box chrome timeline labels (`events_divider_row/1` "oldest" label moves to `EventsBlock`)
- FI-TUI-065 — fixed-width status cells (`emoji_cell/2` 2-column leading-grapheme rule moves to `Text`)
- FI-TUI-070 — OSC 8 hyperlinks, escape-safe truncation, CSI-strip-preserves-links (moves to `Links` + `Text`)
- FI-TUI-073 — bottom-anchored events block geometry (moves to `EventsBlock`)
- FI-TUI-074 — event-line natural-language formatting (moves to `EventLine` + `EventPhrases`)
- FI-TUI-075 — visual-width math table incl. the U+1F528 hammer rationale comment (moves to `Text`)
- FI-TUI-061 — flicker-free frame protocol: touched by call-site renames in renderer.ex only; the protocol itself must not move or change

## Characterization-tests

- `src/test/aiur/regression/warm_marker_semantics_test.exs` — renderer sections (⏳/💤/no-legacy-glyph assertions through `render/1`)
- The renderer ANSI snapshot suite added by T-012 under `src/test/aiur/regression/` (full-frame goldens at wide + narrow widths, help overlay, plus the render-state key-census test) — must pass byte-identical with zero fixture changes
- Additional pinning suites (outside regression/, equally binding, never edit): `src/test/aiur/agent_list/renderer_test.exs` (~73 tests), `src/test/aiur/agent_list/debug_events_ticker_test.exs` (26 tests), `src/test/aiur/agent_list/prewarm_render_test.exs`

## Acceptance criteria

- The six modules exist with these exact names: `grep -l "defmodule Aiur.AgentList.Renderer.Style do" src/lib/aiur/agent_list/renderer/style.ex` (and likewise `Text`/`Links`/`EventPhrases`/`EventLine`/`EventsBlock` in their files) each match.
- Moved code is gone from the facade: `grep -cE "defp (cell|truncate|pad_with_ansi|padding_for|visual_width|grapheme_width|codepoint_width|truncate_visual|take_visible|take_grapheme|split_escape|split_csi|osc_kind|drop_prefix|clip_and_pad|strip_csi|strip_ansi|eol|emoji_cell|ticket_url|issue_url_for|repo_identity|osc8|link_ticket_id|issue_url|pr_url|link_verb_phrase|pr_linkable\?|pr_link_target|pr_html_url|pr_number_url|comment_link_target|wrap_token|publish_event_phrase|progress_phrase|progress_percent_from|progress_label_from|pr_event_phrase|branch_push_phrase|commits_word|commit_message|phrase_for_phase|inline_summary|comment_body_summary|pr_title|extract_event_text|clip_summary|get_in_safe|format_event_line|event_glyph|event_source_ticket_id|ticker_self_echo\?|comment_topic\?|event_subject_id|topic_suffix|describe_event|cross_receive_verb|cross_receive_summary|events_block|render_events_block|selected_identifier|events_divider_row|event_box_inner_row|empty_event_row)\(" src/lib/aiur/agent_list/renderer.ex` returns 0.
- `grep -c "@ansi_" src/lib/aiur/agent_list/renderer.ex` returns 0 (palette lives only in `Style`).
- The facade's public API is unchanged: `grep -cE "^  def " src/lib/aiur/agent_list/renderer.ex` returns 1 (only `render/1`).
- Every new module has a `@moduledoc` (`grep -c "@moduledoc" <file>` ≥ 1 in all six files) and a `@spec` for every public `def`: per new file, `grep -cE "^  @spec " <file>` ≥ number of distinct public function names in that file.
- File size: `wc -l` ≤ 200 for `style.ex`, `links.ex`, `event_phrases.ex`, `event_line.ex`, `events_block.ex`; ≤ 260 for `text.ex` (giant-renderer.md §2 sizes Text at ~210 before specs — a cohesive single concern; do not split it to hit 200).
- Function size: every function clause written NEW in this ticket (test helpers, none expected in lib/) is ≤ 20 logic lines; verbatim-moved clauses are exempt — do not rewrite moved code to shorten it.
- The six test files in Files exist, are non-empty, and cover at least the cases enumerated in Scope step 8; `cd src && mix test test/aiur/agent_list/renderer` passes.
- `cd src && mix test` passes with zero failures and zero edits under `src/test/aiur/regression/`; no snapshot fixture file changes (`git status --porcelain` shows only the paths listed in Files).
- `src/mix.exs` is unchanged (`git diff --name-only` does not contain `src/mix.exs`): the six new modules are absent from `ignore_modules` and covered by the suite.
- No file outside the Files list is modified.

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
- Check: PR diff touches only the 13 paths in Files; zero changes under `src/test/aiur/regression/`, zero golden/fixture changes, `src/mix.exs` untouched.
- Check: T-012 renderer snapshot suite passes on the PR head byte-identical (`cd src && mix test test/aiur/regression/` with no `UPDATE_SNAPSHOTS` anywhere in the PR).
- Check: run the agent list against a live session — events ticker lines render as `💬/📬/📄 <id> <verb> "body"`, ticket IDs and PR/comment tokens are cmd-clickable (OSC 8), selected-row highlight still preserves the ticket link while inverted, and an 80-column terminal shows no row wrap or column drift.
- Check: `cd src && mix test --cover` reports coverage rows for all six `Aiur.AgentList.Renderer.*` modules (they are not exempt).
- Spot-check the diff of `renderer.ex`: deletions + alias-prefixed call-site renames only; the `\e[?2026h`/`\e[?25l`/`\e[?12l`/`\e[H`/`\e[?2026l` frame block and `clear_remaining/2` are byte-identical.

## Executor rules (do not skip)
- Work only on your pre-created branch `aiur/<issue-number>`; the PR base is `v2`. PR description starts `Closes #<issue-number>`.
- Commits: 3-7 word imperative messages. Never mention AI, models, or tools in commits or the PR description.
- Behavior-preserving: no feature or API changes beyond the stated Scope.
- If completing this ticket seems to require editing any file not listed in Files, stop: comment the blocker on the issue instead of touching the file.
- If any test under `src/test/aiur/regression/` fails, your change is wrong. Never edit those tests. Comment on the issue, emit `emit_alert` with `needs_attention: true`, and end your turn without opening a PR.
- Never run `aiurdev --test` or `--test3`. Verification is the Agent gate above, only.
