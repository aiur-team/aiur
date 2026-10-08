---
ticket_id: MP-E8-C9-T03
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: Virtualised rendering and history paging
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C9-T02]
complexity: 3
design_gate: DESIGN-E8
owns_edge_cases: [EC-09, EC-10]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T03 — Virtualised rendering and history paging

> **Wave 0b.** Product paths are cited at `58854d4c8`. Paths marked PROPOSED do
> not exist yet. `J` = `design-source/assets/build.js`, `C` =
> `design-source/assets/build.css`. The design is the specification
> ([claude-design-source-of-truth.md](../claude-design-source-of-truth.md)): port
> the code, remove only the mock parts.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C9 (client timeline
  engine, port of `build.js`).
- **User value.** A history of 1,300 to 10,000 tickets scrolls as smoothly as the
  design. Only the cards near the viewport exist in the DOM. Earlier days load
  from the server when you scroll near the top, and the card you were looking at
  does not move. A live change (a ticket that merges, or a queued ticket that
  starts) does not make the page jump, does not break a locked dependency tree,
  and does not take keyboard focus away from a card.
- **Deliverables.**
  1. The port of `viewport()` (J:604–636), `relayout()` (J:638–675), `update()`
     (J:695–742) and `place()` (J:757–767) into `render.js` (C9-T01's module
     table assigns all four to this ticket, and `loadEarlier` to its
     `history.js`): the board
     skeleton, section heights, section headers, the ±700 px render window, card
     and mark recycling by uid.
  2. The port of `moreHistory`, `initHistFrom` and `loadEarlier` (J:743–755) into
     PROPOSED `build-home/history.js` as a server round trip (`load-earlier`, C3-T02) that keeps the scroll anchor, with
     a single-flight request, error state and retry rule. `histDays` is C9-T02's
     `histDays(D.hist)` (layout.js), not a second copy.
  3. The replacement of C9-T01's `fx.dataChanged` (its `defaultDataChanged`). It
     re-lays out the board after an applied `build-diff` and keeps the scroll
     anchor, the lock, the hover and the focused card (EC-10).
  4. Two primitives for the later tickets, also in `history.js`: `ensureDays(n)`
     (span, C9-T10) and `ensureFrom(ms, keep)` (whole-tree view C9-T11, list
     view C9-T12, reconnect, C10-T03).
  5. Tests: one browser spec, two parity sequences added to C1-T03's runner, and
     the mutation checks listed in "Verification".
- **Scope.**
  - The `viewport()` skeleton (J:605–614: `#bd-content`, `#bd-lanes`,
    `#bd-guides`, `#bd-edges`, the three sections, the empty `#bd-now`) and its
    delegated hover and click listeners (J:618–635; the click listener is J:624–635). The listeners call
    functions owned by C9-T07, C9-T08, C9-T11 and C11 through `fx`, with no-op
    defaults until those tickets land.
  - The three section shells `.bd-sec` / `.bd-sech` / `.bd-layer` and their
    header text (J:656–660).
  - Placement and removal of `.bd-card` elements in the `hist`, `plan` and `nq`
    layers, and of `.bd-mk`, `.bd-lbl` and `.bd-dl` elements from the layout's
    `marks` and `labels`.
  - The scroll-anchor rule for history pages and live changes.
- **Non-goals.**
  - Row packing, density tiers, the flow rule, `histDays` and the layout
    constants: C9-T02 (`computeLayout`, `measureFlow`, `histDays`, `makeMark`,
    `placeMark`, `makeLabel`). This ticket calls them and reads `L`. It assigns
    `S.flow`/`S.K` from `measureFlow` and toggles `.flow` (C9-T02 non-goal).
  - Card content (`makeCard`, `cardDetail`, `decorate`): C9-T05. Until C9-T05
    merges, this ticket adds a placeholder `fx.makeCard` default (an empty
    `div.bd-card[data-id]`) to C9-T01's `fx` table; C9-T05 replaces it. Its
    parity checks compare geometry, not card pixels.
  - Column choice and lane headers (`visibleCols`, `applyCols`, the 220 ms
    debounce): C9-T04. `update()` and `relayout()` call them through `fx` as the
    design does. Until C9-T04 merges, the `fx` default is a stub column map (one
    equal-width column per `D.order` key, plus `unsorted`), read by `place()`
    through one accessor `colFor(it)` so C9-T04 swaps one line (C9-T04 note 3).
  - The `--dot` line (J:654): C9-T10 adds it.
  - The now band content (J:663–671), the live snap (`liveGuard`, `snapLive`,
    `scrollVP`) and `markScrolling`: C9-T08. This ticket sets the band height
    (J:662), leaves an `fx.renderBand` call site, and only reads the `snapping`
    and `scrolling` flags.
  - Edges (`drawEdges`): C9-T07. `update()` calls it as the design does.
  - Loading, empty and stale board states and the S-9 copy: C9-T13.
  - The server side of `load-earlier` (the handler and the day page): C3-T02
    (protocol, fixture source) and C8-T04 (real source).

## Dependencies and blockers

- **Blocked by DESIGN-E8** (feature gate E8-D6).
- **Predecessor: MP-E8-C9-T02** (`computeLayout`, `measureFlow`, `histDays`,
  `makeMark`/`placeMark`/`makeLabel`, the section `items`, `marks` and `labels`).
  Transitively after C9-T01 (`state.js` with `S`, `ctx`, `fx`, `onReset`, `LH = 46`,
  `SEC = 36`; `life.js`; the scroll handler and the 250 ms poller; `store.js`
  with `applyDiff` and `mergeEarlier`; `hook.js` `repaint()`), C3-T02 (payload
  v1, `load-earlier` reply, `decide`/`intake`, `/build-control/:action`), C3-T03
  (URL state) and C2-T04 (`build-home/home.css`, which carries the `.bd-sec*`
  rules).
- **Successors that call this ticket's interface:** C9-T04 (columns), C9-T05
  (cards), C9-T10 (span), C9-T12 (list) and C9-T13 (states) list this ticket in
  their `blocked_by`; C9-T07, C9-T08, C9-T09 and C9-T11 reach it through them.
- **May run concurrently with:** the C4–C8 server tickets and C10-T01. No other
  C9 ticket: C9-T04, T05, T10, T12 and T13 all wait for this one (their
  `blocked_by`). C9-T10 leaves J:642 to this ticket (C9-T10 note 1).
- **Shared contract:** C3-T02 schema v1: the `history` block
  (`{from, more, total, undated, tz}`) and the `earlier` reply with its
  `days: 1..31` parameter. Both fields this ticket asked for (`history.total`,
  the required `end` on `hist` rows) are now in C3-T02 (see "Interface notes").
- **Owner questions.** None block this ticket. The new "earlier days could not
  load" header text follows the S-9 default (unavailable is shown, never empty)
  and is sign-off item S-34 (an allowlist entry of kind `copy`).

## Verified starting point (`58854d4c8`)

**Product.** No home page and no `build-home/` directory exist yet. Everything
this ticket edits is PROPOSED by C2-T03, C3-T02 and C9-T01. Reused patterns:

- `src/priv/static/build-order-grid-hook.js:247-256`: `scheduleDraw` batches work
  into one `requestAnimationFrame` with a `drawScheduled` flag (with a
  `setTimeout(fn, 16)` fallback). `:486-488`: `destroyed` tears the grid down.
  The home hook uses the same two shapes (one pending flag; a `destroyed` guard).
- `src/lib/aiur_web/live/dashboard_live.ex:601-603` and
  `src/lib/aiur_web/components/operator_control_center/history.ex:84-91`: the
  product's only history paging today is a "Load more" button
  (`phx-click="load-more-history"`, `phx-disable-with="Loading…"`). It is server
  rendered. It is not reused: the home page pages by scroll position, as the
  design does.
- `src/lib/aiur_web/components/layouts.ex:276-278`: the socket sends the
  browser's IANA zone (`Intl.DateTimeFormat().resolvedOptions().timeZone`) as
  `time_zone`. The server's day pages use this zone (C3-T02), so server day
  boundaries and the browser's `fmtD` dates agree.
- `src/test/browser/fixture_server.exs:2264`: the `/streamdeck-control/:mode`
  control route. C3-T02 adds `/build-control/:action` next to it; this ticket
  adds three actions to it.
- `src/browser/tests/support/browser-helpers.mjs:102` (`settleAnimations`) and
  `:121-126` (`reconnectLiveView`). `reconnectLiveView` waits on
  `#worker-status[data-live-status]`, which only the harness LiveView renders
  (`src/test/browser/fixture_server.exs:377`), so it cannot be used on `/build`.
  This ticket's reconnect tests call `window.liveSocket.disconnect()` /
  `connect()` and wait for a new `data-build-epoch`, as C9-T01's B7 does.
  `src/browser/tests/support/measurements.mjs:7` (`measureBrowserWork`, which
  needs an injected `operation` name and a `targetSelector`, default
  `#graph-content`) and `:66` (`assertMeasurementBudget`);
  `src/browser/tests/build-order-performance.browser.spec.mjs:16-31` (the
  budget-object precedent for a performance spec).
- `src/browser/package.json:10`: the `test` chain that a new `test:*` script is
  appended to. `:25` `test:parity` is DASH-033's `parity-composition` spec, not
  the E8 harness; the E8 runners are C1-T02's `test:design-parity` and C1-T03's
  `test:build-home-motion` (both PROPOSED).

**Design** (what must be ported exactly):

- **`viewport()` J:604–636.** It replaces `#bd-vp`'s content with the skeleton
  (J:605–614), stores `content`, `lanesEl`, `guidesEl`, `svg`, `bandEl` and
  `secs[s] = {el, layer, head}` (J:615–616), clears `R`, `RL`, `laneEls`,
  `guideEls`, `cols`, `colMap` (J:617), adds the hover listeners (J:618–619),
  resets `lockId` (J:620), adds the `.bd-lt` tray (J:621–623) and one delegated
  click listener (J:624–635).
- **`relayout()` J:638–675.** `renderLoading()` while loading (J:639); the span
  rule (J:642); `renderList()` in list view (J:643); `viewport()` when there is
  no `content` (J:644); the flow rule (J:646–650); `if (lockId) unlock();
  closeTree();` (J:651: unlock only when locked, close the tree every time);
  `computeLayout()` (J:652); it clears all cards and marks (`R.forEach(remove)`,
  `RL.forEach(remove)`, J:655); writes the three headers (J:656–660); sets each
  section element's height from `L.secs[s].h` (J:661) and the band height
  (J:662); renders the band (C9-T08's part, J:663–671); sets `--fs` (J:672); and
  ends with `applyCols(visibleCols(), true); update(true)` (J:673–674).
- **Section headers** (J:657–660), exact strings:
  - History, more days on the server: `History <em>since {fmtD(histFrom)} — scroll
    up to load earlier days</em><em style="margin-left:auto;padding-right:14px">{shown}
    of {total} loaded</em>`;
  - History, everything loaded: `History <em>all {total} from {fmtD(first.start)}</em>`
    plus the same right-hand em;
  - History, none: `History <em>empty</em>` with no right-hand em;
  - Planned: `Planned <em>{n} in build-queue order · dependency waves</em>` or
    `Planned <em>queue empty</em>`;
  - Not queued: `Not queued <em>{n} open · not in the queue</em>`.
  - Only the two history numbers use `toLocaleString()` (J:658). The planned
    count and the not-queued count are plain `String(n)` (J:659–660), so 1,000
    planned tickets read `1000 in build-queue order`. The not-queued header has
    no empty branch (`0 open · not in the queue`). Dates use `fmtD` (J:15,
    `MON[month] + " " + date` in browser local time).
- **`update(force)` J:695–742.** Per section, the render window is
  `A = scrollTop − sectionTop − 700` to `B = scrollTop − sectionTop + clientHeight
  + 700` (J:706). An item is rendered when it overlaps `[A, B]`. The uid is
  `sec + ":" + id` for cards, `sec + ":m" + i` for marks and `sec + ":l" + i` for
  labels, with `uid + "d"` for a label's `.bd-dl` line (J:709, 716, 728, 733).
  A new card gets `.noanim` and loses it after two animation frames (J:711). A
  mark's left is 12 px for `wave` and the gutter otherwise; its width is
  `contentWidth − left − 12` (J:724). Anything not kept is removed
  (J:736–737). Then the `#bd-nowbtn` `.at` toggle (J:738–739, T08), `drawEdges`
  (J:740, T07), and the paging trigger `S.ready && !paging && scrollTop < 260 &&
  moreHistory()` (J:741).
- **`place(el, it)` J:757–767.** Top and height from the item. With no column
  for the item, `opacity: 0`, `pointer-events: none` and `left: 0px` if no left
  was set (J:760). Otherwise left =
  `c.x + lane · (c.w / lanes)`, width = lane width − 4 when lanes > 1, capped at
  70 px for `.mini`/`.bar` cards outside flow mode.
- **Paging J:743–755.** `histDays()` is the sorted set of local midnights of
  loaded history `end` times, cached in `D._days`. `initHistFrom()` keeps the last
  two days (one for `dense`). `loadEarlier()` moves `histFrom` back one day, then
  `relayout()` and `scrollTop = oldTop + (newHistH − oldHistH)`, with `paging =
  true` around it. In the design this is synchronous.
- **Span J:642.** When `S.span > 1`, `histFrom` is moved back so at least `span`
  days are loaded.
- **CSS** (C:192–196; C:886–888; C:1089–1090): `.bd-sec { position: relative;
  z-index: 2 }`, later `pointer-events: none`; `.bd-sech` absolute, top 0,
  `height: 36px`, flex, `gap: .6rem`, `padding-left: 14px`, `font: 700 .64rem
  "JetBrains Mono"`, `letter-spacing: .08em`, uppercase, `color: var(--muted)`,
  `border-top: 1px solid var(--line)` except the first section; `.bd-sech em`
  `font-style: normal`, `font-weight: 500`, `letter-spacing: .02em`, no transform, `color:
  var(--faint)`, `white-space: nowrap` (C:29); `.bd-layer { position: absolute;
  inset: 0 }`, `pointer-events: none`, cards in it `pointer-events: auto`, none
  while `.bd-content.scrolling`.
- **Card transitions** (C:227, 231, 466): `left`, `width`, `top`, `height`,
  `opacity`, `filter`; none on `.noanim` and under `.bd-root.rm`. The product
  takes these from C2-T04's stylesheet unchanged.
- **Not used:** `.bd-more` (C:413) has no markup in the design and C2-T04 deletes
  it. This ticket adds no in-flight visual.
- **Measured in C3-T02:** the initial window is 108 rows (`live`, 2 days) and 89
  rows (`dense`, 1 day); the densest `dense` day has 31 history rows.

## Chosen design

### Port, then change only three things

The design code is ported line for line into the two module files that C9-T01's
module table assigns to this ticket: PROPOSED
`src/priv/static/build-home/render.js` (`viewport`, `relayout`, `update`,
`place`, the anchor and the live mode) and PROPOSED
`src/priv/static/build-home/history.js` (`H`, `syncHistory`, `setPaging`,
`resetHistory`, `loadEarlier`, `ensureDays`, `ensureFrom`; R-G9). At import
time `render.js` runs
`Object.assign(fx, { viewport, relayout, update, dataChanged: onDataChanged, flushLive })`
and `history.js` runs `onReset(resetHistory)` (C9-T01 rules 1–3). Names, uids, the 700 px margin,
the 260 px trigger and all strings stay the same. Only three things change,
because the product's data is paged and live:

1. **`loadEarlier` is a server request** (below).
2. **`relayout` has a live mode** for data changes, which keeps DOM identity.
3. **The header's total comes from the server**, because the client no longer
   holds every history row.

`fx` defaults this ticket adds to C9-T01's `state.js` table (no-ops until the
owner lands, then the owner's `Object.assign` replaces them): `makeCard`
(placeholder `div.bd-card[data-id]`, replaced by C9-T05), `visibleCols` /
`applyCols` (stub column map, replaced by C9-T04), `drawEdges` (C9-T07),
`renderBand` (C9-T08), `renderList` and `openModal` (C9-T12 / C11), `onHover`,
`lockTree`, `fitTree`, `openTree` (C9-T07 / C9-T11). Each is one line.

### History state

The hook keeps the server's view of the window. It never derives it from
loaded rows. The source is `ctx.snap.history`, which C9-T01's `acceptSnapshot`,
`applyDiff` (`set.history`) and `mergeEarlier` keep current:

| Client field | Source | Replaces |
| --- | --- | --- |
| `S.histFrom` | `ctx.snap.history.from`; `0` when `null` | `initHistFrom()` (J:641, J:645) |
| `H.more` | `ctx.snap.history.more` | `moreHistory()` |
| `H.total` | `ctx.snap.history.total` (int or `null`) | `D.hist.length` in the header |
| `H.epoch` | `ctx.proto.epoch` at the last sync | (new: detects a reconnect) |
| `H.state` | `"idle"` \| `"loading"` \| `"error"` | the design's `paging` flag (kept as `paging = H.state === "loading"`) |
| `H.retryArmed` | see the retry rule | (new) |

`syncHistory()` copies these at the start of every `relayout()`. `H` is exported
(C9-T11 and C9-T12 read `H.more` and `H.state`, and C9-T12 sets
`H.retryArmed`). `resetHistory()` (an `onReset` callback) sets
`H = { state: "idle", retryArmed: true, epoch: null }` on every mount.

`histDays` is C9-T02's `histDays(D.hist)`, memoised per `hist` array. C9-T01
re-runs `intake` after every diff and page, so `D`, `D.hist` and `L` are new
objects and the design's per-object caches (`D._days`, `D._fwd`, `L._dayCols`,
J:687–689, J:744) start empty without extra clearing code.

`#build-root` carries `data-bd-paging="idle|loading|error"` (the name C9-T11 and
C10-T03 already wait on), so the parity harness and tests can wait for a
settled board.

### `loadEarlier()` as a request

```js
// history.js (PROPOSED). ctx.push is C9-T01's (e, p) => this.pushEvent(e, p):
// with no callback, LiveView 1.1 returns a Promise of the reply and rejects
// when the push cannot be sent (C9-T01 "Verified starting point").
let inflight = null;
export function loadEarlier(days = 1) {
  const root = ctx.root;
  if (H.state === "loading" && inflight) return inflight;   // the in-flight page, not a new one (R-G9)
  if (!H.more || !root || !root.isConnected) return Promise.resolve(false);
  if (H.state === "error" && !H.retryArmed) return Promise.resolve(false);
  const before = S.histFrom, epoch = ctx.proto.epoch;
  setPaging("loading");                                   // paging stays true until the anchor is restored (C9-T08)
  const fail = () => { if (root.isConnected) { H.retryArmed = false; setPaging("error"); } return false; };
  return inflight = ctx.push("load-earlier", days > 1 ? { before, days } : { before }).then((reply) => {
    if (!root.isConnected || ctx.root !== root) return false;            // hook gone or remounted: drop it
    if (!reply || reply.kind === "error") return fail();
    if (reply.epoch !== ctx.proto.epoch || epoch !== ctx.proto.epoch) { setPaging("idle"); return false; } // resync won
    if (!(reply.history && reply.history.from < before)) return fail();  // no progress (server bug)
    const anchor = takeAnchor();
    mergeEarlier(reply);                                  // C9-T01 store.js: keeps rows already present, replaces history, re-runs intake
    relayout({ live: true }); restoreAnchor(anchor);
    setPaging("idle");
    update();                                             // may fire the trigger again (filtered days)
    return true;
  }, fail).finally(() => { inflight = null; });
}
```

- **Single flight.** A second call while one is in flight returns the
  in-flight promise and sends nothing.
- **Retry rule.** After an error, the trigger in `update()` does not fire again
  until the viewport has been scrolled to 260 px or more and back (`retryArmed`
  becomes true in `update()` when `scrollTop ≥ 260`). A new epoch also re-arms
  it. This stops a request loop while the user sits at the top. C9-T12's
  explicit "Load earlier day" click sets `H.retryArmed = true` itself.
- **Error text.** While `H.state === "error"`, the history header's first em
  reads `since {date} — earlier days could not load · scroll up to retry`. It
  uses the existing `<em>`, so no style changes. It is one of the three new
  strings (with "total unknown" and the interim "unavailable", below).
- **Merge.** C9-T01's `mergeEarlier(msg)` checks the epoch again, adds each row
  whose `id` is not loaded, replaces `history` and re-runs `intake`. A row that
  is already present is kept, because a diff is newer than a page (C3-T02). This
  ticket adds no second merge or indexing code.
- **No client day arithmetic.** `before` is always the current `S.histFrom`, and
  the new `S.histFrom` is the reply's value. The client never subtracts
  86,400,000 ms, so DST days (23 or 25 hours) are correct.
- **Ordering for C9-T08.** `paging` is `true` from the push until
  `restoreAnchor` has run, so `liveGuard` and `snapLive` never act on a
  half-loaded board (C9-T08 interface note).

### The scroll anchor (EC-09, EC-10)

One rule covers a history page, a live change and a reconnect:

- **Take** (before the data change):
  - if the band's natural top (`nat = secs.hist.el.offsetTop + L.secs.hist.h`,
    the same expression as J:587 and J:595) is inside the viewport, the anchor is
    `{kind: "band", off: nat − scrollTop}`;
  - otherwise, the anchor is the list of up to three rendered cards in `hist`,
    `plan` or `nq` whose top is nearest below `scrollTop + LH`, each as
    `{uid, off: absTop − scrollTop}`.
- **Restore** (after `relayout`): the first anchor card that still exists under
  the same uid sets `scrollTop = newAbsTop − off`. If none exists (all three moved
  section or left), or the anchor is the band, `scrollTop = newNat − off`.
- **For a history page** this gives the design's result exactly: rows are added
  above, so every anchor moves down by `newHistH − oldHistH`, which is J:753.
- **No board.** `takeAnchor()` returns `null` when `ctx.L` or `ctx.content` is
  `null` (list view, loading, unavailable), and `restoreAnchor(null)` does
  nothing (C9-T12 interface note 1).

### Live mode of `relayout` (`relayout({ live: true })`)

C9-T01's `receive` applies a diff with `applyDiff` (it owns `decide`, the
upserts, the removes, `set` and `intake`), then calls `fx.dataChanged(msg)`. This
ticket sets `fx.dataChanged = onDataChanged`. `onDataChanged(msg)`:

1. Collects the ids: `changed` = `msg.upsert` ids, `removed` = `msg.remove`.
   When `msg.set` has a key, it calls C9-T01's `renderChrome()` first, as
   `defaultDataChanged` does (C9-T01 exports `renderChrome` from `hook.js` for
   this; one `export` keyword if it is missing).
2. Adds them to `pendingLive` (two `Set`s) and returns if any of these is
   active: `paging`; `ctx.snapping` (C9-T08 sets it; `undefined`, so false,
   before C9-T08); `ctx.content?.classList.contains("scrolling")` (guarded:
   `ctx.content` is `null` in list view, C9-T12; set by
   C9-T08's `markScrolling`); `document.querySelector(".bd-sb.drag")` (C9-T01's
   scrollbar drag).
3. Otherwise schedules `ctx.life.frame("live", flushLive)`, so a burst of diffs
   inside one frame makes one pass.

`flushLive()` does nothing while any of the four is active or `pendingLive` is
empty. Else: take the anchor, `relayout({ live: true })`, restore the anchor,
`update()`, clear `pendingLive`. This ticket adds one `fx.flushLive()` call at
the top of C9-T01's existing 250 ms poller body (J:568–569 port), so a deferred
change runs at most 250 ms after the flag clears. No new interval: C9-T01's B11
counts exactly two (`syncSB` and the poller). C9-T08 may also call
`fx.flushLive()` when a snap ends. A change never moves the page under a
finger, a scrollbar drag or a running snap.

`relayout({ live: true })` is `relayout()` with three differences:

- It does **not** clear `R`. It removes only the elements whose id is in
  `changed` or `removed`; `update()` recreates the changed ones with `.noanim`.
  Kept elements get `.noanim` for this pass (removed after two frames, as in
  J:711), so nothing slides: the visual result equals the design's full
  relayout. Kept elements are re-placed by `update()` from the new `L` items.
- It calls `unlock()` only when the locked id is no longer in `D.byId`, and
  `closeTree()` only when the open tree's root is gone (C9-T11 functions; no-ops
  before C9-T11).
- **Focus.** If `document.activeElement` is a card whose element was removed, the
  new element with the same `data-id` gets `focus({ preventScroll: true })` after
  `update()`. If the ticket left the board, focus goes to `#bd-vp`.
- **Focused card stays rendered.** `update()` records the focused card's id in
  `ctx.a11y.focusId` (C12-T05 reads it) and renders that card even when it lies
  outside the ±700 px window, so scrolling never removes the focused node.

**Reconnect.** C9-T01's `repaint()` (after a resync with a new epoch) calls
`fx.relayout(); fx.update()` and keeps `scrollTop`. This ticket's `relayout()`
detects it in `syncHistory()` (`H.epoch !== null && H.epoch !== ctx.proto.epoch`).
It then takes the anchor and remembers the old `S.histFrom` before it syncs, runs
the normal (full) relayout, restores the anchor and focus, re-arms
`H.retryArmed`, and calls `ensureFrom(oldFrom)` when `oldFrom < S.histFrom`. The
anchor can be taken at that point because the old DOM and the old `L` are still
in place. C9-T01 needs no change for this.

### `ensureDays(n)` and `ensureFrom(ms)`

```js
// days: C3-T02 accepts 1..31 per request and returns the latest `days` active days before `before`.
export async function ensureDays(n) {
  while (histDays(ctx.D.hist).length < n && H.more &&
         await loadEarlier(Math.min(31, n - histDays(ctx.D.hist).length)));
}
export async function ensureFrom(ms, keep = () => true) {   // keep(): stop predicate (C10-T03)
  while (S.histFrom > ms && H.more && keep() && await loadEarlier());
}
```

- `relayout()` replaces the synchronous J:642 line with
  `if (S.span > 1 && histDays(D.hist).length < S.span && H.more) ensureDays(S.span)`.
  The board paints first; the page arrives above it and the band anchor keeps
  the viewport still. With the `days` parameter a span of up to 32 days is one
  request, not one per day.
- On a reconnect, `relayout()` calls `ensureFrom(oldFrom)` (above), so the
  user's position survives it. `ensureFrom` pages one day at a time, because
  the client does not know how many active days lie between the two `from`
  values.
- C9-T11 (J:959) and C9-T12 (J:1180) call `ensureFrom` and `loadEarlier`
  instead of setting `S.histFrom` directly.
- Each loop is sequential and stops on `more: false`, an error, no progress, or
  (for `ensureFrom`) `keep()` returning false, checked before each page.
  It has no other cap: each step is one bounded server call.

### Section headers

`renderHeads()` is J:656–660 with the history total from `H.total`. The
planned and not-queued headers are J:659–660 unchanged (plain numbers, no
`toLocaleString`):

| `D.hist` loaded | `H.more` | `H.total` | `H.state` | History header |
| --- | --- | --- | --- | --- |
| 0 | false | 0 or null | any | `History <em>empty</em>` (C9-T13 replaces this when `sources.history` is not `ok`/`stale`) |
| > 0 | true | int | idle/loading | `since {fmtD(histFrom)} — scroll up to load earlier days` + `{shown} of {total} loaded` |
| > 0 | true | null | idle/loading | same first em + `{shown} loaded · total unknown` |
| > 0 | true | any | error | `since {date} — earlier days could not load · scroll up to retry` + the right em as above |
| > 0 | false | any | any | `all {loaded} from {fmtD(firstStart)}` + `{shown} of {loaded} loaded` |

- `shown` counts loaded history rows with `end >= S.histFrom`, as J:657.
- `firstStart` is the earliest non-null `start` among loaded history rows. If
  every `start` is null, the first em reads `all {loaded}` with no date. It never
  formats `null` (which `fmtD` would show as "Jan 1").
- When `sources.history.state` is `unavailable` or `disabled`, the history
  header shows `History <em>unavailable</em>` until C9-T13 brings the S-9 copy.
  It never shows `empty` or `0 of 0`.
- `history.undated` (closed tickets with no known `end`, C3-T02) is not shown:
  the design has no place for it. C9-T13 or C8-T04 decide whether it needs one.

### Interface this ticket exposes (for C9-T01, T04–T13)

| Name | Shape | Caller |
| --- | --- | --- |
| `fx.viewport()` | as J:604 | `relayout()` (J:644); C9-T04 and C9-T12 rely on it |
| `fx.relayout(opts?)` | `{live?: bool}` → void | C9-T01 `repaint`/`firstPaint`, C9-T04, T05, T08, T10, T11, filters (C10) |
| `fx.update(force?)` | as J:695 | scroll handler and poller (C9-T01), C9-T04 |
| `place(el, it)` | as J:757; reads columns through `colFor(it)` | C9-T04 (column changes) |
| `fx.dataChanged(msg)` = `onDataChanged` | the applied `build-diff` message | C9-T01 `receive` after each applied diff |
| `fx.flushLive()` | void | C9-T01's 250 ms poller (one added line); C9-T08 after a snap ends |
| `loadEarlier(days = 1)` (`history.js`) | `Promise<bool>`; the in-flight promise while loading | `update()`; `ensureDays`; C9-T12 "Load earlier day" |
| `ensureDays(n)`, `ensureFrom(ms, keep?)` (`history.js`) | `Promise<void>` | `relayout()` (span, reconnect), C9-T10, C9-T11, C9-T12, C10-T03 |
| `H` (`history.js`) | `{state, more, total, epoch, retryArmed}` | C9-T11, C9-T12 (read; C9-T12 sets `retryArmed`) |
| `takeAnchor()`, `restoreAnchor(a)` | as above; `null`-safe | C9-T12 list view |
| `ctx.a11y.focusId` | id of the focused card, or `null` | C12-T05 |
| `#build-root[data-bd-paging]` | `idle` \| `loading` \| `error` | C1-T02, C1-T03, C9-T11, C10-T03, tests |

## Implementation steps

1. **Port the code.** Copy J:604–636 (`viewport`), J:638–675 (`relayout`),
   J:695–742 (`update`), J:743–755 (paging) and J:757–767 (`place`) into
   PROPOSED `build-home/render.js`. Keep every name, uid shape, constant (700,
   260, 12, 14) and string. Calls to functions owned by other tickets
   (`applyCols`, `visibleCols`, `drawEdges`, `makeCard`, `renderBand`,
   `renderList`, `openModal`, `onHover`, `lockTree`, `unlock`, `closeTree`,
   `chainOf`, `fitTree`, `openTree`) go through `fx`; add the missing no-op
   defaults (and the placeholder `makeCard` and stub column map) to C9-T01's
   `state.js` table, one line each. Use C9-T02's `measureFlow`, `histDays`,
   `makeMark`, `placeMark` and `makeLabel` in place of the inlined J:646–649,
   J:744, J:719–724 and J:730–733 code. Leave the J:654 `--dot` line to C9-T10.
   Register with one `import "./render.js"` line in `hook.js`.
2. **History state** (`history.js`). Add `H`, `syncHistory()`, `resetHistory()` (an `onReset`
   callback) and `setPaging(state)` (it also writes `data-bd-paging` on
   `ctx.root`). `syncHistory()` reads `ctx.snap.history` at the start of
   `relayout()`. Remove `initHistFrom` and the `D.kind === "dense"` test.
3. **`loadEarlier` request** (`history.js`) and the retry rule in `update()`. It calls C9-T01's
   `mergeEarlier(reply)`; no new merge or indexing code.
4. **Anchor:** `takeAnchor()` and `restoreAnchor(a)`, both `null`-safe.
5. **Live mode:** `onDataChanged`, `pendingLive`, `flushLive`, the `live` branch
   of `relayout`, focus restore. Set `fx.dataChanged` and `fx.flushLive`; add the
   one `fx.flushLive()` line to C9-T01's 250 ms poller body.
6. **Reconnect** branch of `relayout()`, **`ensureDays` / `ensureFrom`**, and the
   J:642 replacement.
7. **Headers:** `renderHeads()` per the table; the error and unknown branches.
8. **Fixture controls** (in C3-T02's `/build-control/:action`; C3-T02 ships
   `diff` and `skip`, this ticket adds query options and one action):
   - `diff?op=move&id=<id>&to=<sec>`: one upsert of that row with a new `sec`
     (and `end = now` for `hist`);
   - `diff?op=title&id=<id>`: one upsert that changes only the title;
   - `earlier?fail=<n>` (the next n `load-earlier` calls reply `unavailable`),
     `earlier?delay=<ms>` and `earlier?stall=1` (no progress: the reply repeats the
     current `from`); `earlier?from=<ms>` (the next reply's `history.from`, for
     the DST test).
9. **Tests** (next section) and the npm script
   `"test:build-home-render": "node scripts/run-browser-tests.mjs tests/build-home-render.browser.spec.mjs"`,
   appended to the `test` chain at `src/browser/package.json:10`.
10. **Parity sequences** `history.load-earlier` and `history.window` added to
    C1-T03's runner, with the owner entry
    `'history.*': { owners: ['MP-E8-C9-T03'], anchor: '#build-root[data-bd-paging]' }`
    in its `OWNER` table.

## Non-happy paths

| Input | Expected behaviour | Test |
| --- | --- | --- |
| `load-earlier` replies `{kind: "error", reason: "unavailable"}` | `data-bd-paging="error"`; header shows the error em; no second request while `scrollTop < 260`; after scrolling to ≥ 260 and back, one new request | `paging error and retry` |
| Reply's `history.from` is not earlier than `before` (server bug) | treated as an error; no request loop | `paging no progress` |
| Reply arrives after a resync with a new epoch | ignored; `S.histFrom` comes from the new snapshot; state `idle` | `paging epoch change` |
| Reply arrives after the hook is destroyed (navigation) | the handler returns without touching the DOM (`ctx.root` detached); no exception in the console | `paging after destroy` |
| The push is rejected (socket down mid-request) | state `error`, no exception; after the reconnect a new epoch re-arms the retry and `ensureFrom` restores the window | `reconnect restores window` |
| Scroll stays near the top while a request is in flight | exactly one request (single flight) | `paging single flight` |
| Page with rows the client already has (a diff came first) | the client's row is kept; no duplicate card | `paging keeps newer row` |
| Epic filter hides every row of a loaded day | the `update()` at the end of the reply fires the trigger again; pages continue until the history grows past the trigger or `more` is false; never two in flight | `paging through filtered days` |
| History row with `end: null` | cannot reach this ticket: C3-T02's validator requires an integer `end` on `hist` rows (counted in `history.undated` instead), and C9-T02 keeps such a row out of `histDays` and the layout (its N12) | — (C3-T02, C9-T02) |
| `history.total` is `null` or missing | header shows `{shown} loaded · total unknown`; never `of 0`, never `of {shown}` | `total unknown` (mutation) |
| All loaded history rows have `start: null` | `all {n}` with no date; never `Jan 1` | `first start unknown` (mutation) |
| `sources.history` is `unavailable` and no rows | header `History <em>unavailable</em>`, never `empty` | `history unavailable is not empty` (mutation) |
| A ticket moves `plan` → `now` while the viewport shows `nq` | the anchored `nq` card keeps its viewport offset within 1 px | `live move keeps anchor` |
| A ticket moves `now` → `hist` while the band is in view | the band keeps its viewport offset within 1 px | `live move keeps band` |
| A diff arrives during a scrollbar drag, a snap or active scrolling | no `scrollTop` change until the flag clears; then one pass | `live deferred during drag` |
| 20 diffs in 1 s | while scrolling: no pass until the scroll settles, then one; otherwise at most one pass per animation frame | `live coalesces` |
| A diff changes the focused card's title | focus is on the new element with the same `data-id` | `live keeps focus` |
| A diff while a tree is locked (C9-T11) and the locked id still exists | the lock stays | `live keeps lock` (added when C9-T11 merges; listed in its handoff) |
| Span 30 requested on a 1-day window | one request with `days: 29`; a second only if the reply has fewer days and `more` is still true; the band stays still | `span ensures days` |
| Reconnect after paging back 5 days | after the new snapshot, `ensureFrom` reloads the 5 days; the anchor card is back at its offset | `reconnect restores window` |
| Resize | not this ticket: C9-T01's resize handler keeps the scroll fraction (J:572) | — |

Security: rows from a page go through the same `esc` rendering as snapshot rows
(C3-T02 EC-30). This ticket adds no new HTML sink; the header numbers are
numbers and dates from `fmtD`.

## Compatibility and rollout

- No configuration key, CLI flag or environment variable. No user-facing docs:
  the page is not reachable at `/` until C12-T01; C12-T07 documents it.
- The new header text (error, total unknown, history unavailable) is a C1-T02
  allowlist entry of kind `copy` with status `pending-sign-off` (S-34) until
  Kevin signs DESIGN-E8.
- Rollback: the page is behind the temporary `/build` route until cutover; revert
  the files.

## Pixel parity

- **Design elements:** `.bd-sec`, `.bd-sech` (with both `em`s), `.bd-layer`; the
  placement of `.bd-card`, `.bd-mk`, `.bd-lbl`, `.bd-dl` in the three layers;
  J:604–767.
- **Screenshot check (C1-T02):** element screenshots of `#bd-sec-hist .bd-sech`,
  `#bd-sec-plan .bd-sech` and `#bd-sec-nq .bd-sech` for `live`, `dense`,
  `newrepo` and `noqueue`, at 1440 and 390 px, dark and light, against the design
  at the same `scrollTop`. The product waits for `data-bd-paging="idle"`. The
  header text must be identical character for character. C3-T02's fixture
  source sends `history.total = D.hist.length` (C3-T02 step 5), so the
  `{shown} of {total} loaded` text matches.
- **Geometry check (until C9-T05):** for every rendered `.bd-card[data-id]` in
  the three section layers, `{top, height}` of the product equals the design
  within 1 px, and the set of rendered ids is equal. `{left, width, opacity}`
  join the check when C9-T04 replaces the stub column map (C9-T04 adds them).
  `.bd-mk`, `.bd-lbl` and `.bd-dl` are compared on `{top, height, left, width}`
  and text. Run at
  three scroll positions per dataset: the live position after load, 2,000 px
  above it, and the top of the loaded history. After C9-T05 merges, the C1-T02
  full-board screenshots replace this check.
- **Motion check (C1-T03 sequences this ticket adds):**
  - `history.load-earlier`: on `live`, scroll to `scrollTop = 200`. The design
    pages synchronously; the product pages through the fixture server. After
    `data-bd-paging="idle"`, both pages have the same `S.histFrom` (read from the
    history header), the same `scrollTop` within 1 px, and the same rendered card
    set. No card has a running transition (`getAnimations()` empty on
    `.bd-card`).
  - `history.window`: on `dense`, scroll in 300 px steps from the band to the top
    of loaded history. After each step, the set of rendered `(section, data-id)`
    pairs is equal on both pages.
- **Not checkable against the design:** live diffs, errors and reconnects (the
  design has no live data). These are covered by the product-only tests below.

## Verification

Browser spec, PROPOSED `src/browser/tests/build-home-render.browser.spec.mjs`
(product page via C1-T02's `productUrl(dataset)` over `GET /build-fixture/:dataset`,
then `/build`; control route `/build-control/...`).
Requests are counted with `page.on("websocket")` frame listeners filtered on the
`load-earlier` event name. Live passes are counted with
`performance.getEntriesByName("bd-live-pass")` (`flushLive` calls
`performance.mark("bd-live-pass")`; no test-only global). The three header tests
call the exported pure function `headHTML(sec, D, S, H, sources)` (which
`renderHeads()` uses) through `page.evaluate(async () => (await
import("/build-home/render.js")).headHTML(...))`, as C9-T01's tests import
`state.js`.

| Test | Setup | Expected | Fails without (mutation) |
| --- | --- | --- | --- |
| `window bounds` (EC-09) | `dense`, at each of 5 scroll positions | every rendered card overlaps `[scrollTop − 700, scrollTop + clientHeight + 700]` in its section's coordinates; every item that overlaps it is rendered | change 700 to `Infinity` (all render), or to 0 (cards missing at the margin) |
| `window recycles` | `dense`, scroll down 300 px and back | a card that stayed in the window is the same DOM node (`===` against a reference kept in the page before the scroll) | clear `R` in every `update()` |
| `paging request` | `live`, scroll to 200 | one `load-earlier` with `before` = the snapshot's `history.from` and no `days`; afterwards `S.histFrom` = the reply's `from` | the trigger at J:741 removed |
| `paging keeps anchor` | `live`, note the top visible card's offset, scroll to 200 | after idle, that card's offset is unchanged within 1 px | drop `restoreAnchor` (page jumps by one day's height) |
| `paging holds the flag` | `live`, `earlier?delay=300`, scroll to 200; a `scroll` listener on `#bd-vp` records `data-bd-paging` at each scroll event | the value recorded at the restore's scroll event is `loading`; it is `idle` after the reply | set `idle` before `relayout`/`restoreAnchor` (the C9-T08 race) |
| `paging single flight` | `earlier?delay=500`, scroll to 100, then 50, then 0 | exactly one request in flight; one more after the first reply if still < 260 | remove the `loading` guard |
| `paging error and retry` | `earlier?fail=1`, scroll to 0 | header shows the error em; no request for 2 s while at the top; scroll to 400 and back → one request; success clears the error | remove `retryArmed` (request loop: > 1 request in 2 s) |
| `paging no progress` | `earlier?stall=1` | state `error`, at most 1 request in 2 s | remove the `from < before` check |
| `paging epoch change` | `earlier?delay=500`, scroll to 0, then `window.liveSocket.disconnect()` / `connect()` during the delay and wait for a new `data-build-epoch` | the late reply is ignored; `S.histFrom` matches the new snapshot | remove the epoch comparison |
| `paging after destroy` | `earlier?delay=500`, scroll to 0, then `live_redirect` to `/commands` | no `pageerror` event; no `data-bd-paging` write on a detached node | remove the `root.isConnected` checks |
| `paging keeps newer row (guard: C9-T01 mergeEarlier)` | `diff?op=title&id=<a row of the earlier day>` before the page, then page | the card shows the diff's title | merge overwrites existing rows. Guards C9-T01's merge rule through this ticket's call; not counted as coverage of this change |
| `paging through filtered days` | `?epic=<an epic absent from 2 days>`, scroll to 0 | requests continue without further scrolling until the section grows past 260 px or `more` is false; never two in flight | drop the final `update()` in the reply handler (paging stops after one day until the user scrolls) |
| `total unknown` | `headHTML("hist", …)` with 10 loaded rows, `H.more = true`, `H.total = null` | right em is `10 loaded · total unknown` | replace the null branch with `?? 0` (shows `of 0`) or with `?? shown` (shows `of 10`) |
| `first start unknown` | `headHTML("hist", …)`, `H.more = false`, every loaded `start` null | first em is `all {n}` with no date | replace the branch with `fmtD(D.hist[0].start)` (shows "Jan 1") |
| `history unavailable is not empty` | `headHTML("hist", …)`, `sources.history.state = "unavailable"`, no rows | header is `History <em>unavailable</em>` | map unavailable to the empty branch |
| `planned count is not localised` | `headHTML("plan", …)` with 1,200 plan rows | `Planned <em>1200 in build-queue order · dependency waves</em>` | add `toLocaleString()` to the planned count |
| `live move keeps anchor` (EC-10) | `live`, scroll so an `nq` card is the anchor; `diff?op=move&id=<plan id>&to=now` | anchor card offset unchanged within 1 px | drop `restoreAnchor` in `flushLive` |
| `live move keeps band` (EC-10) | at the live position; `diff?op=move&id=<now id>&to=hist` | band top offset unchanged within 1 px | anchor on the first card instead of the band |
| `live deferred during drag` | pointer down on `#bd-sb > i`; send a move diff; hold 500 ms | `scrollTop` changes only by the pointer; after pointer up, exactly one `bd-live-pass` within 300 ms | remove the deferral check, or the `fx.flushLive()` line in the poller (no pass after pointer up) |
| `live coalesces` | 20 `diff?op=title` calls in 1 s while the test scrolls `#bd-vp` by 20 px every 50 ms | 0 passes while scrolling; exactly 1 after the scroll settles | call the pass for every diff |
| `live keeps focus` | focus a `plan` card; `diff?op=title&id=<that id>` | `document.activeElement.dataset.id` is the same id | remove the focus restore |
| `live no slide` | `diff?op=move` that shifts kept cards | no running transition on any kept `.bd-card` | remove the `.noanim` on kept cards |
| `span ensures days` | `?span=3` on `dense` (1 day loaded) | exactly 1 request, with `days: 2`; header `since` date is the third-latest active day; band offset unchanged | keep the design's synchronous J:642 line (no request; only 1 day shown), or drop `days` (2 requests) |
| `reconnect restores window` | page back 3 days; `liveSocket.disconnect()` / `connect()`; wait for a new `data-build-epoch` | 3 requests after the snapshot; anchor card offset within 1 px | no `ensureFrom` call on a new epoch |
| `DST from` | `earlier?from=<before − 23 h>` | `S.histFrom` equals the reply value exactly | compute `before − 86_400_000` on the client |

Performance guard (EC-09, budget proposal; C12-T06 sets the final budgets):
`measureBrowserWork(page, { operation: "bd-scroll-step", targetSelector: "#bd-content" })`
(`measurements.mjs:7`) on `dense` for one 300 px scroll step, checked with
`assertMeasurementBudget` (`:66`): the rendered card count is ≤ 3 × the cards
that fit in the viewport, and no long task over 50 ms. The 50 ms long-task
threshold avoids a per-frame wall-clock budget, which is noisy on CI runners
(the precedent `build-order-performance.browser.spec.mjs:16-31` uses generous
bounds for the same reason). The test name says it is a regression guard.

Commands:

```bash
env -C src/browser mise exec -- npm run fixture:preflight
env -C src/browser mise exec -- npm run test:build-home-render
env -C src/browser mise exec -- npm run test:design-parity      # C1-T02 runner: header screenshots, geometry check
env -C src/browser mise exec -- npm run test:build-home-motion  # C1-T03 runner: history.* sequences
```

Mutation check (AGENTS.md): for each row with a mutation, apply it in a
worktree, confirm `git status --porcelain` shows only that hunk, run the test,
see it fail, restore it, see it pass. Record the exact commands in the PR body.

## Completion and handoff

- [ ] `viewport`, `relayout`, `update` and `place` ported into `render.js` with
      the design's names, uids, constants and strings; cross-module calls go
      through `fx` with one-line defaults.
- [ ] `loadEarlier` is a single-flight `load-earlier` request with the error,
      retry and no-progress rules; `paging` covers the request until the anchor
      is restored; `data-bd-paging` is written.
- [ ] The anchor rule keeps the viewport still for pages, live changes and
      reconnects; it is `null`-safe in list view.
- [ ] Live mode keeps DOM identity, focus and the lock, defers during drag, snap
      and scroll, coalesces bursts, and adds no interval.
- [ ] `ensureDays` (with the `days` parameter) and `ensureFrom` exist; J:642
      uses `ensureDays`.
- [ ] Unknown total, unknown first start and unavailable history never render as
      `0`, a default date or `empty`; each has a passing mutation test.
- [ ] The header screenshots and the `{top, height}` geometry check pass against
      the design; the two C1-T03 sequences pass.
- [ ] The three new header strings are in the C1-T02 allowlist
      (`design-parity-allowlist.json`), kind `copy`, status `pending-sign-off`
      (S-34).
- **Dependents:** C9-T04 (replaces the stub column map behind `colFor`; adds
  `{left, width, opacity}` to the geometry check), C9-T05 (replaces the
  placeholder `fx.makeCard`; then adds the full-board screenshot), C9-T08
  (fills `fx.renderBand`; sets `ctx.snapping`; may call `fx.flushLive` after a
  snap), C9-T10 (`ensureDays`, the `--dot` line), C9-T11 (`ensureFrom`, `H`,
  adds `live keeps lock`), C9-T12 (`loadEarlier`, `H.retryArmed`, `null`-safe
  anchor), C9-T13 (replaces the interim `unavailable` header with the S-9
  copy), C12-T06 (re-measures on 10,000 tickets).
- **Docs:** none (not user-reachable before C12-T01; C12-T07 documents the
  page).
- **Sources:** `tickets/README.md` row C9-T03 and its neighbours; `chunks.md`
  C9; `plan.md` §8 (EC-09, EC-10, EC-19), §9 (K-3, K-8); C3-T02 "Snapshot",
  "Diff", "History page"; C9-T01 "Module layout", `fx`, `store.js`, `hook.js`;
  C9-T02 exports; C9-T08, C9-T12 interface notes; C1-T03 `OWNER` table; J and C
  lines cited above; product paths cited in "Verified starting point".

## Interface notes (mismatches with neighbour rows)

1. **History total: resolved in C3-T02.** The `history` block is now
   `{from, more, total, undated, tz}` in the snapshot, the `earlier` reply and
   diff `set.history`, and the fixture source sends `total = D.hist.length`.
   The header screenshot check can pass.
2. **`end: null` on history rows: resolved in C3-T02.** The validator requires an
   integer `end` on `hist` rows; such tickets are counted in `history.undated`.
   C9-T02 also keeps a row without `end` out of the layout. This ticket adds no
   third defence.
3. Settled 2026-10-08: C1-T02's ready condition waits for
   `#build-root[data-bd-mounted]` and `#build-root[data-bd-paging="idle"]` (R-G7).
4. **C9-T01's diff seam is `fx.dataChanged(msg)`,** not a `{changed, removed}`
   call. This ticket adapts to it (derives the ids from `msg.upsert` and
   `msg.remove`) and needs `renderChrome` exported from `hook.js`. C9-T01's
   poller gets one added `fx.flushLive()` line; C9-T01's `fx` table gets the
   one-line defaults listed in "Port, then change only three things". These
   C9-T01 edits are made in this ticket's PR (R-G4).
5. Settled 2026-10-08: paging (`loadEarlier`, `ensureDays`, `ensureFrom`, `H`)
   lives in this ticket's `history.js` (R-G9); `loadEarlier` returns the
   in-flight promise; `ensureFrom` takes a stop predicate (C10-T03).
6. **`viewport()` is not in the README row** but C9-T01's module table, C9-T04
   step 3, C9-T08 and C9-T12 all assign it to this ticket, and `relayout()`
   calls it (J:644). This ticket ports it. The README row should list
   J:604–636.
7. **C9-T11 and C9-T12 set `S.histFrom` directly in the design** (J:959, 1180).
   With server paging they call `ensureFrom` / `loadEarlier`, or they show days
   that were never loaded. Both tickets already say so.

## Decisions made without the owner

1. **Paint first, then page.** With `span > 1` the board paints with the initial
   window and loads the missing days above it, with the band as the anchor.
   The other choice (hold the skeleton until all days load) delays first paint.
   With C3-T02's `days` parameter this is one extra round trip for any span up
   to 32 days.
2. **`ensureFrom` pages one day per request.** The client cannot know how many
   active days lie between two `from` values without day arithmetic, which
   decision 8 forbids. Reconnect and whole-tree view are rare; each step is
   bounded.
3. **A live change keeps DOM nodes** instead of the design's full clear in
   `relayout()`, with `.noanim` so the pixels are the same. Reason: focus,
   hover and the lock must survive frequent diffs (EC-10, EC-19). A reconnect
   uses the design's full relayout plus the anchor and focus restore, because
   the client cannot tell which rows changed while it was offline.
4. **Live changes wait for drag, snap and active scroll to end**, then apply in
   one pass from the existing 250 ms poller; otherwise once per animation
   frame. No new interval.
5. **Three new header texts**, all in the existing `<em>`: the failed-page text,
   "total unknown" and an interim "unavailable". The design has no failure
   state; S-9's default is to show unavailable, never empty. These are
   allowlisted (`copy`, `pending-sign-off`) as S-34 until Kevin approves them.
6. **No in-flight visual.** The design pages synchronously and has no loading row
   (`.bd-more` is dead CSS that C2-T04 does not emit). A day page is one small
   reply.
7. **Retry after leaving the trigger zone**, not on a timer. This avoids a
   background request loop when the server cannot serve history. A new epoch
   and an explicit click (C9-T12) also re-arm it.
8. **The server owns the window** (`history.from`, `more`). The client does no
   day arithmetic, so DST and time-zone day boundaries come from one place.
9. **A stub column map before C9-T04.** `place()` hides any card with no column
   (J:760), so without a stub nothing would be visible and the geometry check
   could not run. The stub is one equal-width column per `D.order` key behind
   `colFor(it)`; C9-T04 deletes it. Until then parity checks compare only
   vertical geometry.
10. **`history.undated` is not shown.** The design has no place for it; adding
    one is a design change for DESIGN-E8, not this port.

## Review log

Adversarial review, 2026-10-08 (sources: runtime `58854d4c8`, design-source,
C3-T02, C9-T01, C9-T02, C9-T04, C9-T08, C9-T10, C9-T12, C1-T02, C1-T03).

1. Corrected design line citations: `relayout` J:638–675 (not 673), `place`
   J:757 (not 756), R clear J:655 (not 651), unlock/closeTree J:651 (not 648;
   unlock only when locked), band J:662–671, `applyCols`/`update(true)`
   J:673–674, render window J:706, uids J:709/716/728/733, `.noanim` J:711,
   mark left J:724, removal J:736–737, `#bd-nowbtn` J:738–739, `drawEdges`
   J:740.
2. Added `viewport()` (J:604–636) to scope: C9-T01's module table and C9-T04,
   C9-T08, C9-T12 assign it to this ticket; the draft dropped it silently.
3. Moved paging from a PROPOSED `history.js` into `render.js`, per C9-T01's
   module table.
4. Replaced the invented `onDataChanged({changed, removed})` seam with C9-T01's
   real `fx.dataChanged(msg)`, kept the `renderChrome` call, and wired
   `flushLive` into the existing poller instead of an unstated hook (C9-T01's
   B11 counts two intervals).
5. Replaced the draft's own `mergeEarlier(D, rows)` and `reindex` extraction
   with C9-T01's `store.js` `mergeEarlier(msg)` (no duplicate merge code);
   `P.epoch`/`hook.pushEvent` replaced by `ctx.proto.epoch`/`ctx.push` (a
   Promise in LiveView 1.1.33); added the rejected-push path.
6. Fixed the C9-T08 race: `paging` now stays `true` until `restoreAnchor` has
   run; added the `paging holds the flag` test.
7. Reconnect: C9-T01 does not call `ensureFrom`; this ticket now detects a new
   epoch in `relayout()` and does it.
8. Interface notes 1 and 2 were stale: C3-T02 now has `history.total`/`undated`
   and requires `end` on `hist` rows. Removed the "header check fails by
   design" claim and the redundant `null end` test (C9-T02 N12 owns it); used
   C9-T02's `histDays(D.hist)` instead of a second copy.
9. `ensureDays` now uses C3-T02's existing `days: 1..31` parameter (one request
   for span ≤ 32, not 29); the draft said the parameter did not exist.
10. The placeholder card is not in C9-T02; this ticket now adds it as an `fx`
    default, plus a stub column map (C9-T04 note 3). Geometry check narrowed to
    `{top, height}` until C9-T04.
11. Header strings: only the history numbers are localised (J:658–660); added
    a test. Added `font-style: normal` to the `.bd-sech em` CSS.
12. Tests: `reconnectLiveView` cannot run on `/build` (waits on
    `#worker-status`, `fixture_server.exs:377`); replaced with `liveSocket` +
    `data-build-epoch`. `live_patch` → `live_redirect`. `window.__bdLivePasses`
    global → `performance.mark`. Header unknown-branch tests now call a pure
    `headHTML` (no fixture needed for `total: null`/`start: null`). Every guard
    test now has a real mutation or is labelled a guard. `live coalesces`
    expectations match the deferral rule. 16 ms wall-clock budget → 50 ms
    long-task bound.
13. Commands: `test:parity` is DASH-033's spec; now `test:design-parity` and
    `test:build-home-motion`, plus the `history.*` entry in C1-T03's `OWNER`
    table. Docs owner C12-T01 → C12-T07.
14. Concurrency: C9-T10 and C9-T12 list this ticket in `blocked_by`, so they
    cannot run alongside it.
- Reconciliation 2026-10-08 (coordinator): paging (`H`, `loadEarlier`, `ensureDays`, `ensureFrom`) moved to `history.js` (R-G9), `loadEarlier` returns the in-flight promise, `ensureFrom(ms, keep)` stop predicate (C10-T03), C9-T10 removed from `takeAnchor` callers, `ctx.content?.classList` guard (C9-T12), focused card rendered outside the window and `ctx.a11y.focusId` exposed (C12-T05), allowlist kind `copy` with status `pending-sign-off` (R-G6), header copy = S-34, fixture route via `productUrl` (R-G7), interface notes 3 and 5 settled, C9-T01 edits made in this PR (R-G4).
