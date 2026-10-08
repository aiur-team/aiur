---
ticket_id: MP-E8-C9-T04
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: Dynamic epic columns
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C9-T03, MP-E8-C1-T03]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-21]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T04: Dynamic epic columns

> **The design is the specification** ([../claude-design-source-of-truth.md](../claude-design-source-of-truth.md)).
> This ticket ports the design's column code. It does not redraw it. The lane
> headers, the guides, the widths, the 220 ms debounce, the 300 ms removal and the
> enter/leave transitions must be the same as the design, frame for frame.

Abbreviations: `J` = `design-source/assets/build.js`, `C` = `design-source/assets/build.css`,
`H` = `design-source/Aiur Dashboard.html`. Product paths are at `58854d4c8` under
`src/`. **PROPOSED** marks a path that does not exist yet.

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C9 (client
  timeline engine, the port of `build.js`).
- **User value.** The board shows one column per epic, and only for the epics
  of the tickets on screen. When you scroll through history, the columns change
  per whole day. Now, planned and not-queued tickets share one fixed column set.
  Zooming changes the visible tickets, so it changes the columns (E8-D13).
  Focusing on a feature locks its columns while you scroll.
- **Deliverable.** PROPOSED `src/priv/static/build-home/columns.js`, a port of:
  - `visibleCols` (J:677–693): whole visible days from history, the fixed forward
    set, the feature lock, the epic-filter fallback;
  - the column debounce block of `update()` (J:698–702): 220 ms, 0 ms when forced;
  - `applyCols` (J:769–794): column widths, `colMap`, `colMap.g`, `bandMap`,
    lane headers (icon, label, count or lock; `temp`, `unsorted`, `lock`,
    `first`), the guides, the flow-mode branch;
  - `syncKeyed` (J:795–804): enter, leave, 300 ms removal;
  - the CSS it needs is already in the consolidated sheet (C2-T04):
    `.bd-lanes`, `.bd-lane`, `.bd-guide`, `.bd-lane-g` and the lane container
    query at 132 px (C:30–32).
  Plus three product-only changes that the live payload needs: an "unknown"
  count that is never `0` (`counts: null`), a fallback column set taken from the
  payload instead of the design's hard-coded keys, and a leave callback that
  removes only its own element. Cache clearing after a live diff is **not** new
  code here: C9-T01 builds a new `D` per diff and C9-T03 clears `L._dayCols` on
  every live pass (4.3).
- **Non-goals.**
  - Row packing, density tiers, flow-mode detection (`S.flow`, `S.K`): C9-T02/T03.
  - `place()`, `update()`'s render window, `relayout()`: C9-T03. This ticket
    fills the column inputs they read (`colMap`, `bandMap`).
  - Edges (`drawEdgesSoon`): C9-T07. This ticket calls it.
  - The band stack count `BK` (J:487–496): C9-T08 sets `L.band.BK`. This ticket
    keeps the `bandMap` computation inside `applyCols`, where the design has it.
  - The feature header, `setFeature`, compact entries: C10-T03. The filter
    popovers and `filtersChanged`: C10-T02. They call this module.
  - Lane-header accessibility beyond what the design has: C12-T05.

## 2. Dependencies and blockers

- **Blocked by DESIGN-E8** (item 2: epic columns, their motion and their stable
  order).
- **MP-E8-C9-T03** (row predecessor): `update()`, `place()`, `relayout()`, the
  render window and the section DOM. This ticket hooks into them.
- **MP-E8-C1-T03** (added; see "Interface notes"): the `columns.enter-leave` and
  `columns.reduce` motion sequences and their meta-tests live there, with
  `OWNER['columns.*'] = 'MP-E8-C9-T04'`. They stay `fixme: awaiting MP-E8-C9-T04`
  until this ticket lands. The `grain.static` group for `.bd-lanes` is also
  this ticket's there.
- Transitive, already in C9-T03's chain: C9-T01 (module layout, payload intake,
  diff path), C9-T02 (`computeLayout`, `colKey`, `S.flow`, `S.K`), C3-T02 (payload
  schema), C3-T03 (URL state: `feature`, `fmode`, `epic`), C2-T04 (stylesheet),
  C1-T02 (parity runner).
- Owner questions: none block. E8-D13 is decided ("Kevin accepts that general
  columns move as you scroll"). The unknown-count look is a design gap; this
  ticket follows S-9's pattern (see Decisions).
- **May run concurrently with** C9-T05 (both follow C9-T03). They touch different
  modules under `build-home/` and each adds one `import` line to `hook.js`.
  C9-T05 reads `colKey` and `D.epics`, not this module. If this ticket lands
  first, C9-T02's placeholder cards must carry `el._it` (interface note 3).

## 3. Verified starting point (`58854d4c8`)

### Product code

- No home-page hook exists yet. `src/priv/static/` has no `build-home/`
  directory. C2-T03 creates it. C9-T01 fixes the module layout ("Module layout
  (fixed here)" in MP-E8-C9-T01.md): `columns.js` is this ticket's file and exports
  `visibleCols` and `applyCols`; the design's closure variables (`vp`, `content`,
  `lanesEl`, `guidesEl`, `svg`, `secs`, `R`, `laneEls`, `guideEls`, `cols`,
  `colMap`, `bandMap`, `D`, `L`) live on `ctx` from `state.js`; cross-module calls
  to files that may land later go through `fx`; every timer goes through
  `ctx.life` (`later(key, ms, fn)`), which `destroyed` disposes.
- `src/lib/aiur_web/static_assets.ex:13-27` `@revalidated_static_paths`. C2-T03
  adds one `build-home` directory entry, so a new file under it (this ticket's
  `columns.js`) needs **no** `StaticAssets` or `layouts.ex` change. Precedent: the
  `aiur-dom-svg-layout` directory entry (`:14`) and its module map (`:36-44`).
- `src/lib/aiur_web/components/layouts.ex:38` loads
  `/aiur-dom-svg-layout-loader.js`; `:54` `var Hooks = {}`; `:253`
  `Hooks.DomSvgLayout = window.AiurDomSvgLayout.createLiveViewHook()`. The home
  loader follows this pattern (C2-T03).
- `src/priv/static/aiur-dom-svg-layout-loader.js:20-50` `createLiveViewHook`: the
  `destroyed` flag (`:23`, `:33`, `:49`) that stops late async work after the hook
  is gone. C9-T01's `ctx.life.dispose()` gives the same guarantee for this
  ticket's timers, so the module needs no flag of its own.
- `src/priv/static/build-order-grid-hook.js` (today's Build Order grid) has no
  lane code to reuse; it retires in C12-T03.
- Browser tests: `src/browser/package.json:10` (the `test` chain, one script per
  spec), `src/browser/tests/support/browser-helpers.mjs:102-120`
  `settleAnimations` (reuse its `getAnimations({ subtree: true })` call),
  `:122-127` `reconnectLiveView`.
- Fixture server: `src/test/browser/fixture_server.exs:2264`
  `get("/streamdeck-control/:mode", …)`, the pattern C3-T02 copies for
  `/build-control/:action`; `:2267-2279` the fixture LiveViews.

### Design code (the thing being ported)

| Element | Location | What must match exactly |
| --- | --- | --- |
| `visibleCols` | J:677–693 | flow → `["s0".."s(K-1)"]`; feature lock → `D.features[F].epics` ∪ `colKey` of every ticket with `feature === F` or `also ∋ F`, plus their deps' epics in `compact`, ordered by `D.order`; else history day sets: rows of `L.secs.hist.items` whose `[y, y+h]` overlaps `[st − htop + LH, st − htop + clientHeight]`, each contributing **its whole day's** key set (`L._dayCols`, keyed by `dayKey(end)`); forward set `D._fwd` (plan ∪ nq, filtered by `epicOk`) added when `st + clientHeight > htop + hist.h + 40`; a focused feature's epics always added; epic filter: the first filter key added only when nothing else is visible; result `D.order.filter(vis.has)` |
| Debounce | J:698–702 | only when `next.length` and `next.join("|") !== cols.join("|")`: `clearTimeout(colTimer)`, then `setTimeout(() => { applyCols(visibleCols()); update(); }, force ? 0 : 220)` |
| `applyCols` | J:769–794 | empty `next` → keep `cols`, else fallback; `maxW = 520`; `gap = flow ? 10 : 16`; `avail = vp.clientWidth − gutW() − 14`; `cw = min(flow ? 1e9 : 520, (avail − gap·(n−1)) / n)`; `colMap[k] = { x: g + i·(cw+gap), w: cw }`; `colMap.g = { x: g, w: avail }`; `bandMap["b"+i] = { x: g + i·(bw+16), w: bw }`, `bw = min(380, (avail − 16·(BK−1)) / BK)`; `--g` set on `#bd-lanes`; `content.style.width = vp.clientWidth`; flow branch removes all lanes and guides, sets `.bd-lane-g` text `Colour = epic`, hides `svg`, `drawEdgesSoon(immediate ? 30 : 380)`; else `.bd-lane-g` = `Time` (Gantt) or `Order`; lanes and guides through `syncKeyed`; re-`place` every rendered card and band card; `drawEdgesSoon(immediate ? 0 : 420)` |
| Lane fill | J:783–788 | `className = "bd-lane" + " temp"? + " unsorted"? + " lock"?`; `--h = e.hue`; `title` = `label + " — short-lived feature epic"` for `temp`, else `label`; `innerHTML = I[e.icon] + "<span>" + esc(label) + "</span><em>" + (locked ? I.lock : count) + "</em>"` |
| Lane position | J:789 | `left = c.x`, `width = c.w` (px); `.first` on `cols[0]` |
| Guide position | J:790 | `left = c.x − gap/2`, `width = c.w + gap` |
| `syncKeyed` | J:795–804 | a key leaving gets `.leave`, removed after **300 ms** if still leaving; a returning key loses `.leave`; a new key: `fill`, add `cls` + `.enter`, append, `pos`, force layout (`getBoundingClientRect`), remove `.enter` |
| Cache rules | J:687, 689, 1126 | `L._dayCols` lives on the layout object; `D._fwd` lives on the data and is cleared only by `filtersChanged` when the epic filter changes |
| Card back-reference | J:791–792, 817 | `applyCols` re-places every card with `place(el, el._it)`; `makeCard` sets `el._it = it` (J:817) |
| Data | J:96, 116, 117–121, 290–293, 332, 301, 18 | `GENERAL` hues 38/312/200/100 and icons `bug pen server docs`; `unsorted` (hue 0, icon `unsorted`); feature epics `temp: true`, icon `layers`; `order` = general, then feature epics by feature start, then `unsorted`; `counts` per epic; `colKey = t.epic \|\| "unsorted"`; `epicOk`; `dayKey` in browser local time |
| Callers | J:673 (relayout, `immediate`), 1095 (`setFeature`), 1126 (`filtersChanged`), 1155 (`renderList` sets `cols = []`), 617 (`viewport()` clears `laneEls`, `guideEls`, `cols`, `colMap`) | |

| CSS | Location | Values that must match |
| --- | --- | --- |
| `.bd-lanes` | C:169, 964, 1135–1136, 1189 | sticky, `top: 0`, `z-index: 9`, `height: 46px`, `color-mix(in srgb, var(--surface-2) 92%, transparent)` (light: `--surface`), `backdrop-filter: blur(5px)`, bottom border `--line`; `isolation: isolate`; `::after` grain `display: none` (C:1189 wins) |
| `.bd-lane` base | C:170–174 | absolute; transition `left .34s cubic-bezier(.22,1,.36,1), width .34s cubic-bezier(.22,1,.36,1), opacity .26s, transform .26s`; `.enter`/`.leave` = `opacity: 0; transform: translateY(-7px)` |
| `.bd-lanes .bd-lane` (wins) | C:431–437 | `top: 0; height: 46px; padding: 0 2px; gap: .4rem`; no border, no background; `600 .72rem "Space Grotesk"`; `letter-spacing: .01em`; colour `--muted`; icon 13 px; label colour `--fg`; count `.6rem` JetBrains Mono 600 `--faint` (C:174, 434); a 1 × 14 px divider at `left: calc(var(--g, 16px) * -.5)`, hidden on `.first`; `temp` label underlined dashed `oklch(.66 .14 var(--h) / .6)`, offset 4 px, 1 px |
| Icon colour `--ec` | C:172, 228–230, 1051–1052 | dark `oklch(.68 .14 h)`, light `oklch(.52 .15 h)`, Gruvbox `oklch(.74 .1 h)`, Gruvbox light `oklch(.55 .11 h)`; `unsorted` → `--muted` |
| Lock icon | C:176 | 11 px, `--fg` |
| Container query | C:30–32 | the lane is `container-type: inline-size`; at ≤ 132 px the count `em` is hidden; label shrinks with ellipsis |
| `.bd-lane-g` | C:177, 356 | absolute `left: 12px; top: 15px`; `700 .58rem` JetBrains Mono, `.08em`, uppercase, `--faint`; in flow `left/right: 12px` |
| `.bd-guides` / `.bd-guide` | C:178–180, 406 | host absolute from `top: 46px`, `pointer-events: none`; guide: no border (C:406 wins over C:179), `color-mix(in srgb, var(--surface) 10%, transparent)`; transition `left/width .34s cubic-bezier(.22,1,.36,1), opacity .26s`; `.enter`/`.leave` opacity 0 |
| Reduced motion | C:231, 348 | `.bd-root.rm .bd-lane, .bd-guide` and `@media (prefers-reduced-motion: reduce)`: `transition: none` |

## 4. Chosen design

### 4.1 Port the functions as they are

The four functions move into `columns.js` with their bodies unchanged except for
the points in 4.2–4.5. The DOM, class names, constants (`520`, `16`, `10`, `14`,
`380`, `40`, `LH`), timings (`220`, `300`, `0/30/380/420`) and the order of
operations stay the same. That is how C1-T02 and C1-T03 can pass.

Module shape: C9-T01 fixed it, so this ticket follows it (no factory, no
private copies of the design's closure variables):

```js
// build-home/columns.js (PROPOSED)
import { S, ctx, fx, LH, gutW } from "./state.js"
import { esc } from "./dom.js"
import { colKey } from "./match.js"           // J:332; match.js is created by C9-T05 or C9-T12, whichever merges first (R-G9);
                                              // if neither has merged, this ticket creates it with J:332–342 verbatim
import { I } from "./icons.js"                // C9-T01 (J:32–73)
// dayKey (J:18): from C9-T02's util.js; never a second copy
const epicOk = (t) => !S.f.epic.length || S.f.epic.includes(colKey(t))   // J:301; C9-T02 keeps its own local copy
let leaveSeq = 0                       // unique keys for the 300 ms leave timers (4.5)

export function visibleCols() { /* J:677–693, ctx.D / ctx.L / ctx.vp / ctx.secs */ }
export function applyCols(next, immediate) { /* J:769–794 + 4.2, 4.4 */ }
export function scheduleCols(force) {  // J:698–702
  const next = visibleCols()
  if (next.length && next.join("|") !== ctx.cols.join("|"))
    ctx.life.later("cols", force ? 0 : 220, () => { applyCols(visibleCols()); fx.update() })
}
function syncKeyed(map, host, cls, fill, pos) { /* J:795–804 + 4.5 */ }

Object.assign(fx, { visibleCols, applyCols, scheduleCols })
```

- State lives where C9-T01 put it: `ctx.cols`, `ctx.colMap`, `ctx.bandMap`,
  `ctx.laneEls`, `ctx.guideEls`. `place()` (C9-T03) already reads
  `ctx.colMap`/`ctx.bandMap`; `viewport()` (C9-T03, J:617) and `renderList()`
  (C9-T12, J:1155) already clear them on `ctx`. So this ticket adds no `reset`.
- Elements are read from `ctx` at call time (`ctx.lanesEl`, `ctx.guidesEl`,
  `ctx.content`, `ctx.svg`), never captured once: `viewport()` replaces them
  (J:605–615).
- `ctx.life.later("cols", …)` is the design's `clearTimeout(colTimer);
  setTimeout(…)`: a keyed timer replaces the pending one.
- Calls into modules that may land later go through `fx`: `fx.update`,
  `fx.drawEdgesSoon` (C9-T07). If `state.js` has no `drawEdgesSoon` default yet,
  this ticket adds `drawEdgesSoon() {}` to the `fx` defaults (one line).
  `place` is imported from `render.js` (C9-T03 is a predecessor).
- `hook.js` gets one line, `import "./columns.js"` (C9-T01 rule 2).

### 4.2 Fallback column set from the payload, not hard-coded keys

J:770 falls back to `["bugs", "design", "infra", "docs"]` when nothing is
visible and no columns exist yet (a new repository, the first paint of an empty
board). In the product the general epics come from config (C5-T01), so those keys
may not exist, and `D.epics[k]` would be `undefined` at J:784 (a crash).

**Rule:** fallback = `D.order.filter((k) => D.epics[k] && D.epics[k].general)`,
or `["unsorted"]` when that list is empty. With the default config this is exactly
`["bugs", "design", "infra", "docs"]` in that order (J:96, 290), so parity holds.

### 4.3 Live data: no new code, but the port must keep two design details

The design never changes its data after load. The product does, and the
neighbour tickets already handle the caches:

- C9-T01 `applyDiff` re-runs `intake`, so `ctx.D` is a **new object** after every
  diff, and `D._fwd` goes with the old one.
- C9-T03's live pass clears `D._days`, `D._fwd` and `L._dayCols` and runs
  `relayout({ live: true })`, which calls `applyCols(visibleCols(), true)` (J:673).
- C10-T02's `filtersChanged` sets `D._fwd = null` itself (J:1126).
- C10-T03's `setFeature` calls `applyCols(visibleCols())` (J:1095).

For this to work the port must keep two things that are easy to "simplify" away:

1. The caches stay **on `D` and `L`** (`D._fwd`, `L._dayCols`), not in module
   variables. A module-level cache survives the new `D` and hides a new epic
   (M-3).
2. The existing-element branch of `syncKeyed` calls `fill(k, el)` again (J:802).
   That is the only path that updates a lane's count, label and lock after a
   `set.counts` or `set.epics` diff (M-4).

### 4.4 The lane count: known, zero or unknown

`D.counts[k] || 0` (J:788) turns an unknown count into `0`, and `D.counts[k]`
throws when `D.counts` is `null`. C3-T02 fixes the contract: `counts` are server
totals over the whole index; when present, **every `order` key has an entry**
(`0` for an empty epic, checked by the validator); `counts: null` means "not
known" (C8-T04 sends it while history is unavailable or incomplete).

| Input | Rendered `em` | Why |
| --- | --- | --- |
| `locked` | `I.lock` | as the design |
| `D.counts` is an object and `Number.isInteger(D.counts[k])` | the number (including `0`) | a known value; a stale board shows it under `.bd-root.stale` (C8-T03/C9-T13) |
| `D.counts` is `null`, or `D.counts[k]` is not an integer (a defensive branch; the validator should prevent it) | `—`, `title` on the `em`: `Ticket count unavailable` | unknown is never `0` |

The `newrepo` fallback lanes show `0`, as the design, because C3-T02's mapping
fills `0` for every `order` key.

### 4.5 Leave timers and the identity guard

The 300 ms leave timer of each element uses `ctx.life.later("col-leave:" +
(++leaveSeq), 300, …)`. A unique key per leave keeps the design's behaviour (one
independent timer per leave, J:797); a shared key per epic would cancel an
earlier timer and change when a lane that left, came back and left again is
removed. `ctx.life.dispose()` (C9-T01 `destroyed`) clears all of them and the
`"cols"` debounce, so no column timer runs after the hook is gone.

In the design, a leave callback deletes `map.get(k)` by key (J:797), so a late
callback can delete a **newer** element with the same key. That happens when the
lane maps are cleared and refilled while a lane is leaving: switching to List and
back within 300 ms (J:1155, then `viewport()` clears `laneEls` at J:617 and
`relayout` adds a new lane for the same key). The new lane then stays in the DOM
untracked, and the next `applyCols` adds a second lane for that key. The port
deletes only when `map.get(k) === el`. This changes no frame of any normal
sequence.

### 4.6 Invariants

1. Every key in `cols` is a key of `D.epics` (flow mode excepted: `s0..s(K-1)`,
   which never reach `syncKeyed`). A key from the URL `epic` list that is not in
   `D.order` never becomes a column (`D.order.filter`, J:692); C3-T03 checks only
   its shape.
2. Column order is always `D.order` order: a stable relative order (E8-D13).
3. One tracked `.bd-lane` and one `.bd-guide` per key in `cols`, plus at most one
   leaving element per key, for ≤ 300 ms.
4. While a feature is focused, `visibleCols()` does not depend on `vp.scrollTop`.
5. No timer from this module runs after `destroyed` (all go through `ctx.life`).

## 5. Implementation steps

1. Create PROPOSED `src/priv/static/build-home/columns.js` (4.1). Copy
   J:677–693, J:698–702 (as `scheduleCols(force)`), J:769–794 and J:795–804.
   Replace free variables with `ctx`/`S` reads at call time. Keep each expression
   and constant.
2. Apply 4.2 (fallback), 4.4 (count), 4.5 (unique leave keys, identity guard).
   Escape the label with `esc` from `dom.js` (C3-T02's `esc`, with `'`), and set
   `title` by property, as the design does.
3. Wire into C9-T03's `render.js`:
   - `update(force)` calls `fx.scheduleCols(force)` where J:698–702 is. If C9-T03
     ported that block inline, replace it with this call;
   - `relayout()` calls `fx.applyCols(fx.visibleCols(), true)` where J:673 is;
   - if C9-T03 shipped a stub column map (all `D.order` keys), delete it.
4. `import "./columns.js"` in `hook.js`; add the `drawEdgesSoon() {}` `fx`
   default if it is missing (4.1).
5. Diff fixtures for the tests (PROPOSED, under C1-T01's
   `src/test/fixtures/build_home/diffs/`): `plan-new-epic.json`,
   `hist-new-epic.json`, `counts-changed.json`, `counts-unknown.json`
   (`set: { counts: null, sources: { …, history: { state: "unavailable", … } } }`).
   Each is a C3-T02 `diff` message against the `live` snapshot. Add a `name`
   query parameter to C3-T02's `/build-control/diff` action (C3-T02 step 7
   foresees it), so it sends that file. With no `name`, C3-T02's default and
   C9-T03's `op=` parameters keep working. C10-T03 reuses this mechanism.
6. PROPOSED `src/browser/tests/build-home-columns.browser.spec.mjs` (section 8),
   and `"test:build-home-columns": "npm run fixture:preflight && node
   scripts/run-browser-tests.mjs tests/build-home-columns.browser.spec.mjs"` in
   `src/browser/package.json`, appended to the `test` chain (`:10`).

## 6. Non-happy paths and edge cases

| # | Input | Expected behaviour | Test |
| --- | --- | --- | --- |
| N-1 (EC-21) | Tickets with `epic: null` (dense dataset) | They go to the `unsorted` key; the lane has `.unsorted`, label `Unsorted`, the dashed-square icon, `--ec: var(--muted)`; it is last (`D.order`) | P-2 region, M-6 |
| N-2 (EC-21) | Ticket with several type labels | Still one epic (C5-T02 resolver); one column | covered by C5-T02; no client path |
| N-3 | URL `?epic=nope` (valid shape, not an epic) | `epicOk` filters every row out, so nothing is visible; J:691 adds `nope`, `D.order.filter` drops it; `next` is empty, so `update()` changes nothing and the first `applyCols` uses the fallback (4.2). No lane `nope`, no page error | M-7 |
| N-4 | Config with no `bugs` key (for example general epics `bug`, `ops`) and an empty board | Fallback lanes `bug`, `ops` from `D.order`; no exception | M-5 |
| N-5 | Config with no general epics and an empty board | One `Unsorted` lane | M-5 |
| N-6 (EC-08) | `counts: null` (history unavailable or incomplete, C8-T04), or a key missing from `counts` | Count `—` with the title; never `0`, never the last known number, no `TypeError` on `null[k]` | M-1, M-2 |
| N-7 | A known zero count (`newrepo` fallback lanes) | `0`, as the design | P-1 on `newrepo` |
| N-8 (EC-10) | A diff adds a planned row with an epic not yet in the forward set while the user looks at the planned section | C9-T03's live pass relayouts; `applyCols(visibleCols(), true)` adds the lane (J:673); the scroll anchor is C9-T03's | M-3 |
| N-9 (EC-10) | A diff adds a merged ticket to today's history with a new epic | The new `L` has no `_dayCols`, so the day key set is rebuilt and includes the epic; the lane appears in the same live pass | M-3 |
| N-10 | A diff changes only `counts` | C9-T03's live pass re-runs `applyCols`; the existing lane is re-filled (J:802) and shows the new number; no lane enters or leaves | M-4 |
| N-11 | Feature focus (`?feature=khala`) and scrolling from the top of history to not-queued | The lane set never changes; lanes in the feature's epic list show the lock | M-8, P-3 |
| N-12 | Feature focus when part of the feature's history is not loaded yet (paged history) | The lock set is computed over loaded rows, as the design does over `D.all`; it can grow once when C10-T03 loads the feature's earlier days, then stays fixed while scrolling | M-8 (loaded case); C10-T03 owns the load |
| N-13 | Unknown `?feature=` | `D.features[F]` is falsy; viewport-driven columns, as J:679 | M-7 |
| N-14 | Flow mode (narrow content, `S.flow`) | No lanes, no guides; `.bd-lane-g` reads `Colour = epic`; edges hidden | P-4 at 390 px where the data triggers flow |
| N-15 | Lane maps cleared and refilled while a lane is leaving (List and back within 300 ms) | Exactly one tracked lane per key, also after the next `applyCols` | M-9 (product only; the design fails it, see 4.5) |
| N-16 | Hook destroyed during the 220 ms debounce or a 300 ms leave | `ctx.life.dispose()` cancels both; no `applyCols`, no DOM write, no page error after destroy | M-10 |
| N-17 (EC-30) | Epic label `<b>x</b>` (C3-T02 hostile fixture) | Rendered as text; no `<b>` element in the lane | M-11 |
| N-18 (EC-20) | Day boundaries | `dayKey` uses the browser's local zone, as the design; C1-T02 runs in `America/Los_Angeles` | P-1 |
| N-19 (EC-19) | Reduced motion | `transition: none` on lanes and guides; the 220 ms and 300 ms timers still run (the design's behaviour); same final geometry | C1-T03 `columns.reduce` |
| N-20 (EC-06, EC-07) | Socket offline or a stale source | No column change of its own; the counts shown are the last known ones under `.bd-root.stale` (C8-T03) | covered by C9-T13 |
| N-21 | Reconnect, full snapshot | New `D`; `relayout` → `applyCols(…, true)`; caches gone with the old objects | covered by C9-T01's reconnect test plus P-1 after a `window.liveSocket` disconnect and connect (`reconnectLiveView` cannot run on `/build`) |
| N-23 | `applyCols` runs before C9-T05 (`makeCard`) has landed | Every element in `ctx.R` carries `_it` (J:817), including C9-T02's placeholder card, so `place(el, el._it)` (J:791) does not throw | interface note 3; P-1 runs on the placeholder cards until C9-T05 |
| N-22 | Many epics (dense: 10 features, 17 feature epics) | Lanes shrink; at ≤ 132 px the count hides (C:32), labels ellipsize | P-2 on `dense` at 1024 px |

Read-only dashboards, auth and financial data do not apply: this module renders
data the page already received and writes nothing.

## 7. Compatibility and rollout

- No config, migration, route or server change. The home page is behind C3-T01's
  temporary `/build` route until C12-T01.
- One new static file under the `build-home/` directory, served by C2-T03's single
  directory entry. No `StaticAssets` change. Inside the hook: one `import` line in
  `hook.js` and, if missing, one `fx` default in `state.js`.
- The fixture server gains a `name` parameter on `/build-control/diff` (test only).
- Rollback: revert the PR. C9-T03's stub column map (if any) comes back, or the
  page renders cards without columns (`place()` hides cards with no column, J:760).

## 8. Verification

### Pixel parity

All checks use C1-T02's `openParityPair` and `expectDesignParity(pair, { name,
region })`, with its frozen clock, time zone, fonts and allowlist. No allowlist
entry is added by this ticket.

| ID | Region and state | Datasets × viewports × theme × palette |
| --- | --- | --- |
| P-1 | `region: '.bd-lanes'` and `region: '.bd-guides'` at the boot position (at live, J:1565) | `live`, `newrepo`, `noqueue`, `offline` × 1440, 1024, 390 × dark, light × Gruvbox, default |
| P-2 | the same regions after `vp.scrollTop = 0` (top of the loaded history) plus 600 ms (220 ms debounce + .34 s transition) | `live`, `dense` × 1440, 1024 × dark, light × Gruvbox |
| P-3 | the same regions with `?feature=khala` and with `?feature=khala&fmode=compact` | `live` × 1440 × dark, light × Gruvbox |
| P-4 | `region: '.bd-lanes'` in flow mode | the cell of `live` or `dense` at 390 px where `S.flow` is true on the design (the test asserts `.bd-content.flow` on the design first, so the cell cannot silently test the non-flow branch) |
| P-5 | `region: '.bd-lanes'` with `?epic=docs` scrolled to a day without `docs` tickets (the J:691 fallback) | `live` × 1440 × dark × Gruvbox |

Also checked, as DOM state (`domState` from C1-T03, both pages, string equality):
for every `.bd-lane` and `.bd-guide`, the key order, `className`, inline `left`,
`width` and `--h`, the `title`, and the `em` text, at each P-1..P-5 state.

Motion: C1-T03 `columns.enter-leave` and `columns.reduce` must pass (no `fixme`).
Their meta-tests (planted `220 → 150` and `300 → 200`) must still detect the
change against the product. C1-T03's `grain.static` group for `.bd-lanes` is also
this ticket's (`OWNER['grain.static'].per['.bd-lanes']`): it turns on when
`.bd-lanes .bd-lane` exists and must pass (C:1135–1139, 1189: `::after` hidden).

Computed style of the lane elements is C2-T04's snapshot; it must stay green.

### Tests

PROPOSED `src/browser/tests/build-home-columns.browser.spec.mjs`. Module-level
cases open the fixture `/build` page, then drive the same module instances the
hook uses through `page.evaluate(async () => await import("/build-home/columns.js"))`
and `import("/build-home/state.js")` (the C9-T01 B-test pattern): they set
`ctx.D`, `ctx.cols`, the maps and the hosts to a synthetic state and call
`applyCols` directly. Page-level cases use `GET /build-fixture/<dataset>`
(C3-T01) and `GET /build-control/diff?name=<file>` (step 5). Each test records
page errors and fails on any.

| ID | Test | Setup → expected | Fails when (mutation check) |
| --- | --- | --- | --- |
| M-1 | "count is unknown when counts are null" | page, `live` (every lane `em` is a number first); diff `counts-unknown` → every unlocked lane `em` is `—` with title `Ticket count unavailable`; no `em` is `0` or a number; no page error | the unknown branch is replaced by `\|\| 0`; or by the last known count (the fixture starts from known numbers, so both are caught); or `D.counts[k]` is read without the `null` check (page error) |
| M-2 | "a missing count key is unknown, a zero is zero" | module, `ctx.D.counts = { bugs: 0 }`, `applyCols(["bugs","infra"], true)` → `bugs` shows `0`, `infra` shows `—` | the missing-key branch returns `0`; or the zero is treated as unknown (`!counts[k]`) |
| M-3 | "new epics from a diff reach the columns" | page, `live`, scroll to the planned section, wait 600 ms, record lane keys (no `design`); diff `plan-new-epic` (a plan row in `design`; live data never assigns `design`, J:138–139, 195–262) → after 600 ms `design` is a lane, in `D.order` position. Repeat at the top of history with `hist-new-epic` (a merged row today in `design`) | the forward set or the day sets are cached in module variables instead of on `D`/`L` (4.3 point 1), so the new `D`/`L` does not clear them |
| M-4 | "a counts diff updates the headers" | page, `live`; diff `counts-changed` (`infra` +3) → after the live pass (`window.__bdLivePasses` from C9-T03 grows by one) the `infra` lane `em` reads the new number, and the `infra` lane element is the same node as before | the existing-element branch of `syncKeyed` skips `fill(k, el)` (J:802) |
| M-5 | "fallback columns come from the payload" | module, `ctx.cols = []`, `ctx.D.epics = { bug, ops (general), unsorted }`, `ctx.D.order = ["bug","ops","unsorted"]`, `applyCols([], true)` → lanes `bug`, `ops`; with no general epics → one `unsorted` lane | the hard-coded `["bugs","design","infra","docs"]` is kept (page error on `e.temp` of `undefined`) |
| M-6 | "unsorted is a real, last column" | page, `dense`, scroll to a day with an `epic: null` ticket, wait 600 ms → last lane is `unsorted` with class `unsorted` and label `Unsorted` | `colKey` maps null to anything but `unsorted`, or `e.unsorted` is not mapped to the class |
| M-7 | "unknown URL keys never become columns" | page, `/build?epic=nope` → no lane `nope`; lanes equal the fallback (4.2: `bugs`, `design`, `infra`, `docs` on `live`). `/build?feature=nope` → no `.lock` lane and the lane keys equal the no-parameter page at the same `scrollTop` | `D.order.filter` is dropped from `visibleCols()` (lane `nope` appears, or a page error on `D.epics.nope`) |
| M-8 | "feature focus locks the columns" | page, `live`, `?feature=khala`; record lane keys at `scrollTop` 0, 25 %, 50 %, 75 %, 100 % (600 ms after each) → all five equal, and `f-khala-srv`, `f-khala-ui` carry `.lock`; then clear the feature → the keys at 0 and 100 % differ (asserted on the design page first, so the fixture can reach the difference) | the feature branch of `visibleCols()` is removed |
| M-9 | "no duplicate lanes when the maps are refilled during a leave" (product only) | module, clock installed: `applyCols(["bugs","infra"], true)`; `applyCols(["bugs"], true)` (`infra` leaves); at +100 ms clear `ctx.laneEls`/`ctx.guideEls`, replace the hosts' children, set `ctx.cols = []` (what J:1155 + J:617 do); `applyCols(["bugs","infra"], true)`; advance to +400 ms; `applyCols(["bugs","infra"], true)` again → exactly one `.bd-lane` and one `.bd-guide` per key in the hosts, and `ctx.laneEls.get("infra")` is that element | the `map.get(k) === el` guard is removed (the old timer deletes the new entry, the last call adds a second `infra` lane) |
| M-10 | "timers stop with the hook" | page, `live`: scroll so the visible set changes (a debounce is pending) and a lane is leaving; then navigate away from `/build` (LiveView `destroyed`); a `MutationObserver` (subtree, attributes, childList) on the old lanes and guides hosts, and a copy of `ctx.cols` → no mutation, `ctx.cols` unchanged and no page error in the next 800 ms | a column timer uses a bare `setTimeout` instead of `ctx.life.later` |
| M-11 | "epic labels are text" | page with C3-T02's hostile fixture (epic label `<b>x</b>`) → the lane `span` `textContent` is `<b>x</b>` and it has no element child | `esc` is removed from the lane fill |
| M-12 | "guard: debounce and removal timing" (also in C1-T03) | page, clock installed: scroll so the visible set changes → lane set unchanged at +200 ms, changed at +230 ms; the leaving lane exists with `.leave` at +500 ms (230 + 270) and is gone at +540 ms | the debounce or the 300 ms removal changes |

Each test above, except M-12, must fail with its production hunk reverted
(AGENTS.md). M-12 is a regression guard for ported timing and says so in its
name. M-7's `feature=nope` half is also a guard (the design already handles it,
J:679) and is not counted. The PR body lists one line per test with the result,
and the exact revert commands run in a separate worktree with
`git status --porcelain` clean except for the revert.

### Commands

```bash
env -C src/browser npm run test:build-home-columns
env -C src/browser npm run test:build-home-motion     # C1-T03; columns.* must not be fixme
env -C src/browser npm run parity:matrix               # C1-T02 report; P-1..P-5 cells green
env -C src/browser npm test                            # the whole chain, including C2-T04's snapshot
```

Manual: open `/build` on the fixture server at 1440 px, scroll from the band to
the top of history and back, focus a feature, narrow the window below the flow
threshold. Compare with the design file side by side. (The full `aiurdev --test`
TUI check is C12-T01's; this ticket has no TUI or chat path.)

## 9. Completion and handoff

- [ ] `columns.js` ports J:677–693, 698–702, 769–804 with the same constants,
      timings and DOM, in C9-T01's module layout (`ctx`, `fx`, `ctx.life`).
- [ ] Fallback from `D.order` general epics (4.2); unknown count `—` for
      `counts: null` (4.4); unique leave keys and identity guard (4.5).
- [ ] `update()` calls `scheduleCols`, `relayout()` calls `applyCols`; any C9-T03
      stub column map is gone.
- [ ] P-1..P-5 green with no new allowlist entry; DOM-state equality green.
- [ ] C1-T03 `columns.enter-leave`, `columns.reduce` and `grain.static` (`.bd-lanes`)
      green, not `fixme`.
- [ ] M-1..M-11 fail with their hunk reverted and pass with it (except the
      guards named in section 8); M-12 green.
- [ ] No docs change: internal port, no config, CLI or documented behaviour
      (AGENTS.md "Docs ship with the change").
- **Dependents:** C9-T07 (edges read `cols` in the signature, J:894; replaces the
  `fx.drawEdgesSoon` default), C9-T08 (`bandMap`), C9-T09 (Gantt label `Time`),
  C9-T11 (`D.order` index), C10-T02 (`D._fwd = null` on epic filter change),
  C10-T03 (`applyCols(visibleCols())` on focus; lock chips), C12-T05 (lane
  accessibility), C12-T06 (column cost at 10k tickets).

### Interface notes for neighbour rows

1. **C1-T03 is a real predecessor.** The `columns.*` sequences and the
   `.bd-lanes` `grain.static` group this ticket must pass are written there. The
   work-order row lists only C9-T03; this doc adds C1-T03 to `blocked_by`
   (C1-T03's own handoff already says so). C1-T03 also lists "C9-T04 M-9" as a
   product-only sequence; M-9 is a module-level test in this ticket's spec
   instead, because a page-level view switch cannot make sure the leaving key
   comes back and gets re-applied, so it could not fail without the guard.
   C1-T03 may drop that entry or point it at this spec.
2. **C3-T02 `counts`: resolved.** C3-T02 already says every `order` key has an
   entry when `counts` is present, `counts: null` means unknown, and its
   validator checks the referential rules (`order`, `features[].epics`,
   `counts`, row `epic` are keys of `epics`). C8-T04 sends `null` while history
   is unavailable or incomplete. Nothing more is asked.
3. **C9-T02/C9-T03 placeholder cards carry `_it`.** `applyCols` re-places every
   card with `place(el, el._it)` (J:791). C9-T05's `makeCard` sets it (J:817);
   until C9-T05 lands, C9-T02's placeholder card must set `el._it = it` too, or
   `place` throws on `undefined.sec`.
4. **C9-T03 may need columns before this ticket.** `place()` hides any card whose
   key has no `colMap` entry (J:760), so C9-T03 cannot show cards without a column
   map. If C9-T03 ships a stub (all `D.order` keys in `ctx.colMap`), this ticket
   deletes it. If C9-T03 ported the J:698–702 block inline in `update()`, this
   ticket replaces it with `fx.scheduleCols(force)`.
5. **C10-T03 names.** Settled 2026-10-08: C10-T03 calls `applyCols(visibleCols())`
   (J:1095), not `columns.visible()/apply()`.
6. **C10-T03 and paged history (N-12).** Settled 2026-10-08: C10-T03 paints first
   (no load before the first `applyCols`), so the lock set can grow once when the
   feature's earlier days load; C10-T03 switches `visibleCols` to `activeFeature()`
   in its PR (R-G4).

## Decisions made without the owner

1. **Fallback columns** are the payload's general epics in `D.order` order, then
   `["unsorted"]`, instead of the design's hard-coded four keys. Same pixels with
   the default config; no crash with a custom config.
2. **An unknown lane count renders `—`** with the title "Ticket count
   unavailable", in the design's count style. The design has no unknown state;
   this follows S-9's pattern ("unavailable" copy, never empty) and AGENTS.md
   "unknown is never zero". Kevin may replace the glyph at sign-off (C12-T08).
3. **The client trusts `counts: null` as the unknown signal** and does not also
   read `sources.*` for the count. C8-T04 already nulls `counts` whenever the
   total is not known, so a second rule would only add a way for the two to
   disagree. Stale counts (`counts` present, board stale) show the number under
   the board's stale styling (C8-T03), because a stale total is a known value
   with an age.
4. **The leave callback deletes only its own element** (4.5). This fixes a
   duplicate-lane state that the design reaches only by switching views within
   300 ms; no normal frame changes. M-9 runs on the product only, as a
   module-level test (interface note 1).
5. **The design's timer behaviour under reduced motion is kept** (the 220 ms and
   300 ms delays still run; only transitions are off), to match the design.
6. **Feature lock over paged history** uses the loaded rows, as the design uses
   `D.all`; C10-T03 paints first and then loads the feature's span, so the set can
   grow once (interface note 6). No new payload field.
7. **Module shape follows C9-T01**, not the factory (`createColumns(ctx)` with
   getters and its own `destroyed` flag) that an earlier draft proposed. C9-T01
   already fixed `ctx`, `fx` and `ctx.life`; a second state holder would let
   `place()` and `viewport()` read different maps. The `invalidate()`/`refresh()`
   helpers of that draft are dropped too: C9-T01's new `D` per diff, C9-T03's live
   pass and C10-T02's `filtersChanged` already do that work.
8. **Lane headers keep the design's markup** (`div` with `title`). Screen-reader
   access to the board is the List view (C9-T12); further lane labelling is
   C12-T05's.

## Sources

- Work-order row and briefs: [README.md](README.md) (C9-T01..T13, C10-T02, C10-T03).
- [../chunks.md](../chunks.md) §C9; [../plan.md](../plan.md) §5, §8 (EC-10, EC-21),
  §10; [../decisions.md](../decisions.md) E8-D13.
- [DESIGN-E8](../../../owner-design-tasks/DESIGN-E8.md) item 2, S-9.
- Neighbour docs: [MP-E8-C1-T02](MP-E8-C1-T02.md), [MP-E8-C1-T03](MP-E8-C1-T03.md)
  (`columns.*`, `OWNER`), [MP-E8-C2-T03](MP-E8-C2-T03.md), [MP-E8-C2-T04](MP-E8-C2-T04.md)
  (N-7: the 132 px boundary), [MP-E8-C3-T02](MP-E8-C3-T02.md) (`counts`,
  `esc`, `/build-control`), [MP-E8-C8-T04](MP-E8-C8-T04.md) (`counts: null`),
  [MP-E8-C9-T01](MP-E8-C9-T01.md) (module layout, `ctx`, `fx`, `ctx.life`, `applyDiff`),
  [MP-E8-C9-T02](MP-E8-C9-T02.md) (`colKey`, placeholder card), [MP-E8-C9-T03](MP-E8-C9-T03.md)
  (live pass, `__bdLivePasses`), [MP-E8-C10-T02](MP-E8-C10-T02.md), [MP-E8-C10-T03](MP-E8-C10-T03.md), [MP-E8-C3-T03](MP-E8-C3-T03.md) (`epic`
  shape-only).
- Design: J:18, 34–42, 96, 116–121, 138–139, 195–262, 290–294, 301, 332, 355, 541, 604–617, 646–649,
  673, 677–702, 757–805, 817, 1091–1096, 1123–1127, 1155; C:30–32, 169–180, 228–231,
  348, 356, 406, 431–437, 964, 1051–1052, 1135–1137, 1189.
- Product at `58854d4c8`: `src/lib/aiur_web/static_assets.ex:13-44`,
  `src/lib/aiur_web/components/layouts.ex:38, 54, 253`,
  `src/priv/static/aiur-dom-svg-layout-loader.js:20-50`,
  `src/browser/package.json:10`, `src/browser/tests/support/browser-helpers.mjs:102-127`,
  `src/test/browser/fixture_server.exs:2264-2279`.

## Review log

Adversarial review, 2026-10-08, against design-source, the runtime tree at
`58854d4c8` and the neighbour ticket docs. All product citations (`static_assets.ex`,
`layouts.ex`, the loader, `package.json`, `browser-helpers.mjs`,
`fixture_server.exs`) and the CSS table were checked and are correct.

1. Line ranges: `visibleCols` is J:677–693 (not 691), `syncKeyed` J:795–804,
   the epic-filter fallback J:691 and `D.order.filter` J:692 (were 690/691),
   `place()`'s hide branch J:760 (was 759).
2. Module shape: replaced the `createColumns(ctx)` factory (own maps, getters,
   `destroyed` flag, `reset`) with C9-T01's fixed layout: exports `visibleCols`,
   `applyCols`, `scheduleCols`; state on `ctx`; elements read at call time
   (`viewport()` replaces them); timers through `ctx.life.later`; `fx` for later
   modules. The factory would have kept a second copy of `cols`/`colMap` that
   `place()` and `viewport()` do not see.
3. Dropped `invalidate()`/`refresh()`: C9-T01 builds a new `D` per diff, C9-T03's
   live pass clears `L._dayCols` and relayouts (J:673), C10-T02 clears `D._fwd`.
   M-3 and M-4 now target this ticket's own code (caches on `D`/`L`; J:802 re-fill).
4. Count rule: C3-T02 already guarantees complete `counts` and uses `counts: null`
   for unknown; the old rule read `counts[k]` (a `TypeError` on `null`) and keyed
   on `sources.index`, which C8-T04 does not use for counts. Fixture renamed
   `counts-unknown.json`. Interface note 2 marked resolved.
5. Leave timers: unique `ctx.life` keys, so a shared key cannot change design timing.
6. M-9 was not able to fail without the guard (after the stale timer deletes the
   entry, no second `applyCols` ran, so the DOM still had one lane). Rewritten as a
   deterministic module-level test with a final re-apply.
7. M-7 expected value was wrong for `?epic=nope` (it shows the fallback set, not
   the no-parameter set); fixed, and the feature half marked as a guard.
8. M-10 spied on `fx.applyCols`, which the debounce closure does not call; now
   observes DOM mutations and `ctx.cols`.
9. Added the C1-T03 `grain.static` `.bd-lanes` group this ticket owns, edge case
   N-23 and interface note 3 (`el._it` on placeholder cards before C9-T05),
   interface note 5 (C10-T03 uses `columns.visible/apply`; C9-T01 names win), and
   the `drawEdgesSoon` `fx` default.
- Reconciliation 2026-10-08 (coordinator): `colKey` imported from `match.js` and `I` from C9-T01 `icons.js` (R-G9), N-21 reconnect via `window.liveSocket` (R-G7), interface notes 5 and 6 settled (C10-T03 uses `applyCols(visibleCols())` and paints first), decision 6 aligned.
