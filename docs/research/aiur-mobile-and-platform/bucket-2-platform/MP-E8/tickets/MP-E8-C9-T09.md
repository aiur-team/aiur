---
ticket_id: MP-E8-C9-T09
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: Gantt mode
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C9-T05, MP-E8-C9-T07, MP-E8-C4-T04]
complexity: 4
design_gate: DESIGN-E8
design_signoff_items: [S-5]
owns_edge_cases: [EC-22, EC-20]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T09 — Gantt mode

## Identity and outcome

- Bucket 2, feature MP-E8 (home page "Continuous build history"), chunk C9
  (client timeline engine, a port of `build.js`).
- **User value:** the operator presses **Gantt** and sees time on the Y axis.
  Each past ticket is a card as tall as its real run time, from start to merge
  or close. Nights and idle days fold into hatched break bands. Running tickets
  in the now band and planned tickets below get an *expected* height from their
  estimate. Planned cards are drawn hatched and dashed (`gplan`) so they never
  look like history; band cards keep their normal look (J:493 gives them no
  `gplan`) (E8-D4, E8-D7). Dependency arrows run between the cards. A past
  ticket whose start nobody recorded shows as a "start unknown" card. It never
  shows a made-up start.
- **Deliverable:** the Gantt branches of the timeline engine, ported from
  `build.js` with the mock `NOW` removed:
  1. PROPOSED `src/priv/static/build-home/gantt.js`: `ganttHist` (interval merge,
     idle-gap compression to `BRK`, the "Idle · … · Nh" labels, hour ticks,
     `tY`), `assignLanes`, the planned-wave Gantt branch and the band Gantt
     height. All are pure functions of the payload rows, the `now` ms value and
     the layout context, so a spec can call them through
     `page.evaluate(() => import("/build-home/gantt.js"))` (C9-T08's method)
     with no layout DOM. They fill C9-T02's `ext.gantt` slots
     (`hist`, `plan`; plus `bandHeight` for C9-T08).
  2. The Gantt branches in the card module that C9-T05 writes: `.bd-time`,
     `.bd-badges`, the Gantt status text and the `gplan` class (J:819–821,
     845–848), plus the `cardDetail` height-tier rule for Gantt items (J:807–813).
  3. Three unknown-value treatments the design does not have: start unknown
     (S-5 default), estimate unknown (C7-T03 rule) and end unknown (skipped).
  4. One browser spec (unit cases plus page cases), with an npm script
     `test:build-home-gantt` in the `test` chain.
- **Non-goals:**
  - No server work. Start and end come from C4-T04 through C8-T04 and C3-T02.
  - No view button and no URL key. The `Timeline/Gantt/List` segment is C10-T01
    (J:1131, J:1143). `?view=gantt` parsing is C3-T03.
  - No edge geometry. C9-T07 ports `drawEdges` (J:888–932), including the
    `svg.gantt` toggle at J:930. Edges measure the cards with
    `getBoundingClientRect` (J:904), so variable heights need no new edge code.
    This ticket proves the result in Gantt view.
  - No compact-mode logic. The compact `entries`, ghosts and the "+N unrelated"
    label inside `ganttHist` (J:450) and the planned waves (J:506) are C10-T03's.
    This ticket ports those lines verbatim because they sit inside its
    functions. C10-T03 tests them.
  - No list view (J:1161, C9-T12), no history header date (J:658, C9-T03), no
    modal conversation span (J:1308, C11).
  - The analytics Gantt (`lib/aiur_web/operator_control_center/analytics/charts.ex:239-292`
    `Charts.gantt/1`, a server SVG with ticket rows on Y and time on X) is not
    reused. It is a different chart with different geometry; reusing it would
    break pixel parity.

## Dependencies and blockers

- **DESIGN-E8** (gate on every E8 ticket), sign-off item **S-5**
  (`owner-design-tasks/DESIGN-E8.md:105`): "Gantt card for a past ticket whose
  start is unknown. Default: end-anchored minimum-height card, 'start unknown'
  tooltip." This ticket follows the default. Kevin's answer may reopen the
  start-unknown card only. DESIGN-E8 item 5 (lines 40–46) is the Gantt
  specification; the design code below is its implementation.
- **MP-E8-C9-T05** (cards): `makeCard`, `cardDetail`, `decorate`, the four
  tiers and the escaping rule. This ticket fills the Gantt branches of those
  functions.
- **MP-E8-C9-T07** (edges): `drawEdges` and the `svg.bd-edges.gantt` class.
  This ticket checks the edges on Gantt geometry.
- **MP-E8-C4-T04** (start and end): the payload `start`/`end` in epoch ms or
  `null`, and `start_src`. Its rules: start is never `createdAt`; skew is
  clamped to start = end; paused time and rework stay inside the bar; a
  reopened ticket keeps its latest end.
- **Transitive:** C9-T01 (hook shell, module layout, the payload `now`
  accessor), C9-T02 (`computeLayout`, `LH`, `SEC`, `CH`, `gap`, flow mode),
  C9-T03 (render window, `place`), C9-T04 (columns; `colKey`, `colMap`, the
  "Time"/"Order" lane label at J:607 and J:782), C3-T02 (payload), C1-T01/T02
  (fixtures, parity runner). C7-T03 is a successor (R-G12), not a predecessor:
  this ticket ships an interim `estOf` and C7-T03 replaces it with `estHours`.
- **Concurrent:** after C9-T07, C9-T08 (now band) runs in parallel. They do not
  edit the same expression: C9-T08's `bandLayout(rows, {…, ganttH})`
  (C9-T08 step 1, Decisions 6) takes the Gantt height as an injected function
  and uses the timeline height while it is `null`. This ticket supplies
  `ext.gantt.bandHeight`, which `computeLayout` passes as `ganttH`. Either may
  merge first.
- **C9-T02 slot contract:** `computeLayout(D, S, dims, sources, ext)` calls
  `ext.gantt.hist(…, gctx)` at J:420 and the per-wave `ext.gantt.plan(…, gctx)`
  at J:509–523; `ext.gantt.bandHeight` serves J:493 (C9-T08), and throws "gantt layout not installed" without them
  (C9-T02 N17). This ticket installs that object. C9-T02 already moves history
  rows with `end == null` to `secs.hist.unplaced` before `hist` sees them.
- **C1-T02 parity harness:** the Gantt cells need `view=gantt` (and `span=`).
  C1-T02's `openParityPair` takes `{ dataset, ticket?, query? }` and applies
  `query` on both sides (R-G7).
- **C10-T01 (not a predecessor):** owns the view button, the J:1141 legend and
  the J:1143 switch order. B5's in-place switch half and B7 need it; until
  C10-T01 is in the tree they are `test.fixme` with a pointer to C10-T01, and
  the Gantt page is reached through `?view=gantt`.
- **Successors:** C10-T03 (feature focus and compact in Gantt) and C7-T03
  (replaces the interim `estOf` with `estHours`) wait on this ticket.
- Sources: `tickets/README.md` row C9-T09 (lines 868–885); `chunks.md` C9
  (lines 223–239); `plan.md` §8 EC-20, EC-22 and §10 items 8 and 10;
  `decisions.md` E8-D4, E8-D7 and "Questions the Gantt mode raises".

## Verified starting point (`58854d4c8`)

**Product (`/home/everdred/github/everdred/aiur-worktrees/runtime/src`).**

- No home-page Gantt exists. The only Gantt is the analytics chart
  `Charts.gantt/1` (`lib/aiur_web/operator_control_center/analytics/charts.ex:239-292`),
  used by `lib/aiur_web/live/analytics_live.ex:180` and
  `lib/aiur_web/components/operator_control_center/build_order_analytics.ex:76`
  with the `TimeBrush` hook. Not touched.
- `src/priv/static/build-home/` and every module in it are PROPOSED (C2-T03
  creates the directory, the loader and `hook.js`; C9-T01 sets the module
  layout).
- Browser tests run through `src/browser/scripts/run-browser-tests.mjs`, one npm
  script per spec, chained in `src/browser/package.json` `"test"` (line 10).

**Design (`design-source/assets/build.js` = J, `build.css` = C; read-only).**

| Element | Where | What must match exactly |
| --- | --- | --- |
| Constants | J:10, J:355, J:358, J:364 | `H = 36e5`; `LH = 46`, `SEC = 36`; `fs = 13`; `CH.full = 9.4*fs` (122.2), `CH.line = 2.5*fs` (32.5), `CH.mini = max(24, 2.3*fs)` (29.9) |
| Pixels per hour | J:360 | `pphG = span <= 1 ? 18 : max(0.45, vh / (span*11))`, `vh = max(300, vp.clientHeight - LH - 40)` |
| Gantt skips the density pass | J:382 | `if (span > 1 && S.view !== "gantt")`: Gantt keeps `det = "full"` and `gap = 14` |
| History entry point | J:419–421 | empty history keeps the "No history yet" mark in Gantt too |
| `ganttHist` | J:424–470 | `BRK = span <= 1 ? 30 : max(4, round(30/sqrt(span)))`; intervals `[start,end]` for history and `[start, NOW]` for running rows; merge when `iv[0] <= l[1]`; first `y = SEC + 12`; a gap `> 3*H` becomes a break of height `BRK`, otherwise linear `(b-a)/H*pph`; trailing segment up to `NOW`; `tY` binary search with clamp; card `y = tY(start)`, `h = max(tY(end) - tY(start) - 1, span <= 2 ? CH.mini : 4)`; break label only when `hrs >= 20`: `"Idle · " + fmtWD(t0) + " " + fmtT(t0) + " → " + fmtWD(t1) + " " + fmtT(t1) + " · " + round(hrs) + "h"`; hour step `[1,2,3,6,12,24].find(s => s*pph >= 30) || 24`; day label on the first tick of each day, `tick: true` otherwise; at most 400 ticks per segment; `o.h = y + 10` |
| `assignLanes` | J:471–485 | per column key, sort by `y`; overlap clusters split the column into `lanes`; `+2` px spacing |
| Lane placement | J:761–765 | `lw = c.w / lanes`; width `lw - 4` when `lanes > 1`; `mini`/`bar` capped at 70 px unless flow (owned by C9-T03; Gantt is its only multi-lane caller) |
| Band Gantt height | J:493 | `gv ? max(min(14*pphG, est*pphG), CH.line + min(48, est*3.2)) : …`; `BH = 42` |
| Planned Gantt | J:509–523 | per wave: column (or flow slot) stacking from the wave start; `hrs = override ? override.hours : est`; `h = max(hrs*pph, span > 2 ? 4 : det === "mini" ? CH.mini : CH.line)`; next `y = yy + h + gap*0.5`; label `"≈ +" + round(cum) + "h"` at `start + 30`; `cum += (end - start) / pph` |
| Card tier for Gantt items | J:807–813 | applies when `it.gantt`, `it.gt` or Gantt history; `full` at `h >= 8.8*fs` (114.4), `line` at `>= 2.1*fs` (27.3), `mini` at `>= 20`, else `bar`; `lanes >= 3` caps at `mini`, `lanes >= 2` at `line` |
| `gplan` class | J:819–821 | `it.gantt` adds ` gplan` |
| History card body | J:845–848 | full Gantt: `.bd-time` = `fmtD(start) fmtT(start)<br>→ [fmtD(end) ]fmtT(end)` (end date only when the day differs), `.bd-badges` = `<span class="h">fmtH(hrs)</span><span>{pts} pts</span>`, and no status row |
| `fmtH` | J:19 | `< 1h` → minutes rounded to 5, floor "5m"; `< 10h` → half hours; else whole hours |
| Lane label | J:607, J:782 | "Time" in Gantt, "Order" otherwise (ported by C9-T04; checked here) |
| Legend | J:1141 | `<span class="bd-leg"><span class="bd-leg-h"></span>Planned estimate</span>` only in Gantt (in `renderTools`, ported by C10-T01) |
| View switch | J:1143 | `renderTools(); viewport(); relayout(); jumpNow(true)` (C10-T01; Gantt must survive it) |
| CSS | C:150 `.bd-leg-h`; C:188, 451 `.bd-edges.gantt` opacities (`.bd-e` .35, `.bd-ea` .45, `.bd-e.bl` .8 then .55, `.bd-e.bad` .85); C:197–200 `.bd-lbl`, `.bd-lbl.tick span::after` (6 px tick); C:201 `.bd-dl`; C:203 `.bd-mk.brk` (dashed `--line-strong` borders, `-45deg` hatch 7/8 px); C:352 `.bd-mk.brk:empty` (6/7 px hatch); C:247–250 `.bd-time`, `.bd-badges`; C:267, 412 `.bd-card.gplan .bd-in` (135° hatch, `--ec` at 10 % then 7 %, dashed border, no shadow); C:409 hover-dim gplan; C:975 light-theme gplan (6 %); C:364, 369 the 150 px container query hides `.bd-time` and shrinks badges |

Design facts that drive the unknown rules:

- The design has no unknown start, estimate or end. With `start` missing,
  J:426 pushes `[undefined, end]`, the sort at J:428 compares `NaN`, and J:846
  prints "NaN". With `est` missing, J:493 and J:517 give `NaN` heights.
- **Edge case in the design itself:** `merged[0][0]` at J:431 throws when
  there is no interval at all. That happens when every loaded history row is
  hidden by compact mode and no agent is running. With real data it also happens
  when every loaded history row has an unknown start.
- C:658 `.bd-card.line.gt` never matches: `gt` is an item flag (J:493), never a
  class. The port must not add a `gt` class, or that rule would start to apply
  and change pixels.

## Chosen design

### Port verbatim, change three inputs

Copy J:424–485 and J:509–523 into `gantt.js` as written, with these changes
only:

1. `NOW` → the payload clock `nowMs()` from C9-T01's `clock.js`. The payload's `now` is the server clock; the client advances it
   with a monotonic timer (C3-T02). The browser wall clock is never used.
2. Unknown values get an explicit branch (below).
3. The functions take their inputs as arguments instead of closing over `S`,
   `D` and `L`: `ganttHist(ents, o, ctx)` (C9-T02's call
   `ext.gantt.hist(entries, NOWL, hs, gctx)`, with `ctx` = C9-T02's `gctx`), `ctx = { now, nowRows, span, pph, flow, K, colKey, CH, gap,
   det, dayL, compact: ext.compact ?? false }`. `nowRows` is `NOWL` (J:357).
   This is structure, not behaviour: the same numbers come out, which the
   layout oracle (Verification G1) proves.

### Unknown and odd values (EC-22, EC-08)

| Input | Rule | Why |
| --- | --- | --- |
| History row with `start === null` (S-5) | Its interval is `[end - dt, end]` with `dt = hMin / pph * H` and `hMin = span <= 2 ? CH.mini : 4` (the design's minimum). This reserves exactly one minimum-height card of linear axis above the end, so the card never sits on a break band or above the section's first `y` (`SEC + 12`). The `dt` is axis space only: it is never shown, stored or used as a start. Card: `y = tY(end - dt)`, `h = hMin`, so its bottom is `tY(end)` (within 1e-9 px). Class `start-unknown` (no CSS: no pixel change). The `.bd-in` `title` ends with ` · start unknown`. A full-tier card (not reachable at the minimum height, but guarded) shows `.bd-time` = `Start unknown<br>→ …end` and the badge `—`. | S-5 default. A start from `end`, `created` or `0` would draw a confident bar at the wrong time. A zero-length `[end, end]` interval would put the card's top half over the preceding break mark, or over the section header when it is the earliest row. |
| History row with `end === null` | Skipped: no interval, no card. | C4-T04 T9: an unknown end cannot be placed on the axis. C9-T02 already moves such rows to `secs.hist.unplaced`; the skip guards direct callers (C10-T03). |
| `start > end` | `start = end` before the interval is pushed and before `tY(start)`. Without it the card `y` is `tY(start)`, below its end. | C4-T04 clamps skew on the server; this guards older rows. |
| `ctx.now` not a number | Not reached: C9-T01 does not apply a snapshot without `now` (its N4), so no layout runs. No extra branch here. | Ponytail: no second guard for a state the caller already rejects. |
| Zero duration | The minimum height. `fmtH(0)` gives "5m" in a full card. | J:19, J:442 as designed. |
| Running row with `start === null` | No `[start, now]` interval. Its band card is unaffected (the band uses the estimate). | Same as S-5. |
| Band row estimate (`estOf(t)` is `null`) | Height `CH.line` (the formula's floor), class `est-unknown`, `title` " · estimate unknown" on `.bd-in` for line/mini/bar tiers. | C7-T03 §4.5 table: "the existing minimum". |
| Planned row estimate unknown | Height = the J:517 minimum, class `est-unknown`, same title. | C7-T03 §4.5. |
| A wave after a wave with an unknown estimate | The cumulative label reads `"≈ ≥+" + round(cum) + "h"`. | The sum is a lower bound. Same `≥` rule as C7-T03's `etaLabel`. |
| No interval at all | `merged` is empty: `cur = ctx.now`, so J:435 calls `lin(now, now)`, which adds nothing. No segment, no break, no tick, no items; `o.h = SEC + 12 + 10 = 58`. | Fixes the J:431 crash (and the `NaN` segment J:435 would add with `cur` undefined) without changing any design dataset. |

Estimates use an interim local `estOf(t)` (`override.hours` if set, else a
numeric `est`, else `null`; never `EST[cx-1]`) in both J:493 and J:516 (R-G12).
Until C7-T03 wires `est`/`override` into the assembler both are `null` on real
data, so these sites render the unknown branch. C7-T03 replaces `estOf` with
`estHours` (same rule). The design reads `t.est` only at J:493; see
"Decisions made without the owner" item 3.

The `start-unknown` and `est-unknown` classes and the `title` text are the
testable marker. Height alone cannot be the marker: `est ?? 0` gives the same
`CH.line` height as the unknown branch.

### Time zone and clock (EC-20)

- Display uses the browser's zone, as the design does: `fmtD`, `fmtWD`, `fmtT`,
  `dayKey` and the tick loop (`setMinutes`, `setHours`, `getHours`) are local
  time (J:15–18, J:458–466). Data is UTC epoch ms from the server.
- Geometry uses milliseconds: `lin` heights are `(b - a) / H * pph`, so a card's
  height is the same in every zone. Only tick and day-label positions move.
- DST: the design's hour loop uses `setHours(getHours() + 1)`. On the
  fall-back night it skips the repeated hour's second label; on the
  spring-forward night the missing hour is jumped. The `k < 400` bound stops the
  loop in every case. Keep both behaviours; they are the design's.
- Fixtures run in `America/Los_Angeles` with `now` = 2026-10-07 14:20 (C1-T01).

### Interfaces

- **Consumes:** payload rows `start`, `end` (ms or `null`), `est`, `override`,
  `pts`, `num`, `title`, `sec`, `status`, `deps` (C3-T02); `nowMs()` (C9-T01);
  `colKey`, `colMap` (C9-T04); `place` (C9-T03); `makeCard`/`cardDetail`
  (C9-T05); the interim `estOf` (replaced by C7-T03's `estHours`,
  `build-home/estimate.js`); `drawEdges` (C9-T07).
- **Does not need `start_src`.** `start === null` is the unknown marker. The
  S-5 default tooltip says "start unknown" for every unknown, whatever the
  source. If Kevin's S-5 answer wants the source shown, read `start_src` then.
- **Exposes:** `ganttHist`, `assignLanes`, `planGantt`, `bandGanttHeight`
  from `gantt.js`, and `ganttExt = { hist: ganttHist, plan: planGantt,
  bandHeight: bandGanttHeight }` for C9-T02's `ext.gantt`. `plan` is the
  per-wave branch (J:510–523): `planGantt(ents, y, ctx) -> { items, end, label,
  unknown }`, where `computeLayout` pushes `items` and `label` and carries `cum`
  and the unknown flag across waves. `bandHeight(t, ctx)` is the `ganttH` that
  C9-T08's `bandLayout` takes. C10-T03 calls `hist` with compact `entries` and
  `ext.compact`.

## Implementation steps

1. Create `src/priv/static/build-home/gantt.js` (PROPOSED path; follow the
   C9-T01 module layout if it differs). Copy J:424–485 into `ganttHist` and
   `assignLanes`; replace `NOW` with `ctx.now`. Add the unknown branches from
   the table: skip `end === null`; `start = min(start, end)`; the interval
   `[end - dt, end]` and the card `y = tY(end - dt)` for `start === null`, with
   `startUnknown: true` on the item; the empty-`merged` guard
   (`cur = merged.length ? merged[0][0] : ctx.now`).
2. Move the J:509–523 planned branch into `planGantt(ents, y, ctx)`. Use
   `estOf`; set `estUnknown: true` on the item when it is `null`; carry an
   `unknown` flag (returned by `planGantt`, carried across waves by `computeLayout`) into the `≈ ≥+Nh` label.
3. Add `bandGanttHeight(t, ctx)` for the `gv` arm of J:493, with the
   `estOf`/unknown rule. Export `ganttExt` and install it as `ext.gantt` in
   the `ext` that C9-T03's `relayout()` builds (C10-T03 step 2 builds
   `{ ...fx.layoutExt(D, S), gantt }`; until C10-T03 lands, `{ gantt:
   ganttExt }`). Do not edit `computeLayout`'s call sites; C9-T02 already
   calls the slots.
4. In C9-T05's card module: keep `cardDetail` J:807–813 verbatim; add the
   Gantt body and status from J:845–848; add the `gplan` class (J:819–821);
   append ` start-unknown` / ` est-unknown` to the class list and the title
   suffixes from the table. All text goes through `esc` (EC-30). Add a
   `durLabel(t)` helper that returns `—` when `start` is `null`, else
   `fmtH((end - start) / H)`.
5. Do not add a `gt` class (C:658).
6. Confirm C9-T07's `svg.classList.toggle("gantt", S.view === "gantt" &&
   !hoverId)` (J:930) is ported; if it is missing, add that one line.
7. Do not port the J:1141 legend or the J:1143 switch: they are in C10-T01's
   `renderTools`. B7 and B5's switch half are `test.fixme` until C10-T01 is
   in the tree (Dependencies).
8. Tests (Verification). Add
   `"test:build-home-gantt": "npm run fixture:preflight && node scripts/run-browser-tests.mjs tests/build-home-gantt.browser.spec.mjs"`
   to `src/browser/package.json` and to the `"test"` chain (line 10), as C9-T02
   does for its spec.
9. Docs: Gantt mode is a new user-facing view, but it is reachable only on the
   temporary `/build` route until C12-T01's cutover, and C12-T07 owns
   `website/docs-app/guide/gui.md` for the home page. Put a short "Gantt view"
   paragraph in the PR body for C12-T07 (as C4-T04 step 7 does): what the
   height means, that idle time over 3 h folds into hatched bands, that hatched
   dashed cards are planned estimates, and that "start unknown" cards end at
   their end time with a minimum height.

## Non-happy paths

| Case (EC) | Concrete input | Expected | Test |
| --- | --- | --- | --- |
| Start unknown (EC-22, S-5) | hist `#41`, `start: null`, `end` = Oct 7 10:00, `pts: 3`, span 1; neighbours with known starts | Interval `[10:00 - 29.9/18 h, 10:00]`; card bottom = `tY(Oct 7 10:00)`, `h = 29.9`, tier `line`, class `start-unknown`, title `#41 · … · start unknown`; no "NaN" in the DOM | U1, B3 |
| Start unknown after a break | `#41` as above; the previous interval ends Oct 6 20:00 (a 14 h gap) | card top ≥ the `brk` mark's bottom; when `#41` is the earliest row, card top ≥ `SEC + 12` | U1 |
| All loaded starts unknown, no agents | two hist rows, both `start: null`; `now` rows empty | no throw; cards end at their ends; no card overlaps a `brk` mark; first card top = `SEC + 12` | U2 |
| No interval at all | compact entries with only gaps, no running rows | no throw; `o.items` empty; `o.h = 58` | U3 |
| End unknown | hist row `end: null` | no card, no interval | U4 |
| Zero duration | start = end = 12:00 | `h = CH.mini` (span ≤ 2) or `4` (span > 2); full-tier body never reached; status-free | U5 |
| Start after end | start 12:05, end 12:00 | `y = tY(12:00)`, minimum `h` (not `tY(12:05)`) | U5 |
| Short gap | intervals end 09:00, next start 12:00 (exactly 3 h) | linear segment, no break | U6 |
| Break without label | 09:00 → 13:30 (4.5 h) | one `brk` mark, `h = 30` at span 1, empty text, `:empty` hatch | U6, B2 |
| Break with label | Mon Oct 5 18:00 → Tue Oct 6 20:00 (26 h, before `now`) | label `Idle · Mon Oct 5 18:00 → Tue Oct 6 20:00 · 26h` | U6 |
| Multi-day ticket | start Oct 5 22:00, end Oct 7 02:00 | one tall card (no split); `.bd-time` `Oct 5 22:00<br>→ Oct 7 02:00`; day labels on both day changes inside it | U7 |
| Same-day ticket | 09:10 → 11:40 | `.bd-time` `Oct 7 09:10<br>→ 11:40`; badge `2.5h` | U7 |
| Reopened ticket | C4-T04 sends the latest end | drawn once, start to latest end | covered by C4-T04 T7 |
| Overlapping tickets in one column | three intervals overlap in `bugs` | `lanes = 3`, tiers capped at `mini`, widths `c.w/3 - 4` | U8 |
| Planned, unknown estimate | plan row `est: null`, `override: null`, span 1 | `h = CH.line` (det `full`), class `est-unknown`; the next wave's label `≈ ≥+Nh` | U9 |
| Planned, override on unknown cx | `est: null`, `override.hours: 6` | `h = 6 * 18 = 108`, no `est-unknown` | U9 |
| Band, unknown estimate | now row `est: null` | `h = CH.line`, class `est-unknown` | U10 |
| Band, override | now row `est: 2`, `override.hours: 8` | `h = max(min(252, 144), 32.5 + 25.6) = 144` | U10 |
| Time zone (EC-20) | `live` dataset in `America/Los_Angeles` vs `Asia/Kolkata` | every card height equal; tick labels differ; day labels at local midnight | B4 |
| DST fall back (EC-20) | one ticket 2026-11-01 00:30 PDT → 03:30 PST, LA (4 h elapsed) | loop ends; label y values strictly increase; card `h = 4 * pph - 1` (71 at span 1) | U11 |
| DST spring forward | one ticket 2027-03-14 01:30 PST → 03:30 PDT, LA (1 h elapsed) | loop ends; label y strictly increase; `h = max(18 - 1, 29.9) = 29.9` | U11 |
| Clock | payload `now` = 14:20 while the browser clock reads 2030 | the trailing segment ends at 14:20 | U12 |
| Many tickets (EC-09) | `dense` dataset in Gantt | render window still ±700 px; `assignLanes` is O(n log n) per column | B1 (C12-T06 measures) |
| Untrusted title (EC-30) | title `<img src=x onerror=…>` in a Gantt card | text, not markup, in `.bd-title` and the `title` attribute | B3 |
| Live diff while in Gantt (EC-10) | a now row moves to hist with real `start`/`end` | one relayout; the card appears in history at its interval | B5 |
| View switch | Timeline → Gantt → Timeline | DOM equals the first Timeline render; no stale `gplan` class | B5 |
| Reduced motion | `prefers-reduced-motion` | Gantt adds no motion; `jumpNow(true)` is instant | C1-T03 |

- **Security:** text only through `esc` and `textContent`. No new network call.
- **Accessibility:** the `title` suffixes give the unknown state in words. The
  list view (C9-T12) stays the screen-reader view; Gantt adds no new focus
  target.
- **Disconnect/stale:** Gantt draws the payload it has. Stale styling
  (`.bd-root.stale`) is C9-T13 and applies unchanged.

## Compatibility and rollout

- Client only. No config key, CLI flag or env var. No GitHub calls.
- Ships behind the temporary `/build` route (C3-T01) until C12-T01's cutover.
- Rollback: revert the commit. Timeline and list views do not depend on
  `gantt.js` except through the `S.view === "gantt"` branches.
- Docs: step 9 (new user-facing view, AGENTS.md "Docs ship with the change").

## Verification

One spec: PROPOSED `src/browser/tests/build-home-gantt.browser.spec.mjs`, run by
`npm run test:build-home-gantt` (step 8). The context uses
`timezoneId: 'America/Los_Angeles'` unless a test says otherwise. The repo has
no `node --test` runner in `src/browser`, and `gantt.js` is a browser ES module
under `priv/static`, so the unit cases call it in the page through
`page.evaluate(() => import("/build-home/gantt.js"))`, as C9-T08 does.

**Unit cases** (pure functions, fixture origin, no layout DOM):

| # | Test | Expected | Fails without |
| --- | --- | --- | --- |
| U1 | "start unknown is end-anchored, minimum height, marked, clear of breaks" | item `abs(y + h - tY(end)) < 1e-9`, `h == 29.9`, `startUnknown == true`; with a 14 h gap before it, `y >=` the `brk` mark's `y + h`; as the earliest row, `y >= SEC + 12` | the unknown branch (M1, M1b) |
| U2 | "all starts unknown does not throw" | two items, each ending at its `tY(end)`; no item overlaps a `brk` mark | the unknown interval (M1b) |
| U3 | "no interval does not throw" | `o.h == 58`, no items, no segments, no `NaN` in `marks`/`labels` | the empty-`merged` guard (M2) |
| U4 | "end unknown is skipped" | no item, no interval | the `end === null` skip (M6) |
| U5 | "zero and negative duration get the design minimum at the end" | zero: `h == 29.9` (span 1), `h == 4` (span 3); start 12:05 / end 12:00: `y == tY(12:00)` | the `min(start, end)` clamp (M7) for the negative half; the zero half is a design-behaviour guard, named so in the test |
| U6 | "gaps over 3h become breaks; labels from 20h" | 3 h → no break; 4.5 h → break, label `""`; Mon Oct 5 18:00 → Tue Oct 6 20:00 → `Idle · Mon Oct 5 18:00 → Tue Oct 6 20:00 · 26h` | — (port guard; G1 is the exact check) |
| U7 | "card time text and badges" | `Oct 5 22:00<br>→ Oct 7 02:00`, `Oct 7 09:10<br>→ 11:40`, `2.5h`, `3 pts` (from `makeCard` in the page) | — (port guard; G1/B1) |
| U8 | "overlaps split lanes" | `lanes == 3` for all three; `cardDetail` ≤ `mini` | — (port guard) |
| U9 | "unknown planned estimate is minimum and marked; override still counts" | `h == 32.5` + `estUnknown`; override 6 → 108; next wave label starts `≈ ≥+` | the `estHours` null branch (M3) |
| U10 | "band height uses estOf; unknown is the floor and marked" | 144 for the override row; 32.5 + `estUnknown` | `t.est` instead of `estOf` (M4), the null branch (M3) |
| U11 | "DST nights terminate and keep order" | finite labels, strictly increasing `y`; fall back `h == 4 * 18 - 1 == 71`; spring forward `h == 29.9` | — (EC-20 guard, named so) |
| U12 | "now comes from the payload" | with `page.clock.setFixedTime("2030-01-01")` and payload `now` = 2026-10-07 14:20, last segment `t1 == payload now` | a `Date.now()` in place of `ctx.now` (M5) |

**G1 — Gantt layout oracle (exact).** Reuse C9-T02's Check 1 oracle
(`window.__E8L`, the design's own `computeLayout` text sliced from the vendored
`build.js` and injected with `page.addScriptTag`) with `S.view = "gantt"`.
The design's `ganttHist` is nested inside `computeLayout` and closes over its
locals, so it cannot be called alone; the oracle runs the whole function. For
datasets `live`, `dense`, `newrepo`, `noqueue` × spans 1, 2, 3, 7, 30 ×
dims `desktop` and `phone` (C9-T02's values), both sides get the same `D`,
`S` and `dims`; the spec requires deep equality (`===` on numbers) of
`secs.hist` and `secs.plan` (`items` as `{ id, key, y, h, sec, lane, lanes,
gantt }`, `marks`, `labels`, `h`) and `band.items` heights. The design rows all
have a known start, end and estimate, so every unknown branch is idle and any
drift from the design fails here. This is what proves U6–U8 and the
"structure, not behaviour" claim.

**Page cases** (fixture route from C3-T01, `?view=gantt`):

| # | Test | Expected |
| --- | --- | --- |
| B1 | parity matrix in Gantt (see Pixel parity) | zero diff above the floor |
| B2 | break marks | `.bd-mk.brk` count and `top`/`height` equal the design page's for `live` and `dense` |
| B3 | start-unknown row (extra fixture row) | `.bd-card.start-unknown` exists, its `title` ends `start unknown`, its bottom = the `tY(end)` read from the item; `document.body.innerText` has no `NaN`; XSS title rendered as text |
| B4 | time zone (EC-20 guard) | two contexts (`timezoneId` LA, Kolkata): equal `.bd-card` heights; differing `.bd-lbl` text |
| B5 | live diff and view switch | after a now→hist upsert, the card is in `#bd-sec-hist` with the interval height; Timeline → Gantt → Timeline (C10-T01 buttons; `test.fixme` until C10-T01) gives the same `.bd-card` class lists as the first Timeline |
| B6 | edges on Gantt geometry | `svg.bd-edges` has class `gantt`; for each design `.bd-e` path in `live`, the product has a path with the same `d` (rounded to 0.5 px) |
| B7 | legend and lane label | `.bd-leg-h` + "Planned estimate" present only in Gantt (`test.fixme` until C10-T01); `.bd-lane-g` reads "Time" |

**Mutation checks** (AGENTS.md "Tests must fail without the production change").
Run each in a worktree; `git status --porcelain` must show only that hunk; put
the commands and results in the PR body:

- M1: replace the start-unknown branch with `start ?? end` → U1 fails (no
  marker, card hangs below its end). Replace it with `start ?? 0` → U1 fails
  (axis starts at 1970).
- M1b: use the interval `[end, end]` and `y = tY(end) - h` → U1 and U2 fail
  (card over the break mark, card above `SEC + 12`).
- M2: delete the empty-`merged` guard → U3 throws.
- M3: replace the estimate null branch with `?? 0` → U9 and U10 fail on the
  `estUnknown` marker and the `≥` label, even though the height is the same.
- M4: use `t.est` at the band (the design's J:493) → U10 fails on 144.
- M5: use `Date.now()` for the trailing segment → U12 fails.
- M6: delete the `end === null` skip → U4 fails (`NaN` item).
- M7: delete `start = min(start, end)` → U5's negative half fails
  (`y == tY(12:05)`).

Commands:

```bash
env -C src/browser npm run test:build-home-gantt
env -C src/browser npm run test:design-parity     # C1-T02 runner, Gantt cells
```

No test reads `~/.aiur` or a live daemon; the browser spec uses the fixture
route only.

**Manual check** (AGENTS.md "Manual testing"): on a `scripts/aiurdev --test`
run, open `/build?view=gantt` against the live daemon, confirm history cards
have heights, break bands appear over nights, a running ticket's band card is
hatched-free and planned cards are hatched and dashed. Capture a screenshot at
390 px and 1440 px for the PR.

## Pixel parity

Checked with C1-T02's `expectDesignParity(pair, { name, region })`, design page
`?example=<dataset>&view=gantt` after `switchTab("build")` against the product
fixture route with the same dataset and `?view=gantt`. Frozen `Date`,
`TZ=America/Los_Angeles`, local fonts, 600 ms boot wait (C1-T02).

- **Whole page:** datasets `live`, `dense`, `newrepo`, `noqueue`, `offline` ×
  1440/1024/390 px × dark/light × Gruvbox/default. Three scroll positions per
  cell: after `jumpNow(true)` (opens at the band), `scrollTop = 0` (oldest
  loaded history), and the planned section top.
- **Spans:** `live` at `span` 1, 2, 3, 7 and 30, because `pphG`, `BRK`, the
  hour step and the minimum heights change with span.
- **Regions:** `.bd-mk.brk` (labelled and empty), `.bd-lbl.tick`, `.bd-dl`,
  a full-tier history card (`.bd-time`, `.bd-badges`), a two-lane and a
  three-lane column, `.bd-card.gplan` (dark and light, C:975), the band Gantt
  stack, `svg.bd-edges.gantt`, `.bd-leg-h` in `#bd-status`, `.bd-lane-g`.
- **Container query:** a Gantt card at 150 px and at 96 px width (C:360–372)
  hides `.bd-time` and shrinks the badges.
- **No design baseline:** the start-unknown and estimate-unknown cards. C1-T02's
  element mode captures them from one extra fixture row each, for Kevin's
  DESIGN-E8 sign-off (S-5). Until then, that capture is the baseline and a
  change to it fails the check. They are allowlisted only as `pending-sign-off`
  entries in `design-parity-allowlist.json`, which every run lists.
- Motion: the view switch and `jumpNow(true)` sequences are in C1-T03's
  scripts; this ticket adds the Gantt variant to them.
- Any difference not approved by Kevin in writing is a failing test.

## Completion and handoff

- [ ] `gantt.js` ports J:424–485, 509–523 and the J:493 Gantt arm with only the
      listed changes; U1–U12 and G1 pass; `ganttExt` is installed as
      `ext.gantt`.
- [ ] Card Gantt branches (J:807–813, 819–821, 845–848) ported; no `gt` class.
- [ ] Start, estimate and end unknown rules render as specified; no `NaN`, `0`
      or plausible default anywhere; M1–M7 (with M1b) fail as stated.
- [ ] B1–B7 pass (B5 switch half and B7 `fixme` only while C10-T01 is absent);
      Gantt cells of the parity matrix green; S-5 captures attached.
- [ ] `test:build-home-gantt` is in the `test` chain.
- [ ] Docs paragraph for C12-T07 in the PR body (step 9).
- **Dependents:** C10-T03 (compact and focus in Gantt), C12-T01 (cutover),
  C12-T06 (performance measurement includes Gantt on `dense`).

### Interface notes for neighbours

- **C3-T02:** Settled 2026-10-08: C4-T04 adds `start_src` and nullable `start`
  (R-G1). C9-T09 does not need `start_src`: `start === null` is the marker. Keep `start`, `end`, `est`
  nullable.
- **C10-T01** ports `renderTools` (J:1128–1150), which contains the J:1141
  "Planned estimate" legend that the README gives to this row. Resolution: C10-T01
  ports the line verbatim; this ticket owns its test (B7) and its parity region.
- **C7-T03:** Settled 2026-10-08: C7-T03 lands after this ticket (R-G12) and
  replaces the interim `estOf` at J:493 and J:516 with `estHours` (decision 3).
- **C9-T08** owns the band stacking (J:493) in `bandLayout`; this ticket
  supplies its `ganttH` as `ext.gantt.bandHeight`. No shared edit.
- **C9-T02:** Settled 2026-10-08: the slots are `ext.gantt.hist` and the
  per-wave `ext.gantt.plan`; `planGantt` returns `{ items, end, label, unknown }`.
- **C1-T02:** Settled 2026-10-08: `openParityPair` takes `{ query }` (R-G7).
- **C9-T01:** Settled 2026-10-08: the payload clock is `clock.js` `nowMs()`.
- **C2-T04:** Settled 2026-10-08: C:658 `.bd-card.line.gt` is in C2-T04's
  dead-rule list.
- **C8-T04:** Settled 2026-10-08: C8-T04 never sends a `hist` row with
  `end: null` (C3-T02 requires an integer `end`); the skip stays as a guard.

## Decisions made without the owner

1. **S-5 default followed:** an end-anchored, minimum-height card with a
   "start unknown" title. The unknown row also reserves one minimum card height
   of linear axis above its end (`[end - dt, end]`), so the axis covers it, a
   run of unknown rows cannot crash the layout, and the card never overlaps a
   break band or the section header. `dt` is never shown as a start. Kevin's
   S-5 answer may change the card; the marker class stays.
2. **Estimate unknown uses the design's minimum height plus a marker class and a
   title suffix,** as C7-T03's table says. Height alone cannot tell unknown from
   zero, so the class is the tested signal. It changes no pixels.
3. **The band Gantt height uses `estOf` (override first; C7-T03 swaps in
   `estHours`),** not the design's `t.est`. The design's fixtures have no
   override on running rows, so parity is unchanged, and E8-D7 says an override sets the expected duration.
4. **The cumulative wave label shows `≥` after a wave with an unknown
   estimate.** The design has no such case. `≥` matches C7-T03's ETA rule.
5. **The empty-interval crash at J:431 is fixed** with a guard that no design
   dataset reaches, so no pixel changes.
6. **A history row with an unknown end is skipped,** not drawn at `now` or at
   its start.
7. **DST behaviour of the tick loop is the design's,** including the skipped
   repeated-hour label on the fall-back night. Changing it would be a visual
   difference with no approval.
8. **The Gantt functions take explicit arguments** instead of closing over the
   design's globals, so they can be unit-tested. Outputs are compared with the
   design's own `computeLayout` on the same input (G1, C9-T02's oracle).
9. **A history row with `start > end` is drawn at its end** (`start =
   min(start, end)`), so the card is never below its own end.
10. **No `node --test` runner is added.** The unit cases run in the page
    through `import()`, like C9-T08's, so the existing Playwright chain covers
    them and no new test tool enters `src/browser`.
11. **The legend and the view switch are not ported here.** C10-T01 owns
    `renderTools` (J:1128–1150). This ticket keeps their tests, marked `fixme`
    until C10-T01 is in the tree, so the README's legend item is checked
    without two tickets writing the same line.

## Review log

Adversarial review, 2026-10-08, against `build.js`/`build.css`, the runtime
tree at `58854d4c8`, the README row and C9-T02, C9-T08, C4-T04, C7-T03,
C9-T01, C10-T01, C10-T03.

1. User value said band cards are hatched; only planned (`gplan`, J:819) are.
   Fixed.
2. Interfaces did not match C9-T02's `ext.gantt = { hist, planItem,
   bandHeight }` slot or C10-T03's `hist(entries, hs, ext)` shape; the ticket
   told the writer to edit `computeLayout` call sites. Now it installs
   `ganttExt`; `ctx` carries `ext.compact`.
3. "Concurrent edit of J:493 with C9-T08, merge T08 first" contradicted
   C9-T08's `ganttH` injection. Replaced.
4. Start-unknown `[end, end]` interval put the card over the preceding break
   band, and above `SEC + 12` when earliest. Changed to a reserved
   `[end - dt, end]` axis span; U1/U2 assert it; M1b added.
5. `start > end` was claimed "treated as start = end" but no step did it
   (`y` stayed `tY(start)`). Added the clamp, U5 negative half, M7.
6. Empty-`merged` text said "one zero-length segment"; `lin` adds none, and
   the design's J:435 also yields `NaN` with `cur` undefined. Reworded with
   `cur = ctx.now`.
7. U5–U8/U11 claimed a Node `vm` could run the design's `ganttHist`; it is
   nested in `computeLayout` and closes over its locals. Replaced by G1, C9-T02's
   `__E8L` oracle in Gantt view.
8. Proposed `node --test` unit spec: no such runner in `src/browser`
   (`run-browser-tests.mjs` spawns Playwright only) and `gantt.js` is a browser
   module. Folded into one Playwright spec with the exact npm script.
9. Break-label example ended at Wed Oct 7 20:00, after the fixture `now`
   (14:20). Moved to Mon Oct 5 → Tue Oct 6.
10. DST heights were `3h * pph`; elapsed time is 4 h (fall back) and 1 h
    (spring forward), and the J:442 `- 1` applies. Fixed to 71 and 29.9.
11. U4 had no named mutation; added M6.
12. Step 7 had this ticket add the legend if C10-T01 had not merged (two
    owners of one line). Now not ported; B5 switch half and B7 are `fixme`
    until C10-T01.
13. Parity cells need `view=gantt`, which C1-T02's `openParityPair` cannot
    pass. Named as a dependency with the shared `{ query }` request.
14. Docs step pointed at an unnamed guide page "C12 writes". Now a PR-body
    paragraph for C12-T07 (`guide/gui.md`), as C4-T04 does.

Verified unchanged: J:10–19, 355–364, 382, 419–523, 604–607, 757–767,
807–848, 930, 1138–1143; C:150, 188, 197–203, 247–250, 267, 352, 360–372,
409, 412, 451, 658, 975; `charts.ex:239-292`, `analytics_live.ex:180`,
`build_order_analytics.ex:76`, `src/browser/package.json:10`;
DESIGN-E8.md:105 (S-5) and lines 40–46; README row predecessors match
`blocked_by`.
- Reconciliation 2026-10-08 (coordinator): C9-T02 slot names (`ext.gantt.hist`, per-wave `ext.gantt.plan`; `planItem` removed), interim `estOf` estimate sites per R-G12 (C7-T03 now a successor that swaps in `estHours`), `nowMs()` clock, C1-T02 `{ query }` per R-G7, `pending-sign-off` spelling, settled interface notes (start_src, C7-T03, C9-T02, C1-T02, C9-T01, C2-T04, C8-T04).
