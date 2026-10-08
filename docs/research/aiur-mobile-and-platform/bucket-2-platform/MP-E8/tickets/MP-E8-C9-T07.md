---
ticket_id: MP-E8-C9-T07
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: Dependency edges
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C9-T05, MP-E8-C9-T04]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-21, EC-09]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T07 — Dependency edges

> `J` = `design-source/assets/build.js`, `C` = `design-source/assets/build.css`,
> `H` = `design-source/Aiur Dashboard.html` (etag 1791431544512943). Product code
> is cited at `origin/main` `58854d4c8`. Paths marked PROPOSED do not exist yet.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C9 (client timeline
  engine), ticket T07.
- **User value.** On the home timeline, the operator sees which ticket waits on
  which, and whether each prerequisite is cleared, pending or broken, without
  opening a ticket. A line to a live ticket stays visible behind the sticky now
  band. Each line has a 14 px hit area; clicking it locks that dependency tree
  (the lock itself is C9-T11).
- **Deliverable.** A port of the design's edge layer (J:879–932), with the mock
  data removed:
  1. PROPOSED `src/priv/static/build-home/edges.js` (the file C9-T01's module
     table assigns to this ticket): `drawEdgesSoon`, `drawEdges`, the signature
     cache, the bezier and arrowhead geometry, the edge classes `ok` / `bl` /
     `bad` / `gh` plus `hl` / `fade`, the `.bd-eh` hit paths with `data-e`, and
     the blurred band copy `svg.bd-now-e`.
  2. Three pure exports in the same file, `edgeClass`, `edgeEmphasis` and
     `edgeGeometry`, so the rules are unit-tested without a browser. C9-T11's
     tree edges (J:1206) call `edgeClass` too.
  3. `Object.assign(fx, { drawEdges, drawEdgesSoon })` and one
     `import "./edges.js"` line in `hook.js`. The callers already exist and call
     these names through `fx` (see "Implementation steps").
- **Non-goals.**
  - `chainOf`, hover, `lockTree`, `unlock`, `fitTree`, the `.bd-lt` tab and the
    tree overlay: C9-T11. The content click listener that sends a `.bd-eh` click
    to `fx.lockTree(eh.dataset.e)` (J:625–626) is C9-T03's port of `viewport()`;
    C9-T11 replaces the `fx.lockTree` default. This ticket only guarantees the
    `.bd-eh` element and its `data-e` value.
  - The `#bd-edges` element itself: C9-T03 creates it in `viewport()` (J:609) and
    stores `ctx.svg`.
  - Gantt geometry and the Gantt edge check: C9-T09 (it reuses this module).
  - The edge legend (`.bd-leg-l`, J:1140): C10-T01.
  - Server edge data (`deps`, `children`, `dep_states`): C4-T05 and C8-T04.
  - Edges in the whole-tree overlay (J:1203–1209): C9-T11.
  - No new edge style. A state the design lacks uses an existing class (see
    "Chosen design").

## Dependencies and blockers

- **Blocked by DESIGN-E8** (Kevin's go). DESIGN-E8 item 3 ("The DAG") asks how an
  edge crosses the now band and how an edge to an off-screen ticket is drawn.
  This ticket follows the design as built: the band copy `.bd-now-e`
  (C:1186–1188, C:1191–1193) and "dropped when the other end is not rendered"
  (J:903). Sign-off item S-36 names this ticket (edges after a flow → wide
  resize, decision 2); the odd-edge looks are C4-T05's S-24.
- **Predecessor: MP-E8-C9-T05** (cards, README row). Edges are drawn between
  `.bd-card` elements that T05 renders, and they read the card classes `ghost`
  and `dim` (J:820, 871–872) and `dataset.id`. T05's `decorateAll` and
  `refreshTicket` (J:877, J:1546) call `fx.drawEdgesSoon`.
- **Predecessor added by this review: MP-E8-C9-T04** (columns). The README row
  lists only C9-T05, and C9-T05 does not depend on C9-T04 (both follow C9-T03).
  This ticket needs C9-T04 merged because (a) decision 2 edits the non-flow
  branch of C9-T04's `applyCols` in `columns.js`, (b) the signature reads
  `ctx.cols` set by `applyCols`, and (c) B6 and B12 use the
  `/build-control/diff?name=<file>` route that C9-T04 step 6 adds. C9-T04 needs
  only C9-T03 and C1-T03, so no cycle and no extra delay on the critical path
  (C9-T05 is the longer branch).
- **Transitive:** C9-T01 (`state.js` with `S`, `ctx`, `fx`, `onReset`; `life.js`;
  `dom.js` `esc`; `store.js` diff intake and `ctx.proto.generation`), C9-T03
  (`viewport()` with `#bd-edges` and the click listener, `update()`, `place()`
  and its `opacity: "0"` contract, J:760, 766), C2-T04 (the consolidated
  stylesheet `build-home/home.css` that holds the edge rules), C1-T02
  (parity runner), C3-T02 (payload schema, `mapRawToPayload`, fixture server).
- **Data contract.** C4-T05 sends per row `deps` (blockers in the index, deduped,
  no self-loop, missing blockers removed) and `dep_states`
  (`{id => "cleared" | "blocking" | "terminal_unsatisfied" | "unknown"}`, one key
  per `deps` id). C3-T02's extension rule lists `dep_states` as an additive key
  owned by "C4-T05 / C9-T07" (step 5 below).
- **May run concurrently with** C9-T06 and C9-T12 (different modules).
- **Successors:** C9-T08 (band; its snap moves the band, and the signature reads
  the band top), C9-T09 (Gantt arrows on Gantt geometry, `svg.bd-edges.gantt`),
  C9-T11 (hover chain, lock; calls `edgeClass` for tree edges and
  `drawEdges(true)` from `setHover`).

## Verified starting point (`58854d4c8`)

**Product.** No home hook exists yet. What exists and is reused as a pattern:

- `src/priv/static/build-order-grid-hook.js` (the Build Order grid, retired by
  this feature) already draws dependency edges into an SVG:
  - `:248-256` `Grid.prototype.scheduleDraw` coalesces draws on
    `requestAnimationFrame`;
  - `:276-314` `drawEdges` builds `<path>` strings and sets `innerHTML`;
  - `:305-306` writes ids into attributes through `escapeAttr`;
  - `:474-476` `escapeAttr` (`&`, `"`, `<`).
  This is the precedent for escaping an id inside an attribute. Do not copy
  `escapeAttr`: C9-T01's `dom.js` `esc` (J:9 plus `'`) already covers `& < > " '`
  and is the one escape function of the home modules. Do not reuse the grid's
  geometry or `.bo-*` classes (plan §5.1: the design replaces them).
- `src/priv/static/aiur-dom-svg-layout-loader.js:20-53`: the loader hook pattern
  with a `destroyed` flag (`__domSvgLayoutDestroyed`) checked before async work.
  C9-T01's `life.js` generalises it: `ctx.life.frame(key, fn)` and
  `ctx.life.dispose()` cancel pending frames on `destroyed`.
- `src/lib/aiur/build_order/edge_state.ex:6, 16-22`: `EdgeState` types
  `:cleared | :blocking | :terminal_unsatisfied | :unknown | :cyclic`.
  `classify/2` (`:9-11`, `:16-22`) returns only the first four: open →
  `:blocking`, closed completed → `:cleared`, closed `not_planned` →
  `:terminal_unsatisfied` (`:19-20`), anything else or unusable health →
  `:unknown`. `:cyclic` (`:13-14`) is a separate constructor; C4-T05 does not
  send it, and this ticket treats it (or any other string) as unknown.
- Browser tests: `src/browser/package.json:10` is the `test` chain; specs run
  through `scripts/run-browser-tests.mjs`. Unit tests for the home modules use
  `node --test` (precedent: C3-T02 `build-home-protocol.test.mjs`, C9-T11
  `build-home-chains.test.mjs`).

**Design (read in full, J:879–932, and its callers).**

| Item | Design source | Rule to keep |
| --- | --- | --- |
| Main layer | J:609 `<svg class="bd-edges" id="bd-edges">` inside `#bd-content`, after `#bd-guides`, before the sections | z-index 1, `pointer-events: none`, `overflow: visible`, `transition: opacity .18s` (C:181) |
| Hidden in flow mode | J:781 `svg.classList.add("hide")` | `.bd-edges.hide { opacity: 0 }` (C:182) |
| Height reset on relayout | J:653 `if (svg) svg.setAttribute("height", 0)` (C9-T03's `relayout`) | unchanged; listed so the port does not drop it |
| Visible set | J:891–893 | every card in `R` and every band item whose `style.opacity !== "0"` |
| Signature | J:894–896 | visible ids, `cols`, `hoverId`, rounded band top relative to content, `content.scrollWidth`; skip when equal and not forced |
| SVG size | J:897 | set height 0 first, then width = `scrollWidth`, height = `scrollHeight` |
| Edge direction | J:900–904 | for ticket `t` and each `did` in `t.deps`: from the blocker card `a` (`did`) to the dependent card `b` (`t`); skipped when `did` is not visible |
| Class | J:905 | `gh` if either card has `.ghost`; else `ok` if blocker done; else `bad` if blocker failed or `t.cue.failed` or `t.cue.blockedChain`; else `bl` |
| Emphasis | J:906 | with a hover chain: `hl` if both ends in the chain, else `fade`; without: `fade` if either card has `.dim` |
| Vertical case | J:908–912 | when `a.bottom <= b.top + 6`: x at card centres; `y1 = a.bottom`, `y2 = b.top - 3`; `dy = max(18, (y2 - y1) / 2)`; arrow `M x2-4,y2-6 L x2,y2+1 L x2+4,y2-6 z` |
| Horizontal case | J:913–918 | `right = a.right <= b.left`; `x1 = right ? a.right : a.left`; `y1 = a` centre; `x2 = right ? b.left - 3 : b.right + 3`; `y2 = b.top + min(18, b.height / 2)`; `dx = max(20, abs(x2 - x1) / 2)`, negative when not `right`; arrow 6 long, 4 half-width, 1 px overshoot |
| Output per edge | J:921 | `path.bd-eh[data-e=<dependent id>]`, then `path.bd-e.<cls><hl>`, then `path.bd-ea.<cls><hl>`; the order matters for `.bd-eh:hover + .bd-e` (C:876) |
| Band copy | J:920, J:925–929 | edges where either end has `sec === "now"` also go into `svg.bd-now-e.bd-edges`, inserted as the band's first child, sized to the band, content translated by `(cr.left - br.left, cr.top - br.top)`; no hit paths there |
| View flags | J:930–931 | `gantt` when view is Gantt and no hover; `hov` when a hover id is set |
| Draw scheduling | J:880–887 | `drawEdgesSoon(ms)` redraws every frame (forced) until `ms` has passed; a second call while a loop runs only extends the end time |
| Callers | J:740 `drawEdges(false)` in `update()`; J:781 `soon(immediate ? 30 : 380)` in flow; J:793 `soon(immediate ? 0 : 420)` in `applyCols`; J:877 `soon(10)` in `decorateAll`; J:984 `drawEdges(true)` in `setHover`; J:1546 `soon(30)` in `refreshTicket` | the same delays |
| Click | J:625–626 | a click on `.bd-eh` stops propagation and locks the tree of `data-e` (C9-T03 listener, C9-T11 lock) |
| Hit path off while scrolling | C:877 | `.bd-content.scrolling .bd-eh { pointer-events: none }` |

**CSS that must compute the same** (final values after the override passes;
C2-T04 owns the consolidation, this ticket proves the result on edges):

| Selector | Final computed rule | Source |
| --- | --- | --- |
| `.bd-e` | `fill: none; stroke: var(--faint); stroke-width: 1.5; opacity: .75` | C:183 |
| `.bd-e.ok` | `stroke: var(--good); stroke-width: 1.8` | C:184 |
| `.bd-e.bl` | `stroke: var(--faint); stroke-dasharray: 5 4; stroke-width: 1.5` (overrides C:185) | C:447 |
| `.bd-e.bad` | `stroke: var(--block); stroke-dasharray: 5 4; stroke-width: 1.8` | C:449 |
| `.bd-e.gh` | `stroke-dasharray: 2 4` | C:186 |
| `.bd-e.hl` | `stroke-width: 2.8; opacity: 1` | C:187 |
| `.bd-e.fade`, `.bd-ea.fade` | `opacity: .04` (C:189/190 .12 → C:410 .05 → C:470 .04) | C:470 |
| `.bd-edges.hov .bd-e.hl.bl` | `stroke-dasharray: none` | C:411 |
| `.bd-ea` | `fill: var(--faint)`; `.ok` `var(--good)`; `.bl` `var(--faint)` (C:448 overrides C:190); `.bad` `var(--block)` | C:190, 448, 450 |
| `.bd-edges.gantt` | `.bd-e` .35; `.bd-ea` .45; `.bd-e.bl` .55 (C:451 overrides C:188 .8); `.bd-e.bad` .85 | C:188, 451 |
| `.bd-edges .bd-eh` | `fill: none; stroke: transparent; stroke-width: 14; pointer-events: stroke; cursor: pointer` | C:875 |
| `.bd-eh:hover + .bd-e` | `stroke-width: 2.8; opacity: 1 !important` | C:876 |
| `.bd-now > .bd-now-e` | `position: absolute; left: 0; top: 0; z-index: 0; pointer-events: none; overflow: hidden; filter: blur(.8px); opacity: .9` | C:1192 |
| `.bd-now > .bd-now-e .bd-e` | `opacity: .7` (specificity 0,3,0, so it also beats `.bd-e.fade` inside the band; keep as designed) | C:1193 |
| `.bd-now` | 82 % opaque board background with `backdrop-filter: blur(5px)`, so main-layer lines show blurred behind the band | C:1187 (light: C:1188) |

## Chosen design

### Module shape

PROPOSED `src/priv/static/build-home/edges.js`, following C9-T01's module rules
(direct imports of files already in `main`, `fx` for later modules, `onReset`
for module state, `ctx.life` for frames):

```js
import { S, ctx, fx, onReset } from "./state.js"
import { esc } from "./dom.js"

let edgeSig = "", edgeUntil = 0
onReset(() => { edgeSig = ""; edgeUntil = 0 })

export function edgeClass(t, did, ghost = false) // → "gh" | "ok" | "bad" | "bl" | ""
export function edgeEmphasis(chain, id, did, dim) // → " hl" | " fade" | ""
export function edgeGeometry(a, b, cr)           // rects → { path, arrow }
export function drawEdgesSoon(ms)                // J:881–887 on ctx.life.frame("edges", …)
export function drawEdges(force)                 // J:888–932
Object.assign(fx, { drawEdges, drawEdgesSoon })
```

`drawEdges` reads only: `ctx.content`, `ctx.svg`, `ctx.bandEl`, `ctx.R`,
`ctx.L.band.items`, `ctx.cols`, `ctx.D.byId`, `ctx.proto.generation`, `S.view`,
and the hover id. The hover id is read as `const hid = ctx.hoverId ?? null`:
`hoverId` stays in C9-T01's `ctx` (C9-T11 sets no `ctx.tree`), and before
C9-T11 lands it is always `null`. The chain is `hid ? fx.chainOf(hid) : null`
(C9-T01's `fx.chainOf` default returns an empty `Set`).

Importing `edges.js` must not touch the DOM at module top level, so
`node --test` can import the three pure exports. If `state.js` or `dom.js`
cannot be imported in Node, move the pure exports into PROPOSED
`build-home/edge-rules.js` (no imports) and re-export them from `edges.js`.

### Class rule (the one change from the design's rule)

The design reads the blocker's `status` (J:905). The real payload carries the
server's judgement per edge in `t.dep_states[did]` (C4-T05).
`edgeClass(t, did, ghost)`, in order:

1. `ghost` (either card has `.ghost`) → `gh`;
2. `dep_states[did] === "cleared"` → `ok`;
3. `dep_states[did] === "terminal_unsatisfied"`, or
   `t.cue && (t.cue.failed || t.cue.blockedChain)` → `bad`;
4. `dep_states[did] === "blocking"` → `bl`;
5. anything else (`"unknown"`, `"cyclic"`, any other string, a missing key, a
   missing or non-object `dep_states`) → `""`, the base `.bd-e` (faint, solid,
   no dash).

`unknown` never becomes `ok` (green, the legend's "Cleared") or `bl` (dashed,
the legend's "Pending"). Step 3 keeps the design's per-row cue rule, so an
unknown edge into a row whose `cue.failed` is set is `bad`: the cue is the
server's claim about that row (C7-T01), not about the edge. C9-T11 calls
`edgeClass(t, did)` without `ghost` for tree edges, which matches J:1206 (no
`gh` branch). On the design data, C4-T05 shows every `dep_states` value gives
the class the design's `status` rule gives, so parity holds. A `not_planned`
blocker arrives as `terminal_unsatisfied` → `bad`, matching `EdgeState`
(`edge_state.ex:19-20`).

### Emphasis rule

As the design (J:906), `edgeEmphasis(chain, id, did, dim)`: with a chain, `" hl"`
when both ids are in it, else `" fade"`; without one, `" fade"` when `dim`
(either card has `.dim`), else `""`. Before C9-T11 lands, `hid` is always `null`.

### Click target

No click code in this ticket. Each edge emits
`<path class="bd-eh" data-e="${esc(id)}" d="…"/>` first, so C9-T03's content
listener (J:624–626) finds it with `closest(".bd-eh")` and calls
`fx.lockTree(eh.dataset.e)`; `dataset.e` returns the unescaped id. Until C9-T11
replaces the `fx.lockTree` default, a click on a line stops propagation and
does nothing visible (the route is the fixture route only).

### Invariants

- An edge is drawn only when both cards are rendered and not hidden
  (`opacity !== "0"`). An edge to a ticket outside the ±700 px window, outside
  the loaded history days, or not in the index is not drawn and leaves no stub.
- A ticket id in the visible set with no row in `D.byId` (removed by a diff
  before the next render) is skipped, never dereferenced. This holds for both
  ends (`t` and `d`).
- `t.deps` that is not an array is treated as `[]`.
- A self-edge (`did === id`) and a repeated `did` are skipped. C4-T05 already
  removes both; the client check costs one `Set` and prevents a loop drawn from a
  card to itself.
- Every id written into markup goes through `esc`.
- No frame callback runs after the hook's `destroyed` (`ctx.life.dispose()`
  cancels the keyed frame), and a new mount starts with `edgeSig = ""` and
  `edgeUntil = 0` (`onReset`). Without the reset, a mount that ends during a
  `soon(420)` loop leaves `edgeUntil` in the future, and the next mount's first
  `soon()` returns early with no loop.

### Signature

The design signature (J:894) plus `ctx.proto.generation`. Without it, a diff that
changes only a blocker's state (blocking → cleared) keeps the same visible set,
the cache matches, and the line stays dashed until something forces a redraw.
C9-T03's live-diff pass calls `update()`, which calls `fx.drawEdges(false)`, so
the generation alone makes a state-only diff redraw. If C9-T03's live-diff pass
moves cards with a transition, it also calls `fx.drawEdgesSoon(30)` (as
`refreshTicket` does, J:1546); add that one line there only if it is missing.

## Implementation steps

1. **Check the element.** C9-T03's `viewport()` creates
   `<svg class="bd-edges" id="bd-edges"></svg>` after `#bd-guides` and before
   `#bd-sec-hist` and stores `ctx.svg`. Add `aria-hidden="true"` to that element
   (decision 6). If it is missing, the C9-T03 port is wrong: fix it there, in the
   position J:609 gives (stacking depends on it).
2. **Pure functions.** Port J:905–918 into `edgeClass`, `edgeEmphasis` and
   `edgeGeometry` with the rules above. Keep the design's string concatenation;
   numbers are not rounded (the design does not round).
3. **`drawEdges(force)`**: J:888–932, with the visible map, the guards from
   "Invariants", the class from `edgeClass`, the emphasis from `edgeEmphasis`,
   the geometry from `edgeGeometry`, and `esc(id)` in `data-e`. Return early when
   `!ctx.content || !ctx.L || !ctx.svg || !ctx.content.isConnected`. The band
   layer: find `.bd-now-e` in `ctx.bandEl` on each draw and create it when
   missing (J:925–926), with `aria-hidden="true"`; C9-T08 may rebuild the band's
   children, and the lazy re-find covers that. Skip the band copy when
   `ctx.bandEl` is null.
4. **`drawEdgesSoon(ms)`**: J:881–887 with `requestAnimationFrame(loop)`
   replaced by `ctx.life.frame("edges", loop)`. `life.frame` deletes its key
   before it calls `loop`, so `loop` can request the next frame with the same key.
5. **Register.** `Object.assign(fx, { drawEdges, drawEdgesSoon })` at the end of
   `edges.js`, and `import "./edges.js"` in `hook.js` (one line, C9-T01 rule 2).
   The call sites are already in place through `fx`: C9-T03 `update()` (J:740,
   `fx.drawEdges` default added by C9-T03), C9-T04 `applyCols` (J:781, J:793,
   `fx.drawEdgesSoon` default added by C9-T04), C9-T05 `decorateAll` and
   `refreshTicket` (J:877, J:1546). Confirm each call exists; add any that is
   missing.
6. **Flow → wide fix (decision 2).** In C9-T04's `applyCols` non-flow branch
   (`columns.js`, before `fx.drawEdgesSoon(immediate ? 0 : 420)`), add
   `ctx.svg.classList.remove("hide")`.
7. **`dep_states` in the schema and the fixtures.** C3-T02's extension rule says
   an additive key lands in one PR with its validator clause, its fixture mapping
   and its producer. If C4-T05 has not added them when this ticket starts, add:
   - the validator clause in `AiurWeb.Build.Payload.validate/1` (PROPOSED
     `src/lib/aiur_web/build/payload.ex`, C3-T02): optional object; keys equal the
     row's `deps`; values in the four strings;
   - one map in `mapRawToPayload` (PROPOSED
     `src/browser/scripts/build-home-fixture-map.mjs`, C3-T02) from the design's
     blocker `status`: `done` → `cleared`, `failed` → `terminal_unsatisfied`,
     anything else → `blocking` (C4-T05's parity mapping);
   - the regenerated five fixtures.
   Without this, the strict validator rejects the field, the design fixtures
   carry no `dep_states`, every edge renders as base `.bd-e`, and B1 fails.
8. **Tests and npm scripts** (see "Verification"): `test:build-home-edges-unit`
   (`TZ=America/Los_Angeles node --test tests/build-home-edges.test.mjs`) and
   `test:build-home-edges` (browser spec) in `src/browser/package.json`, both
   added to the `test` chain (`:10`). Add the diff fixtures
   `edge-state-cleared.json` and `edge-unknown.json` under
   `src/test/fixtures/build_home/diffs/` (C9-T04's `diff?name=` directory).

## Non-happy paths

| Case | Concrete input | Expected | Test |
| --- | --- | --- | --- |
| Blocker not rendered (EC-21, EC-09) | `live` fixture, scroll so the blocker of a planned card is beyond the ±700 px window | no path for that pair in either SVG; no stub line | B2 |
| Blocker in an unloaded history day (EC-09) | dependent in today's plan, blocker merged before `S.histFrom` (the test picks the pair from the fixture rows) | no path until "load earlier" brings the day in; then the path appears | B3 |
| Blocker not in the index (EC-21) | row with `deps: ["999"]`, no row `"999"` (C4-T05 normally removes it) | no path, no error in the console | U4, B4 |
| Unknown edge state (EC-21, AGENTS.md unknown rule) | `dep_states: {"10": "unknown"}`; also `"cyclic"` and `"bogus"` | class `""` (base faint solid); not `ok`, not `bl` | U1 (mutation), B5 |
| `dep_states` absent | row without the key, or `dep_states: null` | every edge of that row is base `""` | U2 |
| Not-planned blocker | `dep_states` `terminal_unsatisfied` with cause `blocker_not_planned` | `bad` | U1 |
| Unknown edge into a failed-cue row | `dep_states: {"10": "unknown"}`, `cue.failed` set | `bad` (the design's row cue) | U1 |
| Ghost card | `ghost = true` with each state | `gh` wins over every state | U1 |
| Cycle (EC-21) | odd-edges fixture (C4-T05): 2-cycle #1↔#2, 3-cycle | one path per directed edge; draw returns; no recursion in this module | U5, B4, B12 |
| Self-loop or duplicate dep | `deps: ["7"]` on row `"7"`; `deps: ["10","10"]` | no self path; one path for `10` | U4 |
| Row removed before render | card `12` in `R`, no `D.byId["12"]`; and a blocker `10` in `R` with no row | `draw` skips both; no `TypeError` | U6 (DOM stub) |
| State change only (EC-10) | `diff?name=edge-state-cleared`: upsert of the dependent with `dep_states` `blocking` → `cleared`, nothing moves | the edge turns `ok` within two frames | B6 |
| Hostile id (EC-30) | id `a"b<c'd&` (C3-T02's id format rejects it at the server, so this is defence in depth) | the `data-e` attribute text is `a&quot;b&lt;c&#39;d&amp;`; one attribute only | U7 |
| Destroy during a draw loop | `soon(420)`, then `live_redirect` away after 50 ms | no mutation of the old `#bd-edges` after `destroyed` | B8 |
| Remount during a draw loop | `soon(420)`, navigate away and back within 200 ms | the new mount draws its edges | B8b |
| Flow then wide | resize 390 → 1440 px | edges visible again (`.hide` removed) | B9 |
| Scrolling | `.bd-content.scrolling` set | `.bd-eh` has `pointer-events: none` (C:877), so drag-scroll does not lock | B10 |
| Many tickets (EC-09) | `dense` fixture | path count = pairs with both ends rendered; DOM count bounded by the window, not the dataset | B11 |
| Disconnect / stale (EC-06) | socket offline | edges stay as last drawn; their state is the last payload's; the stale treatment is C9-T13. No edge claims a newer state | — (no new path) |

Privacy and permissions: edges are read-only and show only ids already on the
page. No write, no server event. Missing blockers arrive as a count only
(C4-T05), so no other repository name reaches the client.

Accessibility: the SVG lines are decorative for screen readers (both SVGs get
`aria-hidden="true"`, which changes no pixels). The dependency information is
available to keyboard and screen-reader users in the list view's deps column
(C9-T12) and the modal's dependency buttons (C11-T01). Forced colours: C12-T05.
Reduced motion: edges have no animation; the `.18s` opacity fade stays (the
design does not remove it under `.rm`).

## Compatibility and rollout

- No config key, CLI flag, environment variable or migration.
- The page is at the temporary fixture route (`/build`, C3-T01) until C12-T01.
  Rollback is reverting this PR; the `fx` no-op defaults from C9-T03 and C9-T04
  take over again.
- Packaging: one new static file under `build-home/`, served by C2-T03's
  directory entry; no change to `layouts.ex` or `StaticAssets`.
- Docs: none. Edge meaning is covered by C4-T05's concepts sentence and C10-T01's
  legend.

## Verification

### Unit tests (PROPOSED `src/browser/tests/build-home-edges.test.mjs`, `node --test`)

| ID | Test | Fails when |
| --- | --- | --- |
| U1 | Table over `edgeClass`: each `dep_states` value (`cleared`, `blocking`, `terminal_unsatisfied`, `unknown`, `cyclic`, `bogus`) × `ghost` × `cue.failed` → expected class, including `unknown` → `""`, `terminal_unsatisfied` → `bad`, and unknown + `cue.failed` → `bad`. Mutation check: replace the step-5 fallback with `"ok"`, then with `"bl"`; both runs must fail | the unknown branch returns a plausible state |
| U2 | `edgeClass` on a row without `dep_states`, and with `dep_states: null` → `""` for every dep. Mutation check: make a missing `dep_states` return `"bl"` (the design's fall-through); U2 must fail | a missing field falls back to a state |
| U3 | `edgeGeometry` on fixed rects: vertical (a above b), horizontal right, horizontal left, the `+6` boundary (`a.bottom == b.top + 6` is vertical, `+7` is horizontal). Exact path strings | geometry drifts from J:908–918 |
| U4 | `drawEdges` with a DOM stub: missing id, self-loop, duplicate → no output for those pairs | the guards are removed |
| U5 | 2-cycle → two paths; function returns | — (guard against a future recursive rewrite; named "guard: cycle stays linear", not counted as coverage) |
| U6 | `drawEdges` with a stub `ctx` whose `R` holds an id absent from `D.byId`, and a blocker absent from `D.byId`, does not throw and emits no path for them | the `!t` or `!d` guard is removed |
| U7 | `drawEdges` with a stub card id `a"b<c'd&` → the `svg.innerHTML` string contains `data-e="a&quot;b&lt;c&#39;d&amp;"` | `esc` is dropped from `data-e` |

### Browser tests (PROPOSED `src/browser/tests/build-home-edges.browser.spec.mjs`)

Against the C3-T01 fixture route, frozen clock and `TZ=America/Los_Angeles`
(C1-T02 setup):

- **B1 parity, region.** `expectDesignParity(pair, { name: "edges-live", region: "#bd-content" })`
  on `live` and `dense` at 1440 and 1024 px, dark and light, Gruvbox and default.
  Then `region: ".bd-now"` for the band copy. The Gantt cell is C9-T09's.
- **B1b structure parity.** For `live`, collect from both pages the list of
  `{class, d}` for every `path` in `#bd-edges` and `.bd-now-e`, sorted. The lists
  are equal. This catches a class or geometry error too thin to move the pixel
  diff.
- **B1c computed style.** For one path of each class, `getComputedStyle`
  `stroke`, `stroke-width`, `stroke-dasharray`, `opacity`, `fill` equal on both
  sides (uses C2-T04's helper and allowlist).
- **B2–B4, B11** as in "Non-happy paths". B11 computes the expected count in the
  test from the fixture rows and the rendered `.bd-card[data-id]` set; it does not
  hard-code a number.
- **B5 unknown.** `diff?name=edge-unknown` sets one `dep_states` value to
  `unknown`; the path's `classList` is exactly `["bd-e"]`, its computed stroke
  equals `--faint` and its dasharray is `none`.
- **B6 state change.** `diff?name=edge-state-cleared` changes one edge from
  `blocking` to `cleared` with no layout change; within two frames the path's
  classes are `bd-e ok`. Mutation check: remove `ctx.proto.generation` from the
  signature (and the `drawEdgesSoon(30)` line if step "Signature" added one);
  the test must fail.
- **B8 destroy.** Start `fx.drawEdgesSoon(420)`, attach a `MutationObserver`
  (subtree, attributes, childList) to the current `#bd-edges`, `live_redirect`
  to `/commands` after 50 ms, wait 600 ms; the observer records no mutation
  after the hook's `destroyed`. Mutation check: replace `ctx.life.frame` with a
  bare `requestAnimationFrame` and remove the `isConnected` guard; mutations
  must be recorded.
- **B8b remount.** Start `fx.drawEdgesSoon(420)`, navigate to `/commands` and
  back to `/build` within 200 ms; after two frames the new `#bd-edges` holds the
  same path count as a fresh load. Mutation check: remove the `onReset`
  callback; the test must fail.
- **B9 flow then wide.** 390 px, then 1440 px; `#bd-edges` has no `hide` class
  and opacity 1. On the design this check fails (see decision 2), so it runs on
  the product only and the C1-T03 resize script has the pending allowlist entry.
  Mutation check: remove step 6's line; B9 must fail.
- **B10 hit target and scroll.** At the midpoint of a `.bd-eh` path,
  `elementFromPoint` returns that `.bd-eh`, its `dataset.e` is the dependent id,
  and a click there does not give `#tk-backdrop` the class `.show` (propagation
  stopped by C9-T03's listener). With `.bd-content.scrolling` set,
  `elementFromPoint` at the same point is not the `.bd-eh`. Mutation check: emit
  the `.bd-eh` path after the `.bd-e` path instead of before; the
  `.bd-eh:hover + .bd-e` computed `stroke-width` on hover is no longer 2.8 and
  the test fails.
- **B12 odd edges (C4-T05 check 2).** Load C4-T05's odd-edges fixture
  (`src/test/fixtures/build_home/odd_edges.json`, `to_payload` output)
  and capture C1-T02 region-mode screenshots (`region: "#bd-edges"`) for the order
  violation (`bad`), the `unknown` edge (base `.bd-e`), the 2-cycle and the
  3-cycle. Zero page errors. The screenshots go to the DESIGN-E8 sign-off (S-24); until
  Kevin signs off they are the baseline, and a change to them fails the check.

### Commands

```text
env -C src/browser npm run test:build-home-edges-unit
env -C src/browser npm run test:build-home-edges
env -C src/browser npm run test:design-parity
env -C src/browser npm run parity:matrix      # report mode; edge regions must be clean
```

Each mutation check above runs in a separate worktree with `git status
--porcelain` showing only the reverted hunk (AGENTS.md); the PR body names the
command and result for each.

### Manual check

Run the fixture route at 1440 px and 390 px. Confirm by eye against the design
HTML with `?example=live`: dashed grey lines into queued cards, green lines from
merged cards, lines into the live band visible and blurred behind it, a
thicker line on hover of the 14 px hit area.

## Pixel parity

- **Design elements reproduced:** `svg.bd-edges` (H via J:609), `.bd-e`,
  `.bd-ea`, `.bd-eh`, `svg.bd-now-e`, the `gantt` / `hov` / `hide` modifiers, and
  the classes `ok`, `bl`, `bad`, `gh`, `hl`, `fade`.
- **How parity is checked:** C1-T02's `expectDesignParity` in region mode on
  `#bd-content` and `.bd-now` (B1), the path-list comparison (B1b), and the
  computed-style comparison (B1c). The threshold is C1-T02's measured floor, not
  the 0.002 default.
- **States the design lacks:** the `unknown`, violation and cycle edges (B12),
  baselined for Kevin's sign-off.
- **Allowlist entries this ticket adds:** one, status `pending-sign-off`: "edges
  return after flow → wide resize" (decision 2, S-36). It affects only the C1-T03 resize
  script, not any static cell. No static cell gets an entry.

## Decisions made without the owner

1. **`dep_states` replaces the design's `status` rule** for the edge class, with
   `unknown` (and any unrecognised value) → base `.bd-e`. This follows C4-T05 and
   the AGENTS.md unknown rule. On the design data the result is identical. Shown
   in the C12-T08 sign-off package next to C4-T05's item, with B12's screenshots.
2. **Edges come back after a flow → wide resize.** In the design, `applyCols`
   adds `.hide` in flow mode (J:781) and nothing removes it; `relayout()` on
   resize (J:572) does not rebuild the viewport (J:644), so after a phone rotates
   from portrait to landscape the lines stay hidden until the view changes. The
   port removes `.hide` in the non-flow branch. This is a behaviour fix, not a
   restyle; it is a `pending-sign-off` allowlist entry (S-36), and Kevin may reject it,
   in which case drop step 6 and B9.
3. **No lock event and no click handler here.** C9-T03 already ports the content
   click listener (J:624–626) with an `fx.lockTree` default, and C9-T11 replaces
   it. A second mechanism (an event) would be dead code once C9-T11 lands.
4. **Client guards for self-loops, duplicates and missing ids** even though
   C4-T05 removes them on the server. They change no pixels and protect against a
   payload from another producer (fixture mapper, a future MP-R1 source).
5. **`ctx.proto.generation` in the signature** so a state-only diff redraws
   (EC-10).
6. **`aria-hidden="true"` on both SVGs.** No pixel change; the information is in
   the list view and the modal.
7. **No visible marker for an edge to an off-screen ticket.** DESIGN-E8 item 3
   asks for one; the design drops the line, and this ticket keeps that.
8. **C9-T04 added to `blocked_by`** (see "Dependencies and blockers").
9. **Reuse `esc`, not `escapeAttr`.** One escape function for the home modules.

## Interface notes (for neighbour tickets)

- Settled 2026-10-08: C9-T04 is in `blocked_by` (decision 8).
- **`dep_states` ownership.** Settled 2026-10-08: per R-G1, whichever of C4-T05 /
  C9-T07 merges first adds the validator clause, the `mapRawToPayload` map and
  the fixtures (step 7); the other only checks they exist.
- **`children` has two sources.** C3-T02's `intake` builds `children` from
  `deps` (J:288) until C4-T05 sends it. This ticket does not read `children`.
- **C9-T11 reads `edgeClass(t, did)`.** This ticket's third parameter `ghost`
  defaults to `false`, so the C9-T11 call shape works unchanged.
- Settled 2026-10-08: `hoverId` stays in `ctx` (C9-T11 sets no `ctx.tree`); the
  `ctx.tree.hoverId()` branch is dropped.

## Completion and handoff

- [ ] `build-home/edges.js` exports `edgeClass`, `edgeEmphasis`, `edgeGeometry`,
      `drawEdges`, `drawEdgesSoon` and registers the last two in `fx`.
- [ ] Every call site in step 5 reaches the module through `fx`; no other file
      draws edges.
- [ ] `dep_states` is in the validator and the fixture mapping (step 7).
- [ ] U1–U7 pass; the U1, U2, U4, U6 and U7 mutation runs fail as described.
- [ ] B1 region parity is clean for `live` and `dense` in all theme and palette
      cells at 1440 and 1024 px; B1b path lists are equal; B1c styles are equal.
- [ ] B2–B12 pass; the B6, B8, B8b, B9 and B10 mutation runs fail as described.
- [ ] No console error on any fixture, including the C4-T05 odd-edges fixture.
- [ ] The PR body lists each mutation command and its result.
- [ ] The pending allowlist entry from decision 2 is in
      `design-parity-allowlist.json` and reported in the run output.
- **Dependents:** C9-T08, C9-T09, C9-T11.
- **Docs:** none (no config, CLI, env var or new surface).
- **Sources:** tickets/README.md row C9-T07; chunks.md C9; plan.md §5, §8
  (EC-09, EC-10, EC-21, EC-30); DESIGN-E8 item 3; MP-E8-C4-T05 (edge payload,
  parity mapping, check 2); MP-E8-C3-T02 (row schema, extension rule, fixture
  server); MP-E8-C9-T01 (module rules, `fx`, `life.js`, `esc`); MP-E8-C9-T03
  (`viewport()`, click listener); MP-E8-C9-T04 (`applyCols`, `diff?name=`);
  MP-E8-C9-T11 (`edgeClass` call, `ctx.hoverId`); MP-E8-C1-T02 (parity
  API); MP-E8-C2-T03 (module folder).
- **Remaining blocker:** DESIGN-E8 only (C9-T04 and C9-T05 are ordinary
  predecessors).

## Review log

Adversarial review, 2026-10-08, against the design source, `58854d4c8` and the
neighbour tickets:

1. Module shape aligned with C9-T01's rules: exports `drawEdges` /
   `drawEdgesSoon` through `fx`, module state reset with `onReset`, frames on
   `ctx.life.frame`. Removed the private `createEdges(ctx)` / `destroy()` object
   and the `ctx.edges` stub request.
2. Fixed field names that do not exist in C9-T01's `ctx`: `ctx.generation` →
   `ctx.proto.generation`, `ctx.S.view` → `S.view`, the `ctx.hover` seam → the
   C9-T11 accessor `ctx.tree.hoverId()` with a `ctx.hoverId` fallback and
   `fx.chainOf`.
3. Removed the `bd-edge-lock` event and the click wiring: C9-T03 owns the content
   click listener and C9-T11 owns `lockTree`. B10 rewritten to test the hit
   target and the path order instead.
4. `viewport()` has an owner (C9-T03 scope ports J:605–635); the "no owner" note
   and the "add the SVG" step were wrong. Step 1 now only adds `aria-hidden`.
5. `refreshTicket` is C9-T05's export, not C11's; successor list corrected.
6. Added MP-E8-C9-T04 to `blocked_by`: the flow → wide fix edits `applyCols`,
   and B6 needs `diff?name=` from C9-T04 step 6. Not transitive through C9-T05.
7. The C3-T02 interface note was stale: C3-T02's extension table already assigns
   `dep_states` to C4-T05 / C9-T07. Step 7 now names `Payload.validate/1`,
   `mapRawToPayload` and the "keys equal `deps`" rule from C4-T05 E17.
8. `edgeClass` signature reduced to `(t, did, ghost = false)` to match C9-T11's
   call `edgeClass(t, did)`; emphasis split into `edgeEmphasis`.
9. `edge_state.ex:6` also types `:cyclic`; recorded that it is not sent and is
   treated as unknown (added to U1).
10. Corrected design line numbers: output per edge J:921 (was 920), band copy
    J:920 and J:925–929 (was 919, 922–927), view flags J:930–931 (was 928–929),
    edge direction J:900–904, signature J:894–896; added the J:653 height reset;
    `.bd-now` rule is C:1187 (light C:1188).
11. Replaced `escapeAttr` with C9-T01's `esc`; B7 (hostile id through the
    payload) replaced by unit test U7, because C3-T02's id format rejects such ids
    at the server.
12. Added B8b and the `onReset` invariant: a mount that ended mid-loop left
    `edgeUntil` in the future and blocked the next mount's first loop. B8 now
    observes DOM mutations, since `life.frame` wraps callbacks and a
    function-name count cannot see them.
13. Added B12 (C4-T05 check 2: odd-edges element screenshots for sign-off) and
    the unit npm script; U2 now has a mutation that can fail; U6 covers a missing
    blocker row too; B9 and B10 got mutation checks.
- Reconciliation 2026-10-08 (coordinator): stylesheet path `build-home/home.css`, dropped the `ctx.tree.hoverId()` branch (hover id read as `ctx.hoverId`), `pending-sign-off` spelling, S-36 for flow → wide edges and S-24 for odd-edge looks, odd-edges fixture path `src/test/fixtures/build_home/`, settled interface notes (C9-T04 edge, `dep_states` owner, `hoverId`).
