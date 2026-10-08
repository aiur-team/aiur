---
ticket_id: MP-E8-C9-T08
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: Now band, live snap and jump to live
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C9-T05, MP-E8-C9-T07, MP-E8-C9-T04]
complexity: 4
design_gate: DESIGN-E8
owns_edge_cases: [EC-05, EC-19]
owner_question_defaults: [S-9 (band variant; copy owned by C9-T13, see Decisions 4)]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T08 — Now band, live snap and jump to live

> **Plan refresh.** This ticket cites product code at `58854d4c8` and the design
> at etag 1791431544512943 (`design-source/IMPORTED.md`). `J` =
> `design-source/assets/build.js`, `C` = `design-source/assets/build.css`,
> `H` = `design-source/Aiur Dashboard.html`. Every `build-home/` path is
> PROPOSED: it does not exist at the base commit. The module layout, `ctx`,
> `fx`, `onReset` and `ctx.life` are C9-T01's (MP-E8-C9-T01 "Module layout").
> If C9-T01 renames them when work starts, use its names and keep the export
> names below.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C9 (client timeline
  engine, port of `build.js`).
- **User value.** The operator always sees every active agent. The "now" band
  sits between history (above) and the plan (below). It sticks to the top of the
  board when the operator looks at the plan, and to the bottom when the operator
  looks at history. It never rests in the middle of the screen: when scrolling
  stops, it glides to the nearer edge. One click on **Live** brings the band
  back. This is the "live pane's top-to-bottom transition" that the design
  mandate says to reproduce frame for frame
  ([../claude-design-source-of-truth.md](../claude-design-source-of-truth.md)).
- **Deliverable.** The PROPOSED ES module `src/priv/static/build-home/band.js`
  (the file C9-T01's module table assigns to this ticket), registered with one
  line `import "./band.js"` in `hook.js` and one
  `Object.assign(fx, { … })`. It ports these parts of `build.js` with mock code
  removed:
  1. **Band header and body** (J:663–671): the counts, the Live pulse, the clock
     or "cached HH:MM", the running/stuck/paused preset buttons, the minimised
     `.bd-now-sum` bar, the minimise button, the ETA slot, the `.bd-now-empty`
     state, the `.min` class, and the band cards. Also `?live=min`.
  2. **Header clicks** (J:629, 631): minimise and the `astate` presets.
  3. **Live snap**: `markScrolling` (J:574–579), `liveGuard` (J:582–591),
     `snapLive` (J:592–602), `scrollVP` (J:1233–1241).
  4. **Jump to live**: `jumpNow` (J:1242–1248) and the `#bd-nowbtn` `.at` state
     (J:738–739, at the call site C9-T03 leaves in `update()`).
  5. The unknown and stale clock states the design does not draw (EC-07, EC-08
     for the band), the interim "agent states unavailable" text, and the
     screen-reader fixes that change no pixels (EC-19).
- **Non-goals.**
  - **Band geometry.** `L.band` (`items`, `h`, `BK`, J:486–496) is computed by
    C9-T02's `computeLayout` (C9-T02 Decisions 1). The Gantt band height (the
    `gv` term of J:493) is C9-T09's `ext.gantt.bandHeight` slot in C9-T02. The
    band stack columns `bandMap` (J:779) are C9-T04's `applyCols`. The band
    height write `bandEl.style.height` (J:662) is C9-T03's `relayout`.
  - **CSS.** Every `.bd-now*`, `.bd-live` and `.bd-content.scrolling` rule
    (for example C:214–223, 301, 353–354, 378–393, 670, 717–721, 820–824, 877,
    888, 965, 1080–1131, 1148–1158, 1187–1193) reaches the product through
    C2-T04's consolidated `build-home/home.css`. This ticket edits no CSS. If a
    parity check fails on a computed style, the fix goes into C2-T04's
    stylesheet as a defect of that port, and the PR says so.
  - **Cards inside the band** (`makeCard`, `decorate`): C9-T05. Agent logo and
    glow: C9-T06.
  - **The blurred band edge layer** `.bd-now-e` (J:925–927, C:1192–1193):
    C9-T07. It finds or recreates the layer on each draw (C9-T07 step 3), so
    this ticket may rewrite the band's children.
  - **`syncAst` and `filtersChanged`** (J:1121–1127) and the filter effect of
    the presets (dimming through `match`, J:335–342): C10-T02 (its `filters.js`
    exports `fx.syncAst` and `fx.filtersChanged`). This ticket calls them and
    adds interim defaults only (step 4).
  - **The final "unavailable" copy and age** in `.bd-now-empty`: C9-T13's
    `bandEmptyHTML` (C9-T13 "Band"). This ticket renders a cause-neutral
    interim text that is never the "no agents" text.
  - **The ETA figure** (Σ estimate ÷ agent cap): C7-T03 `etaLabel`. This ticket
    renders a placeholder that never divides (Decisions 3).
  - **Offline banner and socket-down detection**: C8-T03 (`fx.daemonView()`).
  - **The toolbar markup and the click binding of `#bd-nowbtn`** (`renderTools`,
    J:1128–1150): C10-T01, whose delegated `#bd-tools` listener calls
    `fx.jumpNow(false)` (C10-T01, "Listeners are delegated and bound once per mount").

## Dependencies and blockers

- **Blocked by DESIGN-E8** (the design is the specification; Kevin's sign-off
  is C12-T08).
- **MP-E8-C9-T05** (cards in four tiers): the band calls `fx.makeCard(it)` for
  each band item (J:671). Without it the band has only C9-T03's placeholder
  cards.
- **MP-E8-C9-T07** (dependency edges): the edge signature reads the band top
  (J:894) and the band edge layer is inserted into `bandEl` (J:925–926). The
  snap moves the band, so the edges must already redraw as it moves. The
  parity checks for the band include the `.bd-now-e` layer.
- **MP-E8-C9-T04** (dynamic epic columns): `place()` reads `bandMap[it.key]`
  for band items (J:758) and hides any item with no entry (J:759–760). C9-T04
  owns `bandMap` (C9-T04 Non-goals). C9-T03's stub column map covers only
  section columns (C9-T03 Decisions 9), so without C9-T04 every band card is
  `opacity: 0` and no band parity check can pass. C9-T04 is in `blocked_by`. It runs in parallel with C9-T05 and C9-T07 after
  C9-T03, so the extra edge rarely delays this ticket.
- **Transitive:** C9-T01 (module layout, `ctx`, `fx`, `onReset`, `ctx.life`,
  `nowMs()`, `ctx.socket`, `.bd-root.rm`), C9-T02 (`L.band`, `LH`), C9-T03
  (`relayout`, `update`, `place`, the `paging` state, the `fx.renderBand` call
  site, the viewport skeleton with `#bd-now`), C3-T02 (payload schema), C3-T03
  (`live` and `astate` URL keys), C2-T04 (stylesheet), C1-T02
  (`expectDesignParity`), C1-T03 (`snap.*` motion sequences, whose OWNER is
  this ticket).
- **Not blocked by, but integrates with** (whichever merges second does the
  wiring; see "Interface notes"): C9-T09 (Gantt band heights), C9-T10
  (`fx.jumpNow(true)` after a span change), C9-T11 (`fitTree` calls
  `scrollVP`; `fx.setHover`, `ctx.isScrolling`), C10-T01 (`#bd-nowbtn`
  markup and click), C10-T02 (`fx.filtersChanged`, `fx.syncAst`), C7-T03
  (`etaLabel`), C8-T03 (`fx.daemonView`), C9-T13 (`bandEmptyHTML`).
- **May run in parallel** with C9-T06, C9-T09, C9-T11 and C9-T12 after C9-T07.
  All C9 tickets register in `hook.js`; this ticket adds one import line and
  fills `fx` entries. It touches other modules only at the call sites listed in
  Implementation steps.
- **Owner questions.** The band's "agent states unavailable" state is S-37; it
  follows the S-9 default, and C9-T13 owns its copy (Decisions 4). The DESIGN-E8 sign-off package (C12-T08) shows it.

## Verified starting point (`58854d4c8`)

**Product code (read-only, opened for this ticket):**

- There is no home page, no `build-home/` directory and no now band at the base
  commit. `src/priv/static/` holds the current hand-served hooks:
  `build-order-grid-hook.js`, `time-brush-hook.js`,
  `aiur-dom-svg-layout-loader.js` and others. There is no bundler.
- Hook registration: `src/lib/aiur_web/components/layouts.ex:35–45` loads each
  hook with `<script defer>`; `:54` creates `var Hooks = {}`; `:244–270`
  registers each hook only if its global exists; `:272–287` builds the
  `LiveSocket` with `hooks: Hooks` and a `time_zone` param from
  `Intl.DateTimeFormat().resolvedOptions().timeZone`, then `liveSocket.connect()`
  and `window.liveSocket = liveSocket`. C2-T03 adds one loader for
  `build-home/` here; this ticket does not touch `layouts.ex`.
- The ES-module loader pattern this ticket's module is loaded by:
  `src/priv/static/aiur-dom-svg-layout-loader.js:19–40` (`createLiveViewHook`
  with a `__domSvgLayoutDestroyed` flag and a dynamic `import(url)`). C2-T03
  copies it as `build-home/loader.js` → `build-home/hook.js`.
- Cleanup pattern for hooks: `build-order-grid-hook.js:486–488` and
  `time-brush-hook.js:157–159` call `destroy()` from `destroyed`. In
  `build-home/`, C9-T01's `ctx.life.dispose()` plays that role; this ticket
  arms every timer and frame through `ctx.life` so it needs no `destroy()` of
  its own.
- Live routes: `src/lib/aiur_web/router.ex:139–147` puts `/`, `/commands`,
  `/build-orders`, `/analytics` and `/streamdeck` in one
  `live_session :dashboard`, so a live navigation between them unmounts the
  hook and runs `destroyed`.
- Browser harness: `src/browser/package.json` (`@playwright/test` 1.61.1,
  `@axe-core/playwright` 4.11.3; scripts run through
  `scripts/run-browser-tests.mjs`; the `test` chain is line 10).
  `src/browser/playwright.config.mjs:22–27` sets `animations: 'disabled'` for
  screenshots. Reduced motion is emulated with
  `browser.newContext({ …, reducedMotion: 'reduce' })`
  (`tests/build-order-interaction.browser.spec.mjs:209`).
  `tests/support/measurements.mjs:1–5` `nextPaint` (double rAF).
  `tests/support/browser-helpers.mjs:68` `expectAuditClean(results)` (asserts
  `violations` is empty), `:102` `settleAnimations`.
- Fixture server: `src/test/browser/fixture_server.exs:2264` routes
  `/streamdeck-control/:mode`. C3-T01 adds `/build-fixture/:dataset` and C3-T02
  adds `/build-control/:action` next to it.

**Design source (read for this ticket; the copy is never edited):**

| Ref | What it does | What must match exactly |
| --- | --- | --- |
| J:17 | `fmtT` | `HH:MM` from local hours and minutes |
| J:355 | `LH = 46`, `SEC = 36` | `LH` is the band's sticky top and the snap's `topY` |
| J:486–496 | Band layout (C9-T02 ports it; read here for the tests) | `BH = 42`. `BL` = all now rows (**not** epic-filtered), sorted by `order.indexOf(colKey)` then `num`. `BK = max(1, min(BL.length ∥ 1, floor((vp.clientWidth − (root.clientWidth < 640 ? 46 : 84) − 14) / 230)))`. Row `n` goes to stack `"b" + (n % BK)`. No items when `S.liveMin`. `band.h = liveMin ? 38 : maxY ? maxY + 12 − gap : BH + 44` (86 px when empty) |
| J:779 | `bandMap` (C9-T04 ports it) | `bw = min(380, (avail − 16·(BK − 1)) / BK)`, `x = g + i·(bw + 16)`. Computed **before** the flow-mode return (J:781) |
| J:662 | Band height (C9-T03 ports it) | `bandEl.style.height = L.band.h + "px"` |
| J:663–664 | Counts | `t.agent.state`: running = `active`; stuck = `error`, `retries`, `command`; paused = `paused`, `parked` |
| J:665 | Header start | `<b><i></i>Live</b><time>` + `fmtT(NOW)`, or `"cached " + fmtT(NOW − 6 min)` in the offline demo |
| J:666 | Preset buttons | Inside `<span class="bd-now-st">`, rendered only when the count is > 0, in the order ok, bad, idle. `data-ast` = `active` / `error,retries,command` / `paused,parked`. Text `<i></i>N running` / `N stuck` / `N paused` |
| J:667 | Minimised bar and tail | `.bd-now-sum` only when `liveMin && now.length`; `role="img"`, `aria-label="N running, M stuck, K paused"`; one button per non-zero group, `style="flex:N"`, `title="N running"` etc. Then `.bd-now-min` (`data-min`, title "Expand live" when minimised else "Minimize live", icon `I.chev` when minimised else `I.chevU`, J:43, 66), then `.bd-now-eta` with `(plan + now) + " to go · ETA " + (plan.length ? round(Σ est / 4) + "h" : "—")` |
| J:668 | `syncAst()` | after every header render |
| J:669 | Empty state | `<div class="bd-now-empty">No agents are working right now.</div>` in `.bd-layer` when `now.length === 0`, also when minimised |
| J:670–671 | Min class and cards | `bandEl.classList.toggle("min", liveMin)`; each band card gets `noanim` and keeps it (unlike J:711, which removes it after two frames) |
| J:629 | Minimise click | `liveMin = !liveMin; writeURL(); relayout()` |
| J:631 | Preset click | Same joined value → clear `astate`; else set it. If minimised and not clearing → expand, `writeURL()`, `relayout()`. Then `filtersChanged()` |
| J:1121 | `syncAst` (C10-T02 ports it) | `.on` on `.bd-now-h [data-ast]` when `astate.join(",")` is non-empty and equals `data-ast` |
| J:567 | Scroll listener | `liveGuard(); markScrolling();` then one rAF `update()` |
| J:574–579 | `markScrolling` | First scroll event adds `.bd-content.scrolling` and, when `hoverId && !lockId`, calls `setHover(null)`; 200 ms after the last scroll event removes the class and calls `snapLive()` |
| J:582–591 | `liveGuard` | Returns early (and resets `lastSnapST`) when snapping, no layout, no content, list view, loading or paging. Returns early **without** resetting when `.bd-sb.drag` exists. `nat = histSection.offsetTop + L.secs.hist.h`, `y = nat − scrollTop`, `topY = LH`, `botY = vh − band.h`, `T = 36`. Gives up when `botY <= topY + 72`. Up-scroll with `topY + T < y < botY` → `scrollVP(nat + bh − vh, true)`. Down-scroll with `topY < y < botY − T` → `scrollVP(nat − LH, true)`. Lock 460 ms, then `lastSnapST = scrollTop` |
| J:592–602 | `snapLive` | Same early returns plus `rmOn() === "x"` (never true; see Decisions 5). No snap when `y <= topY + 2`, `y >= botY − 2` or `botY <= topY`. `toTop = (y − topY) < (botY − y)` (a tie goes to the bottom). Lock 480 ms |
| J:1233–1241 | `scrollVP` | Cancels the previous animation. Clamps `y` to `[0, scrollHeight − clientHeight]`. Instant when not smooth or under reduced motion (`rmOn()`, J:540). Else 420 ms, ease-out cubic `1 − (1 − k)^3`, one `requestAnimationFrame` step at a time |
| J:1242–1248 | `jumpNow` | List view → `scrollVP(0, !instant)`. Returns when `!secs.hist || !L`. Else `scrollVP(nat − LH, !instant)`; `update()` after an instant jump |
| J:738–739 | `.at` | `#bd-nowbtn.at` when `band.top > vp.top + LH + 30 && band.bottom < vp.bottom − 30`; nothing when the button is absent |
| J:1135, 1148 | Live button (C10-T01 ports it) | `<button class="bd-live" type="button" id="bd-nowbtn" title="Jump to live"><i></i>Live</button>`; click → `jumpNow(false)` |
| C:215 | Sticky | `.bd-now { position: sticky; top: 46px; bottom: 0; z-index: 7 }` |
| C:380–393 | Header | 36 px high, flex, gap .8rem, padding 0 14px. Live label Bungee 1rem. Pulse dot 8 px with `bdPulse 2s ease-in-out infinite` (C:223, `50% { opacity: .35 }`), stopped by `.bd-root.rm` (C:391). Time JetBrains Mono 700 .74rem. Preset pills 22 px high, radius 999px. ETA `margin-left: auto`. Under the `bd` container at ≤ 560 px, the time and ETA are hidden (C:393) |
| C:1101–1112 | Minimised bar | `max-width: 420px; height: 6px; gap: 3px`; buttons radius 3px, hover `scaleY(1.6)` in .12s; `.on` outline 2px |
| C:1080 | Accent line | `.bd-now::before { display: none !important }`. The final design shows **no** top accent line (the earlier rules C:379, 392, 820 are overridden) |
| C:1081–1082, 1187–1188 | Band surface | Shadows above and below; the background is 82 % opaque with `backdrop-filter: blur(5px)`, so edges show through blurred |
| C:1126–1131, 1148, 1156, 1158 | Grain | `.bd-now::after`, 160 px `feTurbulence` tile, opacity .09, `mix-blend-mode: overlay`, static. In light theme the last rule is `display: none !important` (C:1158), so the grain is **dark-only** |
| C:353–354, 670, 877, 888 | Scrolling state | `.bd-content.scrolling .bd-card` and `.bd-layer > .bd-card` `pointer-events: none`, `.bd-in { transition: none }`, `.bd-eh` `pointer-events: none`, unlocked `.bd-lt` hidden |
| C:717–721 | Live button | 32 px pill, `--good` dot with `bdPulse`; `.at { opacity: .6 }`; `.bd-root.rm` stops the pulse |

The design datasets have 4 to 8 agents (J:203–212, 251–252) and no state
without agents. EC-05's "no agents" and "20+ agents" cases therefore use the
two derived datasets described in Verification.

## Chosen design

**Approach: port the functions as written, in one module, and add the unknown
states at the points where the design uses mock data.** The thresholds, the
timings and the DOM are the design's. The only changes are:

1. `D.now` (the rows) and `NOW` (the clock) come from the payload. The port
   keeps the name `D.now` for rows and reads the clock from C9-T01's `nowMs()`.
2. Three values the design takes from mock data get an explicit unknown
   rendering: the clock, the ETA and the "agent states unavailable" state.
3. Accessible names and states that change no pixels.
4. Timers and frames go through `ctx.life`, and module state is reset through
   `onReset` (C9-T01 rules 3 and 4).

**Module interface** (PROPOSED `src/priv/static/build-home/band.js`):

```js
import { S, ctx, fx, onReset, LH, rmOn } from "./state.js"
import { $, $$ } from "./dom.js"
import { nowMs, stampMs } from "./clock.js"     // C9-T01 clock.js
import { writeURL } from "./url.js"

// pure — no DOM, unit-tested through page.evaluate(import(...))
export const SNAP_T = 36
export function bandCounts(rows)                         // -> { nr, ns, ni, nu }   J:663–664 (+ nu)
export function bandClock({ now, stamp, daemon, agents, socketDown })   // -> { text, title }
export function bandEta(D)                               // -> { text, title }  placeholder, C7-T03 replaces
export function bandEmptyText(D)                         // -> string | null    interim, C9-T13 replaces
export function guardTarget({ dir, y, topY, botY })      // -> "top" | "bottom" | null   J:588–590
export function settleTarget({ y, topY, botY })          // -> "top" | "bottom" | null   J:597–598

// DOM — reached through fx
function renderBand()          // J:663–671 (header, body, .min, cards)
function onBandClick(e)        // J:629, 631; returns true when it handled the event
function markScrolling()       // J:574–579
function liveGuard()           // J:582–591
function snapLive()            // J:592–602
function scrollVP(y, smooth)   // J:1233–1241
function jumpNow(instant)      // J:1242–1248
function syncNowBtn()          // J:738–739

Object.assign(fx, { renderBand, onBandClick, markScrolling, liveGuard, snapLive, scrollVP, jumpNow, syncNowBtn })
if (!fx.syncAst) fx.syncAst = interimSyncAst                 // C10-T02 replaces
if (!fx.filtersChanged) fx.filtersChanged = () => { writeURL(); fx.syncAst() }   // C10-T02 replaces
ctx.isScrolling = () => scrolling                             // C9-T11 reads it
onReset(() => { scrolling = false; lastSnapST = 0; animSeq++; ctx.snapping = false })
```

`ctx.snapping` (not a module-local `snapping`) is the flag, because C9-T03's
`onDataChanged` reads it to defer live passes (C9-T03 `onDataChanged`).

**`scrollVP` with `ctx.life`.** `ctx.life.frame(key, fn)` ignores a second
request for a pending key and has no cancel. So each call increments
`animSeq`, and the step uses the key `"scrollVP:" + seq` and returns at once
when `seq !== animSeq`. This keeps J:1235's "at most one animation" rule, and
`ctx.life.dispose()` cancels any pending step. The 200 ms settle timer, the
460/480 ms lock timers and the clock tick use `ctx.life.later("band-settle" |
"band-lock" | "band-clock", …)`.

**Rules for the unknown states** (the design has none of these; each is new
behaviour in this ticket). Inputs: `now = nowMs()`, `stamp = stampMs()` (the
`now` of the last applied snapshot or diff), `daemon = ctx.snap.daemon`,
`agents = D.sources.agents`, `socketDown = fx.daemonView ?
fx.daemonView().socketDown : ctx.socket === "down"`.

| Input | Band shows | Never shows |
| --- | --- | --- |
| `daemon.state = "live"`, socket up | `fmtT(now)` | — |
| `now` is `null` (before the first snapshot) | `—`, title "Time unknown" | `00:00` or the epoch |
| `daemon.state` `"offline"` or `"stale"`, `heartbeat_at = T` | `cached HH:MM` of `T` (the design's offline demo, J:665; C1-T01's `offline` fixture has heartbeat 14:14) | the live clock |
| same, `heartbeat_at = null` | `cached —`, title "Last heartbeat unknown" | `cached` + the current time |
| `daemon.state = "unknown"` | `—`, title "Daemon state unknown" | the live clock |
| `agents.state = "stale"`, `observed_at = T` | `cached HH:MM` of `T` | the live clock |
| socket down | `cached HH:MM` of `stamp`; `cached —` if `stamp` is `null` | the live clock |
| `agents.state` `"unavailable"` or `"disabled"` | `.bd-now-empty` with `Agent states unavailable` (interim; C9-T13's `bandEmptyHTML` adds the cause and age); no preset buttons; no `.bd-now-sum` | "No agents are working right now." |
| `agents.state` `"ok"` or `"stale"`, zero now rows | "No agents are working right now." (J:669) | — |
| a row with `agent: null` or `agent.state: null` | the card (C9-T05), but it is in no count; `nu` counts it; the `.bd-now-sum` aria-label gains `, N state unknown` | a "running" count that includes it |
| ETA before C7-T03 | `<plan + now> to go · ETA —`, title "ETA not available yet"; `— to go · ETA —` when `sources.queue.state = "unavailable"` | the design's `Σ/4` figure (plan §10 item 9) |

Precedence, top to bottom: `now` null, socket down, daemon state, agents
stale, live.

**Clock tick.** The design renders the clock once per `relayout`. With live data
and no diffs for minutes, that would show an old time as the current one. The
band re-renders only its `<time>` text at each minute boundary of `nowMs()`
(`ctx.life.later("band-clock", 60000 − (nowMs() % 60000), tick)`, re-armed in
`tick`). C9-T01's `nowMs()` advances with a monotonic timer between messages
(C9-T01 `clock.js`).

**Accessibility (EC-19), no pixel change:**

- `.bd-now-sum` uses `role="group"` instead of `role="img"`, with the same
  `aria-label`. A focusable button inside a `role="img"` element is hidden from
  assistive technology but still in the tab order (axe rule
  `nested-interactive`). Each bar button gets `aria-label` equal to its `title`.
- Every `[data-ast]` button gets `aria-pressed` equal to its `.on` state. The
  interim `syncAst` sets it; C10-T02's `syncAst` must keep it (Interface
  notes).
- `.bd-now-min` gets `aria-expanded` (`true` when not minimised) and
  `aria-controls="bd-now"` (the band element id from C9-T03's skeleton).
- Under reduced motion, `scrollVP` is instant (design, J:1237) and the snap
  still happens, instantly (Decisions 5). The pulse stops through
  `.bd-root.rm` (C:391, 721), which C9-T01 sets.
- Keyboard scrolling (arrow keys, Page Up/Down, Space) fires the same scroll
  events, so it gets the same snap. Nothing is keyboard-only here.

**Invariants:**

- The band is never at rest with its top strictly between `topY + 2` and
  `botY − 2` 200 ms + 480 ms after the last scroll event, unless the snap has
  given up (`botY <= topY`, or for `liveGuard` `botY <= topY + 72`), the view
  is list, the board is loading or paging, or the scrollbar is being dragged.
- At most one `scrollVP` animation runs at a time (J:1235).
- No frame step, timer or tick of this module runs after the hook's
  `destroyed` (all go through `ctx.life`).

## Implementation steps

1. **Create `build-home/band.js`** with the pure functions, ported expression
   by expression from the J lines in the table above. Keep the design's
   variable names (`nat`, `topY`, `botY`, `T`, `nr`, `ns`, `ni`) so a reviewer
   can diff the port against `build.js` line by line. `bandCounts` reads
   `t.agent && t.agent.state`; a missing agent or state goes to `nu`.
2. **Port `renderBand`** from J:663–671. Build the header string exactly as
   J:665–667 does (same element order, same classes, same whitespace inside the
   strings, same icons from the icon table C9-T01 ported). Replace the three
   mock values with `bandClock`, `bandEta` and `bandEmptyText`. Add the
   attributes in "Accessibility". All header text is numbers and fixed strings;
   no `reason` from `sources` is shown. Call `fx.syncAst()` after the header
   (J:668). Cards: `fx.makeCard(it)`, `noanim`, append, `it.el = el` (J:671).
   C9-T03's `relayout` already calls `fx.renderBand()` after the band height
   (C9-T03 `relayout`), and C9-T04's `applyCols` places band cards (J:781,
   792); this ticket adds no call there.
3. **Port the click handling** (J:629, 631) into `onBandClick`, which handles
   `[data-min]` and `[data-ast]` and returns `true` when it handled the event.
   C9-T03's content click listener (J:624–635) calls `fx.onBandClick(e)` after
   its `[data-sid]` check (J:630) and returns when it is `true`; if C9-T03 did
   not leave that call, add the one line there. The band buttons never sit
   inside `.bd-eh`, `[data-lt]` or `[data-sid]`, so this order gives the
   design's result. The preset branch ends with `fx.filtersChanged()` (C10-T02
   decision 7).
4. **Interim `syncAst`/`filtersChanged`.** If `fx.syncAst` is missing at import
   time, set it to J:1121 plus `aria-pressed`; if `fx.filtersChanged` is
   missing, set it to `() => { writeURL(); fx.syncAst() }` (URL and button
   state only; no dimming, which is C10-T02's job). Both carry a `ponytail:`
   comment that names C10-T02. C10-T02's `Object.assign` replaces them.
5. **Port the snap.** `fx.liveGuard` and `fx.markScrolling` are already called
   from C9-T01's scroll listener in J:567's order (C9-T01 `fx` defaults).
   `markScrolling` clears the hover through
   `if (ctx.hoverId && !ctx.lockId) fx.setHover(null)` (J:576; `hoverId` and
   `lockId` stay in C9-T01's `ctx`, C9-T11 note 6). `liveGuard`/`snapLive` read C9-T03's paging state (true
   from the `load-earlier` push until the anchor is restored, C9-T03 "Ordering
   for C9-T08"), `S.loading`, `S.view`, `ctx.L`, `ctx.content` and
   `document.querySelector(".bd-sb.drag")`.
6. **Port `scrollVP` and `jumpNow`** as `fx.scrollVP` and `fx.jumpNow`, with
   the `animSeq` rule above. C9-T01's boot, C9-T10's `setSpan`, C10-T01's view
   switch and Live click call `fx.jumpNow`; C9-T11's `fitTree` calls
   `fx.scrollVP`. Before this ticket they are no-ops (C9-T01 `fx` defaults);
   no second copy exists anywhere.
7. **`.at` state.** Port J:738–739 as `fx.syncNowBtn()` and call it from
   C9-T03's `update()` at J:738's position (C9-T03 `update`, "Then the
   `#bd-nowbtn` `.at` toggle"). It does nothing while `#bd-nowbtn` is absent
   (before C10-T01).
8. **Clock tick and reset.** Arm the minute tick in `renderBand` with
   `ctx.life.later("band-clock", …)`. Register the `onReset` callback above.
9. **Derived datasets** for EC-05 (Verification "Fixtures"): `now0` and
   `now24`, produced by C1-T01's exporter (`guardZone`/`patched` path, C1-T01
   "Exporter") from an in-memory patch of the design source, and added to
   C3-T01's dataset list so `/build-fixture/now0` answers 200.
10. **Tests** as listed in Verification, and the npm script
    `test:build-home-now-band` added to the `test` chain in
    `src/browser/package.json:10`.

## Non-happy paths

- **No agents** (EC-05): the design's empty state (J:669), 86 px band
  (`BH + 44`, from C9-T02's `L.band.h`). In the minimised band (38 px) the empty
  text still shows, as in the design (J:669 does not test `liveMin`).
- **20+ agents** (EC-05): the band is tall. With a 1200 px viewport width the
  stack count is `floor((1200 − 84 − 14) / 230) = 4`; 24 agents give 6 cards
  per stack. When `vh − band.h <= LH + 72`, `liveGuard` gives up (J:588), and
  when `vh − band.h <= LH`, `snapLive` gives up (J:597). The band then scrolls
  with the page under its sticky rules. Keep that; do not shrink cards or cap
  the agent count.
- **Agent states unavailable** (EC-07): its own text, never the "no agents"
  text (rules table). Counts are not drawn, because the rows are unknown, not
  zero.
- **Stale agent data or daemon** (EC-07): the values stay on screen and the
  clock becomes `cached HH:MM`, which is the rendered age. `.bd-root.stale`
  styling (C:301, 392) is C8-T03 and C9-T13.
- **Clock unknown** (EC-08): before the first snapshot `nowMs()` is `null`;
  the band shows `—`, never `00:00`.
- **Unknown agent state per row** (EC-08): left out of every count, counted in
  `nu`, named in the minimised bar's aria-label.
- **A live diff changes the band height** while the band is pinned to the top
  or the bottom: no extra code. Sticky positioning (`top: 46px; bottom: 0`)
  keeps the band at its edge; `snapLive` does nothing (`y >= botY − 2` at the
  bottom, `y <= topY + 2` at the top). C9-T03 defers the pass while
  `ctx.snapping` or `.scrolling` is set and keeps the scroll anchor. Test I-8
  guards this.
- **Programmatic scrolls** (C9-T03's anchor correction, `loadEarlier`,
  `fitTree`) fire scroll events, so they pass through `liveGuard` and
  `markScrolling` exactly as in the design. The design accepts that a settled
  band in mid-screen glides to an edge afterwards.
- **History paging is asynchronous** in the product (C9-T03 makes
  `loadEarlier` a server request). `liveGuard` and `snapLive` read C9-T03's
  paging state, which stays "loading" until the anchor is restored.
- **Scrollbar drag**: no snap while `.bd-sb.drag` exists (J:585, 594). The
  settle timer still fires during the drag; `snapLive` returns early while the
  class is present, and the next scroll event after release can snap. As
  designed.
- **List view, loading**: no snap (J:584, 593). `jumpNow` in list view scrolls
  to 0 (J:1243).
- **Reduced motion** (EC-19): instant scroll; the snap still happens.
- **Hook destroyed mid-animation** (LiveView navigation): `ctx.life.dispose()`
  cancels the pending frame and every keyed timer; the next mount's `onReset`
  clears `scrolling`, `lastSnapST` and `ctx.snapping` (ES modules are cached
  per page, C9-T01 rule 3).
- **Untrusted text** (EC-30): the header has none. Card titles go through
  C9-T05's escaping.
- **Read-only dashboard** (EC-12): nothing here writes to the server except
  URL state through C3-T03's `build:url` event, which is allowed read-only.

## Compatibility and rollout

- No configuration, migration, server change or new route. The module is
  served from C2-T03's `build-home/` directory and loaded by its `hook.js`.
- The page is reachable only at the temporary `/build` route (C3-T01) until
  the cutover (C12-T01). Rollback is reverting this PR; the board then shows an
  empty `#bd-now` with C9-T03's band height and no snap.
- Docs: none in this PR. The home page is not user-facing until C12-T01, and
  C12-T07 documents it (`guide/gui.md`). The `live=min` URL key is a URL state
  C3-T03 already validates; it is not a CLI flag or config key.

## Verification

**Fixtures.**

- C1-T01's five datasets (`live`, `dense`, `newrepo`, `noqueue`, `offline`),
  `NOW` = 2026-10-07 14:20:00, `TZ=America/Los_Angeles`.
- Two derived datasets for EC-05, built by C1-T01's exporter from an in-memory
  patch of `build.js` (the file is never edited; IMPORTED.md rule):
  - `now0`: `ACTIVE` emptied (J:203–212). The design side uses the same patch
    through `page.route` (the C1-T03 technique for planted differences).
  - `now24`: `ACTIVE` repeated three times with new keys (`a1b`, `a1c`, …).
  The patch text is checked in next to the fixtures, so both sides use the
  same bytes.
- Unknown-state cases do not need new datasets. They use `/build-control/diff`
  (C3-T02) with a named diff body (PROPOSED
  `src/test/fixtures/build_home/diffs/<name>.json`): `daemon-unknown`,
  `offline-no-heartbeat`, `agents-unavailable`, `agents-stale` (observed
  14:10), `agent-state-null`, `add-four-agents`.

**Tests** (PROPOSED `src/browser/tests/build-home-now-band.browser.spec.mjs`
unless stated). Each test names the production change that makes it fail.

| ID | Case (input) | Expected | Fails when |
| --- | --- | --- | --- |
| B-1 | `guardTarget` with `topY 46, botY 500`: `dir −1` at `y 83` / `82` / `499` / `500`; `dir 1` at `y 463` / `464` / `47` / `46`; `dir 0, y 200`; then `dir −1, y 100` with `botY 118` and with `botY 119` | `bottom`, `null`, `bottom`, `null`; `top`, `null`, `top`, `null`; `null`; `null` for `botY 118`, `bottom` for `119` | `T` is not 36, a `<` becomes `<=`, or the `+ 72` give-up changes |
| B-2 | `settleTarget` with `topY 46, botY 500`: `y 48` (= `topY + 2`), `y 49`, `y 498`, `y 273` (the exact midpoint), and `botY 46` | `null`, `top`, `null`, **`bottom`** (tie), `null` | the tie goes to the top (`<` → `<=`) or the 2 px margin changes |
| B-3 | `bandClock` with `now` 14:20 and these inputs: live; `now: null`; offline heartbeat 14:14; offline heartbeat `null`; daemon `unknown`; agents stale observed 14:10; socket down with `stamp` 14:19; socket down with `stamp: null` | `14:20`, `—`, `cached 14:14`, `cached —`, `—`, `cached 14:10`, `cached 14:19`, `cached —` | **mutation:** the `null`-clock, `unknown` or null-heartbeat branch is replaced by `fmtT(now)`; the test must then fail (AGENTS.md unknown-path rule) |
| B-4 | `bandCounts` on the `live` rows with `a8`'s `agent.state` set to `null` and one extra row with `agent: null` | `nr 2, ns 3, ni 2, nu 2` (the design's `live` counts are 3, 3, 2) | a null state falls into `nr` (for example a `default → active` mapping), or a null agent throws |
| B-5 | `bandEta` on `live` and with `sources.queue.state = "unavailable"` | `<plan + now> to go · ETA —`, the count read from the fixture, and `— to go · ETA —` | **mutation:** the design's `Math.round(Σ / 4) + "h"` is put back |
| B-6 | `agents-unavailable` diff | `.bd-now-empty` text starts with `Agent states unavailable` and is not `No agents are working right now.`; no `.bd-now-st button`; no `.bd-now-sum` | **mutation:** `bandEmptyText` returns the "No agents" text for `unavailable` |
| B-7 | `now0` | `.bd-now-empty` text `No agents are working right now.`; band height 86 px | the empty branch is removed |
| I-1 | click `[data-ast="error,retries,command"]` on `live`; click it again | URL gets `astate=error,retries,command` (through `build:url`), the button has `.on` and `aria-pressed="true"`; second click clears both | the toggle, `fx.filtersChanged` or `syncAst` is not wired |
| I-2 | `?live=min`, then a `.bd-now-sum .bad` click | first paint has `.bd-now.min`, height 38, `aria-expanded="false"`; the click removes `live` from the URL, expands, and sets the preset | J:631's expand branch is missing |
| I-3 | `[data-min]` click on `live` | `.bd-now.min`, URL `live=min`, no band cards, `.bd-now-sum` with three buttons whose `flex` is `3`, `3`, `2`, `role="group"` | the URL write or the `liveMin` relayout is missing |
| I-4 | scroll to the top of history; call `fx.jumpNow(false)` (through `page.evaluate` on `state.js`); sample `scrollTop` each frame. Repeat in `?view=list` | reaches `nat − 46` (±1 px) after about 420 ms along `1 − (1 − k)^3`; in list view it reaches 0 | `jumpNow` or `scrollVP` is missing or `dur` changes |
| I-5 | wheel-scroll 300 px on `live` | `.bd-content.scrolling` present during the scroll; a `.bd-card` under the pointer reports `pointer-events: none`; `ctx.isScrolling()` is `true`; the class is gone 200 ms after the last event | `markScrolling` is not wired |
| I-6 | `newrepo` at a 600 px viewport height; scroll up until `scrollTop < 260` so `load-earlier` starts; hold the reply (`earlier?delay=…`, C9-T03) | no eased `scrollTop` frames while the request is in flight; one anchor jump when it lands | the paging check is dropped from the guard. If the fixture cannot reach this geometry, the PR says so (AGENTS.md) |
| I-7 | `now24` at 1440 × 900; wheel ±100 px around the band; wait 800 ms | `scrollTop` changes only by the wheel deltas; no programmatic frames (EC-05) | the `botY <= topY + 72` or `botY <= topY` give-up is removed |
| I-8 | `live`, pinned at the bottom; `add-four-agents` diff | the band's bottom equals `#bd-vp`'s bottom (±1 px); no eased frames. **Future-regression guard:** it passes on the port as written and protects the "no extra re-pin code" decision; it is not counted as coverage | someone adds a re-pin scroll after a diff |
| I-9 | reduced motion; I-4 and the C1-T03 `snap.reduce` sequence | the target is reached in the first sampled frame; no frame in between | `rmOn()` is removed from `scrollVP`, or J:593's `rmOn() === "x"` is "fixed" to `rmOn()` (the snap disappears) |
| I-10 | start a snap, then navigate live to `/commands` (same `live_session`, `router.ex:139–147`; in the fixture server use the route that shares `/build`'s live session); `requestAnimationFrame` and `setTimeout` are wrapped to record callers | no `scrollVP` step and no band timer runs after `destroyed`; no `pageerror` | a frame or timer is armed outside `ctx.life` |
| I-11 | `page.clock.install()` before load on `live` (payload `now` 14:20:00); `page.clock.runFor(59_000)`, then `runFor(1_000)`, with no diff | `.bd-now-h time` reads `14:20`, then `14:21` | the minute tick is removed, or it fires on the wall clock instead of `nowMs()` |
| I-12 | axe on `.bd-now` in normal and minimised state (`expectAuditClean`), dark and light | no violations | **mutation:** `role="img"` is restored on `.bd-now-sum` (axe `nested-interactive`) |
| I-13 | `agent-state-null` diff in `?live=min` | `.bd-now-sum` aria-label ends with `, 1 state unknown` | the `nu` suffix is dropped |
| I-14 | **needs C10-T01's `#bd-nowbtn`**: `newrepo` at a viewport tall enough that the band floats clear of both edges (`r.top > v.top + 76` and `r.bottom < v.bottom − 30`); then `live` after `fx.jumpNow(true)`; then a click on `#bd-nowbtn` from history | `.at` present in the first case and absent in the second; the click reaches `nat − 46` | `fx.syncNowBtn` is not called from `update()`, or the comparison changes. Whichever of C9-T08 and C10-T01 merges second turns this test on; until then it is `test.fixme` with OWNER `MP-E8-C9-T08`. If `newrepo` cannot reach the floating case, the PR says so |
| I-15 | load `/build-fixture/live` and read `.bd-now-h time` in the first frame after `mounted`, before the first snapshot is applied (hold `build-resync`) | the text is `—` (or the band is not rendered), never `00:00` | the `now: null` branch formats `null` |

**Motion parity (C1-T03).** The `snap.*` sequences in
`src/browser/tests/build-home-motion.browser.spec.mjs` have OWNER
`MP-E8-C9-T08` and anchor `.bd-now-h > b` (C1-T03 OWNER table). This ticket
turns every one of them from `fixme` to passing: `snap.settle-near-top`,
`snap.settle-near-bottom`, `snap.pinned`, `snap.guard-up`, `snap.guard-down`,
`snap.tall-band`, `snap.scrollbar-drag`, `snap.list-view`, `snap.reduce`, and
the `.bd-now` cell of `grain.static` and the `.bd-now-h > b i` inventory cell.
Tolerances are C1-T03's (same 16 ms frame, 1 px). C1-T03's planted mutations
(`dur = 400`, `rmOn()`) must still be caught.

**Commands.**

```bash
env -C src/browser mise exec -- npm run test:build-home-now-band
env -C src/browser mise exec -- npm run test:build-home-motion   # C1-T03 runner
env -C src/browser mise exec -- npm run test:design-parity       # C1-T02 runner, band regions
```

**Mutation check (AGENTS.md).** For B-3, B-5, B-6, I-9, I-10, I-11, I-12,
I-13 and I-15: in a worktree, apply the named mutation, confirm
`git status --porcelain` shows only that file, run the test, and confirm it
fails; restore and confirm it passes. Report the commands and results in the
PR body, one line per test.

**Manual check.** None required by AGENTS.md "Manual testing" for this ticket:
it changes the web page only, not the TUI or chat path. C12-T01 drives the
real CLI at cutover.

## Pixel parity

- **Design elements reproduced:** `.bd-now` (sticky surface, shadows, blur,
  dark-only grain `::after`, hidden `::before`), `.bd-now-h` with `> b` and
  its pulse `i`, `time`, `.bd-now-st` buttons (`ok`, `bad`, `idle`, `.on`),
  `.bd-now-sum` and its buttons, `.bd-now-min` (both icons), `.bd-now-eta`,
  `.bd-now-empty`, `.bd-now.min`, the band layer with its cards,
  `#bd-nowbtn.at`, `.bd-content.scrolling`.
- **How it is checked:** C1-T02's `expectDesignParity(pair, { name, region:
  '.bd-now' })`, and `region: '#bd-nowbtn'` once C10-T01 has merged (same rule
  as I-14), at `threshold: 0` and `PARITY_FLOOR`, over:
  - datasets `live`, `dense`, `newrepo`, `noqueue`, `offline`, `now0`, `now24`;
  - 1440, 1024 and 390 px (390 px exercises the 46 px gutter, `BK = 1`, and the
    ≤ 560 px container rule that hides the time and ETA);
  - dark and light, default and Gruvbox palettes;
  - states: normal, `?live=min`, each preset `.on`, band pinned at the top
    (after `jumpNow`) and at the bottom (scrolled to history and settled).
- **DOM-state parity** (C1-T03 `domState`): `#bd-now` inline `height`, and
  each band card's inline `top`, `left`, `width` and `height`, for every
  dataset and width above. This proves the band as assembled from C9-T02's
  `L.band`, C9-T04's `bandMap` and this ticket's render, without constants in
  the spec.
- **Known pending difference:** the ETA text. The design prints `ETA Nh` from
  `Σ/4`; this ticket prints `ETA —` until C7-T03 merges (Decisions 3). The
  allowlist entry masks the `.bd-now-eta` box and is marked "pending: removed
  by C7-T03". When C7-T03 lands, its fixture capacity must be `4` so the
  product reproduces the design figure, and the entry is deleted. C12-T08
  fails while the entry remains.
- The unknown states (B-3 `—`, `cached —`, B-6 text) have no design
  counterpart. They are shown in the DESIGN-E8 sign-off package (C12-T08, S-37) and
  have no allowlist entry, because no design frame shows them.

## Decisions made without the owner

1. **The accent line stays hidden.** The row asks for "the `::before` accent
   line", but the final design rule is `.bd-now::before { display: none
   !important }` (C:1080), so the design shows no line. Parity wins; the port
   shows none. The earlier `::before` rules are dead, and C2-T04 may remove
   them.
2. **The grain is dark-only**, as the row says and C:1158 confirms
   (`display: none` in light).
3. **ETA placeholder until C7-T03.** The design's constant 4 is wrong for the
   product (plan §10 item 9), and the payload has no agent cap before C7-T03.
   So this ticket renders `ETA —` and never divides. C7-T03 replaces `bandEta`
   with `etaLabel` (C7-T03 "C9-T08").
4. **"Agent states unavailable" in the band** reuses `.bd-now-empty`, by
   analogy with S-9. C9-T13 owns the final copy with cause and age
   (`bandEmptyHTML`, C9-T13 "Band"). This ticket renders only the cause-neutral
   prefix, so the two tickets cannot disagree and the state is never the "no
   agents" text whichever merges first. It is sign-off item S-37.
5. **Reduced motion still snaps, instantly.** J:593's `rmOn() === "x"` is never
   true, so the design snaps under reduced motion; `scrollVP` makes it instant.
   The port keeps the expression's effect (no reduced-motion early return) and
   writes it plainly with a comment that cites J:593. C1-T03 already treats a
   "fix" to `rmOn()` as a failing change.
6. **Band geometry is not ported here.** The README row and the first draft of
   this ticket put J:486–496 and J:779 in C9-T08, but C9-T02 (Decisions 1) and
   C9-T04 (Non-goals) already port them where the design has them. Two copies
   would drift; this ticket reads `L.band` and `bandMap`, and adds C9-T04 as a
   predecessor instead.
7. **Band order is the design's** (epic order, then `num`, J:490, in C9-T02).
   It does not use the row's `ord`.
8. **`.at` is ported as written.** It is set only when the band floats at least
   30 px clear of both edges (J:739), which is rare once the snap works (for
   example, a short board that does not scroll). It is not "fixed" to mean
   "the band is in view".
9. **Accessible names and states** (`role="group"`, `aria-pressed`,
   `aria-expanded`, the `nu` suffix) are added because they change no pixels
   and the never-cut rule covers accessibility.
10. **A minute tick** re-renders the clock, so a live band never shows an old
    time as current (AGENTS.md "a computed age is rendered").
11. **The Live button click is C10-T01's.** C10-T01 binds one delegated
    listener on `#bd-tools` that calls `fx.jumpNow(false)`. This ticket only
    fills `fx.jumpNow`, so there is one listener and merge order does not
    matter.
12. **No `fx.flushLive()` after a snap.** C9-T03 allows it, but C9-T01's 250 ms
    poller already flushes deferred live changes, so the extra call is not
    needed.
13. **Interim `syncAst`/`filtersChanged` defaults.** C10-T02 is not a
    predecessor, and the design calls both from the band (J:631, 668). Without
    a default the first preset click would throw. The defaults are one line
    each and C10-T02 replaces them.

## Interface notes for neighbour rows

These are mismatches or gaps between this row and its neighbours. The
coordinator should settle them before the writers start.

- **README row vs C9-T02/C9-T04.** The row lists "Band layout: BK stacks of
  ≤ 380 px (J:487–496)" and design elements J:662–671 for this ticket, but
  C9-T02 ports J:486–496, C9-T03 ports J:662, and C9-T04 ports J:779. This
  ticket follows the neighbour tickets (Decisions 6). Settled 2026-10-08: C9-T04
  is in `blocked_by`; C9-T02 sets `L.band.BK`.
- **C9-T01 `clock.js`:** Settled 2026-10-08: `clock.js` exports `nowMs()` and
  `stampMs()` (R-G9).
- **C9-T03:** the content click listener calls `fx.onBandClick(e)` after its
  `[data-sid]` check, and `update()` calls
  `fx.syncNowBtn()` at J:738. Settled 2026-10-08: per R-G2, the caller that
  merges first adds the no-op defaults to C9-T01's `fx` table.
- **C10-T02:** Settled 2026-10-08: this ticket's `syncAst` port sets `aria-pressed` on each
  `[data-ast]` button (no pixel change), and C10-T02 imports it unchanged. I-1 fails after C10-T02 merges if it
  does not.
- **C9-T11:** reads `fx.scrollVP` (not a direct import). Settled 2026-10-08: the
  no-op default follows R-G2. `ctx.isScrolling()` is provided here.
- **C9-T13:** replaces `bandEmptyText`'s unavailable branch with
  `bandEmptyHTML(P, nowMs())`; keep the `Agent states unavailable` prefix that
  B-6 checks.
- **C3-T02 `ord` on now rows** is "C8-T01's band order", but the design sorts
  the band by epic order then `num` (J:490). C9-T02 keeps J:490. Settled 2026-10-08: C8-T01's `ord` follows J:490
  (epic order, then `num`).
- **C8-T03** provides `fx.daemonView().socketDown`; it does not render its own
  band clock.
- **C1-T01** already has an in-memory patch path (`patched`, C1-T01
  "Exporter"). Settled 2026-10-08: C1-T01's patch path takes the `now0` and
  `now24` patches; this ticket adds them to the exporter.
- Settled 2026-10-08: the hook file is `src/priv/static/build-home/hook.js`
  (R-G8).

## Completion and handoff

**Acceptance checklist.**

- [ ] `build-home/band.js` ports J:574–602, 629, 631, 663–671, 738–739 and
      1233–1248, with mock values replaced as in the rules table, and
      registers through `fx`.
- [ ] B-1 … B-7 and I-1 … I-15 pass (I-14 as `fixme` until C10-T01 has
      merged); each mutation listed fails as stated.
- [ ] All nine C1-T03 `snap.*` sequences and the band cells of `grain.static`
      and `inventory` pass against the design with no `fixme`.
- [ ] `.bd-now` region parity passes over the full matrix (and `#bd-nowbtn`
      once C10-T01 has merged), with the ETA mask as the only allowlist entry,
      marked pending C7-T03.
- [ ] DOM-state parity of the band height and card geometry passes for all
      seven datasets at 1440, 1024 and 390 px.
- [ ] No timer, frame or tick of this module runs after `destroyed` (I-10).
- [ ] No unknown or unavailable state renders the live clock, `00:00`, `0`,
      the "no agents" text, or a `Σ/4` ETA (B-3, B-5, B-6, I-15).
- [ ] The PR body lists each mutation command and its result.

**Dependent tickets.** C9-T09 (fills `ext.gantt.bandHeight`), C9-T10 and
C9-T11 (call `fx.jumpNow`/`fx.scrollVP`), C10-T01 (button markup and click),
C10-T02 (replaces the interim `syncAst`/`filtersChanged`), C7-T03 (replaces
`bandEta` with `etaLabel`), C8-T03 (`fx.daemonView`), C9-T13 (unavailable copy,
stale styling), C12-T08 (sign-off package lists Decisions 4 and the ETA
allowlist state).

**Sources.** `../tickets/README.md` row MP-E8-C9-T08; `../chunks.md` §C9;
`../plan.md` §5, §8 (EC-05, EC-07, EC-08, EC-19), §10 items 7, 9;
`../decisions.md` E8-D8; `../claude-design-source-of-truth.md`;
`../../../owner-design-tasks/DESIGN-E8.md` S-9; sibling tickets C1-T01, C1-T02,
C1-T03, C2-T03, C2-T04, C3-T01, C3-T02, C3-T03, C7-T03, C8-T03, C9-T01,
C9-T02, C9-T03, C9-T04, C9-T07, C9-T10, C9-T11, C9-T13, C10-T01, C10-T02;
design source J and C lines as cited; product code as cited at `58854d4c8`.

**Remaining blocker.** DESIGN-E8 only.

## Review log

Adversarial review, 2026-10-08 (sources re-opened: J, C, product code at
`58854d4c8`, neighbour tickets C9-T01..T04, T07, T10, T11, T13, C10-T01,
C10-T02, C7-T03, C8-T03, C1-T01, C1-T03).

1. **Scope overlap removed.** Dropped `bandLayout`, `bandColumns`, `ganttH`
   and the band-height write: C9-T02 (J:486–496), C9-T04 (J:779) and C9-T03
   (J:662) already own them. Added Decisions 6.
2. **Added C9-T04 to `blocked_by`.** `place()` hides band cards without
   `bandMap`, and C9-T03's stub covers only section columns.
3. **Module path and pattern aligned with C9-T01:** `band.js` (not
   `now-band.js`), `fx` registration, `onReset`, `ctx.life` timers and
   frames; removed the module `destroy()`. Defined the `animSeq` rule because
   `ctx.life.frame` has no cancel.
4. **`syncAst`/`filtersChanged` ownership moved to C10-T02** (its file exports
   them); this ticket keeps one-line interim defaults (Decisions 13).
5. **Live button click is C10-T01's** (it already binds a delegated
   `#bd-tools` listener); removed this ticket's second listener (Decisions 11).
   I-4 now calls `fx.jumpNow`; added I-14 for `.at` and the click, gated on
   C10-T01. The `.at` state had no test before.
6. **Unavailable copy deferred to C9-T13** (`bandEmptyHTML`); interim text
   matches its prefix (Decisions 4, B-6).
7. **`ctx.snapping`, `ctx.isScrolling()`, `ctx.tree.setHover`** used as C9-T03
   and C9-T11 expect.
8. **Clock:** added the `nowMs() === null` state (C9-T01 returns `null` before
   the first snapshot) with B-3 and I-15; socket-down reads
   `fx.daemonView().socketDown` (C8-T03) and needs `stampMs()` from C9-T01
   (Interface notes). I-11 rewritten so it tests the minute boundary of the
   payload clock.
9. **Design facts corrected:** J:1135 attribute order (`type` before `id`);
   J:1244 early return added to `jumpNow`; J:669 empty div lives in
   `.bd-layer`; stale band styling is C:301/392 (C:401 is the agent logo);
   scrolling rules also at C:877, 888; `playwright.config.mjs:22–27`.
10. **Tests made concrete:** B-1 `botY 118/119` now has `dir`/`y`, plus
    `dir 0`; B-2 midpoint value given; B-3 inputs listed; I-10 uses a real
    live route (`router.ex:139–147`); motion command is
    `test:build-home-motion`; I-8 marked as a future-regression guard not
    counted as coverage.
11. **Resolved interface notes removed** (C1-T03 anchor is already
    `.bd-now-h > b`; `jumpNow`/`scrollVP` are `fx` entries, not C9-T01
    copies); added notes for C9-T01 `stampMs`, C9-T03 call sites, C10-T02
    `aria-pressed`, C9-T11, C9-T13 and the README row.
- Reconciliation 2026-10-08 (coordinator): `markScrolling` clears hover through `ctx.hoverId`/`ctx.lockId` and `fx.setHover` (no `ctx.tree`), band unavailable state = S-37, C9-T04 predecessor wording matches front matter, settled interface notes (README band layout, `stampMs`, `fx` defaults per R-G2, hook path per R-G8).
- Reconciliation 2026-10-08 (coordinator, second pass): settled the `aria-pressed`, `ord` and `now0`/`now24` requests.
