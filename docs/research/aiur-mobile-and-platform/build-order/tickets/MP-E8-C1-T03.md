---
ticket_id: MP-E8-C1-T03
feature_id: MP-E8
chunk_id: MP-E8-C1
bucket: 2-platform
title: Motion and interaction parity scripts
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C1-T02]
complexity: 4
design_gate: DESIGN-E8
owns_edge_cases: [EC-19]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C1-T03 — Motion and interaction parity scripts

> Line numbers: `J` = `../design-source/assets/build.js`, `C` =
> `../design-source/assets/build.css`, `H` = `../design-source/Aiur Dashboard.html`
> (import of 2026-10-08, etag 1791431544512943). Product paths are at
> `58854d4c8`, relative to `src/`. New files are marked PROPOSED.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C1 (parity harness).
- **User value:** "pixel-perfect" includes motion. Screenshots (C1-T02) cannot
  see a 420 ms ease, a 220 ms debounce or a modal that opens from the wrong
  offset. This ticket gives every motion and interaction in the design a
  machine check. A reviewer then reads a number, not an opinion.
- **Deliverable:** one Playwright spec and one support module that:
  1. run the same scripted sequence on the design page and on the product
     fixture page (both opened with C1-T02's helpers);
  2. record **DOM state** (class tokens, inline `top`/`left`/`width`/`height`,
     URL query) and **motion samples** (scroll positions per frame, Web
     Animations timing and computed style at fixed points in time);
  3. compare the two records and fail on any difference that is not in the
     C1-T02 allowlist;
  4. repeat each sequence with `prefers-reduced-motion: reduce` (EC-19);
  5. prove themselves with meta-tests: a planted difference in the design
     (in memory only) must make the comparison fail.
- **Sequences (scope):** live snap (`liveGuard`/`snapLive`/`scrollVP`), modal
  open and close, column enter and leave, view switch, span change, filter dim,
  feature focus and compact, minimap drag and jump flash, whole-tree overlay
  fade, grain overlay (static), and one generic "animation inventory" of every
  running animation in `#build-root`. Two checks the README row implies but
  does not name: the loading spinner under reduced motion (`loading.spin`, the
  only place `.bd-spin` exists) and a live change of the OS motion setting
  (`reduce.live-toggle`).
- **Non-goals:**
  - Porting any motion. C9-T04, C9-T08, C9-T10, C9-T11, C10-T02, C10-T03,
    C11-T01 and C11-T05 port it. This ticket only checks it.
  - Pixel diffs of whole pages (C1-T02) and computed-style snapshots of every
    element (C2-T04).
  - Video capture. It is not deterministic (see Decisions).
  - Forced colours (C12-T05) and keyboard focus rings (S-12).
  - The design's mock live conversation stream (`startLive`, J:1509–1523). The
    product removes it (C11-T05).

## Dependencies and blockers

- **Blocked by DESIGN-E8** (Kevin's go). The sign-off package (C12-T08) runs
  these scripts.
- **Predecessor: MP-E8-C1-T02.** This ticket reuses, and does not re-create:
  - its design opener (the design HTML served as static files, `?example=`,
    `switchTab("build")`, local fonts and d3, `TZ=America/Los_Angeles`);
  - its product opener (the fixture route from C3-T01 with the same dataset);
  - its element-level screenshot mode;
  - its checked-in allowlist, its seeded `Math.random` and its network guard.
  The names are the ones C1-T02 defines (all PROPOSED, in
  `src/browser/support/design-parity.mjs`): `openParityPair(browser, cell, opts)`
  (returns `{ design, product, close() }`), `openDesign`, `openProduct`,
  `waitParityReady(page)`, `seedRandom(page)`, `guardNetwork(page, origins)`,
  `expectDesignParity(pair, { name, region })` (the element-level mode is the
  `region` option) and `loadAllowlist()` over
  `src/browser/support/design-parity-allowlist.json`. If C1-T02 ships other
  names, use those; do not add a second opener or a second list.
- **Clock hand-off with C1-T02.** C1-T02 freezes time with `setFixedTime`. This
  ticket replaces that call with `page.clock.install` + `pauseAt` (C1-T02
  handoff note "C1-T03"), because a fixed time never fires timers.
- Transitively C1-T01 (fixtures, `NOW` = 2026-10-07 14:20, sha256 guard of the
  design files).
- **Dependents:** C12-T08 (runs every script on the final build). The porting
  tickets listed in Non-goals turn their sequence on (see "Product sequences
  that wait on a port" below).
- **May run concurrently** with C2-T01, C2-T03, C3-T01..T03 and all of C4–C8.
  It touches only `src/browser/`. It edits one C1-T02 file, the allowlist
  JSON (C1-T02's loader already accepts the `motion` kind);
  C2-T04, C9-T11 and the porting tickets also append to that JSON, so a rebase
  conflict there is expected and is resolved by keeping every entry.
- **Owner questions followed by default:** S-12 (not in scope), and two new
  reduced-motion differences that go to sign-off (Decisions 3, S-18).

## Verified starting point (`58854d4c8`)

Product harness (all under `src/browser/`):

- `playwright.config.mjs:20-27`: screenshots use `animations: 'disabled'`,
  `maxDiffPixelRatio: 0.002`. Motion cannot be checked through this default;
  this spec sets its own options per test.
- `package.json:10` is the `npm test` chain; `:38` pins `@playwright/test`
  `1.61.1`. The installed `playwright-core` (`node_modules/playwright-core/package.json:3`,
  version `1.61.1`) has the Clock API (`types/types.d.ts:18484`, `clock.runFor`).
  Its fake clock replaces `requestAnimationFrame` and `performance`
  (`lib/coreBundle.js`, the `requestAnimationFrame: (callback) => clock.addTimer({ type: "AnimationFrame" ...` and
  `performance: originals.performance ? fakePerformance(...)` entries). So the
  design's JS-driven scroll (`scrollVP`, J:1234–1241, which reads
  `performance.now()` and the rAF timestamp) can be stepped frame by frame.
- `support/visual.mjs:28-52` `openVisualRoute` (theme seeding, connected
  LiveView, `document.fonts.ready`); `:96-110` the pinned Docker Chromium
  `mcr.microsoft.com/playwright:v1.61.1-noble` runner, which today runs only
  `tests/visual-shell.browser.spec.mjs` (`:103`).
- `tests/support/browser-helpers.mjs:12` `openFixture`; `:89-90` notes that a
  `reducedMotion: 'reduce'` context collapses every duration to 0.01 ms;
  `:102` `settleAnimations` (the `getAnimations({ subtree: true })` pattern
  this ticket reuses).
- `tests/support/measurements.mjs:1-5` `nextPaint` (double rAF).
- `scripts/run-browser-tests.mjs:13` `allocatePort`, `:45` `runBrowserTests`.
- `tests/build-order-interaction.browser.spec.mjs:208-219`: the current
  reduced-motion assertion pattern ("assert near-zero", `< 0.05` s).
- **`priv/static/dashboard.css:6865-6874`**: a global
  `@media (prefers-reduced-motion: reduce)` rule sets, on `*`, `::before` and
  `::after`, `animation-duration: 0.01ms !important`,
  `animation-iteration-count: 1 !important`,
  `transition-duration: 0.01ms !important` and `scroll-behavior: auto !important`.
  This rule will also apply to the home page. It matters for EC-19 (below).

Design motion (what must match exactly):

| Motion | Source | Exact values |
| --- | --- | --- |
| Scroll settle → snap | J:574–579 `markScrolling` | `.bd-content.scrolling` added on scroll; `snapLive` runs 200 ms after the last scroll event |
| Snap during scroll | J:582–591 `liveGuard`; J:567 | runs on **every** `scroll` event, before `markScrolling` (J:567). `topY = LH = 46` (J:355), `botY = vh − band.h`, `T = 36`; gives up when `botY <= topY + 72` (J:588); `y = nat − scrollTop`; scrollTop falling (`dir < 0`) with `y` in `(topY+T, botY)` → bottom; scrollTop rising with `y` in `(topY, botY−T)` → top; lock 460 ms. So a jump from a pinned edge into the middle is caught here; only a move that stays inside the 36 px strip next to the edge reaches `snapLive` |
| Snap on settle | J:592–602 `snapLive` | no snap when `y <= topY+2`, `y >= botY−2` or `botY <= topY`; nearer edge wins; lock 480 ms; skipped in list view, while loading, while paging, and while `.bd-sb.drag` |
| Scroll animation | J:1234–1241 `scrollVP` | `dur = 420`, ease `e = 1 − (1 − k)^3`, one rAF per frame, cancels the previous one; instant when `rmOn()` |
| Reduced-motion snap | J:593 | the guard is `rmOn() === "x"`, which is never true (`rmOn` returns a boolean, J:540). So under reduced motion the snap **still happens, instantly**. A port that "fixes" this to `rmOn()` removes the snap and must fail |
| `.rm` class | J:560 | set once in `shell()`; not updated if the OS setting changes later. `@media` rules (C:348, C:610) and `rmOn()` do update |
| Column debounce | J:698–702 | `visibleCols` change → `applyCols` after 220 ms (0 when forced) |
| Column enter/leave | J:796–805 `syncKeyed`; C:170–171, 179–180 | enter: `.enter` added, layout forced, removed → transition `left/width .34s cubic-bezier(.22,1,.36,1)`, `opacity .26s`, `transform .26s` from `opacity 0; translateY(-7px)`; leave: `.leave` then removed after 300 ms; guides fade opacity only |
| New card | J:711; C:227, 231 | `.noanim` for two frames; card transition `left/width .34s cubic-bezier(.22,1,.36,1), opacity .25s, filter .25s` |
| Scrolling | C:353–354, 670 | card `pointer-events: none`, `.bd-in` transition none, unlocked `.bd-lt` hidden |
| Filter dim | J:872; C:274 | `.dim` = `opacity .26; filter saturate(.3)`, eased by the card transition |
| View / span / feature / filter | J:1143, 1229–1232, 1136–1137, 1146–1147, 1091–1096, 1123–1127 | view (`[data-v]`) and span (`.bd-cal [data-span]`, `.bd-zoom [data-z]`; the CSS-only `.bd-zb` class is never emitted) end with `jumpNow(true)` (instant); compact relayouts; focus only redecorates and re-applies columns; a filter change redecorates, or relayouts when the epic filter changed (J:1126) |
| Modal open | H:1596–1599; C:474 | `.tk-backdrop.show { display: grid }`; `.tk-modal` `animation: tkin 0.24s cubic-bezier(0.22,1,0.36,1)` from `translateY(14px) scale(0.99); opacity 0.4`; `.bdm` 1080 × min(820px, 100vh − 2.4rem) |
| Modal close | J:1398, 1441, 1542; H:5073, 5106; J:1556–1557 | `#bd-tk-close`, Escape, backdrop click; `.show` removed, **no exit animation**; the observer removes `?ticket=` |
| Minimap | J:1527–1530, 1541, 1471–1474; C:569–583, 512–513 | scale `s = min(0.14, map.clientHeight / log.scrollHeight)`; drag sets `log.scrollTop = y/s − clientHeight/2`; `.mm-vw` top = `scrollTop·s`, height = `max(8, clientHeight·s)`; pointerdown on `.mm-e` → smooth `scrollTo` (auto under reduced motion) and `.flash` = `cvFlash 1.2s ease-out`; under reduced motion C:610 sets `.flash` to `animation: none`, so there is **no highlight at all** |
| Tree overlay | C:668, 675–677, 701; J:621–628, 942–947, 1183–1221, 566 | `bdTreeIn .22s ease-out` (opacity from 0), `backdrop-filter: blur(10px) saturate(.7)`; none under `.rm`; Escape closes. Path to open: `?trees=1`, hover a card **outside** `.bd-now` (J:946 ignores band cards), click `[data-lt="lock"]`, then `[data-lt="tree"]` (shown only when `.bd-lt.locked`, C:668). Hover clears on a 280 ms timer (J:947) |
| Grain | C:1125–1139, 1148, 1156, 1158, 1189 | static (no animation). Dark: `.bd-now::after` and `.ax-uc::after` `opacity .09`, `mix-blend-mode: overlay`, 160 × 160 px fractal-noise SVG. Light: `display: none` (C:1158 wins the cascade). `.bd-lanes::after` `display: none` (C:1189) |
| Infinite loops | C:219, 288–299, 318–324, 382, 396–401, 548, 562, 719 | `bdPulse`, `bdRot`, `bdStuck`, `bdAg`, `khSpin`, `cvDot`, `cvRec`; under `.rm` most become `none`, but `.bd-spin` becomes `3s` (C:324), still running; under `.stale` glows are `paused` (C:299) |

Reduced-motion gaps in the design (found by this research):

- **`tkin` has no reduced-motion rule** (H:1598–1599; nothing in C:348 or C:610).
  The design still animates the modal for 240 ms under reduced motion.
- **`.bd-spin` keeps spinning** under `.rm` (C:324, 3 s per turn). It exists
  only in the loading view (`renderLoading`, J:1249–1251), which shows for the
  600 ms boot timer (J:1565) and on a demo switch. A check that runs only after
  ready never sees it.
- The product's global rule (`dashboard.css:6865-6874`) sets every animation and
  transition to 0.01 ms and one iteration. It does not remove them: the product
  still creates a 0.01 ms animation or transition where the design's `.rm` rules
  create none. The comparison must normalise this (Invariants), or every
  reduced-motion sequence fails on a difference no user can see. After
  normalising, `tkin` and `.bd-spin` are the two real differences.

## Chosen design

**Approach: numbers first, pixels only at chosen frames.**

1. **JS-driven motion** (snap, debounce, 300 ms removal, 200 ms settle): before
   navigation, `page.clock.install({ time: NOW - 1000 })` then
   `page.clock.pauseAt(NOW)`, so both pages start at the same wall time and no
   real time leaks into `Date.now()` (relative labels such as "6m ago" stay
   equal on both pages). After `goto`, step the clock with `runFor(16)` until
   `waitParityReady` holds (this fires the design's 600 ms boot timer, J:1565),
   with a bound of 2000 ms of fake time; then measure, stepping with
   `page.clock.runFor(16)`. After each step, read `#bd-vp.scrollTop`, the lane
   key list and the `.leave` set. Both pages run under the same clock, so the
   two sequences are comparable frame by frame. The fake rAF fires on 16 ms
   boundaries (`getTimeToNextFrame`, `coreBundle.js:11434`), so one `runFor(16)`
   is one frame.
2. **CSS-driven motion** (`tkin`, `bdTreeIn`, transitions, `cvFlash`): the fake
   clock does not drive CSS. In the same `evaluate` call that triggers the
   change, read `el.getAnimations()`, `pause()` each one, and record
   `animationName` or `transitionProperty`, `getTiming()` (duration, delay,
   easing, iterations, fill) and `getKeyframes()`. Then set `currentTime` to
   0, 25, 50, 75 and 100 % of the duration and read the computed `opacity`,
   `transform`, `left`, `width` and `filter` at each point.
3. **Pixel check** only at three frames per sequence (0 %, 50 %, 100 %), through
   C1-T02's `expectDesignParity(pair, { name, region })`, with the animation
   paused at that point.
4. **DOM state** after each interaction: for each `.bd-card`, `.bd-lane`,
   `.bd-guide` and `.bd-mk` in the render window, keyed by `data-id` (cards) or
   the lane key: the sorted class tokens, and inline `top/left/width/height`.
   Also the URL query and `#bd-vp.scrollTop`.
5. **Comparison** returns a list of differences, each with a path such as
   `snap.settle-near-top.frame[7].scrollTop: design 1832 product 1840`. A path
   that matches a `motion` allowlist entry (below) is dropped. An empty list
   passes.

**Allowlist kind `motion` (accepted by C1-T02's loader).** C1-T02 owns
`loadAllowlist()` and its kind list (R-G6), which includes `motion`. A motion
difference is neither a node nor a pixel region, so this ticket uses that kind:

```json
{ "id": "tkin-reduced-motion", "kind": "motion", "selector": "#tk-modal",
  "path": "modal.reduce.animation.tkin.*", "property": null, "cells": {},
  "reason": "Product keeps the global reduced-motion rule; the design animates tkin",
  "approval": { "status": "pending-sign-off", "by": null, "date": null,
                "ref": "docs/.../MP-E8/tickets/MP-E8-C1-T03.md Decisions 3" } }
```

Validation (in C1-T02's loader): `path` is required if and only if the kind is `motion`, is
non-empty and uses only `*` as a wildcard. C1-T02's screenshot code ignores
`motion` entries. An entry whose path matched no difference in a full run is
reported as **stale** and fails the run (C1-T02's N11 rule applied to paths).
Status rules are C1-T02's unchanged: `pending-sign-off` passes in CI and is
printed in the annotations; it fails only in the C12-T08 `--gate` run.

**Interfaces (PROPOSED, `src/browser/support/build-home-motion.mjs`):**

```js
// Each sequence runs the same steps on a page, returns a plain record.
export const SEQUENCES = { 'snap.settle-near-top': async (page, ctx) => record, ... }
export async function runOn(page, name, ctx)       // -> { samples: [...], dom: {...} }
export function compareRecords(design, product, allowlist) // -> [{ path, design, product }]
export async function pausedAnimations(page, selector)     // -> [{ name, timing, keyframes, el }]
export async function scrollFrames(page, { from, frames }) // -> [scrollTop, ...]
```

**Invariants:**

- **A missing measurement is never a match.** If the design side of a sequence
  produces zero samples (for example, the animation ended before it was read,
  or a selector matched nothing), `compareRecords` returns
  `{ path, reason: 'unreachable' }`. It never compares two empty lists as equal.
  This is the AGENTS.md "unknown is never zero" rule applied to the harness.
- Sample values come from the design at run time, not from constants in the
  spec. The spec also checks the snap frames against the formula
  `y0 + (y − y0)(1 − (1 − k)^3)` with `dur = 420`, so a design re-import that
  changes the curve is visible.
- Time tolerance: **equal to the frame** (both events in the same 16 ms
  step). Position tolerance: **1 px** for `scrollTop` and inline geometry
  (sub-pixel rounding). Computed opacity: **0.001**. Matrix values: **0.01**.
- **Reduced-motion normalisation.** Under `reduce` only, an animation or
  transition whose duration is below 0.05 s is recorded as `none` on both
  pages, before comparison. This is the existing "near zero" rule of
  `build-order-interaction.browser.spec.mjs:216-219`, and it maps the product's
  0.01 ms global rule onto the design's `animation: none` / `transition: none`.
  It never applies under `no-preference`, where a 0.01 ms animation is a
  difference.
- The design files are never edited. Planted differences for the meta-tests use
  `page.route` to change the response text in memory (IMPORTED.md rule; the
  C1-T01 sha256 guard stays green).

**Product sequences that wait on a port.** The product cannot pass a sequence
before its porting ticket lands. Each product-side test declares its owner:

```js
// owner(s) and the product anchor that proves the port is in
const OWNER = {
  'snap.*':        { owners: ['MP-E8-C9-T08'],  anchor: '.bd-now-h > b' },   // C9-T08 note: not #bd-now (C9-T03)
  'columns.*':     { owners: ['MP-E8-C9-T04'],  anchor: '.bd-lanes .bd-lane' },
  'view.span':     { owners: ['MP-E8-C9-T10'],  anchor: '.bd-zoom [data-z]' },
  // the [data-v] buttons (C10-T01) appear before the views they switch to, so no
  // DOM anchor proves a view is ported: these use a flag the owner's PR removes
  'view.switch.graph': { owners: ['MP-E8-C10-T01'], pending: true },
  'view.switch.gantt': { owners: ['MP-E8-C9-T09'],  pending: true },
  'view.switch.list':  { owners: ['MP-E8-C9-T12'],  pending: true },
  'filter.*':      { owners: ['MP-E8-C10-T02'], anchor: '.bd-fg' },
  'feature.*':     { owners: ['MP-E8-C10-T03'], anchor: '[data-m="compact"]' },
  'modal.*':       { owners: ['MP-E8-C11-T01'], anchor: '#tk-modal.bdm' },
  'minimap.*':     { owners: ['MP-E8-C11-T05'], anchor: '#cv-map' },
  'tree.*':        { owners: ['MP-E8-C9-T11'],  anchor: '#build-root[data-bd-trees="ready"]' },
  'loading.spin':  { owners: ['MP-E8-C9-T13'],  anchor: '.bd-spin' },       // read in the boot window
  'grain.static':  { per: { '.bd-now': 'MP-E8-C9-T08', '.bd-lanes': 'MP-E8-C9-T04', '.ax-uc': 'MP-E8-C10-T04' } },
  'inventory':     { per: { '.bd-glow, .bd-ag': 'MP-E8-C9-T06', '.bd-now-h > b i': 'MP-E8-C9-T08',
                            '.bd-live i': 'MP-E8-C10-T01', '.bd-skel i': 'MP-E8-C9-T13' } },
}
```

A product test runs when the product page has the sequence's anchor element(s),
or, for an entry with `pending: true`, once the owner's PR deletes that flag.
`grain.static` and `inventory` are split into one test per selector group
(`per`), each with its own owner, so a partial port turns on only the groups it
owns. If the anchor is absent, the test calls
`test.fixme(true, 'awaiting <owner>')` inside the test body after the page is
open. It is never skipped silently and never passes. The design-vs-design run
always runs. C12-T08 fails if any `fixme` remains.

**Sequences added by porting tickets.** `SEQUENCES` is open. Porting tickets
already add `modal.goto` (C11-T01), `live.in` (C11-T05, `cvIn` 320 ms),
`tree.tab` and `tree.hover-clear` (C9-T11), and one product-only sequence
(C9-T04 M-9, a page-level product-only sequence for the duplicate-lane fix
the design cannot reach). A product-only
sequence sets `productOnly: true` and asserts fixed expected values instead of
a design record; it is listed as such in the sequence table and never counts
as design parity.

**Full matrix switch.** `AIUR_PARITY_FULL=1` (read once in the spec) runs every
sequence over the full theme × palette × viewport × motion matrix, for C12-T08
(C12-T08 interface note). Unset, step 3's narrowed matrix runs.

## Implementation steps

1. **Probe (first commit, do not skip).** A small test proves on this Playwright
   version that (a) `page.clock.install()` + `pauseAt(NOW)` before `goto` still
   lets the product LiveView connect and patch (`[data-phx-main].phx-connected`,
   as in `visual.mjs:48`; the fake clock also replaces `setTimeout`, so
   LiveView's own timers only fire on `runFor`), and (b) `runFor(16)` advances
   `scrollVP` by exactly one frame on the design. If (a) fails, install the
   clock after `phx-connected`, call `pauseAt` only inside each measured window,
   and make each window start at the same `Date.now()` on both pages. Record
   the result in the PR body.
2. PROPOSED `src/browser/support/build-home-motion.mjs`: `pausedAnimations`
   (reuse the `getAnimations({ subtree: true })` call of
   `browser-helpers.mjs:102`), `scrollFrames`, `domState`, `compareRecords`,
   `SEQUENCES`, `OWNER`. C1-T02's `loadAllowlist()` already accepts the
   `motion` kind (Chosen design); this ticket does not edit
   `design-parity.mjs`.
3. PROPOSED `src/browser/tests/build-home-motion.browser.spec.mjs`. For each
   dataset (`live`, `dense`, `newrepo`, `noqueue`, `offline`), viewport
   (1440 × 900, 1024 × 768, 390 × 844), theme (dark, light), palette (Gruvbox,
   default) and motion setting (`no-preference`, `reduce`): open the design and
   the product with C1-T02's openers, run each sequence on both, and compare.
   To keep run time sane, the full matrix runs only for the inventory and grain
   checks; the other sequences run on `live` at 1440 dark Gruvbox, plus
   `reduce`, plus one 390 px run (the narrow gutter is 46 px, J:541).
   `AIUR_PARITY_FULL=1` runs the full matrix for every sequence.
   A `reduce` run creates the context with `reducedMotion: 'reduce'` **before**
   navigation (through `openParityPair`'s context options), so the design's
   `shell()` sets `.bd-root.rm` (J:560). Only `reduce.live-toggle` uses
   `page.emulateMedia` after load.
4. The sequences, with their exact inputs (values computed from the design page
   at run time):

   | Name | Input | Expected (both pages equal) |
   | --- | --- | --- |
   | `snap.settle-near-top` | start pinned at the top (`y = topY`); lower `scrollTop` by 20 px (`y = topY + 20`, inside the 36 px strip, so `liveGuard` does not fire); no more scroll | `liveGuard` makes no change; at +200 ms `.scrolling` is removed and `snapLive` starts; 27 steps of 16 ms (420 ms) back to `nat − 46` |
   | `snap.settle-near-bottom` | start pinned at the bottom (`y = botY`); raise `scrollTop` by 20 px (`y = botY − 20`) | `liveGuard` makes no change; at +200 ms snaps to `nat + band.h − vh` |
   | `snap.pinned` | from the top pin, lower `scrollTop` by 1 px (`y = topY + 1`) | no change in `scrollTop` from either function (`y <= topY + 2`) |
   | `snap.guard-up` | start pinned at the top, scroll up 100 px | `liveGuard` snaps at once to the bottom; no second snap within 460 ms |
   | `snap.guard-down` | start pinned at the bottom, scroll down 100 px | snaps at once to the top |
   | `snap.tall-band` (EC-05) | viewport height chosen so `vp.clientHeight − band.h <= 46 + 72` | no snap from either function |
   | `snap.scrollbar-drag` | pointer down on `#bd-sb i`, move so the band lands mid-screen, step 300 ms, release, step 700 ms | no snap while `.bd-sb.drag`; the settle timer already fired during the drag, so there is **no snap after release either** until the next scroll event |
   | `snap.list-view` | `?view=list`, scroll | no snap |
   | `snap.reduce` (EC-19) | `snap.settle-near-top` under `reduce` | `scrollTop` is the target in the first sample after +200 ms; no frame in between |
   | `columns.enter-leave` | scroll from the band to the top of history | the lane set changes 220 ms after the triggering `update`; a leaving lane has `.leave` for 300 ms, then is gone; enter transition timing and keyframes as in the table above; lane order equals the design's `left` order |
   | `columns.reduce` | same, under `reduce` | no lane transition longer than 0.05 s; same final lane set and geometry |
   | `view.switch.gantt`, `.list`, `.graph` | click `[data-v="gantt"]`, `[data-v="list"]`, then `[data-v="graph"]` (one test per click) | same URL query, DOM state and `scrollTop` after each click |
   | `view.span` | each `.bd-cal [data-span]` button, then `.bd-zoom [data-z]` −/+ to both ends (J:1136–1137, 1146–1147). The selector must match ≥ 1 element on the design, or the record is `unreachable` | same `span` in the URL, `disabled` on the end buttons, DOM state |
   | `filter.dim` | Model popover (`.bd-fg`) → one model | same `.dim` set; card transition `opacity .25s, filter .25s` sampled at 0/50/100 % |
   | `feature.focus` / `feature.compact` | Feature popover → a feature; then `[data-m="compact"]`; then clear | same `dim`/`ghost`/`also` sets, lane `lock`, gap markers, URL `feature`/`fmode` |
   | `modal.open` | click the first `.bd-card.now`; separately load `?ticket=<id>` | `tkin` timing and keyframes; samples at 0/60/120/180/240 ms; pixel frames at 0/50/100 % of `#tk-modal` |
   | `modal.close` | `#bd-tk-close`, Escape, backdrop click | `.show` gone in the same step, zero running animations on `#tk-backdrop`, `?ticket=` removed, `body` overflow restored |
   | `modal.reduce` | `modal.open` under `reduce` | design: 240 ms `tkin`; product: static (see Decisions 3) |
   | `minimap.drag` | pointer down on `#cv-map` at 10 %, 50 % and 90 % of its height, move 40 px | `log.scrollTop` and `.mm-vw` top/height follow the formulas in the table above on each page |
   | `minimap.jump` | click the first `.mm-e` (the handler is `pointerdown`, J:1474) | target row gets `.flash`; `cvFlash` 1.2 s ease-out; final `scrollTop` after `scrollend` equal within 1 px; under `reduce` the scroll is instant and there is no flash animation on either page (C:610 `animation: none`) |
   | `tree.overlay` | `?trees=1`; hover a history or plan card that has a chain (not a `.bd-now` card, J:946); click `[data-lt="lock"]`, then `[data-lt="tree"]`; then Escape | `bdTreeIn` 0.22 s ease-out; `#bd-tree` `hidden` after Escape (J:566) |
   | `tree.reduce` | `tree.overlay` under `reduce` | no animation on `#bd-tree` on either page (C:701 on the design) |
   | `loading.spin` | read the inventory of `.bd-loading` before the 600 ms boot timer fires (clock paused at NOW, no `runFor` yet) | `khSpin` 0.8 s linear infinite on `.bd-spin` (C:323); under `reduce`: design 3 s (C:324), product none (Decisions 3) |
   | `reduce.live-toggle` | load with `no-preference`, then `page.emulateMedia({ reducedMotion: 'reduce' })`, then run `snap.settle-near-top` and `modal.open` | design: `.rm` stays off (J:560); `rmOn()` and the `@media` rules switch (snap instant, C:348 transitions off). Product: Decisions 4 |
   | `grain.static` | each theme × palette | computed `::after` style of `.bd-now`, `.ax-uc`, `.bd-lanes` as in the table above; `getAnimations()` on them is empty; two element screenshots 1 s apart are identical |
   | `inventory` | every dataset, after ready | the set of running animations in `#build-root` (name, duration, easing, iterations, playState) is equal; for `offline`, glows are `paused` (C:299) |

5. The minimap sequences compare **behaviour against each page's own content**
   (the formulas), because the design's conversation is generated by `convo(t)`
   (J:1306). C11-T03 extends C1-T01's exporter with the `convo(t)` fixture
   (`conversations.json`); the modal's content pixels are compared once it
   lands.
6. The design's mock stream appends rows on timers (J:1461, 1523–1525). Under
   the paused clock these timers fire only on `runFor`: the first one is
   1400 ms after the modal opens (J:1525), the next ones 1600–3800 ms apart
   (3600 ms under reduced motion, J:1522). So a measured window after a modal
   open must stay below 1400 ms of fake time (the `tkin` window is 240 ms). The
   spec asserts that `#cv-log` has the same child count at the start and end of
   each window, so a window that runs too long fails rather than comparing a
   different log. Other design timers also fire on `runFor` and are expected:
   `setInterval(syncSB, 500)` (J:556) and the 700 ms `.bd-sb.act` timer
   (J:555); `domState` does not read `#bd-sb`.
7. Meta-tests (PROPOSED, same spec, `describe('harness self-check')`): each
   loads the design twice, the second time with one planted change through
   `page.route`, and asserts that `compareRecords` reports exactly that path:

   | Planted change (in memory) | Expected difference path |
   | --- | --- |
   | J `dur = 420` → `dur = 400` | `snap.settle-near-top.frame[*].scrollTop` |
   | J `force ? 0 : 220` → `force ? 0 : 150` | `columns.enter-leave.applyAt` |
   | J `}, 300)` in `syncKeyed` → `}, 200)` | `columns.enter-leave.removeAt` |
   | J `rmOn() === "x"` → `rmOn()` | `snap.reduce.frame[*].scrollTop` (the snap disappears) |
   | H `tkin 0.24s` → `tkin 0.3s` | `modal.open.animation.tkin.duration` |
   | C `bdTreeIn .22s` → `bdTreeIn .3s` | `tree.overlay.animation.bdTreeIn.duration` |
   | C:1126 `opacity: .09` → `opacity: .12` (first occurrence only; C:1137 has the same text) | `grain.static.bd-now.after.opacity` |
   | remove C:701 | `tree.reduce.animation.bdTreeIn` |
   | C:324 `animation-duration: 3s` → `1s` | `loading.spin.reduce.animation.khSpin.duration` |
   | `compareRecords(record, emptyRecord)` | `reason: 'unreachable'`, not a pass |

   Plus one determinism test: the design against itself, three runs, zero
   differences. It also asserts that every sequence record has at least one
   sample (snap sequences at least 27 frames), so it cannot pass on empty
   records.
8. `src/browser/package.json`: add `"test:build-home-motion": "npm run
   fixture:preflight && node scripts/run-browser-tests.mjs
   tests/build-home-motion.browser.spec.mjs --config
   playwright.design-parity.config.mjs"` and add it to the `test` chain
   (`package.json:10`). The `--config` is C1-T02's (PROPOSED): it sets the
   per-run `snapshotDir` that `expectDesignParity` writes the design frame to.
   No Docker step: C1-T02 compares two live renders and keeps no checked-in
   baselines, so the pinned-Chromium runner (`visual.mjs:96-111`, which runs
   only `tests/visual-shell.browser.spec.mjs`, `:103`) does not apply.

## Non-happy paths

- **Flaky timing.** Real-time waits are not used for JS motion; only the fake
  clock. The determinism meta-test fails on any run-to-run difference. If the
  probe (step 1) shows LiveView stalls under the fake clock, the clock is paused
  only inside each measured window.
- **An animation ends before it is read.** Triggering and pausing happen in one
  `evaluate` call, so no frame passes between them. If the design side still
  returns nothing, the result is `unreachable` (a failure), never a pass.
- **Native smooth scroll** (`scrollTo({ behavior: "smooth" })`, J:1470–1471)
  is browser-driven and not stepped by the fake clock. Only the start and the
  final position (after `scrollend`) are compared.
- **Scroll events are real-time.** After setting `scrollTop`, the script awaits
  one `scroll` event in the page before it advances the clock. Otherwise
  `markScrolling` has not armed its 200 ms timer.
- **Product-only DOM.** Class tokens that LiveView adds (`phx-*`), `data-phx-*`
  attributes, the `role="status"` on `.bd-loading` (C9-T13) and the
  screen-reader-only agent-state label (plan §10 item 7, S-4) are excluded by an
  explicit list in the support module. Any other extra or missing token is a
  difference.
- **Ids.** Cards are matched by `data-id`. If the product's id differs from the
  design's for the same fixture row, the comparison uses the manifest `ids`
  map that the C3-T02 fixture mapper writes. A card with no partner is a difference, not
  a skip.
- **OS setting changed mid-session** (`reduce.live-toggle` only; every other
  `reduce` run sets the setting before load). The script emulates `reduce` after
  load (`page.emulateMedia`). The design keeps `.bd-root` without `.rm` (J:560)
  but its `@media` rules and `rmOn()` change. A product that updates `.rm` live
  differs; the difference goes to sign-off (Decisions 4).
- **Stale allowlist entry.** A `motion` entry whose path matched no difference
  fails the run, so an entry cannot outlive the difference it excuses (for
  example after C2-T04 scopes the global rule, Decisions 3).
- **Selector matches nothing on the design.** Every sequence input selector is
  checked on the design page first; zero matches make the record
  `unreachable`, not an empty pass (the `.bd-zb` case: the class exists only in
  `build.css`, never in the DOM).
- **Security/privacy:** none. Fixtures only, loopback server, no credentials
  beyond the existing harness `dashboardCredentials`.

## Compatibility and rollout

- No product code, config, migration or route changes. Test-only.
- The spec is added to `npm test` in `src/browser/`. CI time grows; the
  narrowed matrix (step 3) keeps the motion part under about 3 minutes. The
  writer measures and records the time in the PR body.
- Rollback: delete the spec and the support module.
- Docs: none (test-only change, AGENTS.md "Docs ship with the change").

## Pixel parity

- **Design elements checked:** `#bd-vp` and `.bd-now` (snap), `.bd-lanes`,
  `.bd-lane`, `.bd-guide` (columns), `.bd-card` with `.dim`, `.ghost`, `.also`,
  `.hdim` (filters, focus), `#tk-backdrop`, `#tk-modal.bdm` and `tkin` (modal),
  `#cv-map`, `.mm-vw`, `.mm-e`, `.cv-log > .flash` (minimap), `#bd-tree` and
  `bdTreeIn` (tree), `.bd-now::after`, `.ax-uc::after`, `.bd-lanes::after`
  (grain), all keyframes listed in the inventory row.
- **How parity is checked:** numbers through `compareRecords` (timing, keyframes,
  positions per frame, computed style at sample points, DOM state). Pixels
  through C1-T02's `expectDesignParity(pair, { name, region })` at the 0/50/100 % frames of `snap.*`,
  `modal.open` and `tree.overlay`, and for `grain.static`, at the C1-T02
  anti-aliasing threshold.
- **Allowlist:** C1-T02's file. This ticket adds the two `motion`
  `pending-sign-off` entries of Decisions 3 (`tkin-reduced-motion`, path
  `modal.reduce.animation.tkin.*`; `bd-spin-reduced-motion`, path
  `loading.spin.reduce.animation.khSpin.*`) and nothing else. Decision 4 may
  add a third, only if the product differs in `reduce.live-toggle`.

## Verification

Tests (all PROPOSED, `src/browser/tests/build-home-motion.browser.spec.mjs`):

| Test | Expected | Fails without |
| --- | --- | --- |
| `harness self-check: design vs design is stable` | 3 runs, zero differences | the fake clock (real-time sampling drifts) |
| `harness self-check: planted <change>` (9 planted rows of step 7) | exactly the named path is reported | `compareRecords` (replace its body with `return []`: all 9 fail) |
| `harness self-check: empty record is unreachable` | `reason: 'unreachable'` | the non-empty guard in `compareRecords` |
| `harness self-check: reduce normalisation` | a design `animation: none` and a planted product-shaped 0.01 ms animation on the same element compare equal under `reduce`, and differ under `no-preference` | the `< 0.05 s → none` step (remove it: the `reduce` half fails; apply it always: the `no-preference` half fails) |
| `harness self-check: motion allowlist` | an entry for a path that differs drops it; an entry for a path that never differs fails as stale; `kind: 'motion'` without `path`, and `path` on a non-`motion` kind, make `loadAllowlist()` throw | the `motion` branch of `loadAllowlist` and the stale check |
| `harness self-check: missing selector` | `view.span` run with the input selector `.bd-zb` gives `unreachable` | the input-selector check |
| `snap.*`, `columns.*`, `view.*`, `filter.*`, `feature.*`, `modal.*`, `minimap.*`, `tree.*`, `loading.spin`, `reduce.live-toggle`, `grain.static`, `inventory` — design vs product | zero differences after the allowlist, or `fixme: awaiting <owner>` | the owning port (C9/C10/C11) |
| `snap.reduce` (EC-19) | target reached in one step | a port that changes J:593 to `rmOn()` (the planted test proves the check sees it) |

Mutation check (AGENTS.md): in a worktree, with `git status --porcelain` showing
only the revert, replace the body of `compareRecords` with `return []` and run
the self-check block; every planted test and the unreachable test must fail.
Restore; all pass. Then do the same for the normalisation step and the
`motion` branch of `loadAllowlist` (each against its own self-check row).
Report the exact commands in the PR body.

Commands (isolated HOME and no GitHub tokens, because `fixture:preflight` and
the fixture server boot the app; memory note "mix test clobbers agent-token").
The tool paths stay real, or `mise` and `mix` cannot find their installs.
`$HOME` is expanded by the shell before `env` replaces it. Record
`sha256sum ~/.aiur/github-budget/agent-token` before and after; they must match.

```bash
WT=<worktree root>; mkdir -p "$WT/.tmp/home"
ISO=(-u GITHUB_TOKEN -u GH_TOKEN MISE_DATA_DIR="$HOME/.local/share/mise"
     MISE_CACHE_DIR="$HOME/.cache/mise" MIX_HOME="$HOME/.mix" HEX_HOME="$HOME/.hex"
     HOME="$WT/.tmp/home")
env -C "$WT/src/browser" "${ISO[@]}" mise exec -- npm run test:build-home-motion
env -C "$WT/src/browser" "${ISO[@]}" mise exec -- npm run test:build-home-motion -- --grep "harness self-check"
env -C "$WT/src/browser" "${ISO[@]}" AIUR_PARITY_FULL=1 mise exec -- npm run test:build-home-motion   # C12-T08 shape, once
```

Manual: not required. This ticket ships no user-facing surface. The live-pane
transition is checked by eye in C12-T08 with the frames this spec saves.

## Decisions made without the owner

1. **No video.** Playwright video is real-time and lossy, so two runs differ.
   The fake clock plus Web Animations sampling is deterministic and uses only
   platform features (ponytail: reuse). Kevin still sees frames: the spec saves
   the 0/50/100 % element screenshots for C12-T08.
2. **Frame tolerance is one 16 ms step; position tolerance is 1 px.** Smaller is
   not measurable with rAF-quantised timers and sub-pixel `scrollTop`.
3. **Reduced motion keeps the product's global rule** (`dashboard.css:6865-6874`).
   Accessibility is never cut. Two design behaviours differ under `reduce`:
   the modal's 240 ms `tkin` (H:1598, no `rm` rule) and the 3 s `.bd-spin`
   (C:324). The product's 0.01 ms rule normalises to `none`, so the product
   shows both static. They go into the allowlist as
   `pending-sign-off`, with this ticket as the source, and C12-T08 shows them to
   Kevin as S-18 (with C9-T10's dot-grid reduced-motion hold). If Kevin wants the design's behaviour, C2-T04 scopes the global rule
   away from those two selectors.
4. **A live change of the OS motion setting** follows whatever the product does;
   if it differs from the design (J:560 sets `.rm` once), it is a
   `pending-sign-off` entry with "updates live" as the default.
5. **The full theme × palette × viewport matrix runs only for `inventory` and
   `grain.static`.** Interaction sequences do not depend on colour, so running
   them 24 times adds time and no coverage. C12-T08 runs the full matrix once
   with `AIUR_PARITY_FULL=1`.
6. **Minimap checks compare behaviour, not content,** until C11-T03's
   `convo(t)` fixture lands.
7. **Modal close is checked as "instant".** The README row says "modal open and
   close"; the design has no exit animation (H:3685, J:1542), so a product exit
   animation is a difference.
8. **The `rmOn() === "x"` guard (J:593) is treated as design behaviour,** not a
   bug to fix: under reduced motion the snap happens instantly, which is what
   C9-T08's row asks for.
9. **The allowlist kind `motion`, keyed by record path.** The node and pixel
   kinds cannot express a timing difference. C1-T02's one loader accepts
   `motion`, which is smaller than a second list and keeps C1-T02's
   validation, stale and sign-off rules (ponytail: reuse).
10. **Settle-snap inputs stay inside the 36 px strip.** `liveGuard` runs on
   every scroll event (J:567), so a jump into the middle third is caught by it
   and `snapLive` never runs. The settle sequences therefore move 20 px from a
   pin; the guard sequences cover the larger moves.
11. **Reduced-motion normalisation uses the repo's `< 0.05 s` rule**
   (`build-order-interaction.browser.spec.mjs:216-219`), not a new threshold.
12. **`view.switch` uses an explicit `pending` flag, not a DOM anchor.** The
   buttons (C10-T01) exist before the views (C9-T09, C9-T12), so an anchor would
   turn the test on before the port and fail `main`.

## Completion and handoff

- [ ] Probe result (step 1) recorded in the PR body.
- [ ] Support module and spec merged; `test:build-home-motion` in the `npm test`
      chain.
- [ ] Design-vs-design determinism: 3 runs, zero differences.
- [ ] All 9 planted-change tests and the unreachable test pass, and fail with
      `compareRecords` replaced by `return []` (command in the PR body).
- [ ] Every product sequence either passes or is `fixme` naming its owner.
- [ ] `loadAllowlist()` accepts the `motion` kind with its validation; the two
      `pending-sign-off` entries (Decisions 3) are in C1-T02's allowlist with this
      ticket as the source, and neither is stale.
- [ ] `AIUR_PARITY_FULL=1` runs every sequence over the full matrix (C12-T08).
- **Dependents:** C12-T08 (no `fixme` may remain). C9-T04, C9-T06, C9-T08,
  C9-T09, C9-T10, C9-T11, C9-T12, C9-T13, C10-T01, C10-T02, C10-T03, C10-T04,
  C11-T01 and C11-T05 each turn on their sequence (anchor present or `pending`
  flag removed) in their own PR and must pass it.
- **Interface notes for neighbours** (also in the return line to the coordinator):
  - C1-T02: Settled 2026-10-08: C1-T02's loader accepts `motion`, `axe` and
    `copy`; `pending-sign-off` passes in CI and fails only in the C12-T08
    `--gate` run.
  - README rows: C9-T04 and C10-T03 already add C1-T03 to `blocked_by`.
    C9-T08, C9-T10, C9-T11, C10-T02, C11-T01 and C11-T05 name their sequence in
    their own acceptance but not in the README row. C9-T06, C9-T09, C9-T12,
    C9-T13, C10-T01 and C10-T04 own `OWNER` entries (above) and do not mention
    them yet. Either order works with the `fixme` rule; the README should add
    "C1-T03 sequence `<name>` passes" to each row.
  - C1-T01/C3-T02: Settled 2026-10-08: the C3-T02 fixture mapper writes the
    manifest `ids` map; C11-T03 owns the `convo(t)` exporter extension.
  - C2-T04: the global reduced-motion rule will win over `build.css` for the
    home page (`!important`); see Decisions 3.
- **Sources:** `../plan.md` §8 (EC-05, EC-19), §10, §11; `../chunks.md` C1;
  `README.md` rows C1-T02, C1-T03, C9-T04, C9-T08, C9-T11, C11-T01, C11-T05,
  C12-T08; neighbour tickets `MP-E8-C1-T02.md` (names, allowlist, clock note),
  `MP-E8-C9-T04.md`, `MP-E8-C9-T08.md`, `MP-E8-C9-T10.md`, `MP-E8-C9-T11.md`,
  `MP-E8-C10-T03.md`, `MP-E8-C11-T01.md`, `MP-E8-C11-T05.md`, `MP-E8-C12-T08.md`; `../claude-design-source-of-truth.md` ("Motion", "Interaction
  parity"); DESIGN-E8 "States the prototype must show: reduced motion".

## Review log

Adversarial review, 2026-10-08, against design-source, `runtime/src` at
`58854d4c8`, README, C1-T02 and the neighbour tickets.

1. C1-T02 names: `compareElement`/`ALLOWLIST` replaced with C1-T02's real
   names (`openParityPair`, `waitParityReady`, `expectDesignParity({ region })`,
   `loadAllowlist`, `design-parity-allowlist.json`); clock hand-off
   (`setFixedTime` → `install` + `pauseAt`) recorded.
2. Clock start: install at `NOW − 1 s` and `pauseAt(NOW)` before `goto`, so
   both pages share one wall time; boot timer stepped with `runFor`.
3. Snap inputs: `liveGuard` runs on every scroll event (J:567), so the old
   "move to 30 % / 70 %" settle inputs could never reach `snapLive`. Inputs now
   stay inside the 36 px strip; scrollbar-drag expects no snap after release.
4. `.bd-zb` (CSS-only, never in the DOM) replaced with `.bd-zoom [data-z]` and
   `.bd-cal [data-span]`; a selector that matches nothing is `unreachable`.
5. Reduced-motion normalisation (`< 0.05 s → none`) added; without it the
   product's 0.01 ms global rule fails every `reduce` sequence.
6. `.bd-spin` exists only in the loading view, so the `pending-sign-off` entry
   would have been stale; added `loading.spin` and a planted test.
7. Allowlist: C1-T02 already has `pending-sign-off` (interface note corrected),
   but has no kind for a timing difference; added the `motion` kind with
   validation, stale check and self-check tests.
8. Docker step removed: C1-T02 keeps no baselines and has no Docker path;
   `--config playwright.design-parity.config.mjs` added to the script.
9. Mock-stream first timer is 1400 ms (J:1525), not ≥ 1600 ms; other timers
   that fire on `runFor` listed.
10. `OWNER` map completed with anchors (C9-T08's `.bd-now-h > b`), per-group
    owners for `grain.static`/`inventory`, a `pending` flag for
    `view.switch.*`, sequences added by porting tickets, and
    `AIUR_PARITY_FULL=1` for C12-T08.
11. Tree path corrected (lock, then the tree tab; band cards do not hover);
    `tree.reduce` row added to match the planted path; minimap flash under
    reduce is "no animation" (C:610), per C11-T05's note.
12. Determinism test now asserts non-empty records; test commands keep real
    `MISE_*`/`MIX_HOME`/`HEX_HOME` with an isolated HOME and a token hash check.
- Reconciliation 2026-10-08 (coordinator): `pending-sign-off` spelling (all occurrences), pending fails only in the C12-T08 `--gate` run, `motion` kind accepted by C1-T02's loader (no `design-parity.mjs` edit; Decisions 9, step 2), `tree.*` anchor `#build-root[data-bd-trees="ready"]`, M-9 page-level product-only, DOM inventory ignores `phx-*`/`data-phx-*`/`.bd-loading` `role="status"`, `convo(t)` fixture from C11-T03, `ids` map from the C3-T02 mapper, reduced-motion holds are S-18 (with C9-T10 dot-grid), interface notes settled.
