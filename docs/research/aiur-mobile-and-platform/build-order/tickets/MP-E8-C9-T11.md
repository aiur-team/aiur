---
ticket_id: MP-E8-C9-T11
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: Dependency chains, lock tab, whole-tree view
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C9-T07, MP-E8-C9-T10, MP-E8-C8-T01]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-21, EC-18]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T11 — Dependency chains, lock tab, whole-tree view

> **Wave 0b.** Product paths are cited at `58854d4c8`
> (`/home/everdred/github/everdred/aiur-worktrees/runtime/src`). Paths marked
> PROPOSED do not exist yet. `J` = `design-source/assets/build.js`, `C` =
> `design-source/assets/build.css`, `H` = `design-source/Aiur Dashboard.html`.
> The design is the specification
> ([claude-design-source-of-truth.md](../claude-design-source-of-truth.md)): port
> the code, remove only the mock parts.

## Identity and outcome

- Bucket 2, feature MP-E8 (home page "Continuous build history"), chunk C9
  (client timeline engine), ticket T11.
- **User value.** The operator points at a ticket and sees everything it waits
  for and everything that waits for it. The operator can lock that chain, zoom
  the board out until the whole chain fits, or open a clean "Dependency tree"
  overlay with one node per ticket. The same works on real, paged, live data with
  cycles, and on a phone by tapping an arrow.
- **Deliverable.** A port of J:933–985 and J:1183–1221 into two PROPOSED module
  files under `build-home/`, plus small edits to the listener lines that
  C9-T03 (`viewport()`, J:618–635) and C9-T01 (`shell()`, J:561–566) already
  port:
  - `chains.js` (pure, no DOM): `chainOf`, `chainGaps`, `fitFrom`, the tree
    layout (`treeLayout`, the computational half of `openTree`), and the tree
    node status text (`treeStatus`).
  - `trees.js` (DOM; the file name in C9-T01's module table): `onHover`,
    `onLeave`, `toggleLock`, `setHover`, `lockTree`, `unlock`, `fitTree`,
    `treeRange`, `openTree`, `closeTree`, plus a new `reapply()` for live data.
    It registers them in C9-T01's `fx` table.
  - The `.bd-lt` tab markup and the content/document listeners stay in C9-T03
    and C9-T01. This ticket changes only the lines listed in step 5.
- **Scope.**
  - Chain hover (only with `?trees=1`, S-3), with the 280 ms clear on a non-card
    target (J:947) and the 200 ms clear on content `mouseleave` (J:619).
  - The `.bd-lt` lock / fit / eye tab and the lock rules (J:622–633, J:561–565).
  - Edge click to lock (`.bd-eh`, J:626). This works with or without `?trees=1`,
    as in the design.
  - `fitTree` over the server-paged history (C9-T03 `ensureFrom`).
  - The whole-tree overlay (`#bd-tree`) with its `bdTreeIn` fade and backdrop
    blur (C:675–677, 955), and its Escape and outside-click close.
  - Cycle-safe, stack-safe walks (EC-21). Touch: no hover; tap opens the modal;
    an arrow tap locks (EC-18).
  - Unknown values in tree nodes (state, progress, queue position, wave, merge
    date) never render as `0`, `null`, `Merged` or a default date.
- **Non-goals.**
  - Edge drawing, edge classes and the `.bd-eh` hit paths themselves (C9-T07).
    This ticket only reacts to a `.bd-eh` click and calls `drawEdges(true)`.
  - A visible "trees" toggle. The design has a dead `#bd-trees` handler
    (J:1145) and no button in `renderTools` (J:1128–1150). S-3 keeps it hidden.
  - Keyboard access to start a chain lock (the design has none; C12-T05 and
    S-12 own keyboard and focus work). The list view (C9-T12) is the keyboard and
    screen-reader view of dependencies (↑↓ counts).
  - Server-side chain walks. The browser walks only loaded rows (C4-T05
    "Cycles").

## Dependencies and blockers

- **Blocked by DESIGN-E8** (feature gate). S-3 (`?trees=1` only, no visible
  control) is not a blocker: this ticket follows its default "As designed"
  ([DESIGN-E8](../../../owner-design-tasks/DESIGN-E8.md) S-3; plan §10 item 6).
  Kevin's answer may reopen it.
- **Predecessor in the row: MP-E8-C9-T07** (dependency edges): `drawEdges(force)`
  reads `hoverId` and `chainOf` (J:894, J:898) for `hl`/`fade` (J:906), `.bd-eh`
  carries `data-e` (J:921), and the edge class rule that the tree edges reuse
  (J:905, repeated at J:1206; C9-T07 exports it as `edgeClass`).
- **Extra predecessors added by this writer** (see "Interface notes"):
  - **MP-E8-C9-T10** (span and zoom): `fitTree` steps `S.span` through `SPANS`
    (J:302; the constant itself is exported by C9-T01's `state.js`) and must
    leave the `--dot` grid (J:654), `calNear()` and the zoom label correct; P3
    checks the zoom label, which C9-T10 renders. The README row of C9-T10 says
    "`fitTree` uses these (C9-T11)", but the C9-T11 row does not list C9-T10.
  - **MP-E8-C8-T01** (`now-state.js`: `agentState`, `progress`). Tree nodes
    print `AST[t.agent.state].label + " · " + t.pct + "%"` (J:1210). C8-T01 says
    C9-T11 must call its helpers (C8-T01 "Client rules").
- **Transitive** (already merged when C9-T07 merges): C9-T01 (hook shell, module
  seam, URL bridge, the `document` listeners' lifetime), C9-T03 (`relayout`,
  `relayout({live: true})`, `update`, `ensureFrom`, the history state `H`),
  C9-T05 (cards, `R`, `makeCard`), C3-T02 (payload v1, `intake` builds
  `D.children`), C3-T03 (`trees` URL key), C2-T04 (`build-home/home.css`, which
  carries every selector below).
- **Seams to tickets that may land later** (called through C9-T01's `fx` table;
  no-ops until they land): `openModal` (C11-T01), `renderTools` (C10-T01),
  `refText`/`queueText` (C7-T02 `unfiled.js`). The scrolling state is read from
  the `.bd-content.scrolling` class that C9-T08's `markScrolling` sets (J:576–578),
  so no new export is needed from C9-T08.
- **May run concurrently with:** C9-T08, C9-T09, C9-T12, C9-T13 and C10-*. All
  edit separate module files. The shared-file edits are the few lines in C9-T03's
  `render.js` and C9-T01's `shell.js` listed in step 5; merge in README order.
- **Shared contracts:** C3-T02 schema v1 ticket row (`deps`, `sec`, `status`,
  `num`, `qpos`, `wave`, `pct`, `agent`, `end`); C4-T05 `children`,
  `dep_states`, `deps_missing` (optional here; see "Chosen design" 4).

## Verified starting point (`58854d4c8`)

**Product.** No home page and no `build-home/` directory exist yet. Everything
this ticket edits is PROPOSED by C2-T03, C2-T04, C9-T01, C9-T03 and C9-T07.
Reused patterns:

- `src/priv/static/build-order-grid-hook.js:331–447`: the Build Order graph's
  hover highlight and pin. `:339–343` `onPointerOver` uses `pointerover` with a
  same-card guard (`:351–356` `setHover`); `:372–389` `togglePin`/`clearPin`;
  `:441–447` `reapplyHighlight` re-applies the highlight after a LiveView patch
  replaces card DOM. The home hook needs the same re-apply after a live diff
  (step 5).
- `src/priv/static/build-order-grid-hook.js:452–467` `bfsDistance`: an
  iterative queue walk with a visited map. It is the precedent for walking a
  graph without recursion. `:109–112` `destroy` removes the window listener.
- `src/lib/aiur/build_order/dependency_chain.ex:44–63` `reachable/2`: the server
  walk with a `MapSet` of seen nodes. Same semantics as the design's `chainOf`:
  upstream through blockers, downstream through dependents, directional, so a
  chain never grows into the whole graph.
- `src/browser/tests/build-order-interaction.browser.spec.mjs:128–182`: the
  hover → pin → release test and the axe check while a highlight is active
  (`AxeBuilder`, `:1`, `:177`). The new spec copies this shape.
- `src/test/browser/fixture_server.exs:2264`: the `/streamdeck-control/:mode`
  route. C3-T02 adds `/build-control/:action` next to it; C9-T04 adds
  `diff?name=` with fixtures under `src/test/fixtures/build_home/diffs/`. This
  ticket adds two diff fixtures there. C3-T01 adds `GET /build-fixture/:dataset`
  with a fixed `@datasets` list in PROPOSED
  `src/test/support/build_home/fixture_source.ex` (C9-T05 adds `unknowns` the
  same way); this ticket adds `chains` to that list.
- `src/browser/package.json:10`: the `test` chain that the new scripts join.
  `:25` `test:parity` is an existing, unrelated spec
  (`parity-composition.browser.spec.mjs`); the C1-T02 design runner is
  `test:design-parity`.

**Design** (what must be ported exactly):

- **`chainOf(id)`** J:933–938. Set seeded with `id`; `up` walks `deps` and adds
  only ids present in `D.byId`; `dn` walks `D.children` and adds every child
  **without** checking `D.byId` (J:936). Both recurse. Insertion order: `id`,
  then the depth-first pre-order of `up`, then of `dn`.
- **`onHover(e)`** J:941–948 on `content` `mouseover` (J:618). Returns when
  `!S.trees`, `scrolling` or `lockId`. A target inside `.bd-lt` keeps the
  current hover. A `.bd-card` outside `.bd-now` sets the hover at once. Any other
  target clears it after **280 ms**.
- **Content `mouseleave`** J:619: clears after **200 ms** unless locked.
- **`treeRange(id)`** J:949–955: min top / max bottom of chain items in the three
  sections (`secs[sx].el.offsetTop + it.y`) and the band (`bt + it.y`).
- **`fitTree(id)`** J:956–966: moves `S.histFrom` back (never forward) to local
  midnight of the oldest `hist` member's `end`; `room = vp.clientHeight − LH − 70`;
  for each `sp` of `SPANS` (`[1, 2, 3, 5, 7, 10, 14, 21, 30]`, J:302): `S.span = sp; relayout()`,
  stop at the first span whose range fits; `writeURL(); renderTools()`; instant
  `scrollVP` to centre the range (`(a + b) / 2 − clientHeight / 2 + LH / 2`);
  `update()`; then after two `requestAnimationFrame`s, `update(); lockTree(id)`.
- **`lockTree(id)`** J:967–972: finds the element in `R` or the band; sets
  `hoverId = "~"` to force `setHover`; locks; adds `.locked.show` to the tab
  (even when no element was found).
- **`unlock()`** J:973. **`setHover(id, el)`** J:974–985: toggles `hl` on chain
  members except the source and `hdim` on the rest (cards in `R`); `hl` on band
  members; places the tab at `left = card.right − content.left − 1`,
  `top = card.top − content.top + max(0, card.height / 2 − 14)`; toggles
  `.bd-content.hovering`; calls `drawEdges(true)`.
- **The tab** J:620–623: `div.bd-lt` with three buttons `data-lt="lock"`
  (title "Lock this dependency tree", `I.lock`), `data-lt="fit"` ("Zoom out to
  fit this tree", `I.fit`), `data-lt="tree"` ("View the whole tree", `I.eye`)
  (icons J:42, 47, 67).
- **Content click** J:624–635 (C9-T03 ports the listener): `.bd-eh` → `lockTree(eh.dataset.e)` (not gated on
  `S.trees`); `[data-lt]` → lock toggles (lock = current `hoverId`), fit and tree
  act only while locked; while locked, a card in the chain opens the modal and
  any other card does nothing.
- **Document click** J:561–565 (C9-T01 ports it into `shell.js` through
  `ctx.life`, calling `fx.chainOf` and `fx.unlock`): while locked, a click outside `.bd-lt`,
  `.bd-tree`, `.bd-eh`, `#tk-backdrop` and outside the chain unlocks.
- **Document keydown** J:566: Escape closes the tree if open, else unlocks.
- **`relayout()`** J:651: full relayout unlocks and closes the tree (C9-T03 keeps
  this for full relayouts and skips it in live mode).
- **`openTree(id)`** J:1183–1219:
  - `dep(x)` J:1186: memoised longest-path depth over chain-internal `deps`,
    with `depth[x] = 0` set **before** recursing, so a cycle ends. Recursive.
  - rows by depth, sorted by `D.order.indexOf(colKey(t))` then `num` (J:1190).
  - constants `NW = 196, NH = 50, GX = 14, GY = 44, GW = 12, MIN = 0.8` (J:1191);
    `aw = host.clientWidth − 56`, `ah = host.clientHeight − 96`;
    `per = max(2, floor((aw / MIN + GX) / (NW + GX)))`; a row longer than `per`
    wraps into continuation rows spaced `GW` instead of `GY`; rows centred on
    the widest; `sc = max(MIN, min(1, aw / natW, ah / natH))`.
  - edges J:1203–1209: cubic from the blocker's bottom centre to the dependent's
    top centre minus 4, `dy = max(16, (y2 − y1) / 2)`, arrowhead `±4 / −6 / +1`;
    class `ok` / `bad` / `bl` by the J:905 rule (without its `gh` branch).
  - header level count is `rows.length` (J:1214). `rows` is indexed by depth
    (J:1188), so on a cycle it has empty slots (see defect 8).
  - node status `stOf` J:1210: `hist` → `Failed` or `Merged {fmtD(end)}`; `now`
    → `{AST label} · {pct}%`; `plan` → `Q{qpos} · W{wave}`; `nq` → `Not queued`.
  - node button J:1211–1212: classes `bd-tn {sec} ag-{cls} failed sel`, inline
    `left/top/width/height` and `--h` (epic hue); `<span class="bd-tn1"><i></i>
    <b>#num</b><span>{esc(title)}</span></span><em>{status}</em>`.
  - header J:1214: `<b>Dependency tree</b><span>#{num} · {n} tickets · {rows}
    levels</span>` and `#bd-tree-x` "Close" with `I.x`.
  - scroll centres on the root node (J:1217–1219); `host.onclick` opens the
    modal for a node, closes for `#bd-tree-x` or a click outside `.bd-tree-c`.
- **`closeTree()`** J:1221: hides, empties, removes `.treeview` (no CSS uses
  `.treeview`; it is kept for parity of DOM state).
- **`#bd-tree` host** J:550: `div.bd-tree#bd-tree[hidden]` inside `.bd-vpw`,
  sibling of `#bd-vp`. Created by C9-T01's `shell()` port.

**Design defects found** (each handled in "Chosen design"):

1. `dn` does not check `D.byId` (J:936). With paged data, `D.children` names
   tickets that are not loaded, and `openTree` then reads `D.byId[x].deps` of
   `undefined` (J:1186). C4-T05 "Interface notes" asks for the check.
2. `fitTree` takes `Math.min(Infinity, …end)` (J:958). A `hist` row with
   `end: null` gives `0`, so `S.histFrom` becomes 1970-01-01 and, in the product,
   paging would load the whole history.
3. `stOf` prints `Merged` for every non-failed history row, `null%` for an
   unknown progress, crashes on an unknown agent state (`AST[null].label`), and
   prints `Qnull`, `Wnull`, `#null` for unknown fields (J:1210–1214).
4. While locked, cards that `update()` creates later (scrolling into the ±700 px
   window) get no `hl`/`hdim` classes, so they appear sharp in a blurred board.
5. Escape with the ticket modal open over the tree closes both, because H:5106
   and J:566 both handle it.
6. The `document` listeners are never removed (no teardown in a static page).
   C9-T01 already fixes this (`ctx.life`); this ticket adds no bare listener,
   timer or frame.
7. Tree nodes sort by `num`; `pack:` rows have `num: null` (C7-T02), so the
   comparator returns `NaN`.
8. On a cycle, `dep()` leaves depth slots empty (a 3-cycle A→B→C→A entered at A
   gives depths 3, 2, 1, so `rows[0]` is empty) and the header prints
   `rows.length` = `4 levels` for a three-level tree. A self-loop gives depth 1
   and an empty row 0. On acyclic data the depths are contiguous from 0, so
   no slot is empty.

## Chosen design

### 1. Port, with the smallest set of changes

The design code is ported into `chains.js` and `trees.js` with the same names,
constants, timings, class names, strings and order of operations. Only the
changes listed in this section are made. Module shape follows C9-T01's rules
(C9-T01 "Rules for later tickets" 1–4): direct imports for files already in
`main`, `fx` for calls into modules that may land later, `onReset` for module
state, `ctx.life` for every listener, timer and frame.

```js
// build-home/trees.js (PROPOSED; C9-T01 module table)
import { S, ctx, fx, onReset, SPANS, LH } from "./state.js"
import { chainOf, chainGaps, fitFrom, treeLayout, treeStatus } from "./chains.js"
import { edgeClass } from "./edges.js"          // C9-T07, a predecessor
import { agentState, progress } from "./now-state.js"   // C8-T01, a predecessor
let fitToken = 0, hoverGen = 0, openRoot = null, returnFocus = null
onReset(() => { fitToken++; hoverGen++; openRoot = null; returnFocus = null })
Object.assign(fx, { onHover, onLeave, toggleLock, setHover, lockTree, unlock, fitTree,
                    openTree, closeTree, reapply, onTreesChanged,
                    chainOf: (id) => chainOf(ctx.D, id) })
```

- `ctx.hoverId` and `ctx.lockId` stay where C9-T01 put them (J:539, J:939). They
  do not move into this module. C9-T07 reads `ctx.hoverId` directly (it has no
  `ctx.tree` branch); this ticket sets no `ctx.tree` (interface note 4).
- The tab is the `.bd-lt` element that C9-T03's `viewport()` port appends to
  `#bd-content` (J:621–623). `trees.js` finds it with
  `ctx.content.querySelector(":scope > .bd-lt")`, so no new `ctx` field is needed.
- The design's `hoverT` handle (J:940) becomes `ctx.life.later("tree-hover", ms,
  fn)`. `life` has no cancel, so `onHover` bumps `hoverGen` where the design calls
  `clearTimeout(hoverT)`, and each scheduled clear runs only if its `hoverGen` is
  still current. The two Fit frames use `ctx.life.frame("fit-1", …)` and
  `ctx.life.frame("fit-2", …)`.

### 2. `chainOf` — cycle-safe and stack-safe (EC-21)

```js
// build-home/chains.js (PROPOSED)
export function chainOf(D, id) {
  const s = new Set([id]);
  if (!D.byId[id]) return s;                       // locked id left the window
  walk(id, (x) => D.byId[x].deps || [], s, D);     // up
  walk(id, (x) => D.children[x] || [], s, D);      // down
  return s;
}
// Depth-first pre-order with an explicit stack of [node, nextIndex] frames:
// the same insertion order as the design's recursion, no call-stack depth.
function walk(start, next, s, D) {
  const st = [[start, 0]];
  while (st.length) {
    const f = st[st.length - 1], n = next(f[0]);
    if (f[1] >= n.length) { st.pop(); continue; }
    const c = n[f[1]++];
    if (!s.has(c) && D.byId[c]) { s.add(c); st.push([c, 0]); }
  }
}
```

- The `D.byId[c]` check now applies to both directions (defect 1). A dependent
  that is not loaded is not in the chain; it is counted (section 4).
- `up` reads only `deps`; `dn` reads only `children`. The walk is directional,
  as in J:933–938 and `dependency_chain.ex:44`, so two separate chains joined by
  a common blocker do not merge.

### 3. Tree layout — `dep()` without recursion

`treeLayout(D, id, aw, ah)` returns `{ids, rows, pos, natW, natH, sc, edges}` with
the J:1185–1201 arithmetic and constants. `dep(x)` is the same memoised
longest-path function, run on an explicit stack: on entering `x`, if `depth[x]`
is set, return it; else set `depth[x] = 0` (the design's cycle cut), then visit
each `p` of `D.byId[x].deps` with `set.has(p)` and take `max(d, dep(p) + 1)`.
The visiting order equals the recursion, so every depth equals the design's for
the same data, including cycles (a 2-cycle A↔B entered at A gives `B = 1,
A = 2`, the design's result).

- Row sort: `oi(a) − oi(b) || numKey(a) − numKey(b) || (a < b ? −1 : 1)`, where
  `numKey` is `num`, or `+Infinity` when `num` is `null` (defect 7). On the
  design data `num` is never null, so the order is unchanged.
- A self-loop (`x` in its own `deps`) is ignored in `dep()` and in the edges.
  C4-T05 drops self-loops on the server; the client defends anyway.
- `rows` keeps the design's depth index, so node positions equal the design's
  (the design's `forEach` already skips empty slots). The header level count is
  the number of **non-empty** rows (defect 8). On acyclic data this equals
  `rows.length`, so the design header is unchanged byte for byte.

### 4. Honest counts for chains that leave the loaded window

The design holds all data, so its header `#{num} · {n} tickets · {rows} levels`
is complete. The product holds a window. `chainOf` also returns (as a second
function, `chainGaps(D, set)`) two numbers:

- `unloaded`: the number of **distinct** ids named in `deps` or `children` of a
  member that are not in `D.byId` (in the index, outside the window; C4-T05
  sends only index ids). It counts only the first unloaded hop: the client
  cannot see past a row it has not loaded, so the text says "not on the board",
  not a total;
- `missing`: the sum of members' `deps_missing` when every member has a number;
  `null` when any member has `deps_missing: null` (store incomplete). When the
  payload has no `deps_missing` field yet (before C4-T05), `missing` is `0`.

The header span becomes, in order:

| `unloaded + missing` | `missing` | Header span |
| --- | --- | --- |
| 0 | 0 | `#{ref} · {n} tickets · {rows} levels` (design, byte for byte) |
| k > 0 | number | `… · {rows} levels · {k} not on the board` |
| any | `null` | `… · {rows} levels · links not yet known` (plus ` · {k} not on the board` first when `unloaded > 0`) |

The extra text sits inside the existing `<span>`, so no style changes. The two
new phrases appear only on data the design cannot produce, so the C1-T02
design-vs-product run never sees them. They are recorded as C1-T02 `copy`
allowlist entries with status `pending-sign-off` citing S-34 (step 8), and are
in C12-T08's copy sign-off table ("not on the board", "links not yet known").

### 5. Live data (EC-10 interaction)

- `reapply()` re-runs the current state on the current DOM: if `hoverId` is set,
  it recomputes the chain (`hoverId = "~"`-style force) and re-toggles `hl`,
  `hdim` and `.hovering`; if locked, it re-places the tab on the locked card's
  current element (or removes `.show` when the card is not rendered); if the tree
  is open, it rebuilds it with `openTree(openRoot, { keep: true })`, which keeps
  `.bd-tree-s` `scrollLeft`/`scrollTop` and the focused `.bd-tn` (by `data-id`),
  and does not re-trigger `bdTreeIn` (the host stays shown; only its children
  change).
- C9-T03's `update()` calls `fx.reapply()` at its end **only** when it
  created at least one element and `ctx.hoverId` is set (defect 4). C9-T03's
  `relayout({live: true})` already keeps the lock when the id still exists and
  calls `unlock()` / `closeTree()` otherwise; it then calls `update()`, which
  re-applies.
- A diff that removes the open tree's root closes the tree (C9-T03 rule) and
  focus returns as in section 8.

### 6. `fitTree` over paged history

```js
// chains.js (pure): local midnight of the oldest numeric `end` among the chain's
// history members, or null when there is none (defect 2)
export function fitFrom(D, id) {
  const ends = [...chainOf(D, id)].map((x) => D.byId[x])
    .filter((t) => t.sec === "hist" && Number.isFinite(t.end)).map((t) => t.end);
  if (!ends.length) return null;
  const d = new Date(Math.min(...ends)); d.setHours(0, 0, 0, 0); return d.getTime();
}

// trees.js
async function fitTree(id) {
  const token = ++fitToken, from = fitFrom(ctx.D, id);
  if (from != null && S.histFrom > from) await ensureFrom(from);   // C9-T03; design: only moves back
  if (token !== fitToken || ctx.lockId !== id || !ctx.D.byId[id]) return;   // user moved on or remounted
  if (!ctx.content || !ctx.content.isConnected) return;                     // hook destroyed while paging
  /* J:960–964 unchanged: room, the SPANS loop with fx.relayout() + treeRange, fx.writeURL,
     fx.renderTools, instant scrollVP, fx.update; then
     ctx.life.frame("fit-1", () => ctx.life.frame("fit-2", () => { fx.update(); lockTree(id) })) */
}
```

`onReset` bumps `fitToken` on a remount; on `destroyed`, `ctx.life.dispose()`
cancels the frames and the `isConnected` check stops a Fit whose page reply
arrives after the root left the DOM. Nothing runs late.

- `ensureFrom` replaces the direct `S.histFrom` write (C9-T03 "Interface notes"
  5). It pages one day per request and stops on `more: false`, an error or no
  progress. On a paging error the fit still runs on what is loaded, and the
  history header shows C9-T03's error text.
- `Math.min(...ends)` on a long array: `ends` is the chain's history members,
  bounded by the loaded rows. A `ponytail:` comment names the spread limit
  (~100k arguments) and the reduce to use above it.
- A second Fit click while one is waiting bumps `fitToken`; the first returns.
- The relayouts inside the loop are full relayouts, so they unlock and close the
  tree (J:651); the final `lockTree(id)` restores the lock, as in the design.

### 7. Hover gating (S-3) and touch (EC-18)

- Hover listens to `pointerover` instead of `mouseover` (one word in C9-T03's
  J:618 listener line), and `onHover` returns when `e.pointerType === "touch"`. Mouse and pen behave as the design (the same
  targets reach both events). A tap therefore never sets a hover; the click
  opens the modal (J:634), as the design does on a desktop click.
- `S.trees` comes from the URL bridge (C3-T03 key `trees`, value `1`). When it
  turns false (back/forward), `onTreesChanged(false)` runs J:1145's rule:
  `if (lockId) unlock(); else setHover(null)`. The dead `#bd-trees` button
  lookup is not ported.
- Edge click lock stays ungated (J:626). On a phone this is the touch path to
  the chain: tap an arrow (14 px hit stroke, C:875), and the tab shows lock,
  fit and eye. At 390 px the tree overlay lays out with `per = 2` and
  `sc = 0.8` and scrolls inside `.bd-tree-s` (`overflow: auto`, C:683).
- `onHover` reads the design's `scrolling` flag as
  `ctx.content.classList.contains("scrolling")`: C9-T08's `markScrolling` sets and
  clears that class together with the flag (J:576, J:578), so this needs no new
  C9-T08 export and is `false` until C9-T08 lands. C9-T08's `markScrolling`
  calls `fx.setHover(null)` where J:576 does (C9-T08 lists `setHover`,
  `hoverId` and `lockId` in its `ctx`).

### 8. Tree overlay accessibility (no pixel change)

The design's overlay has no dialog semantics. Added, all invisible:

- On open: `role="dialog"`, `aria-modal="true"`, `aria-labelledby` pointing at
  the header `<b>` (given `id="bd-tree-t"`). The previously focused element is
  saved; focus moves to `#bd-tree-x` with `preventScroll: true`.
- Tab and Shift+Tab wrap inside the host (first and last focusable).
- On close: focus returns to the saved element if it is still connected and
  rendered (`el.isConnected && el.getClientRects().length > 0`), else to
  `#bd-vp`. The rendered check matters: when a diff removes the locked root,
  C9-T03 unlocks first, which hides the eye button (`display: none`, C:667), and
  focusing a hidden button would leave focus on `body`. The attributes are
  removed with the content.
- Lock button: `aria-pressed` mirrors `.locked`.
- Escape (defect 5): C9-T01's J:566 port gets two changes. It is added with
  `{ capture: true }`, so it runs before C11-T01's bubble-phase Escape listener
  whatever the registration order, and it returns when `#tk-backdrop.show`
  exists or `e.defaultPrevented` is true. One Escape then closes only the modal
  (C11-T01 closes it and calls `preventDefault()`, settled 2026-10-08); the
  next closes the tree.

### 9. Unknown values in tree nodes (EC-08, AGENTS.md)

`treeStatus(t)` replaces `stOf` (J:1210):

| Row | Design text | Product text |
| --- | --- | --- |
| `hist`, `status: failed` | `Failed` | same |
| `hist`, `status: done`, `end` a number | `Merged {fmtD(end)}` | same |
| `hist`, `status: not_planned` | `Merged …` (wrong) | `Not planned` (S-17 label) |
| `hist`, `status: closed` (duplicate or unknown close reason) | `Merged …` (wrong) | `Closed` (R-G11) |
| `hist`, `end` not a number | `Merged Jan 1` | `Merged · date unknown` |
| `now` | `{AST label} · {pct}%` | `agentState(state).label + " · " + progress(pct).text` → `State unknown`, `—` for unknowns (C8-T01 D7, D8) |
| `plan`, filed | `Q{qpos} · W{wave}` | `queueText(t) + " · " + waveText` (C7-T02): an unknown `qpos` gives `Q?` (C7-T02's rule); an unknown `wave` gives `W?` (the same convention) |
| `plan`, unfiled `pack:` | `Qnull · W{wave}` | `Not filed · W{wave}` (C7-T02 `queueText`) |
| `nq` | `Not queued` | same |

- `ag-{cls}` is added only when `agentState(...).cls` is not null, so an unknown
  state never shows the active border.
- `#{num}` (node and header) is `refText(t)` (C7-T02; `—` for an unfiled row).
  Before C7-T02 lands it is `"#" + t.num` (no unfiled rows exist yet) and the
  queue part is `t.qpos == null ? "Q?" : "Q" + t.qpos`, the same text as
  C7-T02's `queueText`; C7-T02's source scan then forces the helpers.
- Every interpolated value goes through `esc`: the title (as J:1210), the id in
  `data-id`, the status text, and the ref. `--h` is the epic hue that the C3-T02
  validator restricts to a number; if `D.epics[colKey(t)]` is absent (a diff
  race), the `unsorted` epic's hue is used.
- Tree edges call C9-T07's `edgeClass(t, did)` (the J:905 rule with C4-T05's
  `dep_states` mapping, `unknown` → `""`, so the base `.bd-e`), without the
  `ghost` argument, which matches J:1206 (no `gh` branch).

### 10. Teardown

No `destroy()` of its own. Every listener is C9-T01's or C9-T03's (through
`ctx.life.on`); the hover clear and the Fit frames go through `ctx.life.later`
and `ctx.life.frame`; `ctx.life.dispose()` on `destroyed` removes them all.
`onReset` clears the module state on the next mount. The `#bd-tree` host is
inside the hook root, so LiveView removes it with the page.

## Implementation steps

1. **`chains.js`.** Port `chainOf` (section 2), `chainGaps` (section 4),
   `fitFrom` (section 6), `treeLayout` (section 3: J:1185–1201 arithmetic, the
   six constants, `per`, continuation rows, `sc`, the non-empty level count) and
   `treeStatus` (section 9). No DOM access, so it runs under `node --test`.
2. **`trees.js` handlers.** `onHover(e)` = J:941–948 plus the touch return
   (section 7) and the `hoverGen` clear (section 1). `onLeave()` = the J:619
   body (200 ms clear unless locked). `toggleLock(b)` = the J:628 body
   (lock / unlock / fit / tree). Register them, with the functions of step 3
   and 4, in `fx` at import time and add `import "./trees.js"` to `hook.js`
   (C9-T01 rule 2).
3. **`trees.js` state.** Port `setHover`, `lockTree`, `unlock`, `treeRange`
   verbatim, reading `chainOf(ctx.D, id)`, `ctx.hoverId`, `ctx.lockId`, `ctx.R`,
   `ctx.L`, `ctx.secs`, and the tab found as in section 1. `lockTree` adds
   `.show` only when it found an element (else `.locked` alone; Decision 13).
4. **`fitTree`** per section 6. **`openTree` / `closeTree`** per J:1183–1221
   using `treeLayout`, `treeStatus`, `edgeClass`, `refText`, the header rule of
   section 4, and section 8's attributes and focus.
5. **Lines changed in predecessor files** (each a one-line edit; nothing else in
   those files changes):
   - `build-home/render.js` (C9-T03 `viewport()`): the J:618 listener type
     `mouseover` → `pointerover`; the J:619 body → `fx.onLeave()`; the J:628
     body → `fx.toggleLock(b)`.
   - `build-home/render.js` (C9-T03 `update()`): after the create loop,
     `if (created && ctx.hoverId) fx.reapply()`.
   - `build-home/shell.js` (C9-T01 J:566 port): add `{ capture: true }` and
     `if (e.defaultPrevented || document.querySelector("#tk-backdrop.show")) return;`
     (section 8). These predecessor edits are made in this ticket's PR (R-G4).
   - `build-home/url.js` (C9-T01 URL bridge): when `trees` changes, call
     `fx.onTreesChanged(S.trees)`.
   - `#build-root` gets `data-bd-trees="ready"` when `trees.js` registers, the
     anchor C1-T03's `tree.*` sequences should wait for (interface note 9).
6. **Fixtures.**
   - The 2-cycle and the 3-cycle come from C4-T05's odd-edges fixture
     (PROPOSED `src/test/fixtures/build_home/odd_edges.json`); reuse its
     rows, do not redefine them.
   - PROPOSED `src/test/fixtures/build_home/chains.json`, added to `@datasets` in
     C3-T01's `fixture_source.ex`: the `live` fixture plus those cycle rows; a
     12-member chain over three history days in which exactly **4** members sit
     on a day outside the initial window and each of the 4 is a direct blocker
     of a loaded member (so `chainGaps.unloaded` is 4, not 1); a `not_planned`
     history member; a `now` member with `agent.state: null` and `pct: null`; a
     `plan` member with `qpos: null` and one with `wave: null`; and the C3-T02
     hostile title on a chain member. When C4-T05 has merged, one member gets
     `deps_missing: null`.
   - Two diff fixtures under `src/test/fixtures/build_home/diffs/`:
     `chain-add-dep.json` (adds a dep to a locked chain) and
     `chain-remove-root.json`.
   - A Node-only fixture, PROPOSED `src/browser/tests/fixtures/chains-d.mjs`,
     builds `D` objects directly for the cases the validator would reject or
     the payload cannot carry yet (self-loop, `end: null` on a history row, a
     20,000-member linear chain, `num: null`, `deps_missing: null`).
7. **npm scripts** in `src/browser/package.json`, appended to `test` (`:10`):
   `"test:build-home-chains-unit": "node --test tests/build-home-chains.test.mjs"`
   and `"test:build-home-chains": "npm run fixture:preflight && node
   scripts/run-browser-tests.mjs tests/build-home-chains.browser.spec.mjs"`.
8. **C1-T02 allowlist entries: `copy` kind only.** The new texts (section 4 and
   section 9) appear only on data the design cannot produce; each is one `copy`
   entry with status `pending-sign-off` citing S-34 (R-G6), so they pass in CI and
   fail only in C12-T08's `--gate` run until Kevin signs off. The state
   screenshots of the `chains` dataset are product-only baselines
   (`productOnly: true` in C1-T03 terms), listed for C12-T08's sign-off. C1-T03's
   `tree.*` sequences stop calling `test.fixme(true, 'awaiting MP-E8-C9-T11')`
   on their own once the anchor of step 5 exists; nothing is removed by hand.

## Non-happy paths

| # | Input | Expected | Test |
| --- | --- | --- | --- |
| N1 (EC-21) | 2-cycle A↔B, 3-cycle A→B→C→A, hover A | `chainOf` returns each member once and ends; depths equal the design's recursive `dep()`; 3-cycle header `3 tickets · 3 levels` (the design prints `4 levels`, defect 8) | U1, U2, B3 |
| N2 (EC-21) | self-loop A→A | chain `{A}`; no edge drawn; depth 0 | U3 |
| N3 (EC-21) | 20,000-member linear chain (above the 10,000-ticket index, so deeper than any real chain) | `chainOf` and `treeLayout` return without `RangeError` under Node's default stack | U4 |
| N4 (EC-21) | `D.children[A]` names an id not in `D.byId` | not in the chain; `openTree(A)` renders; header `… · 1 not on the board` | U5, B4 |
| N5 | `deps_missing: null` on a member | header ends `links not yet known`; never omits it, never prints `0` | U6, B4 |
| N6 | history member with `end: null` (Node only: C3-T02 keeps undated closed tickets out of `hist`) | `fitFrom` ignores it, so `fitTree` does not request days before the chain's oldest numeric `end`; node text `Merged · date unknown` | U7, U8 |
| N7 | `not_planned`, `state: null`, `pct: null`, `qpos: null`, `wave: null`, pack row | `Not planned`, `State unknown · —`, `Q? · W{wave}`, `Q{qpos} · W?`, `Not filed · W{wave}`; no `ag-*` class for the unknown state | U8, B5 |
| N8 | hostile title / id on a member | rendered as text; `window.__xss` undefined; no injected element | B5 |
| N9 | locked, then a diff adds a dep to the chain | lock kept; new member gets `hl`; tab still at the locked card | B7 |
| N10 | tree open, diff removes its root | tree closes; focus returns to `#bd-vp` (root card gone) | B8 |
| N11 | locked, scroll 3,000 px so new cards render | every new card in the window has `hl` or `hdim` | B9 |
| N12 | Fit clicked, then Unlock before the page reply | no relayout and no lock after the reply | B6 |
| N13 | Fit while paging fails (`/build-control/earlier?fail=1`) | fit runs on loaded data; lock kept; header shows C9-T03's error text | B6 |
| N14 (EC-18) | touch tap on a card with `?trees=1` | no `hl`/`hdim`/`.hovering`; the modal seam is called once | B10 |
| N15 (EC-18) | touch tap on an arrow at 390 px | locked; tab shows fit and eye; eye opens the overlay at `sc = 0.8`, horizontally scrollable | B10 |
| N16 | Escape with the modal open over the tree | only the modal closes; a second Escape closes the tree | B11 |
| N17 | `?trees=1` removed by Back while locked | unlocked; no hover | B12 |
| N18 | hook destroyed during a Fit (page reply pending, or between the two frames) or with the tree open | no `document` listener from the hook remains (count via a wrapped `addEventListener`), no relayout or `lockTree` runs after `destroyed`, no console error | B13 |
| N19 | `?trees` absent | `pointerover` on a card sets nothing | B1 |

Privacy and permissions: the page is read-only here. No write, no new data, no
new server call except C9-T03's existing `load-earlier`.

## Compatibility and rollout

- No config key, CLI flag, environment variable or migration. The page is behind
  the temporary `/build` route until C12-T01; rollback is reverting the files.
- `?trees=1` is the only new behaviour switch, and it already exists in the
  design URL grammar (C3-T03 parses it).
- Docs: none in this ticket. The surface is not user-reachable before C12-T01,
  which documents the home page (including `?trees=1`) in
  `website/docs-app/guide/`. Handoff note for C12-T01: document `?trees=1` and
  the arrow-tap lock.

## Pixel parity

**Design elements reproduced** (values from `build.css`; C2-T04 carries the
rules, this ticket must produce the DOM and classes that select them):

- `.bd-lt` C:661–670, 864–867, 1091–1092: `z-index 12`; column of 24×24 buttons,
  radius 6, gap 2px, `svg 13px`; final skin `background var(--bg-2)`, `1px solid
  var(--line-strong)`, no left border, radius `0 9px 9px 0`, `padding 2px 2px 2px
  1px`; hidden state `opacity 0; translateX(-6px)`; `.show` `opacity 1; none`;
  transition `opacity .16s, transform .2s cubic-bezier(.22,1,.36,1)`; `::before`
  hover zone `inset -18px -14px -18px -22px`; `fit` and `tree` buttons only with
  `.locked`; locked lock button `accent-ink` on `accent-soft`; hidden while
  `.bd-content.scrolling` unless locked. Light: `var(--surface)` (C:984).
  Position: `left = card.right − content.left − 1`, `top = card.top − content.top
  + max(0, h/2 − 14)`.
- Chain highlight: `.bd-card.hl .bd-in` accent border + `0 0 0 2px accent-soft`
  (C:276); band `.bd-now .bd-card.hl .bd-in` `accent-line` (C:671); `.hdim`
  final `opacity .4; filter blur(2.5px) saturate(.4)` (C:467), solid border and
  no shadow (C:408), `gplan` background (C:409); light `blur(2px) saturate(.6);
  opacity .45` (C:977); reduced motion `saturate(.4)` only (C:471);
  `.bd-content.hovering` blurs `.bd-lbl`, `.bd-mk`, `.bd-dl` 2px at `.5`
  (C:469) with `.2s` transitions (C:468); edges `.hl` 2.8 / 1 (C:187), `.fade` `.04`
  (C:470), `.bd-edges.hov .bd-e.hl.bl` solid (C:411).
- `.bd-tree` C:675–701, 955, 979–980, 1063: `inset 1px`, radius 15px,
  `color-mix(bg-2 45%)` (light 60%), `backdrop-filter blur(10px) saturate(.7)`,
  `bdTreeIn .22s ease-out` from `opacity 0`; header `.9rem 1.1rem`, title 700
  `.7rem` JetBrains Mono `.08em` uppercase; count `.72rem` muted; Close 30px,
  radius 8, `surface-3`, 600 `.74rem` Space Grotesk, icon 12px; scroller
  `8px 28px 28px`; `.bd-tn` radius 9, `inset 3px 0 0 oklch(.68 .14 var(--h))`,
  `.sel` accent + `0 0 0 3px accent-soft`, dashed for `plan`/`nq`, `ag-active`
  accent-line, `ag-stuck`/`failed` block-line; `.bd-tn1 i` 6×6 radius 2; `b` 600
  `.72rem` mono; title `.8rem` 550 ellipsis; `em` `.64rem` mono faint, indent
  `calc(6px + .4rem)`; Gruvbox `--sat .1`; reduced motion no animation (C:701).
- Layout numbers `NW 196, NH 50, GX 14, GY 44, GW 12, MIN .8`, `aw − 56`,
  `ah − 96`; timings 280 ms, 200 ms, two rAFs, instant scroll in Fit.

**How parity is checked (C1-T02 side-by-side runner, C1-T03 sequences).** Both
pages load the same dataset with frozen `NOW` and `TZ=America/Los_Angeles`, at
1440, 1024 and 390 px, dark and light, Gruvbox and default:

- **P1 hover:** `?trees=1`, `live`: hover the history or plan card with the
  largest `chainOf` on the `live` data (ties: the lowest number; the spec
  computes it from the fixture with `chains.js`, so the choice is fixed) → full-board screenshot and DOM
  state (`hl`, `hdim`, `.hovering`, `.bd-lt` class and inline `left/top`) equal.
- **P2 locked:** P1, then click the lock button → element screenshot of
  `.bd-lt` and full board equal.
- **P3 fit:** P2, then Fit → `span` in the URL, `scrollTop` within 1 px, zoom
  label text, and the board screenshot equal. The design pages synchronously,
  so the product waits for `data-bd-paging="idle"` and the lock.
- **P4 tree:** P2, then eye → element screenshot of `#bd-tree` after
  `settleAnimations`, and node `left/top/width/height` equal. On `dense` with a
  chain of more than `per` members, the wrap rows and `sc` are equal.
- **Motion (C1-T03):** `tree.overlay` (`bdTreeIn` .22s ease-out; hidden after
  Escape; none under reduce) passes, no longer `fixme`. Added sequences:
  `tree.tab` (the `.bd-lt` opacity/transform transition sampled at 0/50/100 %),
  `tree.hover-clear` (hover a card, move to empty content: classes still on at
  250 ms, gone at 300 ms; leave content: gone by 220 ms).
- **States the design lacks** (cycles, not-loaded members, unknown fields): the
  `chains` fixture's tree screenshots go to Kevin's DESIGN-E8 sign-off as
  `pending-sign-off` baselines (S-34). Any change to them is a failing check.

## Verification

**Node** (PROPOSED `src/browser/tests/build-home-chains.test.mjs`, `node --test`).
The test file keeps a verbatim copy of the design's recursive `chainOf` and
`dep()` as the oracle.

| Test | Input | Expected | Fails with (mutation) |
| --- | --- | --- | --- |
| U1 `chain order equals design` | every id of the five C1-T01 fixtures | `[...chainOf(D, id)]` deep-equals the oracle | drop the `[node, index]` frame and push all children at once (order changes) |
| U2 `cycles end, depths equal design` | 2-cycle, 3-cycle (odd-edges rows) | set sizes 2 and 3; `depth` equals the oracle; level count 2 and 3 | (a) remove `depth[x] = 0` before the visit (endless loop; the test has a 1 s timeout); (b) count levels as `rows.length` (3-cycle gives 4) |
| U3 `self-loop` | A→A | `{A}`, depth 0, no edge | remove the self-loop guard (edge from A to A) |
| U4 `long chain no stack overflow` | 20,000 linear | returns, size 20,000, deepest depth 19,999 | replace `walk` or the explicit-stack `dep()` with the recursive oracle (`RangeError: Maximum call stack size exceeded` at Node's default stack; the npm script passes no `--stack-size`) |
| U5 `children outside window` | child id not in `byId` | not in set; `chainGaps.unloaded === 1`; `treeLayout` does not throw | remove `D.byId[c]` from `walk` |
| U6 `missing unknown is not zero` | one member `deps_missing: null` | `chainGaps.missing === null`; header text contains `links not yet known` | `missing += m ?? 0` |
| U7 `fit ignores null end` | members with `end: [null, t1, t2]`, `t1 < t2` | `fitFrom(D, id) === midnight(t1)` (pure helper used by `fitTree`) | drop the `Number.isFinite` filter (returns 0) |
| U8 `status unknowns` | the N6 and N7 rows | the N6 and N7 texts; `cls` null for state null | (a) `progress` → `pct + "%"`; (b) `AST[s] \|\| AST.active`; (c) `"W" + t.wave`; (d) `"Q" + t.qpos`; (e) the design's `Merged` branch for `not_planned`; (f) `"Merged " + fmtD(t.end)` for `end: null` — each fails |
| U9 `null num sort` | two members `num: null` | stable order by id | remove `numKey` (`NaN` comparator order) |

**Browser** (PROPOSED `src/browser/tests/build-home-chains.browser.spec.mjs`,
dataset `chains` unless noted: `GET /build-fixture/chains`, then open `/build`, C3-T01):

| Test | Steps | Expected | Fails with (mutation) |
| --- | --- | --- | --- |
| B1 `hover needs trees=1` | no `trees`: hover a chain card | no `hl`, no `.hovering`, tab not `.show` | remove the `S.trees` guard |
| B2 `hover timings` | `?trees=1`: hover, move to empty content | classes kept at 250 ms, gone by 320 ms (frozen clock) | 280 → 0 |
| B3 `cycle tree` | `?trees=1`: hover the 3-cycle member A, lock, eye | header `#… · 3 tickets · 3 levels`; 3 `.bd-tn` | U2 (a): test times out; U2 (b): header says `4 levels` |
| B4 `honest header` | lock the 12-member chain, eye (no Fit) | header ends `· 4 not on the board`; second case (runs only when the payload carries `deps_missing`, else `test.fixme(true, 'awaiting MP-E8-C4-T05')`): with the `deps_missing: null` member, ends `links not yet known` | (a) drop `chainGaps` from the header; (b) count unloaded ids with repeats or count only `deps` |
| B5 `node text and escape` | open the tree with the N7 and N8 members | N7 texts; `window.__xss` undefined; `.bd-tn` has no `img` | `esc` removed from the status or id |
| B6 `fit pages, then locks` | lock the 12-member chain, Fit | one or more `load-earlier` requests; after idle, URL `span` set, the oldest member rendered and inside the viewport, still locked; N12 and N13 variants | write `S.histFrom` directly (oldest member not rendered) |
| B7 `live keeps lock` | lock, `/build-control/diff?name=chain-add-dep` | lock kept; new member `hl`; tab `left/top` equals the locked card's computed position | drop `reapply` from the live pass |
| B8 `root removed closes tree` | open tree, `diff?name=chain-remove-root` | `#bd-tree[hidden]`; `document.activeElement` is `#bd-vp` | skip the focus restore |
| B9 `new cards get chain classes` | lock on `dense`, scroll 3,000 px | every `.bd-card` overlapping the viewport has `hl` or `hdim` | remove the step-5 `fx.reapply()` line in `update()` |
| B10 `touch` | context `hasTouch: true, isMobile: true`, 390 px: tap a card; tap an arrow; tap eye | N14, N15 | listen on `mouseover` again (tap sets `hl`) |
| B11 `escape order` | open tree; open a node (C11-T01's modal if merged, else a test stub that adds `#tk-backdrop.show` and a bubble-phase Escape listener that removes it, registered **before** the hook mounts); Escape twice | first closes only the modal, tree still open; second closes the tree | (a) remove the `#tk-backdrop.show` check; (b) drop `capture: true` (the stub's earlier listener removes `.show` first, so the tree also closes) |
| B12 `trees off by Back` | `?trees=1`, lock, `history.back()` to no `trees` | unlocked, no `.hovering` | remove `onTreesChanged` |
| B13 `teardown` | lock, Fit with `/build-control/earlier?delay=500`, then `live_redirect` away before the reply; and a second run that navigates between the two frames | no `document` listener from the hook remains; a spy on `fx.relayout` and `fx.lockTree` records no call after `destroyed`; no console error | (a) drop the `isConnected` check (relayout runs on a detached root); (b) use a bare `requestAnimationFrame` instead of `ctx.life.frame` |
| B14 `axe while locked and with tree open` | lock; open tree | `AxeBuilder` violations `[]`; the overlay has `role=dialog` with name "Dependency tree"; focus on Close; Tab wraps | remove the `role`/label attributes |

Commands:

```bash
env -C src/browser npm run test:build-home-chains-unit
env -C src/browser npm run test:build-home-chains
env -C src/browser npm run test:design-parity     # C1-T02 runner with P1–P4
env -C src/browser npm run test:build-home-motion  # C1-T03 tree.* sequences
```

**Mutation check (AGENTS.md).** For each row with a mutation: in a worktree,
apply only that hunk, confirm `git status --porcelain` shows only that file,
run the test, see it fail, restore, see it pass. Record each command in the PR
body ("U6 fails with `missing += m ?? 0`").

**Manual.** `scripts/aiurdev --test` with the wrapper-tmux recipe is not the
check for this ticket (no TUI change). Request `/build-fixture/chains`, open
`/build?trees=1` in the fixture server and in a phone-width browser; hover, lock, Fit, eye, Escape.

## Completion and handoff

- [ ] `chainOf`, `treeLayout`, `treeStatus`, `chainGaps` in `chains.js`;
      U1–U9 pass and each fails under its mutation.
- [ ] Hover, lock, unlock, Fit, tree open and close ported with the design's
      names, constants, timings, strings and classes.
- [ ] Hover only with `?trees=1`; touch never hovers; arrow tap locks.
- [ ] No walk recurses; cycles, self-loops and not-loaded members are safe.
- [ ] Unknown state, progress, wave, merge date, and unknown chain links never
      render as a value; each has a passing mutation test.
- [ ] Live diffs keep the lock, the highlight and the open tree; new cards get
      the chain classes.
- [ ] No bare listener, timer or frame; nothing runs after `destroyed`.
- [ ] P1–P4 parity green; C1-T03 `tree.*` no longer `fixme`; only `copy`
      allowlist entries (`pending-sign-off`, S-34) added for the new texts.
- [ ] B1–B14 green; both npm scripts in the `test` chain.
- **Dependents.** C9-T12 (list view uses `chainGaps` semantics for `deps_missing`
  if it wants them), C12-T05 (keyboard path to a chain lock, focus rings on
  `.bd-lt` and `.bd-tn`), C12-T06 (re-measures hover on 10,000 tickets),
  C12-T08 (sign-off of the three `copy` entries and the state screenshots),
  C12-T01 (docs for `?trees=1`).
- **Docs.** None here (see "Compatibility and rollout").
- **Sources.** `tickets/README.md` rows C9-T03, C9-T07, C9-T10, C9-T11 and
  rules; `chunks.md` C9; `plan.md` §8 (EC-08, EC-18, EC-21), §10 item 6;
  `DESIGN-E8.md` S-3, S-17; `MP-E8-C9-T03.md` (live mode, `ensureFrom`,
  interface note 5); `MP-E8-C4-T05.md` (cycles, `dep_states`, the `dn` check);
  `MP-E8-C8-T01.md` (`agentState`, `progress`); `MP-E8-C7-T02.md`
  (`refText`, `queueText`, source scan); `MP-E8-C1-T03.md` (`tree.overlay`,
  anchors, `fixme`); `MP-E8-C9-T01.md` (module table, `fx`, `onReset`,
  `ctx.life`, `shell()` listeners); `MP-E8-C3-T01.md` (`/build-fixture`,
  `@datasets`); `MP-E8-C1-T02.md` (allowlist kinds); `MP-E8-C11-T01.md`
  (Escape, Decision 7); `MP-E8-C12-T08.md` (copy sign-off, schema drift);
  J and C lines cited above; product paths in "Verified starting point".

## Interface notes (mismatches with neighbour rows)

1. **C9-T10 is a missing predecessor.** C9-T10's row says `fitTree` uses its
   controls; C9-T11's row lists only C9-T07. `SPANS` itself comes from C9-T01's
   `state.js`; what this ticket needs from C9-T10 is the `--dot` line (J:654)
   and the zoom label that P3 compares. Added to `blocked_by`. No delay:
   C9-T10 needs only C9-T02.
2. **C8-T01 is a missing predecessor.** It ships `now-state.js` and lists C9-T11
   as a caller, but no C9 row depends on it. Added to `blocked_by`.
3. **C9-T03 owns the `viewport()` listeners and the `.bd-lt` tray** (its scope:
   J:618–635). This ticket does not port them again. It changes four lines in
   `render.js` (step 5): `pointerover`, `fx.onLeave()`, `fx.toggleLock(b)`, and
   the `fx.reapply()` call at the end of `update()` (design defect 4), which
   C9-T03's interface table does not list. Settled 2026-10-08: this ticket
   makes these `render.js` edits and registers `onLeave`, `toggleLock`,
   `reapply` and `setHover` in its own PR (R-G2, R-G4).
4. **C9-T07** exports `edgeClass(t, did, ghost = false)`; this ticket calls it
   without `ghost` (J:1206). Settled 2026-10-08: C9-T07 drops the
   `ctx.tree.hoverId()` branch and reads `ctx.hoverId`; this ticket keeps
   `hoverId` in `ctx` (C9-T01) and sets no `ctx.tree`.
5. **C9-T01 owns the `document` click and Escape listeners** (J:561–566 in
   `shell.js`). This ticket changes the Escape line only: `{ capture: true }`
   and the `#tk-backdrop.show` / `defaultPrevented` return (defect 5).
   Settled 2026-10-08: C11-T01's Escape calls `preventDefault()` so one Escape
   closes only the modal; this ticket's shell.js edit is made in its PR (R-G4).
6. **C9-T08** calls `fx.setHover(null)` in `markScrolling` (J:576). This ticket
   reads the scrolling state from the `.bd-content.scrolling` class, so C9-T08
   needs no new export.
7. **C7-T02** patches J:1210/1212/1214 if it lands first; if C9-T11 lands first,
   it uses `"#" + t.num` and the `Q?` guard of section 9, and C7-T02's source
   scan converts them.
8. **`deps_missing`.** Settled 2026-10-08: C4-T05 adds it to C3-T02 as an
   additive field (R-G1). Until C4-T05 merges, `missing` is `0`, the "links not
   yet known" branch is unreachable in the product (U6 covers it in Node), and
   B4's second case is `fixme` naming C4-T05.
9. **C1-T03's `tree.*` anchor.** Settled 2026-10-08: C1-T03 anchors `tree.*` on
   `#build-root[data-bd-trees="ready"]`, which this ticket sets (step 5).
10. **C1-T02 allowlist kinds.** Settled 2026-10-08: C1-T02 accepts the `copy`
    kind with a status (R-G6); this ticket's new texts are `copy` entries,
    `pending-sign-off`, S-34 (step 8).
11. **C4-T05's odd-edges fixture.** Settled 2026-10-08: it lives at
    `src/test/fixtures/build_home/odd_edges.json` with the other build-home
    fixtures.

## Decisions made without the owner

1. **S-3 default followed:** hover needs `?trees=1`, no visible control. The
   dead `#bd-trees` handler is not ported.
2. **Arrow click and tap lock without `?trees=1`**, as the design does (J:626).
   This is also the only touch path to the chain and the tree overlay.
3. **`pointerover` with a touch filter** replaces `mouseover`, so a tap never
   leaves a chain highlight behind the modal. Mouse behaviour is unchanged.
4. **Chain walks skip tickets that are not loaded,** and the tree header says
   how many (`{k} not on the board`) or that links are not yet known. The
   alternative, paging until the chain is complete, is unbounded at 10,000
   tickets. New copy (S-34); `copy` allowlist entries, signed off through C12-T08.
5. **Explicit-stack walks** with the design's visiting order, so results equal
   the design and a long chain cannot overflow a phone WebView's stack.
6. **Unknown node text**: `Not planned`, `Merged · date unknown`,
   `State unknown · —`, `Q?` (C7-T02's text), `W?` (the same convention) and
   `Closed` (R-G11). New copy (S-34), signed off through C12-T08.
7. **Live behaviour the design does not have:** the lock, the highlight and an
   open tree survive diffs; a removed root closes the tree.
8. **Locked cards created by scrolling get the chain classes** (design defect 4).
   Visible only when locked and scrolled, which no P-sequence does, so no
   allowlist entry; listed for Kevin's sign-off in C12-T08.
9. **One Escape closes one layer** (modal before tree), against the design's
   close-both (H:5106 with J:566). Done in the tree's own listener (capture
   phase, plus the `defaultPrevented` check that C11-T01's `preventDefault()`
   sets).
10. **Dialog semantics, focus move and restore, Tab wrap** on the tree overlay,
    and `aria-pressed` on the lock button. No pixel change; C12-T05 owns focus
    rings (S-12).
11. **No keyboard path to start a lock** in this ticket; C12-T05 decides it with
    S-12. The list view (C9-T12) is the keyboard view of dependencies.
12. **Extra predecessors C9-T10 and C8-T01** added to `blocked_by` (interface
    notes 1, 2).
13. **`lockTree` shows the tab only when it found the card.** The design adds
    `.show` even when the locked card is not rendered (J:971), which leaves the
    tab floating at its last position. With paged data that happens; the
    design's own data never reaches it.
14. **Tree level count skips empty depth slots** (defect 8). Equal to the
    design on acyclic data; on a cycle it reports the levels actually drawn.
15. **State stays in C9-T01's `ctx` and listeners stay in C9-T01/C9-T03.** The
    first draft moved `hoverId`/`lockId` into a `createTree(ctx)` closure with
    its own listeners and `destroy()`. That would duplicate two predecessor
    ports and break C9-T01's `shell.js` reads of `ctx.lockId`.

## Review log

Adversarial review, 2026-10-08 (sources re-read: J, C, H, product files at
`58854d4c8`, README rows, C1-T02, C1-T03, C3-T01, C3-T02, C4-T05, C7-T02,
C8-T01, C9-T01, C9-T03, C9-T07, C9-T08, C9-T10, C11-T01, C12-T08).

1. Module shape rewritten to C9-T01's rules: `trees.js` (C9-T01's name, not
   `tree.js`) registers in `fx`, uses `onReset` and `ctx.life`; state stays in
   `ctx.hoverId`/`ctx.lockId`. Dropped `createTree(ctx)`, `mountViewport`,
   `destroy()` and the second copy of the J:561–566 and J:618–635 listeners,
   which C9-T01 and C9-T03 already port.
2. Step 5 now lists the exact predecessor lines changed (render.js ×4,
   shell.js ×1, url.js ×1, root attribute).
3. Escape fix moved off a C11-T01 `preventDefault()` request (C11-T01 Decision 7
   refuses it) to a capture-phase listener with the `#tk-backdrop.show` check;
   B11 gets a stub registered before the hook and a second mutation.
4. Found design defect 8 (empty depth slots on a cycle make the header say
   `4 levels` for a 3-cycle); B3's `3 levels` expectation was not what a
   verbatim port prints. Added the fix, Decision 14 and a U2 mutation.
5. Unknown queue text aligned with C7-T02's `queueText` (`Q?`, not
   `Queue unknown`); wave uses `W?`. N7/U8 updated, U8 gains `qpos` and
   `end: null` mutations.
6. Allowlist step replaced: C1-T02 has no `copy` kind (C12-T08 flags it), and
   the new texts never appear on design data. C1-T03 `fixme` handling corrected
   (it is anchor driven, not removed by hand); anchor problem raised as
   interface note 9.
7. Fixture route corrected to `GET /build-fixture/chains` + `/build` with
   `chains` added to C3-T01's `@datasets`; cycles reused from C4-T05's
   odd-edges fixture; the 12-member chain now defines why the count is 4.
8. U4 was vacuous as scripted (`--stack-size=500` is not in the npm script and
   5,000 frames may not overflow): now 20,000 members at the default stack.
9. N6 marked Node-only (C3-T02 keeps undated rows out of `hist`); B4's
   `deps_missing` case is `fixme` until C4-T05; `fitFrom` added to `chains.js`.
10. Fit after `destroyed`: added the `isConnected` stop and B13 mutations;
    hover timer uses `ctx.life.later` with a generation check.
11. Focus restore checks that the saved element is rendered (the eye button is
    `display: none` after an unlock), so B8's `#bd-vp` expectation holds.
12. Scrolling read from `.bd-content.scrolling` instead of a new C9-T08
    `isScrolling()` export.
13. P1's card choice made deterministic; parity command corrected to
    `test:design-parity` (`test:parity` is an existing unrelated spec).
14. Citations fixed: `SPANS` J:302 (not J:301); edge class rule J:905 (J:906 is
    `hl`/`fade`); `lockTree` J:967–972, `unlock` J:973, `setHover` J:974–985;
    content click J:624–635; `renderTools` J:1128–1150; edge `.hl` C:187;
    `fixture_server.exs:2264`; `fitTree` only moves `histFrom` back (J:959).
- Reconciliation 2026-10-08 (coordinator): C9-T07 reads `ctx.hoverId` only (no `ctx.tree.hoverId()` branch), new copy = S-34 as `copy` allowlist entries with `pending-sign-off` (R-G6), `closed` reads "Closed" in tree nodes (R-G11), Escape also honours C11-T01's `preventDefault()`, odd-edges fixture path `src/test/fixtures/build_home/`, predecessor edits made in this PR (R-G4), interface notes 3/4/5/8/9/10/11 settled.
