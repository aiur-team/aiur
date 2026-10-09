---
title: "feat: Render the analyst report on the Experiments page (EXP-X5-3) - Plan"
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
date: 2026-10-09
epic: aiur-team/aiur#3774
origin: docs/research/experiments/x5/brainstorm.md
---

# feat: Render the analyst report on the Experiments page (EXP-X5-3) - Plan

## Goal Capsule

- **Objective.** Fill the `#exp-report` slot with the X6 analyst's Markdown report, safely rendered, including the tables a data-scientist report needs, with "pending" and "results changed since this report" states.
- **Product authority.** `docs/research/experiments/x5/brainstorm.md` D4 section 6, D7 (report pending), R3, R5. Product Contract unchanged.
- **Open blockers.** EXP-X5-1 (slot). The facade must expose `report: %{markdown, written_at, results_at}` or `nil` (X2 stores what X6 writes).

---

## Summary

Reuse `AiurWeb.Markdown` (`src/lib/aiur_web/markdown.ex`, dependency-free, escapes every content run, 176 lines). Add GitHub-style pipe tables to it, because analyst reports carry sample-size, p-value and effect-size tables, and the renderer has no table support today (it handles headings, paragraphs, fences, blockquotes, lists, inline code, emphasis and links only; module doc lines 3-12).

## Requirements

R3 (section 6), R5 (report pending), D10 (accessible tables).

## Key Technical Decisions

- **KTD1 Extend the shared renderer, not a new one.** A second Markdown renderer would drift. Tables help other surfaces too (ticket context, Commands long context). Change is additive: a block whose first line has pipes and whose second line is a delimiter row (`| --- | :---: |`) becomes a table; anything else stays as before.
- **KTD2 Safety unchanged.** Cell text goes through the same escaping and inline rules as paragraphs. Column alignment comes only from the delimiter row and maps to a fixed class (`md-al-l`, `md-al-c`, `md-al-r`), never an inline style from input. Links keep the `http`/`https` allowlist.
- **KTD3 Input passes the display sanitizer.** The page passes report Markdown through `Aiur.DisplaySanitizer` before rendering, the same contract `AiurWeb.Markdown` documents, so credentials and local paths in a report are redacted.
- **KTD4 Report states.** `nil` report: "The analyst has not written a report for this experiment yet." With `results_at > written_at`: a note "Results changed after this report was written (report <written_at>, results <results_at>)". Times use the shell's relative-time format with the absolute time in `title`.
- **KTD5 Layout.** The report sits in an `an-card` titled "Analyst report" with the author and time in the sub-line. Report tables scroll inside a wrapper on narrow screens. Headings inside the report start at `h3` (the renderer's heading levels are offset by 2 for this slot) so the page outline stays valid.
- **KTD6 No verdict words are added by the page.** The analyst's own words are shown as written; the no-verdict-word rule applies to page chrome only (X6 owns report wording and labels).

## Implementation Units

### U1. Pipe tables in AiurWeb.Markdown

**Goal:** Render GFM-style tables safely.
**Requirements:** KTD1, KTD2.
**Dependencies:** none (can start before EXP-X5-1).
**Files:** `src/lib/aiur_web/markdown.ex`, `src/test/aiur_web/markdown_test.exs`, `src/priv/static/dashboard.css` (table rules next to `.ticket-context-markdown`).
**Approach:** Detect the table block in `render_block/1`; split rows on unescaped pipes; header row to `<thead>`, the rest to `<tbody>`; alignment from the delimiter row; ragged rows padded with empty cells. Add an optional heading offset argument (default 0).
**Test scenarios:**
- A 3x3 table with left, centre and right alignment renders `<table>` with the three classes.
- Cell `<script>alert(1)</script>` renders escaped text.
- Cell link `[x](javascript:alert(1))` renders as text, not a link.
- An escaped pipe `\|` inside a cell stays in the cell.
- A line with pipes but no delimiter row stays a paragraph (no regression for existing ticket text).
- Ragged row with fewer cells is padded; extra cells are kept in a last cell rather than dropped.
- Existing `markdown_test.exs` cases all pass unchanged.
- Heading offset 2 turns `#` into `h3` and caps at `h6`.
**Verification:** markdown tests green; ticket context and Commands pages unchanged in their visual baselines.

### U2. Report slot on the page

**Goal:** Show the report and its states.
**Requirements:** R3, R5, KTD3-KTD5.
**Dependencies:** U1, EXP-X5-1.
**Files:** `src/lib/aiur_web/experiments/components.ex`, `src/lib/aiur_web/experiments/view_model.ex`, `src/lib/aiur_web/experiments/styles.ex`, `src/test/aiur_web/live/experiments_live_test.exs`, `src/test/aiur_web/experiments/view_model_test.exs`, `src/browser/tests/experiments.browser.spec.mjs`.
**Test scenarios:**
- Report present: card "Analyst report" with author and time; a fixture table with p-values renders as a table.
- Report `nil`: the pending copy, exact text.
- `results_at` after `written_at`: the "results changed" note with both times.
- A report containing a home-directory path and a token-shaped string renders redacted.
- Browser at 390: a wide report table scrolls inside its wrapper; the document does not scroll sideways.
**Verification:** suites green; a real X6 report renders on a rebuilt daemon.

---

## Scope Boundaries

- No editing or commenting on the report from the page.
- No Markdown features beyond tables (no footnotes, images or HTML passthrough).

## Risks

- **Renderer change touches other pages.** Mitigated by the "no delimiter row, no table" rule and by running the existing ticket-context and Commands browser specs.

## Documentation

- `website/docs-app/guide/gui.md` "Read an experiment" (added by EXP-X5-1) gains one line: the report is the analyst's text and may lag the charts; the page says when it does.

## Definition of Done

U1-U2 merged; markdown, LiveView and browser suites green on the head SHA.
