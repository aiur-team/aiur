---
title: "feat: Website opencode chat-pane animation"
type: feat
status: active
date: 2026-05-31
deepened: 2026-05-31
origin: docs/brainstorms/2026-05-31-website-opencode-chat-pane-requirements.md
---

# feat: Website opencode chat-pane animation

## Overview

The marketing site (`website/`) runs a looping, text-only simulation of the Aiur dashboard. Feature card #04 "Take the Wheel" — a human dropping into a pre-warmed opencode session in a tmux pane to drive one ticket — is described in prose but never shown. This plan adds a **timed beat inside the existing 90s loop** where the terminal box splits into a dashboard pane + an opencode chat pane, dramatizes the operator deciding on stuck ticket **#321** (UUID PK migration), and shows that decision flowing into the existing downstream `#321 → #324` auto-unblock. After the beat, the box returns to the full-width dashboard and the loop resets cleanly.

The feature extends the existing sim and keeps all of its fidelity rules (1Hz repaint, braille spinner at ~10fps, no other animation) and both scripted unblock chains intact.

---

## Problem Frame

The dashboard sim sells *autonomous* fleet coordination but never shows *human-in-the-loop* intervention, leaving "Take the Wheel" without a visible referent. The fix is a deterministic scripted animation of an opencode pane opening beside the dashboard, faithful to the real Aiur tmux split chrome the operator supplied in reference screenshots (see origin §"Reference: real opencode pane"). See origin: `docs/brainstorms/2026-05-31-website-opencode-chat-pane-requirements.md`.

---

## Requirements Trace

- R1. Take-the-wheel beat renders as a tmux-style split *within* the existing terminal box (dashboard pane + opencode pane), one continuous scene.
- R2. The split is a timed beat inside the loop (dashboard-solo → split → dashboard-solo → reset); full-width phases look identical to today.
- R3. Open/close motivated by existing footer affordances (`▶` moves to driven row, "enter" opens, "q" closes); keys stay decorative.
- R4. Story = "unblock / decide for a stuck agent": dialogue-driven, minimal tool UI (one edit/plan-update + resume).
- R5. Driven ticket is one that does not already auto-resolve: **#321**, whose existing `#321 → #324` unblock becomes a *consequence* of the decision.
- R6. #321 gains a brief needs-decision state before the operator opens it, and leaves it once the decision is given.
- R7. opencode pane obeys sim fidelity: 1Hz repaint, braille spinner ~10fps, chat lines appear whole (no typewriter), no fades/easing.
- R8. opencode pane reproduces real opencode chrome: `$ cmd` transcript lines, dim `→ tool result`/`→ ToolSearch`, brighter assistant prose, `┃`/`│` gutter rail, `▣ Build · issue-<N>` status chip, blue-bordered input box labeled `Build · issue-<N> <project>`, footer braille meter + `esc interrupt   tab agents   ctrl+p commands`. Shares the existing grid, palette, emoji-width handling.
- R9. Reflow: **wide** = side-by-side, dashboard pane abbreviates its own columns (drops LATEST, truncates TITLE/STATUS to a few chars + `…`) so the combined split stays within the existing ~96-col grid budget; **narrow** = panes stack vertically (dashboard full-width on top, keeps LATEST; opencode below), separated by a horizontal rule. Never overflows or squishes.
- R10. Works at the sim's width tiers; opencode truncates its own transcript lines with `…` rather than overflowing.
- R11. With `prefers-reduced-motion`, the beat resolves to a sensible static frame (not a broken half-open state), consistent with the sim's existing static-frame behavior.
- R12. Loop resets cleanly: at the boundary the pane is closed and all driven-ticket state returns to its t=0 seed.

**Origin actors:** A1 (Operator/human), A2 (Driven agent — opencode session for #321), A3 (Fleet — existing dashboard sim).
**Origin flows:** F1 (Take the wheel on a stuck ticket — the scripted beat within the ~90s loop).
**Origin acceptance examples:** AE1 (covers R1, R2 — split only during beat window), AE2 (covers R4, R5, R6 — #321 needs-decision → resumes), AE3 (covers R7 — whole-line repaint, only braille sub-second motion), AE4 (covers F1 step 6 — #324 ingests #321's event and unblocks, in the full-width dashboard after the beat), AE5 (covers R9 — narrow stacks vertically, no overflow).

---

## Scope Boundaries

- No real interactivity — footer keys stay decorative; the viewer cannot drive the session.
- No real opencode integration, no backend, no live model output — deterministic scripted animation like the rest of the sim.
- Not full opencode-TUI fidelity — a believable minimal slice (prompt, reply, one tool action, result), not model picker / token counts / multi-tab / syntax-highlighted diffs.
- Does not move the existing dashboard event timeline. #321's `schema migrated to uuid pks` publish stays at **t=26** and #324's receive/unblock stay at **t=46/t=50** — the beat is timed *around* these existing events, not the other way around. The only data change to #321 is inserting the needs-decision frame and adjusting its own progress frames; #324 is untouched.
- Does not change any other ticket, the #318→#319 hero chain, the 90s loop length, or the 1Hz/10fps cadence.
- Mobile does not skip the beat (vertical stacking), but heavy opencode tool UI may be trimmed further at the narrowest tier if it does not fit.

---

## Context & Research

### Relevant Code and Patterns

- `website/src/dashboard.ts` — single-`<pre>` renderer. `renderFrame(nowMs, baseMs)` builds the whole frame line-by-line; `startDashboard` runs the 100ms tick, the reduced-motion static frame (`baseMs + 31_000` today), and `fitLogLines` height-fitting. The **Seg** abstraction (`raw`/`emo`/`mark`/`spin`/`cat`/`padEnd`/`padStart`/`dashes`/`bordered`) is the width-aware building block to reuse for the opencode pane and the split join. `ticketRow` has the `blocked`-phase spinner branch to mirror for `decide`. Column widths (`IDW`, `AGENTW`, `LATESTW`, etc.) and `INNER`/`WIDTH` define the grid. Ticket selection is currently hardcoded to row 0 (`i === 0`) in the `renderFrame` `forEach`.
- `website/src/simData.ts` — `TICKETS` (#321 at index 5, agent `opus`) and `EVENTS`. #321 frames today: t=0 (`implement` 50 "running migration dry-run"), t=20 (`implement` 75 "backfilling uuid column"), t=24 (`implement` 92 'pushed 2 commits, last: "backfill uuid column"'). #321 EVENTS: t=24 publish 'pushed 2 commits…backfill uuid column', t=26 publish `"schema migrated to uuid pks"`. #324 (codex, "Product search endpoint"): t=0 blocked "blocked on #321 schema", t=50 implement 5 "scaffolding /search endpoint"; EVENT t=46 receive `"← #321: schema ready, unblocking"`. `sample()` overlays the most-recent matching event text into the LATEST cell, so event timing and LATEST stay in lockstep.
- `website/src/terminal.ts` — IntersectionObserver start trigger; no change expected.
- `website/src/styles.css` — `.tui-pre` font scales by container query `clamp(6px, 1.7cqi, 16.5px)` on a `container-type: inline-size` wrapper with `overflow: hidden`. Agent colors: `.ag-opus` (magenta `--term-mag`), `.ag-sonnet` (`--term-accent`), `.ag-codex` (`--term-ok`). `.bd`/`--tui-line`, `.dim`, `.acc`, `.e1`/`.e2` (1ch/2ch emoji cells), `.spin`. New opencode chrome classes hang here.
- Fidelity contract: `elixir/docs/brainstorms/2026-05-30-aiur-terminal-simulation-handoff.md` §4, §8, §10.

### Institutional Learnings

- No `docs/solutions/` entries touch the website sim (searched `tui-pre`/`dashboard`/`opencode`/`terminal`/`website` — none found).

### External References

- None used. The sim is a strong, self-contained local pattern and the operator supplied the fidelity target directly via screenshots (origin §"Reference"). External research skipped.

---

## Key Technical Decisions

### The font is driven by *container* width, not content width — this constrains the entire design

The sim is **one** fixed-width `<pre class="tui-pre">` (WIDTH=96 cols). Its font size is `clamp(6px, 1.7cqi, 16.5px)` where `cqi` is a percentage of the **container's** inline size (`.term-body` has `container-type: inline-size` + `overflow: hidden`). The 96-col grid is hand-tuned so the line exactly fills the container at that font ratio.

The critical consequence: **a wider line does not shrink the font — it overflows and gets clipped.** The font tracks the container, never the content. So any split layout must keep its total rendered line width at or below the existing ~96-col budget, or it will be silently truncated on the right. This single fact drives the side-by-side approach below and replaces the earlier (incorrect) "measure a character budget at the minimum legible font" framing, which assumed content width could drive font size. It cannot.

### Single-`<pre>` column-wise join (origin deferred R1/R2)

The split is composed by building the dashboard box and the opencode box each as arrays of `Seg` rows, then **joining them into one `<pre>`** — row-by-row with a gutter for side-by-side, or stacked top/bottom for narrow. Rejected two side-by-side `<pre>` elements (would need two independent font-scales and break the single-grid illusion).

### Side-by-side fits by abbreviating the dashboard's *own* columns (origin deferred R9)

To keep the combined side-by-side line within the ~96-col budget (so the font is unchanged and nothing clips), the dashboard pane shrinks to ~1/3 of the grid during the beat:

- **Drop the LATEST column entirely** (frees ~33 cols), and at 1/3 width also drop **AGENT** and **TIME**.
- **Truncate TITLE** to a few characters + `…`.
- **Compress PROGRESS** to a short indicator (a few-cell bar or a `NN%` number) rather than the full 10-cell bar.
- **Hard-truncate the event-log lines** to the narrow dashboard INNER width with `…`.
- Keep the marker, ID, the compressed PROGRESS, and a spinner cue on the driven row so the stalled `#321` still reads at a glance.

Directional budget (exact widths tuned in implementation): the dashboard takes ~1/3 of the grid and the opencode pane ~2/3 — roughly opencode box ≈62 cols (`OC_INNER` ~58 + borders), gutter ~2, abbreviated dashboard box ≈30 cols → combined ≈96. The 1/3 : 2/3 ratio is deliberate: the opencode pane carries the most chrome (transcript, chip, input box, footer) and benefits from the extra width (less `…` truncation, better R8/R10 fidelity), while the abbreviated dashboard only needs marker + ID + a short truncated title + progress + a spinner cue for the driven row. Because the combined width stays at the existing budget, **the container-query font ratio is unchanged** and there is no overflow or clip. This is the resolution of the wide-layout fork: not a third `<pre>`, not a font shrink, but the dashboard giving up horizontal real estate so the opencode pane fits beside it.

### Layout choice (side-by-side vs stacked) is a px threshold measured once per resize, not per frame

Deciding wide-vs-narrow by re-measuring geometry every 100ms frame would be wasteful and could flip-flop. Instead, measure the container width **once on resize** (and on `fonts.ready` / first start), cache the chosen layout in module state, and apply hysteresis (a small dead-band around the threshold) so a viewport hovering near the boundary doesn't oscillate. The threshold is a fixed pixel width below which the abbreviated side-by-side line would itself fall under the legibility floor — measured against the real breakpoints in the browser. Side-by-side above the threshold; stacked below.

### Driven-ticket needs-decision state = distinct `decide` phase (origin deferred R6)

Add a `decide` phase with its own emoji (recommend `✋`) and the same spinner treatment as `blocked`, so "needs *you*" reads differently from "blocked on another ticket." Rejected reusing `blocked` (the loop already uses ⏳/blocked for cross-ticket waits; a distinct glyph makes the human cue legible).

### Beat timeline aligns to the *existing* events — events are not moved (origin deferred R2 timing)

Rather than move #321's publish later (which would ripple into #324 and violate R2/scope), the beat is timed so the operator's decision lands *just before* the existing t=26 publish, making the publish read as the decision's consequence:

| Constant | loopSec | Meaning |
|----------|---------|---------|
| `BEAT.decideStart` | ~18 | #321 enters `decide`/stall (needs a decision) |
| `BEAT.open` | ~20 | split opens, opencode pane appears, `▶` moves to #321 |
| `BEAT.decision` | ~24 | operator's decision text appears in the input box |
| (existing) publish | **26** | #321 publishes `schema migrated to uuid pks` — **unchanged** |
| `BEAT.close` | ~30 | split closes, back to full-width dashboard |
| (existing) #324 receive | **46** | #324 ingests `← #321: schema ready, unblocking` — **unchanged** |
| (existing) #324 unblock | **50** | #324 leaves blocked — **unchanged** |

The #324 payoff therefore plays out in the **full-width dashboard after the beat** (origin F1 step 6), not inside the split. The boundary condition is `BEAT.open <= loopSec < BEAT.close` — at `loopSec === BEAT.close` the split is already gone.

To keep the `decide` window `[decideStart, 26)` clean, the existing t=24 "pushed 2 commits" event must be **removed or relocated out of that window** so no stale "pushed 2 commits" text overlays the needs-decision LATEST cell.

New #321 frames: t=0 `implement` 50 "running migration dry-run"; ~t=18 `decide` ~60 "needs a decision: backfill strategy" (progress held); ~t=26 `implement` resuming; ~t=28 `implement` 92 "batched online backfill pushed". The t=26 publish event is preserved.

### Reduced-motion static frame moves to land after the publish (R11)

The reduced-motion static frame offset changes from `baseMs + 31_000` to **`baseMs + 27_000`** (loopSec ≈ 27). That lands inside the still-open split window `[20, 30)` but **after** the t=26 publish, so the frozen frame shows: split open, input box holding the decision, chip `· done`, #321 resuming (`implement`, no frozen spinner). This avoids freezing on an empty/hung input box or a mid-spinner state.

### No typewriter (R7)

Chat lines are selected by loop-time and appear whole on the 1Hz content step, exactly like ticket LATEST text.

### Verification = typecheck/build + a tiny assertion script + manual dev-server observation

`website/` has no test runner (only `tsc --noEmit` + `vite build`) and CI has no website gate (elixir jobs pass unchanged on a website-only PR). Adding a full test framework is out of scope. To still guard the load-bearing invariants, U4 adds a **dependency-free `tsx`/node assertion script** (run locally, not wired into CI) asserting: (a) a golden byte-equality snapshot of `buildDashboardLines({dropLatest:false})` captured *before* the refactor, (b) equal row widths in the side-by-side join, (c) `#321.publish.t < #324.receive.t`. Everything else is verified by build + watching one loop in the browser.

---

## Open Questions

### Resolved During Planning

- *Split rendering structure?* → Single `<pre>`, column-wise `Seg`-row join (see Key Decisions).
- *How does side-by-side fit without shrinking the font?* → The dashboard abbreviates its own columns (drops LATEST, truncates TITLE/STATUS, hard-truncates log lines) so combined width stays ≈96 cols; the container-query font is unchanged.
- *needs-decision representation?* → New `decide` phase + `✋` emoji + blocked-style spinner.
- *Beat timing vs events?* → Events are NOT moved; the beat is timed around the existing t=26 publish (decision at ~t=24). #324 stays at 46/50.
- *Wide-vs-narrow trigger?* → A fixed px threshold measured once per resize with hysteresis, cached in module state — not a per-frame measurement and not a CSS media query.
- *Reduced-motion frame?* → Static offset moves to `baseMs + 27_000` so it lands after the publish on a clean open-split frame.

### Deferred to Implementation

- Exact opencode chat copy — draft transcript in origin §"Proposed opencode session script"; refine while watching it render. The copy must remain coherent with the unchanged t=26 `schema migrated to uuid pks` event (the decision precedes and motivates that publish).
- Exact character widths of the opencode box (`OC_INNER`), the gutter, and the abbreviated dashboard columns; and the precise px threshold (+ hysteresis band) that flips wide→narrow — tune against the real breakpoints in the browser (R9/R10).
- Whether the narrowest tier needs an extra-aggressive opencode trim or fewer transcript rows to stay legible when stacked (origin deferred, R10).

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
// module state, set on resize / fonts.ready (not per frame)
let sideBySide = measureLayout()   // px threshold + hysteresis

renderFrame(nowMs, baseMs):
  loopSec = (nowMs - baseMs)/1000 % LOOP_SECONDS
  if BEAT.open <= loopSec < BEAT.close:
      paneLines = buildOpencodeLines(loopSec)            // transcript→chip→input→footer
      if sideBySide:
          dashLines = buildDashboardLines(loopSec, spinIdx, { dropLatest: true })
          body      = joinColumns(dashLines, paneLines, GUTTER)  // every left row padEnd'd to dash box width
          rows      = [...body, fullWidthFooter]                  // footer spans full width, below both panes
      else:
          dashLines = buildDashboardLines(loopSec, spinIdx, { dropLatest: false })  // keeps LATEST
          rows      = [...dashLines, hrule, ...paneLines]
  else:
      rows = buildDashboardLines(loopSec, spinIdx, { dropLatest: false })   // identical to today
  return "<pre>" + rows.join("\n") + "</pre>"
```

`buildDashboardLines` is today's `renderFrame` body refactored to return a `Seg`-row array and accept a `dropLatest` flag. `buildOpencodeLines` is new and built entirely from the existing `Seg` helpers. `joinColumns` must `padEnd` **every** left row (including dividers, spacers, and any short row) to the dashboard box width before concatenating the gutter + pane, or the right pane's left edge will be ragged. The footer spans the full width **below** both panes in split mode (it is not joined beside the pane).

---

## Implementation Units

- [ ] U1. **Re-time #321 around the existing events and add the `decide` phase to the data model**

**Goal:** Make the data tell the take-the-wheel story without moving any existing event: #321 stalls needing a decision (~t=18), the operator decides (~t=24), and the *existing* t=26 `schema migrated to uuid pks` publish now reads as the consequence. #324 is left exactly as-is.

**Requirements:** R5, R6, R12; supports AE2, AE4.

**Dependencies:** None.

**Files:**
- Modify: `website/src/simData.ts`

**Approach:**
- Add `"decide"` to the `Phase` union.
- Add beat-timing constants as one source of truth, e.g. `export const BEAT = { decideStart: 18, open: 20, decision: 24, close: 30 } as const;` (publish stays at the existing event t=26; #324 stays at 46/50 — those live in EVENTS/frames, not BEAT).
- Rewrite #321 `frames`: keep t=0 (`implement`, 50, "running migration dry-run"); replace the t=20 frame with a `decide` frame at ~t=18 (progress held ~60, latest "needs a decision: backfill strategy"); add a resume frame ~t=26 (`implement`, progress climbing) and ~t=28 (`implement`, 92, "batched online backfill pushed").
- Re-time/relocate #321 EVENTS: the existing t=24 "pushed 2 commits…backfill uuid column" event must move **out of the `[decideStart, 26)` decide window** (relocate to ~t=27 or drop) so no stale push text overlays the `decide` LATEST cell. **Keep the t=26 `schema migrated to uuid pks` publish exactly where it is.**
- **Do not touch #324** (receive t=46, unblock t=50), any other ticket, or the #318→#319 hero chain.

**Patterns to follow:** Existing `TicketScript.frames` / `LogEvent` shapes; `sample()`'s event-overlay contract (latest event text wins for the LATEST cell).

**Test scenarios:**
- Happy path: at loopSec in `[18, 20)`, #321's sampled phase is `decide` with the needs-decision latest text and held progress.
- Happy path: at loopSec ≥ 26, #321's phase is `implement` with progress advancing again.
- Integration (event/LATEST lockstep): #321's `schema migrated to uuid pks` event stays at t=26, strictly before #324's t=46 receive; #324 leaves `blocked` only at t=50.
- Edge: no "pushed 2 commits" text is sampled into #321's LATEST cell anywhere in `[18, 26)`.
- Edge: at the t=0 seed and just before `LOOP_SECONDS`, #321 is back to its seed frame (no `decide` residue) — clean reset (R12).
- Test expectation: no test runner in `website/`; verified via `npm run typecheck` (union exhaustiveness) and the U4 assertion script (`#321.publish.t < #324.receive.t`), plus manual observation of one loop.

**Verification:** Watching one loop, #321 visibly stalls (✋ + spinner) ~t=18, the operator decides ~t=24, the schema event publishes at t=26, and #324 unblocks at t=50 in the full-width dashboard; no console/type errors.

---

- [ ] U2. **Author the opencode session script data**

**Goal:** Provide the deterministic, loop-time-indexed transcript the opencode pane renders, in the real opencode style, timed to the beat (`open`→`decision`→ existing t=26 publish →`close`).

**Requirements:** R4, R7, R8 (content); supports AE2, AE3.

**Dependencies:** U1 (shares `BEAT` constants).

**Files:**
- Modify: `website/src/simData.ts` (co-locate with sim data; export an `OPENCODE_SCRIPT` structure)

**Approach:**
- Model the pane content as time-keyed entries: transcript lines each tagged with a kind (`cmd` `$ …`, `tool` dim `→ …`, `prose` assistant text), a status-chip string (`▣ Build · issue-321`, optionally `· done`), the input-box decision text (`› online backfill in batches, no lock`), and a braille progress fraction for the footer meter.
- Time entries to `BEAT`: question prose appears at `open` (~t=20), decision text in the input box at `decision` (~t=24), acknowledgement + edit + result between `decision` and the t=26 publish, `▣ … · done` by `close`.
- Keep tool UI minimal (one `mix ecto.migrate --dry-run`, one `edit …_add_uuid.exs`, one `→ tool result`) per R4. The transcript should make the t=26 `schema migrated to uuid pks` publish read as the natural result of the decision.
- Draft copy lives in origin §"Proposed opencode session script"; refine wording during U3 rendering.

**Patterns to follow:** `Keyframe`/`LogEvent` time-keyed shapes in the same file; ascending-`t` selection like `sample()`.

**Test scenarios:**
- Happy path: selecting by loopSec returns the cumulative transcript visible at that time (whole lines only, monotonically growing through the beat).
- Edge: before `BEAT.open` and at/after `BEAT.close`, the selector returns empty (pane not shown).
- Test expectation: no test runner; verified via typecheck + manual observation.

**Verification:** The selector yields a coherent, growing transcript across the beat and nothing outside it.

---

- [ ] U3. **Build the opencode pane renderer**

**Goal:** Render the opencode box (transcript → status chip → input box → footer) as a `Seg`-row array faithful to the real chrome.

**Requirements:** R7, R8, R10; supports AE3.

**Dependencies:** U2.

**Files:**
- Modify: `website/src/dashboard.ts`

**Approach:**
- New `buildOpencodeLines(loopSec): Seg[]` (rows consumed by the join in U5).
- Compose with existing helpers: gutter rail `┃`/`│` via `raw(_, "oc-rail")`; `$ cmd` lines via an `oc-cmd` class; dim `→ tool result` via existing `dim`/new `oc-tool`; assistant prose plain/bright; `▣ Build · issue-321` chip via `oc-chip` (accent).
- **Input box char-art** (the most chrome-sensitive element): three (or four) bordered rows —
  - top border `┌────…┐`
  - body row `│ › <decision text padded to OC_INNER> │` with the left `│` carrying the blue `oc-input` class
  - label row showing `Build · issue-321 its-everdred/shopwave` (dim) inside the box
  - bottom border `└────…┘`
  Every input-box row is exactly `OC_INNER` wide so the box is rectangular.
- Footer braille meter (`⬝`×n + `■`) + `esc interrupt   tab agents   ctrl+p commands` in `dim`. (In side-by-side mode this pane footer is part of the pane; the *dashboard* footer spans full width below — see U5.)
- Pane has a fixed inner character width (`OC_INNER`); truncate transcript lines with the existing `trunc(…, OC_INNER)` so they never overflow (R10).
- Spinner reuses the dashboard `SPIN` array + `spinIdx` for any in-progress chip, so sub-second motion is braille-only (R7/AE3).

**Patterns to follow:** `bordered()`, `dashes()`, `trunc()`, `padEnd`/`padStart`, `spin()`, `emo()` in `dashboard.ts`; the box-drawing style of `topBorder`/`logDivider`.

**Test scenarios:**
- Happy path: at a mid-beat loopSec the returned rows include a `$ ` command line, a dim `→` line, the `▣ Build · issue-321` chip, the input box (top/body/label/bottom) with the decision text, and the footer meter — in that vertical order.
- Edge: a transcript line longer than `OC_INNER` is truncated with `…` and the row width equals `OC_INNER` (no overflow).
- Edge: every input-box row width equals `OC_INNER` (rectangular box).
- Edge: braille spinner frame advances with `spinIdx`; no other glyph changes within a 1s window.
- Test expectation: no test runner; verified via typecheck + visual diff against the operator's reference screenshots.

**Verification:** Side-by-side with the reference screenshot, the pane's elements, order, input-box border, and palette read as the real opencode chrome.

---

- [ ] U4. **Refactor the dashboard frame into a reusable line builder with a `dropLatest` option (+ golden assertion script)**

**Goal:** Make today's `renderFrame` body produce a `Seg`-row array and support dropping/abbreviating columns, without changing the full-width output — and lock that no-diff guarantee with a golden snapshot captured before the refactor.

**Requirements:** R2, R9; supports AE1.

**Dependencies:** None (capture the golden snapshot *first*; U5 join consumes this).

**Files:**
- Modify: `website/src/dashboard.ts`
- Create: `website/scripts/assert-sim.ts` (dependency-free `tsx`/node assertions; not wired into CI)

**Approach:**
- **Before refactoring**, capture a golden snapshot: serialize `renderFrame` (or its line array) at a fixed set of loopSec values to a checked-in fixture, so the refactor can be proven byte-identical.
- Extract `buildDashboardLines(loopSec, spinIdx, { dropLatest }): Seg[]` from `renderFrame`. Default (`dropLatest: false`) must be byte-identical to today's output (R2 — full-width phases unchanged).
- When `dropLatest: true` (the ~1/3-width variant): omit LATEST, AGENT, and TIME from `columnHeader`/`ticketRow`; truncate TITLE to a few chars + `…`; compress PROGRESS to a short bar or `NN%`; keep MARKER, ID; recompute the abbreviated `INNER`/box width (~26 inner / ~30 box). **Replace the phase-emoji cell with the spinner glyph for `blocked`/`decide` rows** in this variant (the LATEST cell that normally hosts the spinner is gone, so the spinner moves to the phase column). Hard-truncate event-log lines to the abbreviated INNER with `…`.
- `renderFrame` calls `buildDashboardLines(..., { dropLatest: false })` outside the beat window.
- Add `assert-sim.ts` asserting: golden byte-equality of `buildDashboardLines({dropLatest:false})` at the fixed loopSec set; row-width equality across a `joinColumns` sample (added in U5); `#321.publish.t < #324.receive.t`. Add an npm script (e.g. `"assert": "tsx scripts/assert-sim.ts"`).

**Patterns to follow:** Existing column-width constants and `bordered()` width math; the `blocked` spinner branch in `ticketRow`.

**Test scenarios:**
- Happy path: outside the beat window the rendered frame equals the golden snapshot byte-for-byte — protects R2.
- Happy path: with `dropLatest: true` the dashboard box is narrower, has no LATEST header/cell, TITLE/STATUS are truncated, and every row width is internally consistent (borders align).
- Edge: a `decide`/`blocked` row shows the spinner in the phase-emoji cell in the abbreviated variant.
- Test expectation: `npm run assert` passes; typecheck passes; manual before/after visual check.

**Verification:** `npm run assert` is green; toggling `dropLatest` produces aligned boxes; the non-beat frame is indistinguishable from today.

---

- [ ] U5. **Compose the split, choose layout, freeze log height, and wire the beat into the loop**

**Goal:** During the beat window, join the dashboard and opencode panes into one `<pre>` — abbreviated dashboard side-by-side when width allows, stacked vertically otherwise — return to full-width dashboard outside the window, and keep box height stable, reduced-motion clean, and the loop reset intact.

**Requirements:** R1, R2, R3, R9, R10, R11, R12; supports AE1, AE5.

**Dependencies:** U2, U3, U4.

**Files:**
- Modify: `website/src/dashboard.ts`

**Approach:**
- In `renderFrame`, branch on `BEAT.open <= loopSec < BEAT.close`.
- **Layout decision in module state, not per frame:** compute `sideBySide` once on resize / `fonts.ready` / first start using a fixed px threshold with a hysteresis dead-band; cache it. `renderFrame` just reads the cached flag.
- **Side-by-side:** `joinColumns(dashLines, paneLines, GUTTER)` — `padEnd` **every** left (dashboard) row to the abbreviated dashboard box width (including dividers/spacers/short rows), then concatenate `GUTTER` + the pane row. Pad the shorter column with blank, full-width rows so both panes have equal height and borders align. The **dashboard footer spans the full combined width below both panes** (it is not joined beside the pane). Assert equal left-row width in a dev check (feeds U4's `assert-sim.ts`).
- **Stacked:** dashboard full-width (LATEST kept) on top, a horizontal rule, then the opencode pane below (R9).
- **Freeze log height during the beat (was deferred — now required):** hold `logLines` to its non-beat value during the beat so the box doesn't resize mid-loop; size the opencode pane to **consume the freed rows** (side-by-side: the pane occupies the dashboard's vertical budget; stacked: the pane plus rule fit within the conserved total height). Total `<pre>` line count stays stable across open/close.
- **R3 marker by id, not index:** compute the #321 row once at module init via `TICKETS.findIndex(t => t.id === 321)` and select that row during the beat; restore to the default row outside the beat. The marker moves to #321 and the split opens on the **same** frame (`BEAT.open`), and both revert simultaneously at `BEAT.close`.
- **R11 reduced-motion:** static frame offset is `baseMs + 27_000` (loopSec ≈ 27) — inside `[20, 30)` and after the t=26 publish — so the frozen frame is a fully-open split with the decision in the input box, chip `· done`, #321 resuming (no frozen spinner).
- **R12:** all beat state is derived from `loopSec` (no mutable beat state); verify nothing persists across the wrap. The only module state is the cached `sideBySide` flag, which is layout-only and resize-driven, not loop-driven.

**Patterns to follow:** `renderFrame` structure; `fitLogLines` geometry read; `mark(selected)` selection.

**Test scenarios:**
- Happy path (AE1): loopSec 10 → full-width dashboard only; 24 → split visible with opencode pane (decision in input box); 80 → full-width again.
- Happy path: `▶` is on the #321 row exactly during `[BEAT.open, BEAT.close)`, default row otherwise; marker move and split open coincide.
- Edge (AE5): at a narrow container width the two panes stack vertically, dashboard keeps LATEST, and no row exceeds the container (no horizontal overflow).
- Edge (height): `<pre>` line count is identical just-before, during, and just-after the beat (no vertical jump).
- Edge (R11): the reduced-motion static frame (loopSec ≈ 27) renders a fully-open, legible split with the decision shown.
- Edge (R12): at the loop wrap the frame is full-width dashboard and #321 shows its seed frame.
- Integration: side-by-side join pads unequal pane heights and every left row to the dashboard box width so borders stay aligned (assert in `assert-sim.ts`).
- Test expectation: no test runner; verified via `npm run assert`, typecheck, and manual observation at wide and narrow widths, with and without reduced-motion.

**Verification:** Watching one loop at a wide and a narrow viewport, the beat opens/plays/closes on schedule, neither layout overflows, box height stays constant, reduced-motion shows a clean static split, and the loop resets identically to today.

---

- [ ] U6. **opencode chrome styling**

**Goal:** Add the CSS classes the opencode pane needs so it matches the real chrome palette within the existing `.tui-pre` aesthetic.

**Requirements:** R8, R7.

**Dependencies:** U3 (class names are defined together).

**Files:**
- Modify: `website/src/styles.css`

**Approach:**
- Add `.tui-pre` descendant classes used by U3: `oc-rail` (dim gutter, `--tui-line`), `oc-cmd` (command lines), `oc-tool` (dim tool-result), `oc-chip` (accent filled-square chip), `oc-input` (blue left border for the input box — reuse an existing accent/blue token or add one), and any prose class. Reuse existing tokens (`--term-accent`, `--term-mag`, `--term-ok`, `--tui-line`, `--dim`) wherever possible.
- **Pin emoji/glyph widths:** `▣`, `✋`, and `👍` (if used) must be assigned `.e2` or `.e1` to match their actual advance width, or verify they render single-width in the monospace stack — otherwise the column math drifts. Confirm against the rendered grid.

**Patterns to follow:** Existing `.tui-pre .ag-*`, `.bd`, `.dim`, `.acc`, `.spin` rules; the color-variable palette.

**Test scenarios:**
- Test expectation: none automated — pure styling. Verified visually against the reference screenshots (chip color, blue input border, dim tool lines, gutter rail) and by confirming `▣`/`✋` don't break alignment.

**Verification:** Pane colors and weights match the reference, glyph widths don't shift the grid, and `npm run build` passes.

---

## System-Wide Impact

- **Interaction graph:** All beat state is a pure function of `loopSec`. The only loop-level mutable state is `logLines` (height fitting, frozen during the beat per U5) and the cached `sideBySide` layout flag (resize-driven, not loop-driven). The split must not introduce mutable beat state that survives a loop wrap.
- **Error propagation:** N/A — no async or external calls; failures surface as type errors at build or visual glitches.
- **State lifecycle risks:** The reduced-motion static frame lands inside the beat window (loopSec ≈ 27) — must render a coherent open split (R11). Log-line height is frozen during the beat so the box height is conserved (U5).
- **API surface parity:** Single rendering path (`renderFrame`); no other interface renders the sim.
- **Integration coverage:** Event/LATEST lockstep (`sample()` overlay) keeps #321's t=26 publish before #324's t=46 ingest (unchanged) — the cross-data invariant that makes AE4 true, asserted in `assert-sim.ts`.
- **Unchanged invariants:** Full-width dashboard phases (R2), the #318→#319 hero chain, all non-#321 tickets, **#324's t=46/t=50 timing**, **#321's t=26 publish**, the 90s loop length, and the 1Hz/10fps cadence are explicitly unchanged. `buildDashboardLines({dropLatest:false})` must equal the golden snapshot.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Side-by-side combined line exceeds ~96 cols → silent right-edge clip (font is container-driven, not content-driven) | Dashboard abbreviates its own columns (drop LATEST, truncate TITLE/STATUS, hard-truncate log lines) to hold combined width ≈96; `assert-sim.ts` checks join row widths; verify no clip in the browser. |
| Ragged right-pane edge from unequal left-row widths in the join | `joinColumns` pads **every** left row to the dashboard box width; dev assertion on equal left-row width. |
| Box height jumps when the split opens/closes | U5 freezes `logLines` during the beat and sizes the pane to consume the freed rows; line-count-stable test scenario. |
| Refactor of `renderFrame` changes the full-width output | Golden snapshot captured before the refactor; `assert-sim.ts` byte-equality on `buildDashboardLines({dropLatest:false})` (R2). |
| Layout flip-flop near the wide/narrow threshold | Threshold measured once per resize with a hysteresis dead-band, cached in module state. |
| Reduced-motion static frame renders a half-open / hung-input split | Static offset moved to `baseMs + 27_000` (after t=26 publish, inside open window) so it freezes on a clean, fully-open frame (R11). |
| `▣`/`✋`/`👍` render as wide glyphs and break column math | U6 pins them to `.e1`/`.e2` or verifies single-width against the grid. |
| No automated test gate for `website/` | `npm run build` (tsc + vite) + `npm run assert` (golden/invariant script) + manual dev-server observation. CI on the PR runs the unchanged elixir jobs (green) + PR-description lint. |

---

## Documentation / Operational Notes

- Update the memory note `project_terminal_sim_demo.md` only if the final beat timeline or driven-ticket choice diverges from what's already recorded there.
- PR body must satisfy `mix pr_body.check` (Context, TL;DR, Summary w/ bullets, Alternatives, Complexity routing, Test Plan w/ checkboxes, `Closes #` line). Patch the body via REST (`gh api -X PATCH`), not `gh pr edit` (buggy on classic Projects).
- Branch `feat/website-opencode-pane` is off `origin/main`, independent of the npm/init stack. Open its own PR; do not merge.

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-05-31-website-opencode-chat-pane-requirements.md`
- Related code: `website/src/dashboard.ts`, `website/src/simData.ts`, `website/src/terminal.ts`, `website/src/styles.css`
- Fidelity contract: `elixir/docs/brainstorms/2026-05-30-aiur-terminal-simulation-handoff.md` (§4, §8, §10)
- Related issue: #29 (website for Aiur)
