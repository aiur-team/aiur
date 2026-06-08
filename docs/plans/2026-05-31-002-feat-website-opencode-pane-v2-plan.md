---
title: "feat: Website opencode pane v2 — staged steering narrative"
type: feat
status: active
date: 2026-05-31
origin: docs/brainstorms/2026-05-31-website-opencode-pane-v2-requirements.md
supersedes-beat-of: docs/plans/2026-05-31-001-feat-website-opencode-pane-plan.md
---

# feat: Website opencode pane v2 — staged steering narrative

## Overview

The take-the-wheel beat shipped (PR #242, plan `docs/plans/2026-05-31-001-feat-website-opencode-pane-plan.md`) as a short, whole-line, box-drawing opencode pane whose operator decision *caused* #321's downstream `#321 → #324` auto-unblock. This v2 reworks that beat into a more faithful, more cinematic scene and splits the loop into **two distinct stories**: (1) a human-in-the-loop steering beat on #321 that does *not* resolve the ticket, followed by (2) a separate autonomous unblock between two other agents (`#318 → #319`). It also rebuilds the opencode pane to mimic the real opencode UI (background-tinted message blocks instead of box-drawing chrome), removes all footer/help text, animates the selection cursor walking the agent list, and adds character-by-character typing in the input box.

This extends the existing single-`<pre>` sim and keeps its core fidelity (1Hz content repaint, braille spinner, ≤96-col grid, container-query font, clean loop reset). The one deliberate fidelity relaxation is the operator's input typing (see Key Decisions).

Work pushes directly to `main` per the operator's standing website-fix instruction — no feature branch, no PR. Each unit lands as its own small commit, build/assert green before each push.

---

## Problem Frame

The shipped beat reads as one causal chain (human decides → ticket resolves → downstream unblocks). The operator wants the loop to instead show the two capabilities *separately and more vividly*: a human walking to a stuck agent and steering it (without the agent finishing), and — distinctly — agents unblocking each other with no human involved. The pane must also look like the real opencode TUI (background message blocks, accent gutter on commands, filled input field, `❗`/chip) rather than the box-drawing approximation that shipped. See origin: `docs/brainstorms/2026-05-31-website-opencode-pane-v2-requirements.md`.

---

## Requirements Trace

Carried/revised from the v2 requirements deltas (D1–D7) and the still-valid shipped requirements (R1–R3, R7 layout/lifecycle/fidelity, R9–R12 reflow/reduced-motion/reset):

- R-V1 (D1). Loop tells **two separate occurrences**: human steering on #321 **first**, then a `#318 → #319` autonomous unblock **after** the beat closes. The `#321 → #324` causal tie is removed; #321 stays unresolved; #324 stays blocked.
- R-V2 (D2). opencode pane reproduces real opencode chrome with **background-tinted regions, not box-drawing lines**: plain assistant prose, accent gutter bar only on `$ cmd` / `→ tool` lines, a background-block user message, `▣ Build · issue-321` chip, `❗ Alert sent.` (replacing `👍`), and a filled input field with an accent left bar + label. No `┃` per-line rail, no `┌┐└┘` box.
- R-V3 (D2). **No footer/help text** in either pane at any resolution (dashboard footer already removed this session; remove the opencode `esc interrupt …` footer too).
- R-V4 (D3). **Typewriter is allowed for the operator's input only** — char-by-char at semi-random but consistent speed (~80–140ms/char), deterministic on `loopSec`. Everything else still appears whole on the 1Hz repaint.
- R-V5 (D4). The selection cursor **descends the agent list one row at a time** to #321 before the pane opens, and **ascends back to the top** after it closes; the left dashboard log keeps updating throughout.
- R-V6 (D5). Staged sequence in order: cursor descent → pane open → static history ending in "blocked on a user-facing decision" → `❗ Alert sent.` + pre-loaded A/B/C question → operator types `lets brainstorm options` → Enter posts it as a user block → pause → agent replies "OK. Let me get back to you with some options." → pause → pane closes + cursor ascends.
- R-V7 (D6). `prefers-reduced-motion` resolves to a clean static frame: pane open, posted user message + agent reply visible, input empty, cursor static.
- R-V8 (D7). Stack panes vertically only on a truly narrow portrait viewport; medium/landscape stay side-by-side; wide pins the dashboard log to 3 lines. **(Shipped this session — verification-only here.)**
- R-V9 (R12). Clean loop reset: all beat/animation state derived from `loopSec`; nothing persists across the wrap.

**Origin actors:** A1 (Operator/human), A2 (Driven agent — opencode session for #321), A3 (Fleet — dashboard sim, including the `#318 → #319` autonomous pair).
**Origin flows:** F1 (Take the wheel on a stuck ticket — now non-resolving), F2 (autonomous `#318 → #319` unblock — separate occurrence).
**Origin acceptance examples (revised):** AE-V1 (R-V1 — human beat opens before the `#318 → #319` receive fires), AE-V2 (R-V6 — staged sequence renders in order), AE-V3 (R-V4 — only the operator input types char-by-char; all other lines whole), AE-V4 (R-V7 — reduced-motion freezes on the posted-message + reply frame, input empty, no cursor blink; covered by U6), AE-V5 (R-V8 — narrow stacks, no overflow; verification-only, R-V8 already shipped this session).

---

## Scope Boundaries

- No real interactivity — the cursor walk, typing, and "Enter" are scripted; the viewer cannot drive the session.
- No real opencode integration, backend, or live model output — deterministic animation like the rest of the sim.
- Not full opencode-TUI fidelity — a believable minimal slice (history, alert, decision question, one typed reply, one agent reply), not model picker / token counts / multi-tab / syntax-highlighted diffs.
- Does not change the `#318 → #319` chain's *content* — only its **timing** (re-sequenced to play after the human beat) so it reads as the second, separate occurrence.
- Does not change the 90s loop length, the 1Hz/10fps cadence, or any non-#321/#324/#318/#319 ticket.
- Responsive stacking threshold and wide-res 3-log behavior already shipped this session; this plan only verifies them, it does not re-implement them.

---

## Context & Research

### Relevant Code and Patterns

- `website/src/dashboard.ts` — single-`<pre>` renderer. **Seg** model (`raw`/`emo`/`mark`/`spin`/`cat`/`padEnd`/`padStart`/`dashes`/`trunc`/`esc`) is the width-aware building block; every row must total its geometry width. opencode helpers today: `ocRail` (`┃ `), `ocRow` (rail + padEnd to `OC_INNER`=63), `ocBlank`, `ocTranscript` (cmd/tool/ack/prose), `ocInputBox` (box-drawing `┌┐└┘`), `ocFooter`, `buildOpencodeLines`. `OC_PANE_W`=65, `OC_INNER`=63, `OC_RAIL_W`=2, `OC_GUTTER`=1. `renderFrame(nowMs, baseMs)` computes `loopSec`, `inBeat = loopSec >= BEAT.open && loopSec < BEAT.close`, then branches non-beat / side-by-side `joinColumns` / stacked. `buildDashboardLines(loopSec, spinIdx, {dropLatest, selectedId?, logOverride?})` builds the dashboard; `ticketRow` has the `blocked`/`decide` spinner branch and `mark(selected)` (`▶`). Ticket selection in full-width defaults to row 0 (`i === 0`). Module flags: `sideBySide`, `wide`, `logLines`. `chooseLayout` (resize-driven) sets `wide`/`sideBySide`; `fitLogLines` pins `logLines`.
- `website/src/simData.ts` — `BEAT = { decideStart, open, decision, close }`, `TICKETS` (#321 index 5, `opus`; #318 codex, #319 sonnet), `EVENTS` (incl. `#318→#319` at t=8–14, `#321` t=26 publish, `#324` t=46 receive), `OPENCODE_SCRIPT` (chip / chipDoneAt / inputLabel / decisionText / decisionAt / `lines: OcLine[]`). `sample()` overlays the latest matching event text into the LATEST cell.
- `website/src/styles.css` — `.tui-pre { font-size: clamp(6px,1.7cqi,16.5px); white-space: pre; }`. Tokens: `--term-accent`, `--term-ok`, `--term-dim`, `--term-mag`, `--tui-line`, `--term-bg`, `--term-fg` (dark + light themes). Existing oc classes: `.oc-rail`/`.oc-cmd`/`.oc-tool`/`.oc-chip`/`.oc-input`. `.e1`/`.e2` pin 1ch/2ch glyph cells. `.cursor` is an existing blinking-block class (`@keyframes blink`).
- `website/scripts/assert-sim.ts` — invariant checks: golden byte-equality (non-beat frames), abbreviated rows == 30 cols, **`#321.publish.t < #324.receive.t`** (will be removed), opencode rows == `OC_PANE_W`, side-by-side join == 96 cols.
- `website/scripts/gen-golden.ts` + `dashboard-golden.json` — golden captured at `Ls = [0,5,10,18,45,60,80]` via `renderFrame(L*1000, 0)` (node default `logLines`=`MIN_LOG_LINES`=6).

### Institutional Learnings

- `docs/solutions/` has no entries touching the website sim (confirmed in the v1 plan). Memory note `project_terminal_sim_demo` records the agreed creative decisions (ShopWave theme, AGENT column, unblock chains) — update it only if the final beat timeline / driven-ticket choice diverges from what it records.

### External References

- None. The sim is a strong self-contained local pattern and the operator supplied the fidelity target (reference screenshots) directly. External research skipped.

---

## Key Technical Decisions

### Two occurrences, re-sequenced — human beat first, `#318 → #319` after (R-V1)

Remove the causal `#321 → #324` chain: drop #321's `t=26 "schema migrated to uuid pks"` publish and #324's `t=46 "← #321: schema ready, unblocking"` receive. #321 holds its `decide` state through the human beat and does **not** resume. #324 stays `blocked` all loop (coherent: #321 never delivers). Move the human beat to play **before** the `#318 → #319` autonomous unblock in loop time — the `#318 → #319` content is unchanged, only re-timed so it reads as the second, separate demonstration. This reverses shipped R5/AE4; it is the central narrative change.

### Background-block rendering inside the `<pre>` (R-V2)

opencode delineates turns with background color, not box-drawing. Within one monospace `<pre>` (`white-space: pre`), a row whose full content is wrapped in a single `<span>` padded to the pane width renders as a solid colored band when that span carries a `background-color`. So the pane is composed of:
- **Plain prose rows** — no rail, no background.
- **Command/tool rows** — a short accent **gutter glyph** (e.g. `▌`, width-pinned) + space on the left only, then dim/ok text. This is the only gutter marker.
- **User-message block** — one or more consecutive rows each wrapped in a `oc-userblock` background span (subtle accent tint), the operator's posted text inside.
- **Input field** — a small stack of rows each wrapped in an `oc-field` background span with an accent left bar glyph; the prompt row shows `› <typed text><cursor>`, a label row shows `Build · issue-321 its-everdred/shopwave` (dim). No `┌┐└┘`.

Every row still totals `OC_PANE_W`=65 cols (the assert and join math are unchanged). Replacing the `┃ ` rail with a 0–2 col gutter means non-cmd/tool rows pad content to the full 65 (no rail), and the renderer must keep widths exact.

### Typewriter scoped to the operator's input only (R-V4)

The shipped "no typewriter" rule is relaxed for exactly one element: the operator typing `lets brainstorm options` into the input field, char-by-char at semi-random-but-consistent speed. Implement as a **precomputed array of cumulative per-char reveal offsets** (deterministic, seeded constant — not `Math.random()` at render time) so the same `loopSec` always yields the same revealed substring and the loop stays reproducible/reset-clean. The visible substring length = count of offsets ≤ `(loopSec - typeStart)`. Sub-second resolution is fine at the existing 100ms tick. The blinking cursor reuses the existing `.cursor` class. At `sendAt`, the field clears and the full text appears as a `oc-userblock` (posted whole). All other lines (history, alert, A/B/C question, agent reply) appear whole on the 1Hz step.

### Cursor descent/ascent are functions of `loopSec`, rendered in the full-width dashboard (R-V5)

The `▶` marker walks the visible rows by computing the selected row index from `loopSec`:
- `[descentStart, open)` — full-width dashboard (pane not yet open), marker steps row 0 → #321's visible index (5), one row per fixed step (~0.4–0.5s).
- `[open, close)` — split open, marker pinned on #321.
- `[close, ascentEnd)` — full-width dashboard again, marker steps #321 index → 0.
- otherwise — marker on default row 0.

This requires `buildDashboardLines` to honor `selectedId`/selected-row in the **full-width** variant too (today full-width hardcodes row 0). The left log keeps updating because the dashboard is rebuilt every frame regardless of marker position. No mutable state — the row index is a pure function of `loopSec`.

### Beat timeline (constants tuned in implementation)

The v2 beat is longer than the shipped 10s window. Directional budget (exact constants are an implementation detail, validated by watching one loop): descent ~3s, open + read history ~3s, alert + question land, type window ~3s, send, pause ~1.5s, reply, pause ~1.5s, close + ascent ~3s — roughly an ~16–20s beat. It must (a) start before the `#318 → #319` receive so the human beat is visibly first, and (b) leave the rest of the loop coherent. The `BEAT` shape grows to carry the new milestones (`descentStart`, `open`, `alertAt`, `typeStart`, `sendAt`, `replyAt`, `close`, `ascentEnd`); the pane is open only `[open, close)`.

### Pane row budget — fix `OC_TOTAL_ROWS` ≤ dashboard height before rendering (R-V2)

The shipped v1 pane was ~17 rows and fit under the 18-row dashboard. v2 *adds* the A/B/C question (~3 rows), an agent reply, and a posted user block while only removing the 1-row footer — so the fullest state plausibly crosses 18 and would force the whole joined grid to grow then shrink mid-loop. Before U3 renders anything, enumerate the maximum rows the pane can occupy:

| Section | Max rows |
|---|---|
| chip | 1 |
| static history | N (lock N — budget ~5–6) |
| `❗ Alert sent.` | 1 |
| A/B/C question | up to 3 |
| posted user block | 1 |
| agent reply | 1–2 |
| input field (prompt + label) | 2 |

Lock `OC_TOTAL_ROWS` as a named constant whose value is **≤ 18** (the abbreviated/full dashboard height). If the natural maximum exceeds 18, trim the history line count or collapse the A/B/C question onto fewer rows until it fits — do not let the pane drive the grid taller than the dashboard. U6 asserts `buildOpencodeLines(loopSec).length === OC_TOTAL_ROWS` for **every** `loopSec` in `[open, close)` *and* `OC_TOTAL_ROWS ≤` the abbreviated dashboard row count. This converts the deferred "logLines/pane-height rebalancing" question into a checked invariant.

### Reduced-motion frame lands on the posted-message + reply state (R-V7)

Set the reduced-motion `nowMs` offset to a `loopSec` in `[replyAt, close)` so the frozen frame shows the pane open, the posted `lets brainstorm options` block and the agent reply both visible, the input field empty, and the cursor static (the static frame must not animate the cursor blink — gate `.cursor` out under reduced motion or freeze on a non-blinking variant).

### Verification = build + assertion script + manual one-loop observation

`website/` has no test runner; `npm run build` = `tsc --noEmit && vite build`, `npm run assert` = `tsx scripts/assert-sim.ts`. Update the assertions for the new data/geometry, regenerate the golden for non-beat frames, and watch one loop at wide + narrow + reduced-motion in the browser.

---

## Open Questions

### Resolved During Planning

- *Drop the downstream unblock entirely?* → No. Keep it as a **separate** `#318 → #319` occurrence after the human beat; only the `#321 → #324` causal tie is removed (origin D1, user clarification).
- *How to render background blocks in a `<pre>`?* → Full-row `<span>` with `background-color`, padded to pane width; one band per message turn.
- *How to keep typing deterministic?* → Precomputed cumulative per-char offset array keyed off `loopSec`, not runtime randomness.
- *Where does reduced-motion freeze?* → `[replyAt, close)` — posted message + reply visible, input empty, cursor static.
- *Update v1 plan or write v2?* → New v2 plan referencing v1 (v1 is fully shipped; v2 reverses several of its decisions).
- *Does the pane risk growing taller than the dashboard?* → Yes — resolved as the "Pane row budget" decision: `OC_TOTAL_ROWS` is a named constant ≤ dashboard height, asserted in U6 (no longer a deferred rebalancing question).
- *Does #324's blocked text need a tweak?* → Yes — reword it so it no longer names #321 (resolved in U1; see Key Decisions).

### Deferred to Implementation

- Exact A/B/C question copy and the static-history transcript lines — draft and refine while rendering against the reference screenshots. **These strings are the entire narrative payload; vague copy is the clearest path to a generic/AI-slop result. Lock them (and which lines are `prose` vs `cmd`/`tool`) against the reference before U3, ideally with an operator glance.**
- Exact `BEAT` constants, the per-row cursor-walk cadence, and the per-char typing offsets — tuned by watching one loop. **Constraint: the constants must (a) keep the human beat opening before the re-timed `#318 → #319` receive, and (b) avoid leaving the loop-opening window `[0, descentStart)` visually dead — once `#318 → #319` moves after `BEAT.close`, nothing fills the early loop. Decide the loop-opening motion explicitly (start the descent early near t≈2–4, or keep a small early ambient event) rather than discovering dead air at tuning time.**
- Exact palette tokens / opacity for `oc-userblock` and `oc-field` backgrounds in both themes, and the gutter glyph choice (`▌` vs a bg bar) — validate contrast and that glyphs don't break column math. **The user-message block is the single element that distinguishes a human turn from assistant prose; pick opacity so the band is clearly visible against `--term-bg` in *both* dark (`#111317`) and light (`#f7f2e8`) themes before relying on it.**

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. Treat it as context, not code to reproduce.*

```
renderFrame(nowMs, baseMs):
  loopSec = (nowMs - baseMs)/1000 % LOOP_SECONDS
  spinIdx = ...
  sel     = selectedRow(loopSec)        // 0..5, walks during descent/ascent, pinned on #321 in-beat
  paneOpen = BEAT.open <= loopSec < BEAT.close

  if not paneOpen:
      dash = buildDashboardLines(loopSec, spinIdx, { dropLatest:false, selectedId: idAt(sel) })
      return pre(dash)                  // includes descent (before open) and ascent (after close)
  else if sideBySide:
      dash = buildDashboardLines(loopSec, spinIdx, { dropLatest:true, selectedId: 321 })
      return pre(joinColumns(dash, buildOpencodeLines(loopSec, spinIdx)))
  else:
      ... stacked ...

buildOpencodeLines(loopSec, spinIdx):
  rows = [ chipRow ]
  rows += staticHistoryRows()                       // whole; prose plain, cmd/tool with accent gutter
  if loopSec >= BEAT.alertAt:  rows += [ alertRow("❗ Alert sent."), questionRowsABC() ]   // whole
  if loopSec >= BEAT.sendAt:   rows += userBlock("lets brainstorm options")               // posted whole
  if loopSec >= BEAT.replyAt:  rows += [ proseRow("OK. Let me get back to you with some options.") ]
  rows += inputField(loopSec)                        // typed substring + cursor pre-send; empty post-send
  return padAllTo(rows, OC_PANE_W, OC_TOTAL_ROWS)     // pad to fixed row count AND fixed col width

inputField(loopSec):
  shown = (BEAT.typeStart <= loopSec < BEAT.sendAt) ? revealedSubstring(loopSec) : ""
  ...background-block rows with accent left bar, prompt row "› {shown}{cursor}", label row...
```

`buildOpencodeLines` keeps a **fixed total row count** (`OC_TOTAL_ROWS`) across the beat — it emits blank background/plain rows for not-yet-shown turns so the split height stays stable and `joinColumns` padding/height math is unchanged.

**Row budget (hard constraint — see "Pane row budget" decision below):** `OC_TOTAL_ROWS` must be **≤ the dashboard's rendered height** (currently 18 rows on wide: `NON_TICKET_ROWS`=9 + `VISIBLE_TICKETS`=6 + `WIDE_LOG_LINES`=3). `joinColumns` sets joined height to `max(left, right)`, so a pane taller than the dashboard makes the *entire* grid grow vertically the instant the beat reaches its fullest state and shrink again at close — a visible mid-loop jump and a container overflow at constrained heights. The fullest state (chip + history + alert + A/B/C question + posted user block + agent reply + input field) is also exactly the reduced-motion freeze frame, so an overflow here ships permanently to reduced-motion users.

---

## Implementation Units

- [ ] U1. **Re-sequence the data: two occurrences, drop the `#321 → #324` tie, restructure `OPENCODE_SCRIPT` for the staged narrative**

**Goal:** Make `simData.ts` tell the v2 story: #321 stays in `decide` through the human beat (no resume, no publish), the `#318 → #319` unblock is re-timed to play after the beat, and the opencode script carries the staged-narrative content (history, alert, A/B/C question, typed text, posted message, agent reply) with the new `BEAT` milestones.

**Requirements:** R-V1, R-V6, R-V9; supports AE-V1, AE-V2.

**Dependencies:** None.

**Files:**
- Modify: `website/src/simData.ts`

**Approach:**
- Grow `BEAT` to the v2 milestones: `descentStart`, `open`, `alertAt`, `typeStart`, `sendAt`, `replyAt`, `close`, `ascentEnd` (values directional; tune in U6 verification). Keep `decideStart` semantics for #321's stall.
- Rewrite #321 `frames` so it holds `decide` ("needs a decision: backfill strategy" or similar) from ~`decideStart` through the loop — remove the t=26 `implement`/resume frames.
- **Remove** the `#321` `t=26 "schema migrated to uuid pks"` publish EVENT and the `#324` `t=46 "← #321: schema ready, unblocking"` receive EVENT. Leave #324 `blocked` for the loop, and **reword #324's blocked LATEST so it no longer names #321** as the unblocker (e.g. block it on a generic/different dependency). Without this, a viewer watching the 90s loop sees #324 promise "blocked on #321 schema" while #321 visibly never delivers — an unfulfilled tie that reads as a bug, the opposite of the intended coherence. (Resolves the former open question.)
- **Re-time the `#318 → #319` EVENTS *and* #318's own completion frames** (today #318 hits `done`/"auth API ready" at t=8/11) **and #319's frames** to fire *after* `BEAT.close`, so #318 finishes shortly *before* #319 ingests it (crisp cause-and-effect, not a 25s gap of #318 sitting "done"). The text/content of each event and frame is unchanged — only the times move. Verify #319's pull-in→rebase→implement arc still fits the remaining loop seconds with believable progress pacing.
- Replace `OPENCODE_SCRIPT` with a v2 structure: `chip`, static `history` lines (kind-tagged: `prose`/`cmd`/`tool`), `alertText` ("❗ Alert sent." rendered by the pane), `question` (A/B/C copy), `typedText` ("lets brainstorm options") + the per-char reveal offsets (or a function deriving them deterministically), `reply` ("OK. Let me get back to you with some options."), `inputLabel`, and milestone times keyed to `BEAT`. Keep `OcLine`/`OcKind` or extend the types as needed.

**Patterns to follow:** Existing `TicketScript.frames` / `LogEvent` / `OpencodeScript` shapes; `sample()`'s latest-event-wins overlay contract.

**Test scenarios:**
- Covers AE-V1. At `loopSec` just before `BEAT.open`, the `#318 → #319` receive has **not** fired (human beat is first); the `#318 → #319` receive fires only after `BEAT.close`.
- Happy path: at `loopSec` in `[decideStart, close)`, #321's sampled phase is `decide` with the needs-decision LATEST text and no "schema migrated"/"pushed" text anywhere.
- Edge: no `#321` publish event and no `#324` receive event exist in `EVENTS`.
- Edge: at the t=0 seed and just before `LOOP_SECONDS`, #321 and #319 are at their seed frames (clean reset, R-V9).
- Test expectation: no test runner; verified via typecheck + the U6 assert script + manual observation.

**Verification:** Across one loop, #321 visibly stalls (`✋`/`decide` + spinner) and never resolves; the `#318 → #319` unblock plays *after* the pane closes; no stale #321 publish/#324 receive in the log.

---

- [ ] U2. **opencode chrome CSS: background blocks, gutter bar, filled input field, `❗`/glyph width pins; remove rail/box styling**

**Goal:** Add the `.tui-pre` descendant classes the v2 pane needs so background-tinted blocks, the accent gutter, and the filled input field render correctly in both themes, with glyph widths pinned so the grid never drifts.

**Requirements:** R-V2, R-V3.

**Dependencies:** None (class names defined together with U3; can land alongside).

**Files:**
- Modify: `website/src/styles.css`

**Approach:**
- Add `oc-userblock` (subtle accent-tint `background-color`, readable fg) and `oc-field` (input-field background + accent left-bar treatment) classes; ensure backgrounds read well on both dark (`--term-bg #111317`) and light (`#f7f2e8`) themes using existing tokens / low-opacity accent.
- Add/adjust a gutter class for the cmd/tool accent bar glyph; keep `oc-cmd`/`oc-tool`/`oc-chip` colors.
- Pin `❗` (and the gutter glyph, e.g. `▌`) to `.e2`/`.e1` or verify single/double-width in the monospace stack so column math holds.
- Ensure the reduced-motion media query suppresses the `.cursor` blink (static frame must not animate).

**Patterns to follow:** Existing `.tui-pre .oc-*`, `.e1`/`.e2`, `.cursor`, the dark/light token blocks.

**Test scenarios:**
- Test expectation: none automated — pure styling. Verified visually against the reference screenshots (block tint, gutter bar, filled input field, chip) in both themes, and by confirming `❗`/`▌` don't shift the grid.

**Verification:** Pane colors/weights match the reference; glyphs don't break alignment; `npm run build` passes; reduced-motion shows no cursor blink.

---

- [ ] U3. **Rebuild `buildOpencodeLines`: background-block renderer, accent gutter, filled input field, `❗ Alert sent.`, no footer/rail/box**

**Goal:** Render the v2 opencode pane as a fixed-height `Seg`-row array faithful to opencode chrome — plain prose, gutter-barred cmd/tool, `▣` chip, `❗ Alert sent.`, A/B/C question, user-message background block, agent reply, and a filled input field — every row exactly `OC_PANE_W` cols, no `┃` rail / `┌┐└┘` box / footer.

**Requirements:** R-V2, R-V3, R-V6; supports AE-V2, AE-V3.

**Dependencies:** U1 (script data), U2 (classes).

**Files:**
- Modify: `website/src/dashboard.ts`

**Approach:**
- Add a `block(content, cls)` Seg helper that pads content to the pane width and wraps the whole row in a single `<span class>` so the `background-color` spans the full row; use it for `oc-userblock` and `oc-field` rows. **Every row — including blank placeholders and background-block rows — must carry `OC_PANE_W` literal padding characters *inside* the wrapping span** (do not rely on CSS width), so the Seg width model and the assert's `visibleWidth` agree.
- Rewrite `buildOpencodeLines`: chip row → static history rows (prose plain via railless `padEnd` to 65; cmd/tool with the accent gutter glyph + dim/ok text) → (after `alertAt`) `❗ Alert sent.` row + A/B/C question rows → (after `sendAt`) `oc-userblock` rows with the posted text → (after `replyAt`) agent reply prose row → input field rows (U4 fills the typed text). Keep a **fixed total row count** (`OC_TOTAL_ROWS`, ≤ dashboard height — see "Pane row budget") by emitting blank/placeholder rows for not-yet-shown turns so split height is stable.
- Add a plain-row helper (railless `padEnd` to 65) to replace `ocRow`'s rail-prefix behavior, then delete `ocRow`, `ocRail`, `ocFooter`, the `┌┐└┘` `ocInputBox`, and the `👍` `ack` branch. **`ocRow` is load-bearing** — it is called by `ocBlank`/`ocTranscript`/`ocInputBox`/`ocFooter`, so it must be replaced (not just have its `ocRail` dependency deleted) or the build breaks. Truncate any over-long line with `trunc(_, …)` so rows never exceed 65.

**Patterns to follow:** `padEnd`/`cat`/`raw`/`trunc`/`spin`; the row-width discipline of the old `ocRow`; existing chip logic.

**Test scenarios:**
- Covers AE-V2. At a `loopSec` after `alertAt` but before `sendAt`, the rows include (in order) the chip, history (with at least one gutter-barred cmd/tool row and plain prose), `❗ Alert sent.`, the A/B/C question, and the input field — and no footer/rail/box glyphs.
- Edge: every returned row's display width equals `OC_PANE_W` (65), including `oc-userblock` and `oc-field` rows (assert in U6).
- Edge: total row count is identical at every `loopSec` in `[open, close)` (stable split height).
- Edge: a line longer than the inner width is truncated with `…`, row still 65 cols.
- Test expectation: no test runner; typecheck + U6 assert + visual diff vs reference.

**Verification:** Side-by-side with the reference, the pane reads as real opencode chrome (blocks not lines), order is correct, no footer/help text, every row 65 cols.

---

- [ ] U4. **Operator input typing + Enter-posts animation (deterministic on `loopSec`)**

**Goal:** Animate the operator typing `lets brainstorm options` char-by-char in the input field at semi-random-but-consistent speed, then "post" it whole as a user block at `sendAt` (field clears) — all a pure function of `loopSec`.

**Requirements:** R-V4, R-V6; supports AE-V3.

**Dependencies:** U3 (renderer), U1 (typed text + offsets).

**Files:**
- Modify: `website/src/dashboard.ts`

**Approach:**
- Compute the revealed substring from a precomputed cumulative per-char offset array (constant/seeded, defined in U1 or derived deterministically), as the count of offsets `≤ (loopSec - typeStart)`. No runtime `Math.random()`.
- In the input field prompt row, render `› {revealed}{cursor}` while `typeStart ≤ loopSec < sendAt`; render empty `› {cursor}` after `sendAt`. Cursor via the existing `.cursor` span.
- **Cursor width accounting:** the existing `.cursor` is an *empty* `<span class="cursor"></span>` drawn at a fixed pixel width via CSS — it carries **zero text characters**, but the assert's `visibleWidth` counts text chars (+ `.e1`×1, `.e2`×2) and has no `.cursor` branch, so a row containing it measures one column short of 65. Reconcile this: give the cursor a width-1 `Seg` whose padding budget accounts for the visible cell (the row pads to 65 treating the cursor as 1 col), and extend `visibleWidth` in U6 to count `.cursor` as 1 col like `.e1`. The Seg model and the assert must agree that the cursor occupies exactly one column.
- At `loopSec ≥ sendAt`, U3's renderer shows the posted `oc-userblock` (the message appears whole the moment Enter "posts").

**Patterns to follow:** Deterministic-from-`loopSec` derivation used elsewhere in `renderFrame`; existing `.cursor` usage.

**Test scenarios:**
- Covers AE-V3. At increasing `loopSec` in `[typeStart, sendAt)`, the revealed substring is monotonically non-decreasing and equals a prefix of `lets brainstorm options`; no other pane line types char-by-char.
- Edge: at `loopSec` just before `sendAt`, the full string is shown in the field and no user block exists; at `loopSec ≥ sendAt`, the field is empty and the user block shows the full string.
- Edge: the same `loopSec` always yields the same revealed substring (determinism / reset-clean).
- Test expectation: no test runner; typecheck + manual observation of one loop.

**Verification:** The input visibly types at a human-plausible cadence, the cursor blinks, and Enter cleanly moves the text into a posted block.

---

- [ ] U5. **Cursor descent/ascent + wire the v2 beat into `renderFrame` (selectedId in full-width)**

**Goal:** Walk the `▶` marker down the agent list to #321 before the pane opens and back to the top after it closes, with the left log still updating; open the split only `[open, close)`; keep full-width phases otherwise.

**Requirements:** R-V5, R-V6, R-V9, R1–R3; supports AE-V1, AE-V2.

**Dependencies:** U3 (pane), U1 (BEAT milestones).

**Files:**
- Modify: `website/src/dashboard.ts`

**Approach:**
- Add a `selectedRow(loopSec)` pure helper: row 0 outside the animation; stepping 0→5 across `[descentStart, open)`; pinned 5 (#321) in `[open, close)`; stepping 5→0 across `[close, ascentEnd)`; back to 0 after. Cadence one row per fixed step.
- Extend `buildDashboardLines` so the **full-width** variant honors a `selectedId`/selected-row (today it hardcodes row 0) — so the marker can move while the pane is closed.
- In `renderFrame`: `paneOpen = open ≤ loopSec < close`. When closed, render full-width dashboard with `selectedId` from `selectedRow`. When open, current side-by-side / stacked split with #321 selected. The left dashboard rebuilds every frame, so the event log keeps updating during descent/ascent.
- All state derived from `loopSec`; no mutable beat/marker state (R-V9).

**Patterns to follow:** `mark(selected)` / `ticketRow` selection; existing `renderFrame` branch structure; `joinColumns`/`stackRule`.

**Test scenarios:**
- Covers AE-V1/AE-V2. `selectedRow` returns 0 at `loopSec < descentStart`, an increasing index through `[descentStart, open)`, 5 (#321) through `[open, close)`, a decreasing index through `[close, ascentEnd)`, and 0 after.
- Happy path: pane is present iff `open ≤ loopSec < close`; at `descentStart` and `close+ε` the frame is full-width with the marker mid-walk.
- Edge: the event log content advances between two `loopSec` values during descent (left pane keeps updating).
- Edge (R-V9): at the loop wrap the frame is full-width with the marker on row 0 and #321 at its seed.
- Test expectation: no test runner; typecheck + U6 assert + manual observation at wide and narrow widths.

**Verification:** Watching one loop, the cursor walks down to #321, the pane opens, plays the staged sequence, closes, and the cursor walks back up — the left log updating throughout; loop resets cleanly.

---

- [ ] U6. **Reduced-motion frame + assertion/golden updates**

**Goal:** Land the reduced-motion static frame on the posted-message+reply state, update `assert-sim.ts` for the new data/geometry, and regenerate the non-beat golden so `npm run assert` and `npm run build` are green.

**Requirements:** R-V7, R-V1; supports AE-V1, AE-V3, AE-V4.

**Dependencies:** U1, U3, U4, U5.

**Files:**
- Modify: `website/src/dashboard.ts` (reduced-motion offset)
- Modify: `website/scripts/assert-sim.ts`
- Modify: `website/scripts/gen-golden.ts` + `website/scripts/dashboard-golden.json`

**Approach:**
- Set the reduced-motion `nowMs` offset to a `loopSec` in `[replyAt, close)` so the frozen frame shows pane open, posted user block + agent reply visible, input empty, cursor static (rely on U2's reduced-motion `.cursor` suppression). **Update the hardcoded `baseMs + 28_000` literal in `startDashboard` (and its now-stale comment, which still describes the deleted t=26 publish / #321 resume) to a value inside the new `[replyAt, close)` window.** Since there is no automated reduced-motion render check, a stale literal silently freezes on an incoherent second.
- `assert-sim.ts`:
  - **Remove** the `#321.publish.t < #324.receive.t` check.
  - **Add** a two-occurrence ordering check using `BEAT.close < receive_318_319.t` (the autonomous unblock fires *after* the pane closes — `BEAT.open <` is too weak: it would pass even if the receive fired mid-beat, violating R-V1's "distinct, sequential occurrences").
  - **Add** a fixed-height check: `buildOpencodeLines(loopSec).length === OC_TOTAL_ROWS` for every `loopSec` in `[open, close)`, and `OC_TOTAL_ROWS ≤` the abbreviated dashboard row count.
  - **Extend `visibleWidth`** to count `.cursor` as 1 col (like `.e1`), then keep/extend the opencode-rows == `OC_PANE_W` check to cover the new block/field/input rows.
  - **Add** a reduced-motion check that the chosen reduced-motion `loopSec` falls in `[replyAt, close)`.
  - Keep the side-by-side join == 96 and abbreviated == 30 checks.
- Regenerate the golden: ensure `gen-golden.ts`'s `Ls` are all **non-beat / non-animation** seconds (exclude `[descentStart, ascentEnd)`). **The current `Ls = [0,5,10,18,45,60,80]` includes `t=18`, which the v1 beat used as `decideStart` and the v2 beat window will likely cover — drop/replace any `Ls` second that now falls inside `[descentStart, ascentEnd)` (re-check 18 and 45 against the final constants).** Re-capture `dashboard-golden.json`.

**Patterns to follow:** Existing `assert-sim.ts` `visibleWidth` helper and check structure; `gen-golden.ts` capture loop.

**Test scenarios:**
- Happy path: `npm run assert` passes all checks including the new beat-ordering check and the opencode-row-width check over the full beat window.
- Covers AE-V1: the new assert fails if `BEAT.open ≥` the `#318 → #319` receive time.
- Edge: golden `Ls` contains no second inside `[descentStart, ascentEnd)`; non-beat frames match byte-for-byte.
- Edge (R-V7): the reduced-motion `loopSec` lands in `[replyAt, close)`.
- Test expectation: `npm run assert` green; `npm run build` green; manual reduced-motion check in the browser.

**Verification:** `npm run assert` and `npm run build` are green; reduced-motion shows a clean, legible, static open-split frame with the posted message and reply.

---

## System-Wide Impact

- **Interaction graph:** All beat/typing/cursor state is a pure function of `loopSec`. The only loop-level mutable state remains `logLines` (height fit) and the resize-driven `sideBySide`/`wide` flags. No new mutable beat state may survive a loop wrap.
- **Error propagation:** N/A — no async/external calls; failures surface as type errors at build or visual glitches.
- **State lifecycle risks:** The reduced-motion frame now lands in `[replyAt, close)` and must render a coherent open split (R-V7). Split height must stay stable across the longer beat (fixed pane row count; revisit `logLines` rebalance if needed).
- **API surface parity:** Single rendering path (`renderFrame`); no other interface renders the sim.
- **Integration coverage:** The two-occurrence ordering (human beat before `#318 → #319` receive) is the cross-data invariant making AE-V1 true — asserted in `assert-sim.ts`.
- **Unchanged invariants:** 90s loop length, 1Hz/10fps cadence (plus the one new operator-input typing motion), ShopWave dashboard demo conventions, `#318 → #319` content, all non-#321/#324 tickets, the side-by-side/stacked geometry and ≤96-col budget. `buildDashboardLines({dropLatest:false})` outside the animation window must equal the regenerated golden.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Background-block `<span>` doesn't span the full row (trailing-space collapse / inline-box gaps) | Pad content to full pane width *inside* the single wrapping span; verify the band is solid edge-to-edge in both themes before relying on it. |
| `❗`/`▌` render as unexpected width and break the 65-col grid | U2 pins them to `.e1`/`.e2` or verifies advance width against the rendered grid; U6 assert checks every opencode row == `OC_PANE_W`. |
| Re-timing `#318 → #319` after the beat collides with other ambient events or makes the loop feel empty early | Tune `BEAT` + event times watching one loop; keep ambient publish/read traffic distributed. |
| Typing animation introduces non-determinism (runtime randomness) → loop not reset-clean | Precomputed cumulative offsets keyed off `loopSec`; determinism test scenario in U4. |
| Longer beat makes the split box height jump vs full-width | Fixed pane row count (blank placeholders for unshown turns); revisit `logLines` rebalance; visual height check. |
| Golden left stale → assert green but frame regressed | Regenerate golden in U6 with beat/animation seconds excluded; byte-equality check on non-beat frames. |
| Reduced-motion frame freezes on a blinking cursor or mid-type | U2 suppresses `.cursor` blink under reduced motion; U6 offset lands in `[replyAt, close)` with empty input. |
| No automated test gate for `website/` | `npm run build` + `npm run assert` + manual one-loop observation at wide/narrow/reduced-motion. |

---

## Documentation / Operational Notes

- Update memory note `project_terminal_sim_demo` only if the final beat timeline or the two-occurrence framing diverges from what it records.
- No PR/issue for this work — pushes directly to `main` per the operator's standing website-fix instruction. Commit per unit with short (3–7 word) messages, build/assert green before each push.

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-05-31-website-opencode-pane-v2-requirements.md`
- Shipped v1 plan (superseded beat): `docs/plans/2026-05-31-001-feat-website-opencode-pane-plan.md`
- Shipped v1 requirements: `docs/brainstorms/2026-05-31-website-opencode-chat-pane-requirements.md`
- Related code: `website/src/dashboard.ts`, `website/src/simData.ts`, `website/src/styles.css`, `website/scripts/assert-sim.ts`, `website/scripts/gen-golden.ts`, `website/scripts/dashboard-golden.json`
- Fidelity contract: `elixir/docs/brainstorms/2026-05-30-aiur-terminal-simulation-handoff.md` (§4, §8, §10 — §10 no-typewriter relaxed for operator input per D3)
- Related PR: #242 (shipped v1 beat); related issue #29 (website for Aiur)
