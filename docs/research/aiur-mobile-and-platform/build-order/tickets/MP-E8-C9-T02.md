---
ticket_id: MP-E8-C9-T02
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: Timeline layout and density tiers
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C9-T01]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-18]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T02 — Timeline layout and density tiers

> **Wave 0b.** Product paths are cited at `58854d4c8` under
> `/home/everdred/github/everdred/aiur-worktrees/runtime/src`. Paths marked
> PROPOSED do not exist yet. `J` = `design-source/assets/build.js`, `C` =
> `design-source/assets/build.css` (design etag 1791431544512943). This ticket
> ports the geometry of the three board sections. It draws no card (C9-T05),
> runs no render window (C9-T03) and lays out no Now band (C9-T08).

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C9 (client timeline
  engine, port of `build.js`).
- **User value.** The board puts each ticket at the same place and the same
  size as the design: one row per epic slot in time order, a day label on each
  new day, wave labels in the planned section, card heights that shrink with
  the span (full → line → mini → bar), and a narrow "flow" layout on a phone.
  Because the layout is the design's own code, the C1-T02 screenshots can match.
- **Deliverable.** PROPOSED `src/priv/static/build-home/layout.js` (the file
  C9-T01's module table assigns to this ticket), plus the shared helper file
  below if it does not exist yet. `layout.js`:
  1. ports `computeLayout()` (J:355–422 and J:497–533, the README row's ranges)
     as a pure function of the data model, the view state, the viewport sizes
     and the source states. The Gantt branches and the Now band (J:486–496) are
     call sites for C9-T09 and C9-T08;
  2. ports the flow and slot-count rule from `relayout()` (J:646–649);
  3. ports the label and marker element code from `update()` (J:714–734) as
     three small factories that C9-T03 calls inside its render window;
  4. adds two non-design states the data contract allows: an unavailable or
     disabled source, and an unknown wave (see "Non-happy paths").
- **Shared helpers** (C9-T04 and C9-T12 already import them from "C9-T02's
  `util.js`"):
  - PROPOSED `build-home/util.js`: `MON`, `WD`, `p2`, `fmtD`, `fmtWD`, `fmtT`,
    `dayKey`, `fmtH`, `fmtRange` (J:12–26 verbatim);
  - `build-home/icons.js` (`sv`, `I`, J:32–73) is C9-T01's (R-G9); this ticket
    imports `I` from it.
- **Non-goals.**
  - The render window, `place()`, section heights on the DOM, `--fs`, the
    `.flow` class toggle and section headers: C9-T03 (it calls this module).
  - **The Now band** (`BL`, `BK`, `BH`, the stacks, `band.h`, J:486–496): C9-T08
    ("Band layout", README row; C9-T08 step 3 and C9-T04 non-goals agree). This
    ticket leaves the call site `out.band = { items: [], h: 0, BK: 1 }` that
    C9-T08 asks for.
  - Gantt geometry (`ganttHist`, `assignLanes`, J:424–485; planned Gantt items,
    J:509–523): C9-T09 fills the `ext.gantt` slot this ticket leaves.
  - Compact feature mode (`entries` with ghosts, J:366–379): C10-T03's
    `layoutExt`. `rows()` keeps its `gap` branch (J:406) and the planned
    section keeps J:506, so C10-T03 needs no edit here.
  - Columns (`visibleCols`, `applyCols`): C9-T04. Card tiers inside a card
    (`cardDetail`, J:807–813): C9-T05.
  - Final copy, age, filtered and window-empty markers (S-9): C9-T13, which
    replaces this ticket's interim source check with `sectionState`/`emptyMark`.
  - No CSS. Every rule these elements use is already in C2-T04's sheet.

## Dependencies and blockers

- **Blocked by DESIGN-E8** (Kevin's go).
- **Predecessor: MP-E8-C9-T01.** This ticket needs from it:
  - the module layout: `state.js` (`S`, `ctx`, `fx`, `LH = 46`, `SEC = 36`,
    `gutW`), `dom.js` (`esc` with `'` → `&#39;`); this module imports `LH`,
    `SEC` and `esc` from there and defines no second copy;
  - the data model `D` from C3-T02's `intake(snapshot)`:
    `{epics, features, order, counts, hist, now, plan, nq, all, byId, children}`,
    and the last snapshot's `sources` block (`ctx.snap.sources`), which
    `intake` does not return;
  - the view state `S` with the design's field names (`view`, `span`,
    `histFrom` from `history.from`, `feature`, `fmode`, `f.epic`, `liveMin`,
    `flow`, `K`), written by C3-T03's URL bridge.
- **Transitive:** C3-T02 (payload and `intake`), C2-T04 (stylesheet), C1-T01
  (fixtures and vendored design), C1-T02 (parity harness).
- **Owner questions.** S-9 (unavailable vs empty) follows its written default
  (same `.bd-mk.empty` marker with "unavailable" copy); C9-T13 adds the age and
  the final copy. No other S-n or OQ-E8-n item changes this layout.
- **Successors:** C9-T03 (calls `computeLayout`, `measureFlow`, `histDays` and
  the factories), C9-T04 (reads `S.flow`, `S.K`, item `key`s, `colKey`),
  C9-T05 (reads `L.det`, `L.base`, `L.fs`), C9-T07 (item `y`/`h`), C9-T08
  (replaces the `out.band` stub with `bandLayout`), C9-T09 (`ext.gantt`),
  C9-T10 (spans), C9-T13 (replaces the interim empty/unavailable check),
  C10-T02 (replaces the local `epicOk` with `rowOk`), C10-T03 (`ext.entries`,
  `ext.compact`, `ext.gapLabel`).
- **May run concurrently with** C9-T12 (list view; it imports `util.js` only)
  and the server tickets C4–C8.
- **Shared contracts:** none (CONTRACT-REQUESTS.md).

## Verified starting point (`58854d4c8`)

**Design (read-only reference).**

- J:355 `const LH = 46, SEC = 36;` — top lane height and section header height.
- J:358 `vh = Math.max(300, (vp ? vp.clientHeight : 700) - LH - 40)`; J:359
  `gap = 14`; J:360 `pphG` (read only by the Gantt branches); J:362
  `baseDet = "full"`.
- J:361 `dayL` is read only by `ganttHist` (J:463). It goes to C9-T09.
- J:364 `CH = { full: 9.4 * fs, line: 2.5 * fs, mini: Math.max(24, 2.3 * fs) }`
  with `fs = 13` (J:358). So `full` 122.2, `line` 32.5, `mini` 29.9 px.
- J:366 `compact = !!(F && S.fmode === "compact")`; J:370–379 `entries`;
  J:380 `gapLabel` (read by `rows()` J:406 and by J:506).
- J:381 history list: `D.hist.filter(t => t.end >= (S.histFrom || 0) && epicOk(t)).sort((a, b) => a.end - b.end)`.
  `epicOk` is J:301.
- J:382–392 **density for span > 1** (not in Gantt): `from` = the `span`-th last
  active day; `n` = the number of rows those entries pack into;
  `target = vh / max(1, n)`; `gap = max(2, min(14, target * .18))`;
  `ch = min(CH.full, max(5, target - gap))`; tier = `full` if `ch ≥ CH.full`,
  `line` if `ch ≥ CH.line`, `mini` if `ch ≥ 22`, else `bar`; `pitch = ch + gap`.
- J:393–415 `rows()`: in normal mode a row holds at most one card per epic key
  (`colKey`, J:332: `t.epic || "unsorted"`); a repeated key starts a new row. In
  flow mode a row holds up to `K` cards in slots `s0..s(K-1)`. A history row gets
  a day label `{ y, day: fmtD(end), t: WD[day], line: lastDay != null }` from its
  earliest-ending card when the day changes. `y += pitch` per row.
- J:416–421 history section: empty → mark `{ kind: "empty", y: 36, h: 96,
  label: "No history yet", sub: "A new repo — nothing has merged. The first
  tickets are running in the Now band below." }`, `h = 140`; Gantt →
  `ganttHist`; else `h = rows(…, SEC + 4, …) + gap`.
- J:486–496 Now band: C9-T08 (above). Nothing after J:496 reads a band value.
- J:497–527 planned: empty → mark `"Nothing planned"`, sub `"The build queue is
  empty. " + NQL.length + " open tickets are not queued — promote some to keep
  agents busy."`; else per wave ascending (J:503): J:506 compact all-gap wave →
  one `gap` mark; else `y += gap * .6`, label `{ y, day: "W" + w, t: count +
  (w === 1 ? " · ready" : ""), tk: true, line: w > 1, wave: true }`, then Gantt
  (J:509–523) or `rows(…)` without time labels; `h = y + gap`.
- J:529–531 not queued: `h = rows(…, SEC + 4, …) + gap`, no empty mark.
- J:541 `gutW = () => (root.clientWidth < 640 ? 46 : 84)` (C9-T01 ports it to
  `state.js`).
- J:646–649 flow rule: `avail = vp.clientWidth − gutW() − 14`;
  `nEst = max(4, distinct colKey over D.now ∪ D.plan)` (unfiltered);
  `S.flow = avail / nEst < 62`; `S.K = max(2, floor(avail / 140))`.
- J:714–734 marker and label elements (inside `update()`):
  - marker (J:719–720): `div` with `className = "bd-mk " + kind`; `empty` →
    `<b>label</b><p>sub</p>`; else, when `label` is set,
    `<span>label[ <em style="font-style:normal;color:var(--faint)">· sub</em>]</span>`,
    and an empty element when it is not;
  - placement (J:723–724): `top`, `height`, `left = kind === "wave" ? 12 : gut`,
    `width = cw − left − 12`, set in that order;
  - label (J:730–733): `div.bd-lbl[.tick][.wave]`, `top = y`,
    `[<b>day</b>]<span>[I.ticket]t</span>`; when `line`, a sibling
    `div.bd-dl` at `top = y − 6`.
- J:744 `histDays` maps every row's `end` to a local midnight and caches on
  `D._days`. A row with `end: null` becomes 1970-01-01 (`new Date(null)`).
- **No producer emits a `wave` marker.** `kind: "wave"` is read at J:724 but no
  code pushes it; waves render as `.bd-lbl.wave` labels (J:508).
- `S.density` (J:303) is never read by `computeLayout`; the `[data-d]` listener
  (J:1144) has no button to bind to (`#bd-tools-l`, J:1130–1133, has none; the
  two `data-d` buttons in `Aiur Dashboard.html` are the agent-count stepper).
  Density is a function of span only.

**CSS these elements use (C2-T04 ports them; this ticket only emits the classes).**

- `.bd-lbl` C:197–199 (absolute, `padding-left: 12px`, `translateY(-.15rem)`;
  `b` .72rem 700 `--fg`; `span` .62rem JetBrains Mono `--faint`), C:200
  (`.tick`, Gantt only), C:355 (`.bd-lbl.wave b` JetBrains Mono .82rem), C:722
  (`span svg` 10×10, `vertical-align: -1px`, `margin-right: 3px`), C:468–469
  (hover blur, C9-T11).
- `.bd-dl` C:201 (`border-top: 1px dashed var(--line)`).
- `.bd-mk` C:202, C:204 (pill `span` .16rem/.65rem padding, 999px radius,
  600 .64rem JetBrains Mono), `.gap` C:205–206, `.empty` C:210–212 (column,
  `b` .95rem, `p` .82rem `--muted` max 46ch), `.brk` C:203 (Gantt),
  `.bd-mk.wave` C:207–209 (no producer).
- `.bd-sec` C:192, `.bd-sech` C:193 (36 px = `SEC`), `.bd-layer` C:196.

**Product code.**

- No layout code exists for this page. `src/priv/static/build-order-grid-hook.js`
  is the Build Order grid and is not reused (plan §5 "Not reused", plan.md:163).
- Module serving: `src/lib/aiur_web/static_assets.ex:13-27`
  `@revalidated_static_paths`. C2-T03 adds the one `build-home` directory entry,
  so a new file under `build-home/` is served with no edit there.
- Test precedent for a static ES module:
  `src/browser/tests/dom-svg-layout-adapter.browser.spec.mjs:12-21` makes a
  context with `httpCredentials: dashboardCredentials`
  (`./support/layout-worker.mjs`), opens the fixture with `openFixture`
  (`src/browser/tests/support/browser-helpers.mjs:12`) and calls
  `page.evaluate(async () => { const m = await import('/aiur-dom-svg-layout/measurement.js') … })`.
  This ticket tests `layout.js` the same way.
- `src/browser/package.json:10` the `test` chain; `:31` `test:layout` is the
  precedent for a module-level spec script.
- `src/browser/playwright.config.mjs:30-34` sets no `timezoneId`; this ticket's
  spec sets `timezoneId: 'America/Los_Angeles'` on its context (as C1-T02 does).

## Chosen design

**Port the code; change only the inputs.** The design reads closure variables
(`D`, `S`, `vp`, `root`). The port takes them as arguments. The arithmetic,
the order of operations and the constants stay byte-for-byte, so the results
are bit-identical (the parity test compares with `===`, not with a tolerance).

```js
// build-home/layout.js (PROPOSED)
import { LH, SEC } from "./state.js"                                   // C9-T01
import { esc } from "./dom.js"                                         // C9-T01
import { WD, fmtD, fmtRange, dayKey } from "./util.js"                 // J:12–26
import { I } from "./icons.js"                                         // J:32–73
export const colKey = (t) => t.epic || "unsorted"                      // J:332
export const CH = { full: 9.4 * 13, line: 2.5 * 13, mini: Math.max(24, 2.3 * 13) } // J:364, fs = 13
export function histDays(hist)                       // J:744, memo per array, finite `end` only
export function measureFlow(D, dims)  -> { flow, K } // J:646–649
export function computeLayout(D, S, dims, sources, ext = {}) -> L      // J:355–422, 497–533
export function makeMark(m)  -> HTMLElement          // J:719–720
export function placeMark(el, m, contentW, gut)      // J:723–724
export function makeLabel(lb) -> [HTMLElement, HTMLElement | null]     // J:730–733
```

- `dims = { vpW, vpH, gut }`: `vp.clientWidth`, `vp.clientHeight` and C9-T01's
  `gutW()`. Only `vpH == null` takes the design's 700 fallback (J:358
  `vp ? … : 700`); a real `0` stays `0` (do not write `||`).
- `sources` is `ctx.snap.sources` (C3-T02).
- `ext` holds the slots later tickets fill, each with the design's non-compact,
  non-Gantt default:
  - `ext.entries` (C10-T03; default `list => list.map(t => ({ t }))`, J:371);
  - `ext.compact` (default `false`, J:366) and `ext.gapLabel` (default J:380
    verbatim), read at J:406 and J:506 (C10-T03 interface note 3);
  - `ext.gantt = { hist, plan, bandHeight }` (C9-T09 fills all three; C9-T08 reads `bandHeight`). The port calls
    `ext.gantt.hist(entries, gctx)` at J:420 and `ext.gantt.plan(waves, gctx)`
    at J:509, a per-wave function called once for each wave's entries, with
    `gctx = { span, pph: pphG, flow, K, compact, gapLabel, colKey, CH, gap, det,
    nowRows: NOWL, hs, y }` (C9-T09 "ctx"). C9-T09 fixes the return of `plan`
    (the design branch advances `y` and `cum`). `pphG` (J:360) is computed here
    for `gctx`.
  - With `S.view === "gantt"` and no `ext.gantt`, `computeLayout` throws
    `Error("gantt layout not installed")`. A silent non-Gantt layout under a
    Gantt label would be wrong.
- **Output `L`** has the design's shape, so C9-T03..T09 port with no renames:
  `{ det, base, fs, ch, pitch, gap, secs: { hist, plan, nq }, band }`. Each
  section is `{ items: [{ t, ghost, key, y, h, sec }], marks: [m], labels: [lb], h }`.
  `band` is the stub `{ items: [], h: 0, BK: 1 }` until C9-T08 replaces it with
  `bandLayout` (C9-T08 step 3). One addition: `secs.hist.unplaced` (ids of
  history rows with no finite `end`).
- **`histDays` memo.** The design caches on `D._days` and never clears it. The
  port memoises by the identity of the `hist` array (a `WeakMap`). C9-T01
  builds a new array when it applies a diff or a page, which clears the memo.
  Nothing is written onto `D`. Rows whose `end` is not a finite number are
  skipped, so no 1970 day appears (C9-T03 "null end" test relies on this).
- **Interim source-aware empty marks** (EC-03, S-9 default). The design writes
  "No history yet" when the list is empty and "Nothing planned" when the queue
  is empty. A list can also be empty because its source failed. Until C9-T13
  replaces this check with `sectionState`/`emptyMark`, the rule is the subset of
  C9-T13's table that needs no age or reason text. `st` is
  `sources?.[key]?.state`; a missing entry or a value outside
  `ok | stale | incomplete | unavailable | disabled` counts as `unavailable`
  (C9-T13's client defence; the C3-T02 validator already rejects a missing key).

  | Section (empty list) | Key | `st` | Mark (always `kind: "empty", y: SEC, h: 96`, section `h = SEC + 104`) |
  | --- | --- | --- | --- |
  | hist | `history` | `ok`, `stale`, `incomplete` | design mark; `stale` adds `stale: true, observed_at` |
  | hist | `history` | `unavailable` / `disabled` | `label` "History unavailable" / "History disabled", `sub` `""` |
  | plan | `queue` | `ok`, `stale`, `incomplete` | design mark; the design sub only when `index` is `ok` or `stale`, else `sub` "The build queue is empty. The open-ticket index is unavailable, so the number not queued is unknown." (C9-T13 copy); `stale` as above |
  | plan | `queue` | `unavailable` / `disabled` | "Queue unavailable" / "Build queue disabled", `sub` `""` |
  | nq | `index` | `unavailable` / `disabled` | "Open tickets unavailable" / "Open-ticket index disabled", `sub` `""` |
  | nq | `index` | other | no mark, height as designed (J:531) |

  The labels are C9-T13's, so its later change only adds the `sub`. Every
  unavailable mark also carries `source` and `state` fields for C9-T13. When
  every source is `ok`, the mark objects are exactly the design's (no extra
  fields), so the oracle compares them unchanged.
- **Unknown wave.** C3-T02 allows `wave: null` on plan rows (the client shows
  "W?"). Rows with a `wave` that is not an integer ≥ 1 go into one group after
  every numbered wave,
  with the label `{ day: "W?", t: count + " · wave unknown", tk: true, line:
  true, wave: true }`. The design's code would sort `null` first and print
  "Wnull".
- **Escaping.** `makeMark` and `makeLabel` pass every text through `esc`, as
  J:720 and J:731 do. `day` and `t` are built from numbers and dates here, but
  marks from C10-T03 and C9-T13 carry other text, so the factories do not trust
  their input.

## Implementation steps

1. If absent, create `build-home/util.js` (J:12–26 verbatim, each as an
   `export const`). Import `I` from C9-T01's `build-home/icons.js`.
2. Create `build-home/layout.js` with the exports above and add
   `import "./layout.js"` to `hook.js` only if C9-T01 rule 2 requires it (the
   module registers nothing in `fx`; C9-T03 imports it directly). Copy
   J:355–422 (without J:355, which `state.js` has) and J:497–533 into
   `computeLayout`, with these mechanical edits only:
   - `D`, `S` → arguments; `vp.clientHeight` → `dims.vpH` (700 when `null`);
   - `histDays()` → `histDays(D.hist)`; `epicOk` (J:301) as a local closure over
     `S.f.epic` (C10-T02 later swaps it for `rowOk`);
   - J:366–380 → `const compact = !!ext.compact, entries = ext.entries ?? …,
     gapLabel = ext.gapLabel ?? …` with the defaults above;
   - J:420 and J:509–523 → `ext.gantt.hist(entries, gctx)` /
     `ext.gantt.plan(waves, gctx)` (once per wave); throw
     at the top when `S.view === "gantt"` and `!ext.gantt`;
   - J:486–496 → `out.band = { items: [], h: 0, BK: 1 }` with a comment
     `// J:486–496 Now band: C9-T08 bandLayout`;
   - `dayL` (J:361) is not copied (Gantt only, C9-T09);
   - the wave loop sorts numbered waves as J:503 does and appends the unknown
     group last;
   - history rows whose `end` is not a finite number are removed from
     `histList` before the sort and their ids go to `secs.hist.unplaced`;
   - the empty marks follow the source table above.
3. `measureFlow`: J:646–647 verbatim on `dims` and `D`, with `gutW()` →
   `dims.gut`. It returns `{ flow, K }` (J:648–649). The caller (C9-T03
   `relayout`) assigns `S.flow`, `S.K` and toggles `.bd-content.flow`, as
   J:648–650 do.
4. `makeMark`, `placeMark`, `makeLabel`: J:719–720, J:723–724 and J:730–733
   verbatim, as factories. `placeMark` takes `contentW` (`content.offsetWidth`,
   J:704) and `gut`.
5. In `computeLayout`'s caller (C9-T03), nothing else; in this module, call
   `console.warn` once per distinct `hist` array when `unplaced` is not empty,
   with the ids. No pixel change.
6. Add the spec and the npm script (Verification). No CSS, no Elixir, no
   layout or `StaticAssets` change.

## Non-happy paths

Each row: input → expected → test (Verification names).

| # | Input | Expected | Test |
| --- | --- | --- | --- |
| N1 | Phone width: `gut` 46 (root 358), `vpW` 356, 5 epics in now ∪ plan (EC-18) | `avail` 296; `296 / 5 = 59.2 < 62` → `flow: true`, `K: 2`; rows hold 2 cards in `s0`, `s1` | `flow boundary`, oracle cells `phone-*` |
| N2 | `avail / nEst` exactly 62 (`vpW` 370, `gut` 46, 5 epics) | `avail` 310 → `flow: false` (strict `<`) | `flow boundary` |
| N3 | `vpW` 0 and `vpH` 0 (hidden tab, first paint), span 2, six history rows of one epic on the last day | `avail` −60 → `flow: true`, `K: 2`; `vh` = 300 (the `max`), so `target` 50, `gap` 9, `ch` 41, `det: "line"`. No throw, no `NaN` in any `y`/`h` | `zero viewport` |
| N4 | Span 2, 12 rows in the last 2 days, `vpH` 386 (`vh` 300) | `target` 25, `gap` 4.5, `ch` 20.5 → tier `bar`, `pitch` 25 | `tier boundaries` |
| N5 | Same with 7 rows; with 2 rows | `gap` ≈ 7.71, `ch` ≈ 35.14 → `line`; 2 rows → `ch` 122.2 → `full` | `tier boundaries` |
| N6 | Span greater than the loaded days and `history.more` true | Layout uses the loaded days (deterministic). Loading enough days first is C9-T03/C9-T10 (handoff) | `span exceeds loaded days` |
| N7 | `sources.queue.state = "unavailable"`, `plan = []` | `kind: "empty"`, `label` "Queue unavailable", `source: "queue"`; no "Nothing planned" anywhere | `unavailable is not empty` |
| N8 | `sources.history` missing, `hist = []` | label "History unavailable", `state: "unavailable"`; no "No history yet" | `unavailable is not empty` |
| N9 | `queue` `ok`, `plan = []`, `index` `unavailable` | "Nothing planned" with the C9-T13 unknown-count sub; no "0 open tickets" | `unknown count is not zero` |
| N10 | `queue` `stale`, `plan = []` | design empty mark with `stale: true` and `observed_at` | `stale empty keeps age input` |
| N11 | Three plan rows with `wave: null` next to waves 1, 2 | labels `W1`, `W2`, then `W?` "3 · wave unknown"; never `Wnull`, `W0`, `W—` | `unknown wave` |
| N12 | History row with `end: null`, with `S.histFrom = 0` (with a real `from` the design filter already drops it) | not placed; id in `secs.hist.unplaced`; not in `histDays`; one warning; other rows unchanged | `history row without end` |
| N13 | `epic: null` rows (EC-21) | key `"unsorted"`; two in a row split into two rows | oracle cell `odd-data` |
| N14 | Day boundary and DST (EC-20): five history rows of **one** epic (so five rows) ending 2026-10-31 23:30 PDT, 2026-11-01 00:30 PDT, 01:30 PDT, 01:30 PST, 23:30 PST | In America/Los_Angeles: labels "Oct 31"/"Sat" on row 1, "Nov 1"/"Sun" on row 2, nothing after. In UTC: "Nov 1"/"Sun" on row 1, "Nov 2"/"Mon" on row 5 | `day labels follow the browser zone` |
| N15 | Text with markup in a mark label (`<img src=x onerror=…>`) | escaped text, no element created (EC-30) | `factories escape` |
| N16 | A diff adds a history row on a new day | the new day is in `histDays` (no stale memo) | `histDays follows new arrays` |
| N17 | `view = "gantt"` before C9-T09 | throws "gantt layout not installed" | `gantt slot guard` |
| N18 | 1,300 rows (`dense` fixture), span 30 | same result as the design; layout is O(n log n) apart from the per-wave filter the design also has | oracle cells `dense-*` |

Permissions, privacy, concurrency, retries and disconnects do not apply: this
module is a pure function with no I/O. Disconnect and stale handling is C9-T01
and C9-T13; this ticket only keeps a failed source from looking empty.

## Compatibility and rollout

- Additive files under `build-home/`; served by C2-T03's directory entry. No
  config key, CLI flag, environment variable or migration.
- The page is reachable only on the fixture route until C12-T01's cutover, so
  the Gantt throw (N17), the empty band stub and the interim S-9 copy cannot
  reach a user.
- Rollback: revert the commit. Nothing else imports the module until C9-T03.
- **Docs:** none. This is internal client code with no new user-facing surface
  yet (AGENTS.md "Docs ship with the change": not required for internal work).
  The home page guide is written with C12-T01.

## Pixel parity

- **Design elements reproduced:** `computeLayout` sections and `rows`
  (J:356–422, 497–533), the flow rule (J:646–649), the marker and label
  elements (J:714–734); classes `.bd-lbl`, `.bd-lbl.wave`, `.bd-lbl.tick`,
  `.bd-dl`, `.bd-mk.empty`, `.bd-mk.gap`; `.bd-mk.wave` is reproduced by the
  factory but no design code emits it (README row lists it; see C2-T04 note).
  Constants `LH` 46, `SEC` 36, `CH` (122.2 / 32.5 / 29.9 at `fs` 13), `gap` 14,
  the 62 px flow threshold, the 140 px slot width, the 22 px mini threshold,
  wave spacing `gap * .6`.
- **Check 1 — layout oracle (exact).** The spec reads the vendored design
  `build.js` (C1-T01's copy), checks that the anchors
  `  window.AiurBuild = {`, `const avail = vp.clientWidth - gutW() - 14;` and
  `S.K = Math.max(2, Math.floor(avail / 140));` each occur once (true at
  J:1559, J:646, J:649), and inserts before the first anchor:

  ```js
  window.__E8L = { run(d, st, dims) {
    D = d; Object.assign(S, st); S.f = { ...S.f, ...(st.f || {}) }
    vp = { clientWidth: dims.vpW, clientHeight: dims.vpH }; root = { clientWidth: dims.rootW }
    <design text from the second anchor to the end of the third, sliced from build.js>
    const L = computeLayout(); return { L, flow: S.flow, K: S.K }
  } };
  ```

  It injects that script into the fixture page with `page.addScriptTag`. The
  IIFE's top level has no side effect apart from `window.AiurBuild` (render is
  only called by the design page). The oracle is the design's own text; the spec
  copies no formula. For each cell, both sides get the **same** `D` object
  (C3-T02 `intake` of the fixture, with `D._days` deleted before each oracle
  run), the same `S`, and the same sizes (`gut` for the port is
  `rootW < 640 ? 46 : 84`, which is what the oracle's `gutW()` computes). The
  spec serialises both results (items as `{ id, key, y, h, sec, ghost }`, marks,
  labels, `h` for `hist`, `plan`, `nq`, and `det`, `base`, `fs`, `ch`, `pitch`,
  `gap`, `flow`, `K`) and requires deep equality with `===` on numbers. `band`
  is not compared (C9-T08 adds it to this oracle). Cells: datasets `live`,
  `dense`, `newrepo`, `noqueue` × spans 1, 2, 3, 5, 7, 10, 14, 21, 30 × dims
  `desktop` (1406×860, root 1408), `laptop` (990×700, root 992), `phone`
  (356×620, root 358), `narrow` (288×560, root 290) = 144 cells, plus
  `liveMin`, an epic filter (`f.epic` = the first key of `D.order`), and the
  synthetic `odd-data` and boundary sets. The oracle cells use only states
  where the design and the port agree by definition: every source `ok`, every
  `wave` ≥ 1, every `end` finite.
- **Check 2 — DOM parity of labels and markers.** Open the design with C1-T02's
  `openDesign` (dataset `live`, 1440×900, light, `aiur` palette). Read every
  `#bd-sec-hist|plan|nq .bd-layer > .bd-lbl, .bd-dl, .bd-mk` as `{ section,
  outerHTML }`, plus `#bd-vp` `clientWidth`/`clientHeight`, `#build-root`
  `clientWidth` and `#bd-content` `offsetWidth`. In the product fixture page,
  run `computeLayout` with those sizes, span 1 and `S.histFrom` = the second-last
  day of `histDays(D.hist)` (the design's `initHistFrom` for a non-dense
  dataset, J:746), and build every label and mark with the factories and
  `placeMark`. Each design element must have a product element with an
  identical `outerHTML`. Product elements outside the design's render window
  are ignored, because the window is C9-T03's. Repeat for `newrepo` (the "No
  history yet" mark) and `noqueue` ("Nothing planned").
- **Check 3 — screenshots.** Region screenshots of `#bd-sec-hist`,
  `#bd-sec-plan` and `#bd-sec-nq` need C9-T03's render loop. This ticket adds
  the region names `sec-hist`, `sec-plan`, `sec-nq` to C1-T02's matrix as a
  handoff; C9-T03 turns them on.
- **Approved differences:** none. The unknown-wave label and the unavailable
  marks are states the design does not show; they are sign-off item S-34
  (Decisions) and are not allowlist entries, because no design cell renders them.

## Verification

Spec: PROPOSED `src/browser/tests/build-home-layout.browser.spec.mjs`. Script:
`"test:build-home-layout": "npm run fixture:preflight && node scripts/run-browser-tests.mjs tests/build-home-layout.browser.spec.mjs"`,
appended to the `test` chain in `src/browser/package.json:10`. The context uses
`httpCredentials: dashboardCredentials` and `timezoneId: 'America/Los_Angeles'`
except where a test says otherwise, and `openFixture(page)` gives the origin
that serves `/build-home/*`.

| Test | Input | Expected | Fails without (mutation) |
| --- | --- | --- | --- |
| `layout oracle` | 144 + 4 cells (Check 1) | deep equal, every cell | change `* 0.18` to `* 0.2` (J:387) in the port; change `y += gap * 0.6` to `y += gap * 0.5`; drop `+ gap` on the hist `h` |
| `labels and markers match the design` | Check 2 | identical `outerHTML` per design element | drop `(lb.wave ? " wave" : "")`; change `lb.y - 6` to `lb.y - 5` |
| `flow boundary` | N1, N2 with a 5-epic synthetic `D` | N1 `flow: true, K: 2`; N2 `flow: false` | `< 62` → `<= 62` (N2 fails); `62` → `59` (N1 fails: 59.2 is not < 59) |
| `zero viewport` | N3 | `flow: true`, `K: 2`; `det: "line"`, `ch` 41, `gap` 9; every number finite | remove `Math.max(300, …)` (`vh` −86 → `ch` 5, `det: "bar"`); use `dims.vpH \|\| 700` (`vh` 614 → `ch` ≈ 88.33) |
| `tier boundaries` | N4, N5 synthetic, `vpH` 386 | `bar` (ch 20.5, gap 4.5, pitch 25); `line`; `full` | `ch >= 22` → `ch >= 20` (N4 becomes `mini`) |
| `span exceeds loaded days` | N6: live window (2 days), span 7 | `det`, `ch`, `gap` equal the oracle on the same rows | — (guard that the port does not fetch or invent days; named `guard:` in the test title, not counted as coverage) |
| `unavailable is not empty` | N7, N8 | labels "Queue unavailable" / "History unavailable"; factory output has no "Nothing planned" / "No history yet"; section `h` 140 | replace the source check with `true` (shows the design's empty copy); read a missing key as `ok` (N8 fails) |
| `unknown count is not zero` | N9 | sub equals the C9-T13 unknown-count string | always appending `NQL.length` ("0 open tickets") |
| `stale empty keeps age input` | N10 | mark `{ kind: "empty", stale: true, observed_at: <fixture ms> }` | dropping `observed_at` |
| `unknown wave` | N11 | labels `["W1", "W2", "W?"]`, last `t` "3 · wave unknown"; no label matches `/W(null\|0\|—)$/` | `w ?? 0` (gives `W0`); removing the unknown group (gives `Wnull` first) |
| `history row without end` | N12 | id in `unplaced`; no item for it; `histDays` has no value before the fixture's first day; other items equal the oracle without that row; one `console.warn` with the id | keeping the row (it is placed with no label); removing the finite check in `histDays` (a 1970 day appears) |
| `day labels follow the browser zone` | N14 in LA, then a new context with `timezoneId: 'UTC'` | labels as `[day, t, y]`: LA `[["Oct 31","Sat",40],["Nov 1","Sun",40 + pitch]]`; UTC `[["Nov 1","Sun",40],["Nov 2","Mon",40 + 4·pitch]]`; second label `line: true` | `dayKey` on UTC getters (LA second label moves to row 5, so its `y` fails) |
| `factories escape` | `makeMark({ kind: "gap", label: '<img src=x onerror="window.__xss=1">' })`, same for a label `t` | `textContent` equals the raw string; no `img` in the element; `window.__xss` undefined | remove `esc` in `makeMark` |
| `histDays follows new arrays` | N16: compute, then a new `hist` array with a row on a new day | the new day is in `histDays(newHist)` and in the span-2 `from` | caching on a module-level variable instead of per array |
| `gantt slot guard` | N17 | throws "gantt layout not installed" | silently running the non-Gantt path |

Commands:

```bash
env -C /path/to/checkout/src/browser npm run test:build-home-layout
```

Mutation check (AGENTS.md "Tests must fail without the production change"):
run each mutation in a worktree, confirm `git status --porcelain` shows only
that hunk, run the spec, see the named test fail, restore, see it pass. The
oracle test is the main guard: reverting any ported line to a different
formula breaks at least one cell. Put the exact commands in the PR body.

Manual testing is not required for this ticket: it renders nothing on its own.
C9-T03 adds the first visible board on the fixture route.

## Completion and handoff

- [ ] `build-home/layout.js` exports `colKey`, `CH`, `histDays`, `measureFlow`,
      `computeLayout`, `makeMark`, `placeMark`, `makeLabel`, and imports `LH`,
      `SEC`, `esc` from C9-T01's modules (no second copy).
- [ ] `util.js` exists (created here or already on `main`); `I` comes from
      C9-T01's `icons.js`.
- [ ] The layout oracle passes all cells with exact equality.
- [ ] Labels and markers match the design's `outerHTML` (Check 2).
- [ ] Every test in Verification passes and fails under its mutation.
- [ ] No CSS, Elixir, layout or `StaticAssets` change in the diff.
- [ ] `test:build-home-layout` is in the `test` chain.

**Handoffs.**

- **C9-T03:** call `measureFlow(D, { vpW, gut: gutW() })` then
  `computeLayout(D, S, { vpW, vpH, gut }, ctx.snap.sources, ext)` in
  `relayout`, with `ext = { ...fx.layoutExt(D, S), gantt }` (C10-T03); set
  `S.flow`, `S.K`, `.bd-content.flow`, `--fs` (`L.fs`), section heights and the
  band height from `L`; use `makeMark`/`placeMark`/`makeLabel` in the window
  loop with the design's uids (`s:m<i>`, `s:l<i>`, `s:l<i>d`). Load at least
  `span` active days (or until `history.more` is false) before a span-`s`
  relayout, as J:641–642 assumes all days are present. Do not pass
  `view: "gantt"` before C9-T09 has merged (N17 throws). Turn on the C1-T02
  region checks `sec-hist`, `sec-plan`, `sec-nq`.
- **C9-T08:** replace the `out.band` stub at the J:486–496 position with
  `bandLayout` (its step 3); it reads `CH`, `ch`, `gap`, `span`, `baseDet`,
  `pphG` and `dims` from `computeLayout`'s scope, and adds `band` to the
  Check 1 oracle comparison.
- **C9-T09:** supply `ext.gantt = { hist, plan }` (`hist(entries, gctx)`,
  per-wave `plan(waves, gctx)`) with the `gctx` above; port `dayL` (J:361) and `bandGanttHeight` (for C9-T08) in
  `gantt.js`.
- **C9-T13:** replace the interim table with `sectionState`/`emptyMark`; the
  labels already match, so only `sub`, the age and the filtered/window states
  change.
- **C10-T03:** Settled 2026-10-08: C10-T03 adds `ext.compact` and
  `ext.gapLabel` (with `ext.entries`) from `layoutExt`; `rows()` and J:506
  already read the slots, with the design defaults here.
- **C3-T02:** Settled 2026-10-08: hist rows require an integer `end` (a row
  with unknown end is not sent); plan rows may have `wave: null` (N11 shows
  "W?"). The N12 guard stays as defence.
- **C2-T04:** Settled 2026-10-08: `.bd-mk.wave` (C:207–209) is on C2-T04's
  dead-rule list.

**Sources.** `J` lines above; `C` lines above; plan §5, §8 (EC-03, EC-08,
EC-18, EC-20, EC-21, EC-30); tickets/README.md C9 rows; MP-E8-C9-T01 "Module
layout"; MP-E8-C3-T02 "Messages (schema v1)", ticket row table and `intake`;
MP-E8-C9-T03, C9-T04, C9-T08, C9-T09, C9-T12, C9-T13, C10-T01, C10-T02,
C10-T03 interface notes; MP-E8-C2-T03 "Files"; MP-E8-C1-T01 "Exporter";
MP-E8-C1-T02 "Deliverable"; DESIGN-E8 S-9.

## Decisions made without the owner

1. **The Now band is not laid out here.** The README rows give J:487–496 to
   C9-T08, and C9-T08 and C9-T04 both expect C9-T08 to set `L.band`. This
   ticket leaves the stub C9-T08 asked for. Until C9-T08 merges, the fixture
   board has an empty band.
2. **Gantt and compact are slots, not ports.** A missing Gantt slot throws
   instead of drawing a non-Gantt board under the Gantt view.
3. **A failed source never shows the design's empty copy.** Unavailable,
   disabled, missing and unknown-state sources get a marker in the
   empty-marker style with C9-T13's labels (S-9 default). The section height
   stays the same. `incomplete` keeps the design copy, as C9-T13's
   `sectionState` does; C9-T13 owns any change to that.
4. **The "N open tickets are not queued" sentence is replaced** with C9-T13's
   unknown-count sentence when the index is not `ok` or `stale`, instead of
   printing 0.
5. **Unknown wave** gets a last group labelled `W?` "n · wave unknown". The
   design has no such state; it is sign-off item S-34 with the other new copy.
6. **A history row without a finite end time is not placed** and is logged,
   instead of being drawn with no date or adding a 1970 day.
7. **Filter-empty states keep the design copy here.** With an epic filter that
   hides every history row, the design still says "No history yet". C9-T13's
   `filtered` state replaces it; this ticket does not pre-empt that copy.
8. **`histDays` is memoised per `hist` array** instead of on `D._days`, so live
   diffs cannot leave a stale day list. No pixel change.
9. **Dead design code is not ported:** the density state (`S.density`, the
   `[data-d]` listener at J:1144, which is C10-T01's toolbar). Density depends
   on span only, as in the design. `dayL` is not dead: it moves to C9-T09.
10. **The gutter is an input (`dims.gut`)**, taken from C9-T01's `gutW()`, so
    the 640 px rule has one copy.
11. **`util.js` is created here when absent,** because C9-T04 and C9-T12
    already name `util.js` as this ticket's file; `makeLabel` imports
    `I.ticket` from C9-T01's `icons.js`.

## Review log

Adversarial review, 2026-10-08, against the design source, `58854d4c8` and the
neighbour tickets.

1. Removed the Now band geometry (J:486–496) from scope. It belongs to C9-T08
   per the README rows and the C9-T08/C9-T04 tickets; replaced with C9-T08's
   requested stub, removed `BH`/230 px/`n % BK` from parity and tests, and
   rewrote Decision 1.
2. Corrected "`dayL` is unused": it is read by `ganttHist` at J:463; it moves
   to C9-T09.
3. Added the `ext.compact` and `ext.gapLabel` slots (J:366, J:380, J:506)
   that C10-T03 interface note 3 requests; `rows()` J:406 calls `gapLabel`.
4. Aligned the Gantt slot with C9-T09 (`ganttHist`, `planGantt`, its `ctx`
   fields) and C10-T03 (`ext.gantt.hist(…, ctx)` with `compact`).
5. Removed the duplicate `LH`, `SEC`, `gutterWidth` exports; they come from
   C9-T01's `state.js`, `esc` from `dom.js`. Fixed helper ranges (J:12–26, not
   12–24; icons J:32–73, not 30–80) and made this ticket create `util.js` and
   `icons.js`, which C9-T04 and C9-T12 already expect.
6. `histDays` now skips non-finite `end` (the design maps `null` to 1970),
   which C9-T03's `null end` test depends on; added the mutation.
7. Source table: added `incomplete` and unknown states, matched C9-T13's
   `kind: "empty"` marker and labels, dropped the `kind: "unavailable"` branch
   and the `data-source` attributes (C9-T13 uses `#build-root[data-bd-states]`).
8. `flow boundary` mutation `62 → 60` killed neither case (59.2 < 60); changed
   to `62 → 59`.
9. `zero viewport` could not fail under its mutation (span 1 ignores `vh`);
   set span 2 with six rows and an exact `ch`; added the `vpH || 700` mutation.
10. `day labels` test asserted only text, which the UTC-getter mutation leaves
    unchanged; it now asserts `y` and uses one epic so each row is its own row.
11. Marker description now includes the empty-element branch for a mark with
    no `label` (J:720); placement order noted for `outerHTML` equality.
12. Check 2 now fixes `S.histFrom` to the design's `initHistFrom` value, so
    both sides lay out the same rows.
13. The C3-T02 request is already accepted in its row table; changed to "done".
14. Decision 7: C9-T13's `filtered` state owns the filtered copy.
15. Spec context adds `httpCredentials: dashboardCredentials` as the precedent
    spec does; tier tests state `vpH` 386 so `vh` is 300.
- Reconciliation 2026-10-08 (coordinator): Gantt slots `ext.gantt.hist(entries, gctx)` and per-wave `ext.gantt.plan(waves, gctx)` (C9-T09 fills), C10-T03 adds `ext.compact`/`ext.gapLabel` (settled), `icons.js` is C9-T01's (R-G9), plan `wave: null` allowed by C3-T02 (shows "W?"), new copy = S-34, C3-T02 and C2-T04 handoffs marked settled.
