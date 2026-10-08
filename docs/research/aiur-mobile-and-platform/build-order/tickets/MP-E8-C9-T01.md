---
ticket_id: MP-E8-C9-T01
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: Hook shell, scrollbar, payload intake, URL bridge
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C3-T02, MP-E8-C3-T03, MP-E8-C2-T04]
complexity: 4
design_gate: DESIGN-E8
owns_edge_cases: [EC-11]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T01 — Hook shell, scrollbar, payload intake, URL bridge

> **Wave 0b.** Paths are cited at `58854d4c8`. Paths marked PROPOSED do not exist
> yet. `J` = `design-source/assets/build.js`, `C` = `design-source/assets/build.css`,
> `H` = `design-source/Aiur Dashboard.html`. This ticket is the root of C9: it
> fixes the module layout that the other twelve C9 tickets, C10 and C11 fill in.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C9 (client timeline
  engine, the port of `build.js`).
- **User value.** The home page boots from real server data, not from a timer and
  mock data. It stays correct across reconnects and missed messages. Its overlay
  scrollbar looks and moves exactly as in the design. Every filter or view change
  is in the address bar, so a link reproduces the view.
- **Deliverables.**
  1. The body of PROPOSED `src/priv/static/build-home/hook.js` (C2-T03 ships a
     stub with the export `createBuildHomeHook`). It owns the hook lifecycle:
     `mounted`, `updated`, `disconnected`, `reconnected`, `destroyed`.
  2. Eight new ES modules under PROPOSED `src/priv/static/build-home/`: `state.js`,
     `life.js`, `clock.js`, `dom.js`, `icons.js`, `shell.js`, `store.js`, `url.js`
     (see "Module layout"; `protocol.js` is C3-T02's).
  3. The port of `shell()` (J:543–573): it wires the server-rendered hosts, the
     overlay scrollbar `#bd-sb` (track click, thumb drag, `.act`/`.drag`/`.off`),
     the document Escape and outside-click handlers, the 250 ms scroll poller and
     the 140 ms resize handler. Every listener, interval, timer, frame and
     observer is removed on `destroyed`.
  4. Payload intake: the `build-resync` request on mount and reconnect, the
     `build-diff` handler, both run through C3-T02's `decide`/`intake`; diff
     application; the payload clock that replaces the design's `NOW` constant.
  5. The client side of the C3-T03 URL bridge (`build:url` both ways), in place
     of `readURL`/`writeURL` (J:304–328).
  6. A browser spec and an ExUnit source scan (see Verification).
- **Non-goals.**
  - No board drawing: layout (C9-T02), `update`/`relayout`/`place` (C9-T03),
    columns (C9-T04), cards (C9-T05), agents (C9-T06), edges (C9-T07), the now
    band and its snap, `markScrolling`, `scrollVP`, `jumpNow` (C9-T08), Gantt
    (C9-T09), span and zoom (C9-T10), trees and locks (C9-T11), the list (C9-T12),
    loading, empty and stale states (C9-T13).
  - No toolbar, filters, feature header or usage strip (C10). No modal (C11). No
    offline banner or "Reconnect" button (C8-T03 client side, C9-T13).
  - No server code. `build-resync`, `load-earlier` and `build-diff` are C3-T02's;
    `build:url` and `data-url-state` are C3-T03's; `data-build-state` is C3-T01's.
  - No CSS. C2-T04 ports every `.bd-sb`, `.bd-vpw` and `.bd-vp` rule. This ticket
    adds no rule and edits no ported line.

## Dependencies and blockers

- **Blocked by DESIGN-E8** (feature gate).
- **Predecessors (row):**
  - **C3-T02** — the payload schema v1, `decide(state, msg)` and
    `intake(snapshot)` in `build-home/protocol.js`, the events `build-resync`
    (reply = snapshot), `load-earlier` (reply = page) and the push `build-diff`,
    the epoch and generation rules, `data-build-epoch` read by its reconnect test.
  - **C3-T03** — `data-url-state` on `#build-root` (JSON of `URLState.t()`), the
    hook → server event `build:url` (flat string map), the server → hook push
    `build:url` `%{state: state}`, no echo.
  - **C2-T04** — the consolidated stylesheet `build-home/home.css` with the
    `.bd-sb`, `.bd-vpw`, `.bd-vp` rules, and its computed-style spec
    `home-css-parity.browser.spec.mjs` (`npm run test:home-css`); parity depends
    on it.
- **Transitive:** C3-T01 (BuildLive, the dead-render shell and skeleton inside
  `#build-root`, `data-build-state`/`data-build-reason`, fixture routes
  `/build-fixture/:dataset`); C2-T03 (`build-home/` directory, `loader.js`, the
  `BuildHome` hook name, the health attribute `data-build-home-hook`); C1-T02 and
  C1-T03 (parity harness).
- **C3-T01 handoff, taken on here.** C3-T01 asks C9-T01 to read
  `data-build-state`/`data-build-reason` in `mounted`/`updated`, to render
  `unavailable` without a spinner, to keep the server skeleton until the
  first payload instead of the design's 600 ms timer, to **write the
  hook-owned `data-*` again in `updated()`** (LiveView removes every `data-*` on
  the ignored root that the server did not render, on every patch; C3-T01
  "Non-happy paths" and its guard test B6), and to turn C3-T01's B4 loading-frame
  cell on `#bd-vp` into a pass/fail check (C3-T01 "Completion and handoff").
  This ticket does all four.
- **Snapshot transport (checked 2026-10-08).** The writer reported a mismatch
  (C3-T01 "pushes with `push_event`" against C3-T02 "the hook asks with
  `build-resync`"). The current C3-T01 file says C3-T02 decides the transport and
  that its design answers a `build-resync` event with a reply (C3-T01 step 2);
  `push_event` appears only as a C3-T01 non-goal. C3-T02 "Transport" is the
  contract: the hook asks in `mounted`/`reconnected`, the reply is the snapshot,
  and there is no initial push. `data-build-state="ready"` is set by C3-T01's own
  mount read, independently of the reply, which is why `ready` alone does not
  end loading here.
- **Successors:** every other C9 ticket (T02, T12 directly), C10-T01, and through
  them C10, C11 and C8-T03's client side. They add modules to the layout below.
- **May run concurrently with:** C4–C8 (server), C10/C11 writers who read this
  ticket's layout but merge after it.
- **Owner questions.** None block this ticket. S-9 (unavailable copy) is C9-T13's;
  this ticket ships the minimal unavailable pill that C9-T13 may restyle (see
  Decisions).

## Verified starting point (`58854d4c8`)

**Product (read-only, `/home/everdred/github/everdred/aiur-worktrees/runtime/src`).**

- `lib/aiur_web/components/layouts.ex:35-45` — the `<script defer>` list (`:38`
  the DOM-SVG loader); `:54` `var Hooks = {};`; `:252-254` the loader-style
  registration `Hooks.DomSvgLayout = window.AiurDomSvgLayout.createLiveViewHook()`;
  `:272-287` the `LiveSocket` with `time_zone` in connect params (`:276`) and
  `window.liveSocket = liveSocket` (`:287`). C2-T03 adds the `BuildHome` line in
  this same pattern; this ticket does not edit `layouts.ex`.
- `priv/static/aiur-dom-svg-layout-loader.js:20-55` — the loader precedent:
  dynamic `import()`, a `__…Destroyed` flag so a destroy before the import
  resolves creates nothing, and forwarding of `beforeUpdate`/`updated`/`destroyed`.
  C2-T03's `loader.js` copies it and also forwards `disconnected`/`reconnected`.
- `priv/static/build-order-grid-hook.js:71-78` (`ResizeObserver` plus window
  `resize`), `:109-112` (`destroy` disconnects both), `:478-489` (hook object with
  `mounted`/`updated`/`destroyed`) — the house cleanup pattern. No product hook
  today uses `handleEvent` (`grep -rn "handleEvent(" priv/static` finds none).
- **LiveView 1.1.33** (`mix.lock`), client file
  `deps/phoenix_live_view/priv/static/phoenix_live_view.js`:
  - `:4092-4106` `pushEvent(event, payload, onReply)`: without `onReply` it
    returns a Promise of the reply; with it, errors are swallowed.
  - `:5421-5430` `pushHookEvent` **rejects** with "unable to push hook event.
    LiveView not connected" when the view is not connected.
  - `:5162-5226` `pushWithReply`: a push that was already sent when the socket
    drops is neither resolved nor rejected until its `PUSH_TIMEOUT` (`:146`,
    30 s) fires `timeout` (`:5216-5224`). So a `build-resync` in flight at a
    disconnect can still be pending when `reconnected` runs (see `resync()`).
  - `:4131-4149` `handleEvent` adds a `window` listener `phx:<event>` and returns
    a ref; `removeHandleEvent(ref)`. `:4162-4166` `__cleanup__` removes them all,
    and `:4933-4934` calls it after `destroyed`. So `handleEvent` listeners need no
    manual cleanup; DOM listeners the hook adds itself do.
  - `:5271-5306` `putRef`: every hook `pushEvent` sets `data-phx-ref-loading`,
    `data-phx-ref-lock` and the class `phx-hook-loading` on the hook element
    (`#build-root`) until the reply. No stylesheet styles `phx-hook-loading`
    (`grep` of `dashboard.css` and `C`), so no pixel changes, but DOM-class
    comparisons see it (see Non-happy paths).
  - `:3995-3997`, `:4074-4087` — `__reconnected`/`__disconnected` hook callbacks
    exist; the hook instance survives a rejoin when its element survives
    (`phx-update="ignore"`).
- `browser/tests/support/browser-helpers.mjs:121-126` `reconnectLiveView` waits on
  `#worker-status[data-live-status]`, which `/build` does not render. Tests here
  disconnect and connect through `window.liveSocket` directly.
- `browser/package.json` — one npm script per spec, chained in `"test"`.

**Design (the specification).**

- `shell()` J:543–573:
  - J:544–551 writes `root.innerHTML`: `#bd-usage`, `#bd-offline`, `#bd-fh`,
    `.bd-toolbar` › `#bd-tools-l`, `#bd-filters`, `#bd-tools`; `.bd-vpw` ›
    `#bd-vp`, `#bd-sb` › `i`, `#bd-tree[hidden]`; `#bd-status`. C3-T01's dead
    render has the same nodes in the same order, with the loading skeleton inside
    `#bd-vp`.
  - J:554 `syncSB`: if `scrollHeight <= clientHeight + 1` add `.off` and stop;
    else remove `.off`; thumb height `max(28, track * clientHeight / scrollHeight)`
    px; `transform: translateY(min(1, scrollTop / (sh − ch)) * (track − h) px)`.
  - J:555 on `#bd-vp` scroll: `syncSB`, add `.act`, remove it 700 ms after the
    last scroll (one timer, restarted).
  - J:556 `ResizeObserver(syncSB)` on `#bd-vp` and `setInterval(syncSB, 500)`.
  - J:557–558 thumb `pointerdown`: `preventDefault`, `setPointerCapture`, add
    `.drag`; `pointermove` sets `scrollTop = s0 + dy * k` with
    `k = (sh − ch) / max(1, track − thumb)`; `pointerup` removes `.drag` and both
    listeners. There is no `pointercancel` handler.
  - J:559 track `pointerdown` (target is the track itself): jump,
    `scrollTop = (clientY − top) / height * (sh − ch)`, not smooth.
  - J:560 `root.classList.toggle("rm", prefers-reduced-motion)` once.
  - J:561–565 document click: unlock a locked tree unless the target is detached,
    inside `.bd-lt, .bd-tree, .bd-eh, #tk-backdrop`, or a card in the locked chain.
  - J:566 document Escape: close the tree overlay if it is open, else unlock.
  - J:567 `#bd-vp` scroll: `liveGuard(); markScrolling();` and one rAF `update()`.
  - J:568–569 a 250 ms poller: if not loading, a layout exists, the root is
    visible and `scrollTop` changed, `update()`.
  - J:570 document click outside `.bd-pop`/`.bd-fg` closes the filter popover.
  - J:571–572 window resize, 140 ms debounce: keep the scroll fraction
    `scrollTop / scrollHeight`, `relayout()`, restore, `update()`.
- `readURL`/`writeURL` J:304–328; `S` J:303 (`demo`, `models`, `example` are mock).
- Boot J:1550–1574: `init()` (`readURL`, `shell`, `dataFor`, usage popover, modal
  observer), `render()` → `renderAll()` → after **600 ms** `S.loading = false;
  viewport(); relayout(); jumpNow(true); S.ready = true;` then one rAF opens
  `?ticket=`. `renderAll` J:1265–1269 renders usage, offline, features, filters,
  tools, then the loading frame or `viewport(); relayout()`.
- `NOW` (J:11) is read outside `dataFor` at J:349 (`featStats`, C10-T03), J:427
  and J:435 (`ganttHist`, C9-T09), J:665 (band time, C9-T08), J:1308 (modal,
  C11), J:1415 (chat clock, C11).
- `esc` J:9 escapes `& < > "` only.
- **CSS to match exactly** (C2-T04 ports it; this ticket's DOM must hit it):

  | Selector | Values |
  | --- | --- |
  | `.bd-vpw` C:674, 953, 1119–1120 | `position: relative`; `border-radius: 16px; padding: 1px`; gradient `color-mix(fg 13%, bg)` → `color-mix(fg 4%, bg) 80%`; `--board-bg: var(--surface-2)` (light `var(--bg-2)`) |
  | `.bd-vp` C:166, 351, 944–945, 954 | `height: min(76vh, 860px)`; `overflow-x: hidden; overflow-y: auto`; `scrollbar-width: none`; WebKit scrollbar hidden; `border: 0; border-radius: 15px` |
  | `.bd-sb` C:946–947 | `position: absolute; top: 50px; right: 3px; bottom: 6px; width: 10px; z-index: 15; border-radius: 6px`; `.off` → `display: none` |
  | `.bd-sb i` C:948, 985 | `left/right: 3px; top: 0; border-radius: 4px`; `background: color-mix(in srgb, var(--fg) 22%, transparent)` (light 18%); `transition: left .12s, right .12s, background .12s`; `cursor: grab` |
  | `.bd-sb:hover i, .act i, .drag i` C:949–950 | `left/right: 2px`; background `fg 38%`; `.drag i` → `cursor: grabbing` |
  | `.bd-root.rm …` C:231, 297–298, 324, 391, 401, 471, 701, 721 | the static equivalents; this ticket only sets the class |

## Chosen design

### Module layout (fixed here)

All files live in PROPOSED `src/priv/static/build-home/`, are ES modules served by
C2-T03's directory entry, and import each other with relative paths. `hook.js` is
the only module the loader imports.

| File | Owner | Exports |
| --- | --- | --- |
| `loader.js`, `logos.js` | C2-T03 | (classic loader), `LOGOS` |
| `protocol.js` | C3-T02 | `decide`, `intake` |
| `hook.js` | **C9-T01** | `createBuildHomeHook` (keeps the C2-T03 export and health attribute) |
| `state.js` | **C9-T01** | `S`, `ctx`, `fx`, `onReset(fn)`, `resetState(urlState)`, constants `SPANS`, `FKEYS`, `LH = 46`, `SEC = 36`, `rmOn`, `gutW`, `isVisible` |
| `life.js` | **C9-T01** | `createLife()` |
| `clock.js` | **C9-T01** | `setNow(ms)`, `nowMs()` |
| `dom.js` | **C9-T01** | `$`, `$$`, `esc` |
| `icons.js` | **C9-T01** | `I` (the design's icon table, J:32–73, verbatim; C10-T04 and others import it) |
| `shell.js` | **C9-T01** | `shell()`, `syncSB()` |
| `store.js` | **C9-T01** | `acceptSnapshot`, `applyDiff`, `mergeEarlier` |
| `url.js` | **C9-T01** | `fromServer(state)`, `writeURL(extra)`, `flushURL()` |
| `layout.js` | C9-T02 | `computeLayout` |
| `render.js` | C9-T03 | `viewport`, `relayout`, `update`, `place` |
| `history.js` | C9-T03 | `loadEarlier` (returns the in-flight promise when a page is loading), `ensureDays`, `ensureFrom` |
| `columns.js` | C9-T04 | `visibleCols`, `applyCols` |
| `cards.js` | C9-T05 | `makeCard`, `decorate`, `cardDetail` |
| `agents.js` | C9-T06 | agent indicator helpers |
| `edges.js` | C9-T07 | `drawEdges`, `drawEdgesSoon` |
| `band.js` | C9-T08 | `liveGuard`, `snapLive`, `scrollVP`, `jumpNow`, `markScrolling` |
| `gantt.js` | C9-T09 | `ganttHist`, `assignLanes` |
| `span.js` | C9-T10 | `setSpan`, `calNear` |
| `trees.js` | C9-T11 | `chainOf`, `lockTree`, `unlock`, `fitTree`, `openTree`, `closeTree` |
| `list.js` | C9-T12 | `renderList` |
| `states.js` | C9-T13 | `renderLoading`, `renderUnavailable`, empty markers |
| `tools.js`, `filters.js`, `features.js`, `usage.js` | C10-T01..T04 | `renderTools`, `renderFilters`/`filtersChanged`, `renderFeatures`, `renderUsage` |
| `offline.js` | C8-T03 (client) | `renderOffline` |
| `modal/*.js` | C11 | `openModal`, `openFromURL`, … |

**Why a function table (`fx`).** The design is one closure whose functions call
each other in cycles (`shell` → `update` → `place` → `drawEdgesSoon` → …). Split
into files that land in different PRs, a direct import of a file that does not
exist yet would fail to load. So `state.js` exports one object `fx` with a
no-op default for each cross-module call that `hook.js` and `shell.js` make:

```js
// state.js — a later module replaces its entries at import time: Object.assign(fx, { update, relayout })
export const fx = {
  viewport() {}, relayout() {}, update() {}, jumpNow() {}, liveGuard() {}, markScrolling() {},
  unlock() {}, closeTree() {}, chainOf: () => new Set(), renderFilters() {},
  renderUsage() {}, renderOffline() {}, renderFeatures() {}, renderTools() {},
  renderLoading() {}, renderUnavailable: defaultUnavailable, dataChanged: defaultDataChanged,
  drawEdgesSoon() {}, openFromURL() {}
}
```

`drawEdgesSoon` is in the defaults because the diff path calls it (C9-T07
request: `soon(30)` after every applied diff, as J:1546 does after a refresh).
C9-T04 then does not need to add it.

Rules for later tickets:
1. A module imports what it needs directly when the file already exists in
   `main` (for example `cards.js` imports `esc` from `dom.js`). It goes through
   `fx` only for a call into a module that may land later.
2. A module registers itself with one line in `hook.js` (`import "./cards.js"`),
   so parallel PRs conflict on one line at most.
3. Module-level state is reset on every mount: a module that keeps state calls
   `onReset(() => { … })` at import time. **ES modules are cached per page**, so a
   LiveView navigation away from `/build` and back runs `mounted` again on the
   same module instances. Without the reset, the second mount would see the first
   mount's `S`, `D` and maps.
4. A module that adds a listener, timer, frame or observer uses `ctx.life`, never
   a bare `addEventListener`/`setInterval`.
5. A later ticket that needs an `fx` entry whose owner has not merged adds the
   no-op default to this table in its own PR; the owner replaces it (R-G2).
   Later tickets that need small edits in this ticket's modules make them in
   their own PRs (R-G4): C10-T01 (`renderTools` at mount, the `onServerURL`
   view handling), C9-T03 (export `renderChrome`, `fx.flushLive`) and C9-T13
   (`writeOwnData`).

### `state.js`

- `S` is the design's `S` (J:303) without the mock keys `demo` and `models`:
  `{ view, span, feature, fmode, f: { type, model, feature, epic, tstate, astate },
  pop, loading, ready, flow, K, density, trees, liveMin, ticket }`. `f.type` stays
  because the design keeps it in `S` (the type filter is absent, OQ-E8-4).
- `ctx` holds the design's closure variables (J:537–539): `root`, `vp`, `content`,
  `lanesEl`, `guidesEl`, `svg`, `bandEl`, `secs`, `R`, `RL`, `laneEls`, `guideEls`,
  `cols`, `colMap`, `bandMap`, `lockId`, `hoverId`, `inited` (J:539; the resize
  handler at J:572 does nothing until it is `true`; `firstPaint()` sets it, as
  `render()` does at J:1563), plus `D` (the `intake` result),
  `L` (the layout), `snap` (the last payload-form snapshot), `proto` (`{ epoch,
  generation, inFlight }` for `decide`), `resyncSeq` (the id of the current
  `build-resync` request), `socket` (`"up" | "down"`), `offline` (set by
  C8-T03's client side; this ticket only declares it), `life`, `push` (it keeps
  and returns the LiveView `pushEvent` reply promise) and `reload`.
- `resetState(urlState)` rebuilds `S` from defaults, applies `fromServer(urlState)`,
  clears `ctx`, then runs every `onReset` callback.
- `rmOn`, `gutW` (`root.clientWidth < 640 ? 46 : 84`) and `isVisible`
  (`root.offsetParent !== null`) are J:540–541 and J:580 verbatim.

### `life.js`

```js
export function createLife() {
  const offs = [], timers = new Map(), frames = new Map()
  return {
    on(target, type, fn, opts) { target.addEventListener(type, fn, opts); offs.push(() => target.removeEventListener(type, fn, opts)) },
    every(ms, fn) { const id = setInterval(fn, ms); offs.push(() => clearInterval(id)) },
    later(key, ms, fn) { clearTimeout(timers.get(key)); timers.set(key, setTimeout(() => { timers.delete(key); fn() }, ms)) },
    frame(key, fn) { if (frames.has(key)) return; frames.set(key, requestAnimationFrame(() => { frames.delete(key); fn() })) },
    observe(el, fn) { const ro = new ResizeObserver(fn); ro.observe(el); offs.push(() => ro.disconnect()) },
    media(query, fn) { const m = matchMedia(query); m.addEventListener("change", fn); offs.push(() => m.removeEventListener("change", fn)) },
    dispose() { while (offs.length) offs.pop()(); timers.forEach(clearTimeout); timers.clear(); frames.forEach(cancelAnimationFrame); frames.clear() }
  }
}
```

Keyed timers replace the design's ad-hoc handles (`sb._t`, `rz`, `scrollTimer`), so
a scroll storm keeps one pending timer, not one per event.

### `clock.js` (replaces `NOW`)

- `setNow(ms)` is called with the `now` of every applied snapshot and diff. It
  stores `ms` and `performance.now()`.
- `nowMs()` returns `ms + (performance.now() − at)`, the server clock advanced by a
  monotonic timer (C3-T02: "it never uses the browser's wall clock as the data
  clock"). Before the first snapshot it returns `null`; a caller that formats a
  time from `null` must render the unknown state, not the epoch or "00:00".
- Every design read of `NOW` becomes `nowMs()` in the ticket that ports that code
  (table above). The ExUnit scan below fails if any `build-home/*.js` file defines
  `NOW` or calls `Date.now()` or `new Date()` with no argument.

### `dom.js`

`$`, `$$` (J:7–8) and `esc` (J:9) with `'` → `&#39;` added (C3-T02 decision 8;
no pixel change).

### `shell.js` (port of `shell()`)

- **Adopt, do not rewrite.** The design writes `root.innerHTML` (J:545). The
  product's dead render (C3-T01) already contains those exact nodes plus the
  loading skeleton, and rewriting them would flash an empty board between the
  dead render and the first payload (EC-01). `shell()` looks up the ten ids
  (`bd-usage`, `bd-offline`, `bd-fh`, `bd-tools-l`, `bd-filters`, `bd-tools`,
  `bd-vp`, `bd-sb`, `bd-tree`, `bd-status`) and the thumb `#bd-sb > i`; if
  any is missing it logs one `console.error` naming it, sets
  `data-build-home-hook="failed"` and returns `false`; the hook then stops.
- Ports J:552–572 line for line, with three mechanical changes: listeners go
  through `ctx.life`; cross-module calls go through `fx`; `lockId` and `S.pop` are
  read from `ctx`/`S`. All numbers are the design's: 28 px thumb minimum, `+ 1`
  overflow slack, 700 ms `.act`, 500 ms `syncSB` interval, 250 ms poller, 140 ms
  resize debounce.
- **Two additions with no pixel effect** (Decisions 7 and 8): `pointercancel` and
  `lostpointercapture` on the thumb run the same code as `pointerup`; a
  `prefers-reduced-motion` change listener re-toggles `.rm`.

### `store.js` (payload intake)

- `acceptSnapshot(msg)`: requires `Number.isFinite(msg.now)`; otherwise returns
  `{ error: "invalid" }` and changes nothing. Else `ctx.snap = msg`,
  `ctx.D = intake(msg)`, `setNow(msg.now)`, `ctx.proto.epoch/generation` from the
  message. The intake result keeps `D.sources` and `D.capacity` (C7-T03's
  `etaLabel` reads both).
- `applyDiff(msg)`: works on a copy of the payload-form snapshot: for each
  `upsert` row, remove the row with that `id` from every section and insert it into
  `sections[row.sec]`; delete each `remove` id; replace each `set` block whole;
  then `ctx.D = intake(copy)`, commit the copy, `setNow(msg.now)`, set the
  generation. If anything throws (a row without `id` or with an unknown `sec`), the
  old `snap` and `D` stay and the hook requests a resync. Re-running `intake`
  reuses C3-T02's single derivation (`all`, `byId`, `children`, sort by `ord` then
  `num`, `to: null` → `Infinity`) instead of a second, incremental one.
- `mergeEarlier(msg)`: only when `msg.epoch === ctx.proto.epoch`; adds the rows
  whose `id` is not already loaded (a diff is newer than a page), replaces
  `history`, re-runs `intake`. C9-T03 sends `load-earlier` and keeps the anchor.
- **Identity rule for renderers:** row objects are new after every diff. Compare
  rows by `id`, never by object identity. The design's `refreshTicket` test
  `it.t === t` (J:1545) becomes `it.t.id === t.id` (C9-T03/C9-T05).

### `hook.js` (lifecycle and intake)

```text
mounted:
  ctx.life = createLife(); ctx.push = (e, p) => this.pushEvent(e, p); ctx.reload = () => location.reload()
  resetState(JSON.parse(el.dataset.urlState || "{}"))          // C3-T03; parse error → {} (defaults)
  if (!shell()) return
  el.dataset.buildHomeHook = "mounted"                          // C2-T03 health contract
  el.dataset.bdMounted = ""                                     // data-bd-mounted: C1-T02 ready condition
  this.handleEvent("build-diff", receive); this.handleEvent("build:url", onServerURL)
  showServerState(el.dataset)                                   // unavailable → fx.renderUnavailable
  resync()
updated:      writeOwnData(); showServerState(el.dataset)       // only data-* reach an ignored element
disconnected: ctx.socket = "down"; ctx.proto.inFlight = false; ctx.resyncSeq++; writeOwnData()
reconnected:  ctx.socket = "up";   writeOwnData(); resync(); flushURL()
destroyed:    ctx.life.dispose(); ctx.proto.inFlight = false; ctx.resyncSeq++   // handleEvent refs are removed by LiveView
```

- `writeOwnData()` writes every hook-owned attribute on `#build-root` from
  `ctx`: `data-build-home-hook="mounted"`, `data-bd-mounted`, `data-build-socket`,
  `data-build-epoch`, `data-build-generation` (the last two only after a
  snapshot). C3-T01's rule: LiveView removes each of them on the next server
  patch (nav count, nav toggle, URL patch, rejoin render), and `updated()` runs
  in that same patch, so writing them again there keeps them. Without it, B7,
  C3-T02's reconnect test and C2-T03's health attribute read a missing value.
- `resync()` is single flight: if `ctx.proto.inFlight` it returns; else it sets
  it, takes `seq = ++ctx.resyncSeq`, calls `ctx.push("build-resync", {})`, and on
  reply or rejection clears `inFlight` **only if `seq === ctx.resyncSeq`**. A
  reply whose `seq` is old is dropped. The reply goes to `receive(reply)`; a
  rejection (socket down) does nothing, because `reconnected` resyncs.
- **Why `disconnected` clears the flag.** A push already sent when the socket
  drops stays pending until LiveView's 30 s push timeout (`pushWithReply`,
  Verified starting point). Without the reset, `reconnected` would find
  `inFlight` still set, skip its resync, and leave the board on the old epoch
  until the next gap. C3-T02 requires "If the reply never comes (the socket
  drops), `reconnected()` starts a fresh one". The sequence id makes a late
  settle of the old promise harmless.
- `receive(msg)`: `msg.kind === "error"` → if no snapshot yet,
  `fx.renderUnavailable(msg.reason)`; else keep the board. Otherwise
  `switch (decide(ctx.proto, msg))`:
  - `"apply"` snapshot → `acceptSnapshot`; first one: `firstPaint()`; later
    ones: `repaint()`. Diff → `applyDiff`, then `fx.dataChanged(msg)`, then
    `fx.drawEdgesSoon(30)` (C9-T07 request).
  - `"ignore"` → nothing.
  - `"resync"` → `resync()`.
  - `"reload"` (`v ≠ 1`) → reload once (guard key `aiur-build-reloaded` in
    `sessionStorage`, in try/catch); if the guard is already set, or storage throws,
    `fx.renderUnavailable("version")` instead, so a mismatch never loops.
  - After each apply: `writeOwnData()` (epoch and generation).
- `firstPaint()` = the design's `render()` first branch (J:1563–1571) without the
  timer: `ctx.inited = true; S.loading = false; renderAll(); fx.jumpNow(true); S.ready = true;
  ctx.life.frame("ticket", fx.openFromURL)`. `renderAll` is J:1265–1269 with each
  call through `fx`.
- `repaint()` (a resync after reconnect or a gap): `renderChrome()` (usage,
  offline, features, filters, tools), `fx.relayout()`, `fx.update()`. No
  `viewport()`, so cards are not rebuilt and do not replay their enter
  transition, and `scrollTop` is kept.
- `defaultDataChanged(msg)` = `renderChrome()` when `msg.set` has a key, then
  `fx.relayout(); fx.update()`. C9-T03 replaces it with anchor-keeping logic
  (EC-10).
- `showServerState(ds)`: when `ds.buildState === "unavailable"` and no snapshot
  has been applied, `fx.renderUnavailable(ds.buildReason)`. `"ready"` alone does
  **not** end loading; only an applied snapshot does (the attribute says the
  server loaded, not that this hook has the data).
- `defaultUnavailable(reason)` (C9-T13 replaces it): inside `.bd-loading`, remove
  `.bd-spin` and set the text to `Build timeline unavailable · <words>`, where
  `not_wired` → "no data source", `timeout` → "timed out", `crashed` → "source
  crashed", `version` → "page out of date, reload", `invalid` → "invalid data",
  `unavailable` → "source unavailable", anything else → "unknown cause"
  (AGENTS.md collapsed-cause rule: the fallback is cause-neutral). Text is set
  with `textContent`, not `innerHTML`.

### `url.js` (bridge, C3-T03 contract)

- `fromServer(state)` maps `URLState.t()` JSON to `S`: `view`, `span`, `feature`,
  `fmode`, `epic`/`model`/`tstate`/`astate` → `S.f.*` (arrays, order kept),
  `live_min` → `S.liveMin`, `trees` → `S.trees`, `ticket` → `S.ticket`. A missing
  key takes the design default. It never reads `location.search`.
- `writeURL(extra)` builds the flat map `writeURL` (J:316–328) would have written,
  minus `models`/`example`: only non-default keys, lists joined with `,`, and
  `ticket` only when `extra` has it (`""` clears). It calls
  `ctx.push("build:url", params)`. It never calls `history.replaceState`. If the
  push rejects (socket down), it sets a pending flag.
- `flushURL()` (on `reconnected`): always sends the current state once, because
  the new LiveView process mounted from the address bar and a write lost while
  the socket was down must reach it (C3-T03 "Disconnect and rejoin"). It then
  clears the pending flag. An equal state causes no patch on the server.
- `onServerURL({ state })` (the push): `fromServer(state)`, then
  `renderChrome(); fx.relayout(); fx.update()`, plus `fx.jumpNow(true)` when
  `span` changed (as `setSpan`, J:1229–1232). It does **not** call `writeURL`
  (no echo).

### Invariants

1. The board leaves the skeleton only after a snapshot with a finite `now` is
   applied. No timer ends loading.
2. `nowMs()` is never derived from `Date.now()`. Unknown time is `null`.
3. A diff is applied at most once (C3-T02's `decide`), and a failed apply never
   leaves a half-mutated `D`.
4. After `destroyed`, no listener, interval, timer, frame or observer added by a
   `build-home` module remains.
5. The hook never writes the address bar; LiveView does (`push_patch`).
6. Every hook-owned `data-*` on `#build-root` survives a server patch
   (`writeOwnData()` in `updated()`).
7. After `reconnected`, a `build-resync` is always sent, whatever the state of a
   request made before the drop.

## Implementation steps

1. `state.js`, `life.js`, `clock.js`, `dom.js` as above (about 120 lines in
   total).
2. `shell.js`: port J:552–572 into `shell()`. Keep the order of handlers. Keep
   `syncSB` exported for C9-T03 (the design calls it only from inside `shell`;
   exporting it costs nothing and lets a relayout resync the thumb).
3. `store.js` with the three functions; import `intake` from `./protocol.js`.
4. `url.js` with the three functions.
5. `hook.js`: replace the C2-T03 stub body with the lifecycle above. Keep the
   export name and the `data-build-home-hook="mounted"` write; add
   `writeOwnData()` and call it from `updated`, `disconnected`, `reconnected`
   and after each apply.
6. PROPOSED `src/test/aiur_web/build/home_assets_scan_test.exs` (source scan).
7. Add this ticket's B-tests to C3-T01's spec
   `src/browser/tests/build-home-shell.browser.spec.mjs` (PROPOSED there, with
   the npm script `test:build-home` already in the `"test"` chain). No new spec
   file and no new script: C3-T01 owns both names.
8. C1-T03 sequences `sb.scroll-reveal`, `sb.drag`, `sb.track-click` (see Pixel
   parity), added to C1-T03's `SEQUENCES` table with this ticket's anchor
   `#bd-sb`, plus the C1-T02 cells `c9t01-sb-*`. The `off` cell and C3-T01's
   `#bd-vp` loading cell are gates now; the others carry `test.fixme(true,
   'awaiting MP-E8-C9-T03')` until the product draws `#bd-content`.

## Non-happy paths

| # | Input | Expected | Test |
| --- | --- | --- | --- |
| N1 | Server never answers (`/build-fixture/hold`) | Skeleton and spinner stay; no `#bd-content`; still so at 2 s (past the design's 600 ms). At about 5 s C3-T02's bounded read replies `{kind: "error", reason: "unavailable"}` and the pill then reads "· source unavailable" (N3) | B1 |
| N2 | `data-build-state="unavailable"`, reason `timeout` | Pill "Build timeline unavailable · timed out", no `.bd-spin`, no `#bd-content`, no `.bd-mk.empty` | B2 |
| N3 | `build-resync` replies `{kind: "error", reason: "unavailable"}` before any snapshot | Same unavailable pill, "source unavailable" | B2b |
| N4 | Snapshot with `now: null` or missing | Not applied; unavailable "invalid data"; `nowMs()` stays `null` | B3b |
| N5 | Browser clock wrong (Playwright clock at 2030-01-01) | `nowMs()` equals the fixture `now` within 1 s | B3 |
| N6 | Gap (`/build-control/skip` then `diff`, twice, quickly) | Exactly one `build-resync` in flight; generation equals the server's afterwards | B5 |
| N7 | Diff whose upsert row has no `id` | `D` unchanged (same `byId` keys), one resync requested, no uncaught error | B6 |
| N8 | Socket drops and returns | `data-build-socket` `down` then `up`; a new `data-build-epoch`; the board is repainted with `relayout()` + `update()` and without `viewport()` (so card nodes are kept once C9-T03 draws them) | B7 |
| N9 | Filter change while disconnected | No unhandled rejection; after reconnect `page.url()` carries the change | B8 |
| N10 | `?feature=<b>&astate=bogus,paused&example=dense` | `S.feature === null`, `S.f.astate == ["paused"]`, no demo dataset; values come from `data-url-state`, not `location.search` | B9 |
| N11 | Hook writes `astate=bogus,paused` | Server canonicalizes; URL ends `?astate=paused`; `S.f.astate == ["paused"]`; `history.length` unchanged; the hook does not send `build:url` again | B10 |
| N12 | Navigate `/build` → `/commands` → back to `/build?view=list` | `S.view === "list"`, not the first mount's state; Escape calls `fx.unlock` once, not twice; no interval from the first mount runs | B11 |
| N13 | `pointercancel` during thumb drag (touch) | `.drag` removed; later scrolls do not move with the pointer | B12 |
| N14 | `v: 2` snapshot | One reload; on the second `v: 2`, unavailable "page out of date, reload" and no further reload | B13 |
| N15 | Missing host (a C3-T01 markup drift) | `console.error` names the id; `data-build-home-hook="failed"`; no exception | B14 |
| N16 | Reduced motion on at mount, then off | `.rm` present, then removed | B15 |
| N17 | Destroy before the module import resolves | Covered by C2-T03's loader (nothing is created) | C2-T03 |
| N18 | A server patch (nav toggle) after the first snapshot | `data-build-home-hook="mounted"`, `data-build-socket`, `data-build-epoch`, `data-build-generation` are still present with the same values | B17 |
| N19 | Socket drops while a `build-resync` is in flight (`hold`: the reply takes 5 s) | After `connect()`, a second `build-resync` is sent at once; a late settle of the first request does not clear the second's flag | B18 |
| N20 | Content taller than `#bd-vp` | Thumb height `max(28, track × ch / sh)`; `.act` for exactly 700 ms after the last scroll; drag and track click move `scrollTop` by the J:557–559 formulas | B19 |

**Stale and unknown.** The only value this ticket renders is the unavailable pill.
It never renders "ready", an empty board, a zero or a time when the data is
missing (N1–N4). Section-level unavailable and empty copy (S-9) is C9-T13's.

**Security.** All payload strings reach the DOM only through `esc` or
`textContent`. `fromServer` accepts only the validated state the server sends;
the hook does not parse `location.search`. No new endpoint, no credential, no
write: URL state needs no `dashboard_writable` check (C3-T03).

**LiveView side effects.** Each `pushEvent` adds `phx-hook-loading` and
`data-phx-ref-*` to `#build-root` until the reply, and LiveView holds server
patches to that element (its `data-*`) until then. No CSS targets the class.
C1-T02 and C1-T03 ignore `phx-*` class tokens and `data-phx-*` attributes in
DOM comparisons.

## Compatibility and rollout

- No configuration key, CLI flag or environment variable. No docs: the page is the
  unlinked `/build` route until C12-T01; the home-page docs ship with C12-T07
  (AGENTS.md "Docs ship with the change": no user-facing surface changes here).
- No migration. No server change.
- Assets: new files under `build-home/`, served and revalidated through C2-T03's
  one directory entry; `layouts.ex` and `StaticAssets` are not edited.
- Rollback: restore the C2-T03 stub body of `hook.js`; the new modules are then
  never imported.

## Pixel parity

**Design elements:** `.bd-vpw`, `#bd-vp` (hidden native scrollbar), `#bd-sb` and
its thumb `i` in the states default, `:hover`, `.act`, `.drag`, `.off`, in dark
and light; the host order of `#build-root` (J:544–551); `.bd-root.rm`.

**What can be compared at this merge.** The thumb's size and position depend on
`#bd-vp.scrollHeight`, which the board content sets. That content is drawn by
C9-T03 (`viewport`, `update`), a successor. Before C9-T03 the product `#bd-vp`
holds only the skeleton, so the states `top`, `act`, `hover` and `drag` cannot
match the design's board. So:

- **Pass/fail now:** the loading frame, with `openParityPair(…, { phase:
  'loading' })` (C1-T02): cell `c9t01-sb-off` (region `#bd-sb`, both sides
  `.off`) and C3-T01's cell on `#bd-vp` (its B4), which this ticket turns from
  report mode into a gate. The product side is `/build-fixture/hold`, captured
  within 4 s of load, before C3-T02's 5 s bounded read replies `unavailable` and
  the pill text changes.
- **Registered now, enforced by C9-T03:** the cells `c9t01-sb-top`, `-act`,
  `-hover`, `-drag` and the three motion sequences below. Until `#bd-content`
  exists on the product side, each calls `test.fixme(true, 'awaiting
  MP-E8-C9-T03')` (C1-T03 rule: never skipped silently, never a pass; C12-T08
  fails while any `fixme` remains). C9-T03 removes the `fixme` (handoff).
- **Behaviour now, without the design:** B12 and B19 make `#bd-vp` scrollable
  with a test-only spacer and check the J:554–559 formulas directly.

1. **Screenshot (C1-T02 element mode).** `expectDesignParity(pair, { name:
   "c9t01-sb-<state>", region: "#bd-sb" })` in the full matrix (1440/1024/390 px ×
   dark/light × Gruvbox/default), for: `top` (just painted), `act` (50 % scrolled,
   within 700 ms), `hover`, `drag` (mid-drag), `off` (loading frame; the design at
   `S.loading`, the product at `/build-fixture/hold`). Datasets `live` and `dense`
   (dense proves the 28 px minimum). The region is the scrollbar only, because the
   board inside `#bd-vp` is drawn by later tickets; full-board parity is
   C12-T08's.
2. **Computed style.** C2-T04's spec (`home-css-parity`, `npm run test:home-css`)
   on `#bd-sb`, `#bd-sb i`, `.bd-vpw`, `#bd-vp`: the `off` state now; the other
   states once C9-T03 lands (same gate as item 1). Values are listed in Verified
   starting point.
3. **Motion and DOM state (C1-T03 `compareRecords`, frozen clock).**
   - `sb.scroll-reveal`: scroll `#bd-vp` by 400 px; sample `#bd-sb` classes and the
     thumb's `style.height`/`style.transform` at 0, 100, 699, 700, 701 ms. Design
     and product records must be equal (`.act` until 700 ms).
   - `sb.drag`: thumb down, move 100 px in 5 steps, up; record `scrollTop` per step
     and `.drag`.
   - `sb.track-click`: click at 75 % of the track; record `scrollTop` (instant, no
     animation frames).
   Reduced-motion variants run too (C1-T03 rule). Allowlist: none. Any difference
   fails unless Kevin approves it in writing.

## Verification

ExUnit (PROPOSED `src/test/aiur_web/build/home_assets_scan_test.exs`):

| Test | Expected | Fails without |
| --- | --- | --- |
| S1 "build-home clock comes from the payload" | `clock.js` exports `nowMs` and `setNow`; `hook.js` imports `./clock.js`; no `build-home/*.js` matches `\bNOW\b`, `Date\.now\(` or `new Date\(\)` | `clock.js` (missing file fails the first assertions). The pattern part is a **guard against future regressions** by later C9–C11 tickets; the test name says so and it is not counted as coverage of this change |
| S2 "guard: build-home modules use ctx.life" | no `build-home/*.js` except `life.js` contains `setInterval(`, `addEventListener(` on `document`/`window`, or `new ResizeObserver(` | **Guard against future regressions, not coverage of this change**: with this ticket reverted, the files do not exist and the scan passes. The behaviour is covered by B11 (dispose). A self-check plants a bare `setInterval(` in a temp copy of `shell.js` and asserts the scan reports it, so the regex is proven to bite (the ported shell would otherwise have 7 such calls: 2 `setInterval`, 1 `ResizeObserver`, 4 `document`/`window` listeners) |

Browser (C3-T01's PROPOSED `src/browser/tests/build-home-shell.browser.spec.mjs`, extended here; product
side `GET /build-fixture/<dataset>` then `/build`, per C3-T01; tests read
module state with `page.evaluate(async () => (await import("/build-home/state.js")).ctx)`,
which returns the same module instance the hook uses):

| Test | Steps | Expected | Mutation that must fail it |
| --- | --- | --- | --- |
| B1 skeleton until data | `hold`; wait 2 s | 16 `.bd-skel > i`, one `.bd-spin`, no `#bd-content`, `S.loading === true` | add `setTimeout(firstPaint, 600)` in `mounted` |
| B2 unavailable from the server | `unavailable` (C3-T01: reason `unknown`) | `.bd-loading` text `Build timeline unavailable · unknown cause`; no `.bd-spin`; no `#bd-content`; no `.bd-mk.empty` | `showServerState` ignores `unavailable` (pill keeps "Loading…") |
| B2b error reply | `ctx.proto` reset, call `receive({v:1, kind:"error", reason:"unavailable"})` before a snapshot | pill "· source unavailable"; `S.loading` still `true` | treat the error as an empty snapshot |
| B3 data clock | `page.clock.install({ time: new Date("2030-01-01") })`; `live` | `|nowMs() − fixture.now| < 1000` | `nowMs = () => Date.now()` |
| B3b unknown now | `receive({...live, epoch:"x", now:null})` on a fresh state | not applied; `ctx.D === null`; `nowMs() === null`; pill "· invalid data" | drop the `Number.isFinite` check, or fall back to `Date.now()` |
| B4 diff applies | `live`; `GET /build-control/diff` | `data-build-generation` +1; the upserted id in `ctx.D.byId` with the new values | `receive` ignores `build-diff` |
| B5 single-flight resync | wrap `ctx.push` with a counter; `skip`, `diff`, `diff` | `build-resync` count 1 while in flight; afterwards generation equals the server's | remove the `inFlight` guard (count 2) |
| B6 bad diff | `receive` a diff (next generation) whose upsert row lacks `id` | `Object.keys(ctx.D.byId)` unchanged; resync count 1; `pageerror` count 0 | mutate `ctx.snap` in place instead of a copy |
| B7 reconnect | `live`; wrap `fx.viewport` and `fx.relayout` with counters after first paint; `liveSocket.disconnect()`, then `connect()` | `data-build-socket` `down` → `up`; `data-build-epoch` changes; after the new epoch, `fx.viewport` count unchanged and `fx.relayout` count +1 | `reconnected` without `resync()` (epoch unchanged); `repaint` calling `viewport()` (viewport count +1) |
| B8 deferred URL | disconnect; set `S.view = "list"` and `writeURL()`; connect | no `pageerror`/unhandled rejection; `page.url()` ends `?view=list` | drop `flushURL()` from `reconnected` |
| B9 initial state | `/build?feature=%3Cb%3E&astate=bogus,paused&example=dense&span=7` | `S.feature === null`, `S.f.astate` `["paused"]`, `S.span === 7`, no `S.demo` | reintroduce the design's `readURL()` (`S.feature === "<b>"`) |
| B10 write and no echo | count `ctx.push("build:url")`; set `S.f.astate = ["bogus","paused"]`; `writeURL()` | URL ends `?astate=paused`; `S.f.astate` `["paused"]` (server push applied); push count 1; `history.length` unchanged | `history.replaceState` instead of the push (URL keeps `bogus`); echo in `onServerURL` (count 2) |
| B11 remount | open `/build`; `live_redirect` to `/commands`; back to `/build?view=list`; spy `fx.unlock` with `ctx.lockId = "1"`; press Escape; count live intervals with an init script that wraps `setInterval`/`clearInterval` and records only ids whose creation stack (`new Error().stack`) contains `/build-home/` (LiveView and other scripts also create intervals) | `S.view === "list"`; `fx.unlock` called once; build-home intervals alive = the ones of the current mount only (2: `syncSB` and the poller) | skip `resetState` (view stays graph); skip `ctx.life.dispose()` (unlock twice; 4 intervals) |
| B12 pointercancel | `live`; append a test-only `<div style="height:4000px">` to `#bd-vp` and call `syncSB()` (so the thumb exists before C9-T03 draws content); pointerdown on the thumb, dispatch `pointercancel`, then dispatch `pointermove` 100 px lower | `#bd-sb` has no `.drag`; `scrollTop` unchanged by the move | remove the `pointercancel` listener |
| B13 version | stub `ctx.reload`; `receive({...live, v:2})` twice | `ctx.reload` called once; then pill "· page out of date, reload" | remove the `sessionStorage` guard (reload twice) |
| B14 missing host | hold `/build-home/hook.js` with `page.route` until the page has loaded, remove `#bd-sb` with `page.evaluate`, then release the route | `data-build-home-hook="failed"`; one console error naming `bd-sb`; no `pageerror` | `shell()` without the host check (TypeError) |
| B15 reduced motion | `emulateMedia({ reducedMotion: "reduce" })` before load, then `"no-preference"` | `.bd-root.rm` present, then absent | remove the `media` listener (second assertion); remove the toggle (first) |
| B16 escape | `esc("<'\"&>")` | `&lt;&#39;&quot;&amp;&gt;` | the design's `esc` (no `'`) |
| B17 data survives a patch | `live`; wait for `data-build-epoch`; click `#nav-toggle` (a server patch, as C3-T01 B6) | `data-build-home-hook="mounted"`, `data-build-socket="up"`, `data-build-epoch` and `data-build-generation` equal their values before the click | drop `writeOwnData()` from `updated` (all four attributes absent) |
| B18 resync after a drop in flight | `hold`; wait until `#build-root` has `phx-hook-loading` (the first `build-resync` is pending); `liveSocket.disconnect()`; `connect()`; count `build-resync` pushes | count 2 within 1 s of `connect()`; after the first request's promise settles, `ctx.proto.inFlight` still reflects the second request | do not clear `inFlight` in `disconnected` (count stays 1 until the 30 s push timeout); drop the `seq` check (the late settle clears the flag of the second request) |
| B19 scrollbar formulas | `live`; append a test-only `<div style="height:4000px">` to `#bd-vp`; call `syncSB()`; install the Playwright clock | no `.off`; thumb height `max(28, track × ch / sh)` px; scroll to 50 %: `transform` `translateY(0.5 × (track − h) px)`, `.act` present at 699 ms and absent at 701 ms; drag 100 px: `scrollTop = 100 × (sh − ch) / max(1, track − h)` (±1); track click at 75 %: `scrollTop = 0.75 × (sh − ch)` (±1); remove the spacer, `syncSB()`: `.off` | change 28 → 24, 700 → 600, or the `k` factor; remove the `.off` branch |

The scrollbar parity checks (Pixel parity 1–3) run in the C1-T02/C1-T03 specs
under `npm run test:design-parity`, `npm run test:build-home-motion` and
`npm run test:home-css`.

Commands (isolated HOME, per the "mix test clobbers agent-token" note):

```bash
env -C /path/to/aiur/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- \
  mix test test/aiur_web/build/home_assets_scan_test.exs
env -C /path/to/aiur/src/browser npm run fixture:preflight
env -C /path/to/aiur/src/browser npm run test:build-home
env -C /path/to/aiur/src/browser npm run test:design-parity
env -C /path/to/aiur/src/browser npm run test:build-home-motion
env -C /path/to/aiur/src/browser npm run test:home-css
```

Mutation check (AGENTS.md): for each mutation in the tables, apply it in a
worktree, confirm `git status --porcelain` shows only that hunk, run the test, see
it fail, restore, see it pass. Put the exact commands and results in the PR body.

Manual check: open `/build-fixture/live` then `/build` in a browser, scroll,
drag the thumb, click the track, toggle reduced motion, stop and restart the
daemon and watch the board repaint. This ticket does not touch agent chat or the
TUI, so the AGENTS.md TUI recipe does not apply; C11-T06 and C12-T01 run it.

## Completion and handoff

- [ ] The modules in "Module layout" owned by C9-T01 exist; `hook.js` keeps the
      C2-T03 export and health attribute.
- [ ] Loading ends only on an applied snapshot; unavailable never shows as loading,
      ready or empty.
- [ ] `nowMs()` replaces `NOW`; the scan test guards later tickets.
- [ ] Diffs, gaps, duplicates, reconnects and version mismatches behave as in
      N4–N19.
- [ ] URL state flows only through `build:url`, with no echo and no
      `history.replaceState`.
- [ ] All listeners, timers, frames and observers are released on `destroyed`.
- [ ] Hook-owned `data-*` survive server patches (B17).
- [ ] S1–S2 and B1–B19 pass; each listed mutation fails; the `off` scrollbar
      cell and C3-T01's `#bd-vp` loading cell pass in the full matrix with no
      allowlist entry; the other `c9t01-sb-*` cells and `sb.*` sequences are
      registered as `fixme` awaiting C9-T03.
- **Dependents:** C9-T02..T13 fill `layout.js` … `states.js` (and C9-T03
  `history.js`) and register in
  `hook.js`; C10-T01..T04 fill `tools.js`, `filters.js`, `features.js`,
  `usage.js`; C11 fills `modal/` and `fx.openFromURL`; C8-T03 fills `offline.js`
  and reads `ctx.socket`/`data-build-socket`.
- **Handoffs.**
  - **C9-T03:** replace `fx.dataChanged` with the anchor-keeping version (EC-10);
    `loadEarlier` lives in its `history.js`;
    it also calls `fx.refreshTicket(id)` for each upserted row whose item did
    not move (C9-T05 decision 7 expects "the diff applier" to do this; the
    applier's render step is `dataChanged`). Send `load-earlier` and call
    `mergeEarlier`; compare rows by `id`. Remove the `fixme` from the
    `c9t01-sb-top/-act/-hover/-drag` cells and the `sb.*` sequences once
    `#bd-content` is drawn, and call `syncSB()` after `relayout()`.
  - **C9-T07:** Settled 2026-10-08: C9-T07 reads `ctx.proto.generation`. The
    hook already calls `fx.drawEdgesSoon(30)` after every applied diff; C9-T07
    only replaces the default.
  - **C9-T08, C9-T09, C9-T13, C10-T04:** the payload clock is `nowMs()` from
    `clock.js` (the name C9-T08 and C9-T09 proposed). It returns `null` before
    the first snapshot.
  - **C9-T13:** replace `fx.renderUnavailable` with the S-9 copy; keep "unknown
    cause" as the cause-neutral fallback.
  - **C1-T03:** Settled 2026-10-08: DOM comparisons ignore `phx-*` classes and
    `data-phx-*` attributes (C1-T02/C1-T03).
  - **C3-T02:** its reconnect test cannot use `reconnectLiveView` on `/build`
    (it waits on `#worker-status`); use `window.liveSocket` and
    `data-build-epoch`, as B7 does.
- **Docs:** none (internal; C12-T07 documents the page).
- **Sources:** `tickets/README.md` row C9-T01 and the C9, C3, C2 rows;
  `chunks.md` C9; `plan.md` §5, §8 (EC-01, EC-10, EC-11, EC-20); C3-T01, C3-T02,
  C3-T03, C2-T03, C2-T04, C1-T02, C1-T03 ticket docs; J, C and H lines cited above;
  the product paths in "Verified starting point".

## Decisions made without the owner

1. **Module layout with an `fx` table and `onReset`.** One function table instead
   of stub files for every future module: the least code that lets thirteen PRs
   land in any order, and one import line per module in `hook.js`.
2. **Adopt the server-rendered shell; never rewrite `#build-root`.** A missing host
   fails loudly (`failed`) instead of silently rebuilding.
3. **No 600 ms boot timer.** Loading ends on the first valid snapshot, as C3-T01
   requires.
4. **Data clock = payload `now` + monotonic elapsed time.** No wall-clock fallback;
   an invalid `now` makes the payload invalid.
5. **Minimal unavailable pill** "Build timeline unavailable · <cause>" in the
   design's `.bd-loading` box without the spinner. C9-T13 and S-9 may change the
   copy; the rule "never loading, ready or empty" stays.
6. **A resync repaints without `viewport()`,** so a reconnect does not replay card
   enter transitions and keeps the scroll position. The design never resyncs, so
   there is nothing to match.
7. **`pointercancel`/`lostpointercapture` end a thumb drag.** The design lacks them;
   without them a cancelled touch leaves `.drag` stuck. No pixel change in the
   normal flow.
8. **Reduced motion follows a live preference change.** The design reads it once.
   Accessibility; no pixel change at mount.
9. **A version mismatch reloads once,** guarded in `sessionStorage`, then shows
   unavailable instead of looping.
10. **URL changes made while disconnected are sent on reconnect,** because the new
    LiveView process mounts from the old address bar.
11. **Diffs re-run `intake` on a copy of the payload-form snapshot,** so there is
    one derivation and a failed diff never half-applies. Cost is O(rows) per diff;
    C12-T06 measures it at 10,000 tickets.
12. **No retry button for a whole-board unavailable state.** Recovery is a
    reconnect or a reload. A button needs design copy (S-16 owns Reconnect).
13. **`esc` lives in `dom.js` and escapes `'`,** per C3-T02 decision 8.
14. **The hook lives at `build-home/hook.js`, not `build-home-hook.js`.** The
    README row names `src/priv/static/build-home-hook.js`; C2-T03 (a transitive
    predecessor) already fixes the module URL `/build-home/hook.js` and the
    `build-home/` directory. Following C2-T03 adds no second file.
15. **`NOW` is replaced where each read is ported, not all in this ticket.** The
    README row says "everywhere it is read (band time, `jumpNow`, Gantt)". Those
    reads live in code that C9-T08, C9-T09, C10-T03 and C11 port; this ticket
    ships `nowMs()` and the S1 scan, which fails if any later module defines
    `NOW` or reads the wall clock. Porting those functions here would be scope
    creep into five other tickets.
16. **A disconnect drops the in-flight resync.** LiveView keeps a sent push
    pending for up to 30 s after a drop, so without this `reconnected` would not
    resync (C3-T02 requires that it does). A sequence id ignores the late settle.
17. **Scrollbar parity is split by what is reachable.** The `off` state and the
    loading frame are gates now; the scrolled states need C9-T03's board and are
    registered as `fixme` cells that C9-T03 turns on. B19 checks the formulas
    now with a test-only spacer. The parity rule is not relaxed: C12-T08 fails
    while any `fixme` remains.
18. **The payload clock is named `nowMs()`,** the name C9-T08 and C9-T09 already
    use, and distinct from `D.now` (the now-section rows from `intake`).

## Review log

Adversarial review, 2026-10-08 (feasibility, coherence, design, scope; checked
against `runtime/src` at `58854d4c8`, `design-source`, the README row, `chunks.md`
and the C1-T02, C1-T03, C2-T03, C2-T04, C3-T01, C3-T02, C3-T03, C9-T03, C9-T04,
C9-T05, C9-T07, C9-T08, C9-T09, C9-T13, C11-T01 ticket files).

1. **`updated()` did not re-write hook-owned `data-*`.** C3-T01 requires it
   (LiveView removes them on every patch). Added `writeOwnData()`, invariant 6,
   N18 and B17.
2. **Single-flight resync could block the reconnect resync** for up to 30 s
   (verified in LV 1.1.33 `pushWithReply` `:5162-5226`, `PUSH_TIMEOUT` `:146`).
   `disconnected` now clears the flag; a sequence id drops late settles.
   Invariant 7, N19, B18; Verified starting point entry added; Decision 16.
3. **Pixel parity was not runnable at merge:** the `top/act/hover/drag` cells and
   the `sb.*` sequences need C9-T03's board, a successor. Split into gates now
   (`off`, C3-T01's `#bd-vp` loading cell, which the ticket had not picked up)
   and `fixme` cells; added B19 (formulas with a spacer); B12 no longer depends
   on `dense` content. Decision 17, C9-T03 handoff.
4. **B7 used `#bd-sec-hist`,** which no code in this ticket draws (`fx.viewport`
   is a no-op until C9-T03). Rewritten with `fx.viewport`/`fx.relayout` spies.
5. **Spec file and npm script collided with C3-T01,** which already creates
   `build-home-shell.browser.spec.mjs` and `test:build-home`. Now extends them.
6. **Wrong stylesheet name:** `build-home/home.css` → `build-home/build-home.css`
   (C2-T03, C2-T04); C2-T04's computed-style spec and `test:home-css` named.
7. **Line citations corrected:** `build-order-grid-hook.js` `:71-78` and
   `:478-489`; `pushHookEvent` `:5421-5430`. Other cited product and design lines
   were opened and match.
8. **"nine ids" → ten ids,** listed by name; the thumb `i` is checked too.
9. **`ctx.inited` was missing:** the resize handler (J:572) needs it; `firstPaint`
   sets it (J:1563).
10. **Clock renamed `now()` → `nowMs()`** to match C9-T08/C9-T09 and avoid the
    `D.now` clash. Decision 18.
11. **S2 was counted as coverage but passes with the ticket reverted** (the files
    would not exist); relabelled as a guard with a planted-call self-check;
    the call count corrected from 4 to 7.
12. **B11 interval count** would include LiveView's own intervals; now filtered
    by creation stack.
13. **Interfaces with successors:** `fx.drawEdgesSoon(30)` after each diff (C9-T07
    request) and its default; C9-T07 `ctx.generation` → `ctx.proto.generation`;
    C9-T05's `refreshTicket` call placed in C9-T03's `dataChanged`.
14. **Writer-reported C3-T01/C3-T02 transport mismatch:** checked; the current
    C3-T01 defers to C3-T02's `build-resync` reply. Recorded under Dependencies;
    no change needed in either neighbour.
15. **Scope vs README row:** hook path and the per-ticket `NOW` replacement were
    silent deviations; now Decisions 14 and 15. `flushURL` wording made
    unambiguous; B14 steps made concrete (`page.route` hold).

Residual risks: the scrolled-state scrollbar parity is not enforced until C9-T03
lands (registered `fixme` cells, C12-T08 gate); C9-T07's file still writes
`ctx.generation` and must read `ctx.proto.generation`. The data-* removal rule
behind B17 was confirmed in LV 1.1.33 `phoenix_live_view.js:813-818`.
- Reconciliation 2026-10-08 (coordinator): stylesheet path `home.css` (R-G8), new `icons.js` module (R-G9), `loadEarlier`/`ensureDays`/`ensureFrom` moved to C9-T03 `history.js` in the module table, `data-bd-mounted` set on mount and in `writeOwnData` (R-G7), `ctx.push` keeps the reply promise, intake keeps `D.sources`/`D.capacity`, `ctx.offline` declared for C8-T03, R-G2/R-G4 rule 5 (later edits by C10-T01, C9-T03, C9-T13), C9-T07 and C1-T03 handoffs marked settled.
