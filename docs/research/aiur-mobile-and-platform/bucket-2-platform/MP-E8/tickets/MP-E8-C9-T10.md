---
ticket_id: MP-E8-C9-T10
feature_id: MP-E8
chunk_id: MP-E8-C9
bucket: 2-platform
title: Span, zoom and calendar controls
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C9-T02, MP-E8-C9-T03, MP-E8-C10-T01]
complexity: 2
design_gate: DESIGN-E8
owns_edge_cases: []
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C9-T10 — Span, zoom and calendar controls

> **Wave 0b.** Product paths are cited at `58854d4c8`. Paths marked PROPOSED do
> not exist yet. `J` = `design-source/assets/build.js`, `C` =
> `design-source/assets/build.css`, `H` = `design-source/Aiur Dashboard.html`.
> The design is the specification
> ([claude-design-source-of-truth.md](../claude-design-source-of-truth.md)):
> port the code, remove only the mock parts.

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C9 (client timeline
  engine, port of `build.js`).
- **User value.** The operator changes how many days the timeline shows: one
  click for Day, Week or Month, or −/+ for the nine finer steps. The board
  re-lays out at the new density, returns to the live band, and the address bar
  keeps the span, so a shared link opens at the same zoom.
- **Deliverable.** PROPOSED `src/priv/static/build-home/span.js`, a port of:
  - `setSpan` and `calNear` (J:1228–1232);
  - `CALI` and `calIc` (J:1222–1227);
  - the Range and Zoom markup (J:1136–1137) as `spanToolsHTML()`;
  - their click handlers (J:1146–1147) as `wireSpanTools(host)`, one delegated
    listener (the names and the delegation are C10-T01's contract, its 4.3);
  - the dot-grid size (J:654) as `dotSize(span)`.
  Plus one line in `render.js` (C9-T03) that sets `--dot`, and the tests in
  section 8.
- **Scope.**
  - `.bd-seg.ic.bd-cal` with three buttons (`data-span` 1, 7, 30), the `CALI`
    icons, and the `.on` state from `calNear()`.
  - `.bd-seg.bd-zoom` with `−` (`data-z="1"`), the `.bd-zv` label, and `+`
    (`data-z="-1"`), including the disabled ends.
  - Both groups are hidden in list view, as J:1136 does.
  - `--dot` on `#bd-vp` after every timeline or Gantt relayout.
  - `jumpNow(true)` after a span change (through `fx`).
  - Accessibility additions that do not change pixels (section 4.5).
- **Non-goals.**
  - `SPANS` itself: `state.js` (C9-T01) exports it. This ticket imports it.
    (The README row lists `SPANS` in this ticket's scope; C9-T01's module table
    gives it to `state.js`. See Interface note 6.)
  - `scrollVP` and `jumpNow` (J:1233–1248, inside the README row's "J:1222–1248"
    range): C9-T08's `band.js`. This ticket only calls `fx.jumpNow(true)`.
  - What the span does to the layout (pixels per hour, density tiers, `BRK`,
    flow mode, J:358–533): C9-T02 (timeline) and C9-T09 (Gantt).
  - Loading the extra history days a wide span needs (J:642): C9-T03 already
    replaces that line with `ensureDays(S.span)` inside `relayout()`.
  - The rest of `#bd-tools` (`#bd-nowbtn`), the view segment and the status
    line: C10-T01 (`renderTools`) and C9-T08 (`jumpNow`, `scrollVP`).
  - `fitTree`, which steps through `SPANS` (J:956–965): C9-T11.
  - URL parsing and validation of `span`: C3-T03 (server) and C9-T01 (`url.js`).
  - Keyboard shortcuts for zoom. The design has none (J:566 handles only Escape).

## 2. Dependencies and blockers

- **Blocked by DESIGN-E8** (feature gate). The design shows every state of these
  controls; the only sign-off item is S-18 (dot-grid reduced motion, Decision 4).
- **Predecessors.**
  - **MP-E8-C9-T02** (README row): `computeLayout` reads `S.span`, so a span
    change has a visible effect.
  - **MP-E8-C9-T03** (added, see Interface note 1): `relayout()` lives in
    `render.js`, and this ticket adds the `--dot` line there. `relayout()` also
    calls `ensureDays(S.span)`, so a wide span loads its days.
  - **MP-E8-C10-T01** (added, see Interface note 2): `renderTools()` in
    `tools.js` writes `#bd-tools` and calls `fx.spanToolsHTML()` and
    `fx.wireSpanTools(host)`. Without it nothing renders this ticket's markup,
    so the page tests in section 8 cannot run. C9-T01 creates
    `build-home/icons.js` with `sv` (J:32), which `span.js` imports (R-G9).
  - Transitively C9-T01 (`state.js` with `S`, `SPANS`, `ctx`, `fx`; `url.js` with
    `writeURL`; `onServerURL`), C3-T03 (`span` URL key), C2-T04
    (`build-home/home.css`, which carries every rule in section 4.4).
- **Soft dependency, not a blocker: C9-T08** (`jumpNow`). This ticket calls
  `fx.jumpNow(true)`. Until C9-T08 merges, `fx.jumpNow` is C9-T01's no-op
  default, so the board does not return to the band after a span change. This
  ticket's tests check that the call happens; C9-T08's tests check where it
  scrolls.
- **Successors.** C9-T11 (`fitTree` imports `SPANS` and relies on the `--dot`
  line in `relayout()`), C12-T05 (accessibility pass), C12-T07 (docs), C12-T08
  (sign-off).
- **May run concurrently with:** C9-T04..T09, C9-T12, C9-T13, C10-T02..T04, and
  all server tickets. File overlap: one line in `render.js`, one `import` line in
  `hook.js`, and the two `fx` defaults in `state.js` if C10-T01 has not added
  them. `tools.js` is not edited (C10-T01 already calls the `fx` entries).
- **Owner questions.** No `OQ-E8-n`. S-18 (dot-grid reduced motion) follows
  Decision 4.

## 3. Verified starting point (`58854d4c8`)

**Product.** No home page and no `build-home/` directory exist yet. `span.js`,
`render.js`, `tools.js`, `state.js` and `url.js` are PROPOSED by C9-T01's module
table ([MP-E8-C9-T01.md](MP-E8-C9-T01.md) "Module layout": `span.js` → C9-T10,
exports `setSpan`, `calNear`; `state.js` exports `SPANS`). Reused patterns:

- `src/priv/static/build-order-grid-hook.js:114-131`: `setZoom` clamps,
  updates the readout and writes an announcement; `onZoomClick` maps
  `data-bo-zoom` to a step. `:185-195`: the readout text and the disabled state
  at each end. This is the product's current zoom control. This ticket keeps its
  announcement idea and the design's markup.
- `src/lib/aiur_web/components/operator_control_center/build_order_graph.ex:101-109`:
  the zoom group has `role="group" aria-label="Zoom controls"`, the readout
  has `aria-live="off"`, and a separate `<p class="sr-only" aria-live="polite"
  aria-atomic="true" data-bo-grid-announce>` carries the announcement. This
  ticket copies that split.
- `src/priv/static/dashboard.css:215-225`: `.sr-only` (absolute, 1×1 px, clipped).
  It has no visible pixels. The root layout loads this file on every page
  (`src/lib/aiur_web/components/layouts.ex:290`, `<link rel="stylesheet"
  href="/dashboard.css" />`).
- `src/priv/static/dashboard.css:6865-6874`: under `prefers-reduced-motion:
  reduce`, `*` gets `transition-duration: 0.01ms !important`. This already
  removes the `.bd-vp` dot-grid transition for those users (see 4.5).
- `src/priv/static/time-brush-hook.js:94`: a hook that pushes a server event
  (`pushEvent("time-domain", …)`). `url.js` (C9-T01) follows it for `build:url`.
- Browser tests: `src/browser/package.json:10` (the `npm test` chain);
  `src/browser/tests/` has no `build-home-*` spec yet. Sibling tickets add
  `build-home-shell` (C9-T01), `build-home-render` (C9-T03) and
  `build-home-columns` (C9-T04) in the same pattern.

**Design (the specification).**

| Element | Source | What must match |
| --- | --- | --- |
| `SPANS` | J:302 | `[1, 2, 3, 5, 7, 10, 14, 21, 30]` |
| Default | J:303 | `span: 1` |
| URL | J:310, J:320 | `span` read only if in `SPANS`; written only when `≠ 1`; `zoom` deleted (C3-T03 drops it) |
| Range markup | J:1136 | `<div class="bd-seg ic bd-cal" aria-label="Range">`; buttons `[1,"Day"]`, `[7,"Week"]`, `[30,"Month"]`; `type="button"`, `data-span`, `class="on"` when `calNear() === value`, `title` = label; icon `calIc("1" \| "7" \| "31")` |
| Zoom markup | J:1137 | `<div class="bd-seg bd-zoom" aria-label="Zoom">`; button `data-z="1"`, `title="Zoom out · more days"`, `aria-label="Zoom out"`, text `−` (U+2212), `disabled` when `span >= 30`; `<span class="bd-zv" title="{span} day(s) in view">{round(100/span)}%</span>`; button `data-z="-1"`, `title="Zoom in · fewer days"`, `aria-label="Zoom in"`, text `+`, `disabled` when `span <= 1` |
| List view | J:1136 | neither group is rendered when `S.view === "list"` |
| Position | J:1135–1137 | inside `#bd-tools`, after `#bd-nowbtn`: Live, Range, Zoom |
| Zoom step | J:1146 | `i = SPANS.indexOf(span)` (`-1` → `0`), `j = clamp(i + data-z, 0, 8)`, `setSpan(SPANS[j])` |
| Range click | J:1147 | `setSpan(+data-span)` |
| `calNear` | J:1228 | `[1,7,30].reduce((a,b) => |ln(b/span)| < |ln(a/span)| ? b : a)` (strict `<`: a tie keeps the smaller) |
| `setSpan` | J:1229–1232 | no-op if equal; else `S.span = sp; writeURL(); renderTools(); relayout(); jumpNow(true)` |
| `CALI` | J:1222–1226 | three path strings (below), drawn by `sv(p, 1.9)` (J:32: `viewBox="0 0 24 24"`, `fill="none"`, `stroke="currentColor"`, round caps and joins) |
| `--dot` | J:654 | `max(14, 30 − 16·ln(span)/ln(3)).toFixed(1) + "px"` on `#bd-vp`, set in `relayout()` after `computeLayout()`, not in list view (J:643 returns first) |

`CALI` paths, copied byte for byte:

```js
"1":  '<rect x="4" y="4" width="16" height="16" rx="2.5"/><path d="M4 9h16"/>',
"7":  '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M3 9h18M9 9v11M15 9v11"/>',
"31": '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M3 9h18M3 14.5h18M9 9v11M15 9v11"/>',
```

Values these formulas give (checked by hand from J:654, J:1137, J:1228):

| span | `calNear` | `.bd-zv` | `.bd-zv` title | `--dot` | − | + |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Day | `100%` | `1 day in view` | `30.0px` | enabled | disabled |
| 2 | Day | `50%` | `2 days in view` | `19.9px` | enabled | enabled |
| 3 | Week | `33%` | `3 days in view` | `14.0px` | enabled | enabled |
| 5 | Week | `20%` | `5 days in view` | `14.0px` | enabled | enabled |
| 7 | Week | `14%` | `7 days in view` | `14.0px` | enabled | enabled |
| 10 | Week | `10%` | `10 days in view` | `14.0px` | enabled | enabled |
| 14 | Week | `7%` | `14 days in view` | `14.0px` | enabled | enabled |
| 21 | Month | `5%` | `21 days in view` | `14.0px` | enabled | enabled |
| 30 | Month | `3%` | `30 days in view` | `14.0px` | disabled | enabled |

CSS (all in `C`; C2-T04 copies these into `home.css` in cascade order):

| Selector | Lines | Final computed values |
| --- | --- | --- |
| `.bd-seg` | 117, 418–423 | `inline-flex`; `padding: 2px`; `border-radius: 9px`; border transparent with the v5 gradient edge: `--bgc: var(--surface-3)`, `--bt: color-mix(in srgb, var(--fg) 15%, var(--bgc))`, `--bb: var(--bgc)` |
| `.bd-seg button` | 118–120, 29 | `height: 28px`; `padding: 0 .7rem`; `border-radius: 7px`; no border or background; `color: var(--muted)`; `font: 600 .74rem "Space Grotesk"`; `nowrap`; `.on` → `background: var(--surface)`, `color: var(--fg)`, `box-shadow: var(--shadow-sm)` |
| `.bd-seg.ic button` | 632, 633, 715 | `padding: 0 .5rem`; svg `15px` |
| `.bd-cal button svg` | 931 | declares `16px × 16px`, but it **loses**: specificity (0,1,2) is lower than `.bd-seg.ic button svg` (0,2,2, C:633 and C:715). The computed icon size is **15 × 15 px**. Copy C:931 as it is (C2-T04); do not "fix" it to 16 px |
| `.bd-seg.bd-zoom` | 151, 634 | `align-items: center`; `gap: 0` |
| `.bd-seg.bd-zoom button` | 635, 716, 636 | `min-width: 30px` (716 wins over 635's 28 px); `justify-content: center`; `padding: 0 .45rem`; `font-size: .9rem`; `:disabled` → `opacity: .35`, `cursor: default` |
| `.bd-zv` | 155, 637, 932 | `font-family: "JetBrains Mono"`; `min-width: 2.4rem`; `font-size: .66rem`; `display: inline-grid`; `place-items: center`; `text-align: center`; `color: var(--muted)` |
| `.bd-vp` dot grid | 1095, 1096, 1098, 1099 | `background-size: var(--dot, 22px) var(--dot, 22px)`; `transition: background-size .4s cubic-bezier(.22,1,.36,1)`; the final image is C:1098 (dark: `color-mix(in srgb, var(--fg) 8%, transparent) .7px, transparent 1.2px`) and C:1099 (light: 12 %) |
| Toolbar breakpoints | 644, 723, 941, 1024 | the right tools stay in `.bd-bar-r`; below 1180 px and 720 px the filters move to their own line (C10-T01 owns the toolbar) |

Dead in this area (not emitted by J, so not ported): `.bd-zb` (C:152–154,
418–425; J has no `bd-zb` class) and `#bd-fit` (C:638; J has no `bd-fit` id).
C2-T04 lists both as dead rules; this ticket emits neither.

## 4. Chosen design

Port the design's code into `span.js` with three changes: no mock path, a
guard on the value, and a loading guard. Everything else is line for line.

### 4.1 `span.js` (PROPOSED)

```js
// build-home/span.js — port of J:1222–1232, 1136–1137, 1146–1147, 654
import { S, ctx, fx, SPANS, onReset } from "./state.js";
import { writeURL } from "./url.js";
import { $ } from "./dom.js";
import { sv } from "./icons.js";                          // J:32, created by C9-T01

const CALI = { /* the three strings above, byte for byte */ };
export const calIc = (n) => sv(CALI[n], 1.9);
export const calNear = () => [1, 7, 30].reduce((a, b) => Math.abs(Math.log(b / S.span)) < Math.abs(Math.log(a / S.span)) ? b : a);
export const dotSize = (span) => Math.max(14, 30 - 16 * Math.log(span) / Math.log(3)).toFixed(1) + "px";

export function setSpan(sp) {
  if (!SPANS.includes(sp) || sp === S.span) return;   // guard added; the equality test is J:1230
  const refocus = focusedRangeControl();               // 4.5
  S.span = sp; writeURL(); fx.renderTools();
  restoreFocus(refocus); announce();
  if (S.loading) return;                               // 4.3
  fx.relayout(); fx.jumpNow(true);
}

export function spanToolsHTML() { /* J:1136–1137 with the 4.5 attributes; "" in list view */ }

let wired = new WeakSet();
onReset(() => { wired = new WeakSet(); });             // a remount gets a new ctx.life
export function wireSpanTools(host) {                  // J:1146–1147, delegated once per host
  if (wired.has(host)) return;
  wired.add(host);
  ctx.life.on(host, "click", (e) => {
    const z = e.target.closest("[data-z]"), d = e.target.closest("[data-span]");
    if (z && host.contains(z)) {
      const i = SPANS.indexOf(S.span), j = Math.max(0, Math.min(SPANS.length - 1, (i < 0 ? 0 : i) + (+z.dataset.z)));
      setSpan(SPANS[j]);
    } else if (d && host.contains(d)) setSpan(+d.dataset.span);
  });
}
Object.assign(fx, { spanToolsHTML, wireSpanTools });
```

- **Listeners.** C10-T01's `renderControls()` calls `fx.wireSpanTools(host)`
  after every write of `#bd-tools` (C10-T01 4.3). `#bd-tools` itself is not
  replaced, only its children, so one delegated listener per host is enough.
  It goes through `ctx.life.on` (C9-T01 rule 4), so `destroyed` removes it, and
  the `WeakSet` stops a second listener on each rewrite (C10-T01 4.3 note: the
  `offs` list would otherwise grow on every rewrite). A click on a `disabled`
  button sends no `click` event, so the delegated handler does not see it, as
  in the design.
- **Module state.** Only `wired`. `onReset` clears it, because a LiveView
  navigation away and back runs `mounted` again on the same module instance
  (C9-T01 rule 3). Without the reset, a remount that kept the same `#bd-tools`
  node would get no listener. `S.span` lives in `state.js`.

### 4.2 The `--dot` line in `relayout()`

In `render.js` (C9-T03), at the J:654 position (after `L = computeLayout()` and
`svg.setAttribute("height", 0)`):

```js
ctx.vp.style.setProperty("--dot", dotSize(S.span));
```

`render.js` imports `dotSize` from `span.js`. This is the only place that sets
`--dot`, as in the design. So every path that changes `S.span` and calls
`relayout()` gets the right grid:
- `setSpan`;
- C9-T01's `onServerURL` (back, forward, legacy redirect);
- C9-T11's `fitTree`;
- the first paint from a `?span=` link.
List view returns before this line (J:643), so `--dot` keeps its last value
there, as in the design.

### 4.3 Span change while the board is loading

The design draws the toolbar during loading (J:1265–1267 `renderAll` → `renderTools`
before `renderLoading`), so the controls can be clicked while the skeleton shows.
In the design, loading ends on a 600 ms timer (J:1565–1568), so a click then is
harmless: `relayout()` starts with `if (S.loading) return renderLoading();`
(J:639) and only redraws the same skeleton, and `jumpNow` returns early
without a layout (J:1244).

In the product, loading ends only when a snapshot arrives (C9-T01 invariant 1),
and the loading frame has a second form: when the server reports
`data-build-state="unavailable"` before any snapshot, C9-T01's
`showServerState` / C9-T13's `renderBoardUnavailable` replace the spinner with
"Build timeline unavailable · …" while `S.loading` stays `true` (C9-T01 B2,
B2b). A design-faithful `relayout()` from a span click would then run
`renderLoading()` (J:639) and put the spinner and "Loading build timeline…"
back, so the board would claim it is loading when the server said it is
unavailable. So during loading `setSpan` updates `S.span`, the URL, the toolbar
and the announcement, and stops there. The intake path (C9-T01) calls
`relayout()` and `jumpNow(true)` when the snapshot arrives, and that relayout
reads the new `S.span`.

### 4.4 Interfaces

| Export | Shape | Called by |
| --- | --- | --- |
| `setSpan(sp)` | `number → void`; ignores values not in `SPANS` and equal values | `wireSpanTools`; C9-T11 may use it |
| `calNear()` | `→ 1 \| 7 \| 30` | `spanToolsHTML` |
| `calIc(n)` | `"1" \| "7" \| "31" → string` (SVG markup) | `spanToolsHTML` |
| `dotSize(span)` | `number → string` such as `"19.9px"` | `render.js` `relayout()` |
| `spanToolsHTML()` | `→ string`; `""` when `S.view === "list"` | `tools.js` `renderControls()` (C10-T01 4.1), after `#bd-nowbtn`; its output is part of C10-T01's re-render key |
| `wireSpanTools(host)` | `Element → void`; idempotent per host | `tools.js` `renderControls()`, after each write of `#bd-tools` |

`fx.spanToolsHTML` (default `() => ""`) and `fx.wireSpanTools` (default no-op)
are the `fx` entries C10-T01 defined (its 4.3 and step 2). Whichever of the two
tickets merges first adds the defaults to `state.js` (Interface note 2).

### 4.5 Accessibility additions (no pixel change)

The design's controls are native `<button>`s, so they are focusable and work
with Enter and Space. Four gaps stay, and each fix has no visible pixels:

1. **The Range buttons have no accessible state.** Add `aria-pressed="true|false"`,
   the same as the `.on` class (`calNear() === value`). The visual and the
   programmatic state then agree. Add `aria-label` equal to `title` (Day, Week,
   Month), so the name does not depend on the title fallback.
2. **`aria-label` on a plain `div` is ignored by screen readers.** Add
   `role="group"` to `.bd-cal` and `.bd-zoom`, as `build_order_graph.ex:101` does.
3. **Focus is lost on every click.** A span change changes C10-T01's re-render
   key, so `renderTools()` rewrites the children of `#bd-tools`; the button that
   had focus is removed and focus falls to `<body>`. A keyboard user
   could not press − twice. `setSpan` records the focused control (`data-z` or
   `data-span` value) before `renderTools()` and focuses the new button with the
   same attribute afterwards (`focus({ preventScroll: true })`). If that button
   is now disabled (an end was reached), focus moves to the other zoom button.
   The ring is `:focus-visible` (S-12, C12-T05), so a mouse click shows no ring.
4. **The new zoom is not announced.** One persistent
   `<p class="sr-only" id="bd-range-live" aria-live="polite" aria-atomic="true">`
   is created the first time it is needed, as the last child of `ctx.root`. It
   lives outside `#bd-tools`, so `innerHTML` does not replace it. `announce()`
   sets its `textContent` to `"{span} day(s) in view, zoom {pct}%"`. `.bd-zv`
   keeps no live attribute, because its node is replaced each time.

**Reduced motion.** `build.css` keeps the 0.4 s `background-size` transition
under `.bd-root.rm` and under `prefers-reduced-motion` (C:231 and C:348 do not
list `.bd-vp`). In the product the global rule `dashboard.css:6865-6874`
already sets `transition-duration: 0.01ms !important` on every element under
`reduce`, so the dot grid does not animate for those users. `.rm` is set only
from the same media query (J:560 `rmOn()`). This ticket adds no rule
(C12-T05 agrees, its row "C9-T10 decision 4"). P-2 runs without
reduced-motion emulation, so the computed `transition` matches the design.

## 5. Implementation steps

1. Create PROPOSED `src/priv/static/build-home/span.js` as in 4.1, with
   `spanToolsHTML()` built from J:1136–1137. The only differences from the design's
   strings are the attributes in 4.5 (`role`, `aria-pressed`, `aria-label` on
   the Range buttons). Keep the class names, `title` texts, `−` (U+2212) and
   the button order.
2. Add `import "./span.js";` to `hook.js` (C9-T01 rule 2).
3. In `render.js` `relayout()`, add the J:654 line from 4.2 and the `dotSize`
   import.
4. `tools.js` needs no edit: C10-T01's `renderControls()` already calls
   `fx.spanToolsHTML()` and `fx.wireSpanTools($("#bd-tools"))`. If `state.js`
   lacks the two defaults, add `spanToolsHTML: () => ""` and
   `wireSpanTools() {}` to its `fx` object.
5. Write `focusedRangeControl()`, `restoreFocus()` and `announce()` (4.5) in
   `span.js`. The live region uses the product's `.sr-only`
   (`dashboard.css:215`), which the root layout loads on every page
   (`layouts.ex:290`).
6. Add the browser spec and the `test:build-home-span` npm script (section 8)
   to the `"test"` chain in `src/browser/package.json`.
7. Turn on C1-T03's `view.span` product sequence (owner `MP-E8-C9-T10` in its
   `OWNER` table; its anchor is already `.bd-zoom [data-z]`, Interface note 3).
8. Add the C1-T02 region checks in section 8.2 to the design-parity specs.

## 6. Non-happy paths and edge cases

This ticket owns no `EC-nn` from plan §8. These are the cases its own code meets:

| # | Input | Expected behaviour | Test |
| --- | --- | --- | --- |
| N1 | `setSpan(4)`, `setSpan("7")`, `setSpan(NaN)` (bad values from a future caller) | No change: `S.span`, the URL push count and the DOM are unchanged | T8 |
| N2 | Click the Range button that is already `.on`, but the span is not its value (span 10, Week) | The span becomes 7. `.on` alone does not mean a no-op (J:1230 compares values) | T5 |
| N3 | Click Week again at span 7 | No `build:url` push, no relayout | T5 |
| N4 | − at span 30, + at span 1 | The button is `disabled`, so it sends no `click` event (also not for `element.click()`). The clamp (J:1146) and the `SPANS` guard (N1) are a second defence; the guard masks the clamp, so no test can isolate the clamp (kept because it is the design's code) | T4 |
| N5 | Click during loading, before the first snapshot | `S.span`, URL, toolbar and announcement update; no `relayout()`, no `jumpNow`. The skeleton stays; the snapshot's first relayout reads the new span | T9a |
| N5b | Click while the board shows "Build timeline unavailable" (server `unavailable` before any snapshot, `S.loading` still `true`) | The unavailable copy stays; the spinner and "Loading build timeline…" do not come back (4.3) | T9b |
| N6 | A server push changes the span (back or forward) | C9-T01's `onServerURL` re-renders the tools and calls `relayout()`. The Range `.on`, the label and `--dot` follow, with no echo push | T10 |
| N7 | `?view=list&span=7` | No Range or Zoom group. Switching to Timeline shows Week `.on` and `14%`; `--dot` is `14.0px` after that relayout | T7 |
| N8 | Socket down when the span changes | The board changes locally. `writeURL` keeps a pending flag, and `flushURL` sends the state on reconnect (C9-T01). Nothing in this ticket writes to the server | covered by C9-T01 B8 |
| N9 | Stale or offline board (C8-T03, C9-T13) | The controls stay usable: span is a view setting over cached data and writes nothing | T6 (with `offline`) |
| N10 | Rapid clicks (eight − in a row) | Each click is one full relayout and one URL push, as in the design. The span ends at 30. C9-T03's `ensureDays` is single-flight, so paging does not overlap | T4 |
| N11 | Keyboard: Tab to −, press Enter eight times | Focus stays on − after presses 1–7. After the eighth (span 30, − disabled) it is on + | T11 |
| N12 | Phone width (390 px) | The controls render in the wrapped toolbar (C:723, C:1024). Each button is at least 30 × 28 px, above the 24 px minimum of WCAG 2.5.8 | P-1 at 390 px |

**Unknown values.** Every value shown here is computed from `S.span`, and
`S.span` is always one of `SPANS` (the server validates it, C3-T03; `setSpan`
guards it, N1). This ticket shows no unknown, stale or unavailable value. That is
why it needs no unknown-branch mutation test. The guard test T8 is the nearest
equivalent: without the guard, `setSpan(4)` shows `25%`, a label the design
can never produce.

**Security.** No untrusted text reaches this markup. Every string is a constant
or a number from `SPANS`.

## 7. Compatibility and rollout

- **Configuration, migration, packaging:** none. One new static module under the
  `build-home/` directory that C2-T03 registers once.
- **URL compatibility:** `span` keeps the design's key and values. The legacy
  `zoom` key is dropped by C3-T03.
- **Feature gating:** the home page is not reachable from `/` until C12-T01. This
  ticket ships behind that cutover.
- **Rollback:** revert the PR. `fx.spanToolsHTML` falls back to `""`, so the toolbar
  shows no Range or Zoom group and the board stays at span 1 (or at the span from
  the URL, without a dot-grid change).
- **Docs:** no config key, CLI flag or environment variable. The controls are
  part of the new home page, which C12-T07 documents in
  `website/docs-app/guide/`. Hand C12-T07 one sentence: "Day, Week and Month set
  the visible range; − and + step through 1–30 days; the span is kept in the
  link."

## 8. Verification

### 8.1 Behaviour tests

PROPOSED `src/browser/tests/build-home-span.browser.spec.mjs`, npm script
`"test:build-home-span": "npm run fixture:preflight && node scripts/run-browser-tests.mjs tests/build-home-span.browser.spec.mjs"`.

- **Module cases** import `/build-home/span.js` from the fixture server into a
  blank page with stubs for `fx.relayout`, `fx.jumpNow`, `fx.renderTools` and
  `ctx.push`. This is the C9-T04 pattern.
- **Page cases** use the fixture route `/build` with `GET /build-fixture/<dataset>`
  (C3-T01) and count `build:url` pushes the way C9-T01's B10 does.
- Every test fails on any page error.

| ID | Test | Setup → expected | Fails when (mutation) |
| --- | --- | --- | --- |
| T1 | "calNear matches the design table" | module; for each of `SPANS` → `1,1,7,7,7,7,7,30,30` | `Math.log` ratio replaced by linear distance (span 3 gives Day) |
| T2 | "zoom label and title" | page `live`, `?span=N` for each of `SPANS` → `.bd-zv` text and `title` exactly as the section 3 table | `Math.round` → `Math.floor` (span 21 gives `4%`); `day`/`days` plural removed |
| T3 | "dot grid size follows span" | page `live`, `?span=1,2,3,5,30` → `#bd-vp` style `--dot` = `30.0px`, `19.9px`, `14.0px`, `14.0px`, `14.0px`; computed `background-size` = `30px 30px` … | the `max(14, …)` floor removed (span 5 gives `6.6px`); the `render.js` line removed (no `--dot`, computed `22px 22px`) |
| T4 | "zoom steps through SPANS and stops at the ends" | page `live` at span 1: `+` disabled, `−` enabled; click `−` eight times → pushed `span` values `2,3,5,7,10,14,21,30`; then `−` has the `disabled` attribute and `+` has not; `element.click()` on `−` → zero pushes | the `disabled` condition removed (`−` not disabled at 30); the `data-z` signs swapped (the first click pushes nothing) |
| T5 | "range click sets the exact span; a repeat is a no-op" | page `?span=10` → Week has `.on` and `aria-pressed="true"`; click Week → one push with `span=7`; click Week again → zero pushes, `fx.relayout` count unchanged | the `sp === S.span` test removed |
| T6 | "a span change relayouts and jumps to live" | module; `setSpan(7)` with `S.loading = false` → `writeURL`, `renderTools`, `relayout`, `jumpNow(true)` called once each, in that order; repeat on page `offline` → same, and no write event other than `build:url` | any of the four calls removed or reordered |
| T7 | "list view hides the controls and keeps the span" | module: `S.view = "list"` → `spanToolsHTML() === ""`. Page `?view=list&span=7` → no `.bd-cal`, no `.bd-zoom`; click `[data-v="graph"]` → Week `.on`, `14%`, `--dot` `14.0px` | `spanToolsHTML` without the list test (module part fails; the page part alone would pass, because C10-T01's `renderControls` also skips the call in list view) |
| T8 | "only SPANS values are accepted" | module; `setSpan(4)`, `setSpan("7")`, `setSpan(NaN)` → `S.span` still 1; zero pushes; zero relayouts | the `SPANS.includes` guard removed (span 4, label `25%`) |
| T9a | "a span change during loading only updates the toolbar" | module; `S.loading = true`; `setSpan(7)` → `S.span === 7`, `writeURL` and `renderTools` once each, `relayout` and `jumpNow` zero times | the `S.loading` return removed (`relayout` called once) |
| T9b | "a click on an unavailable board keeps the unavailable copy" | page `GET /build-fixture/unavailable` (C3-T01); wait for `.bd-loading` text `Build timeline unavailable · …`; click Week → URL has `span=7`, Week `.on`, the `.bd-loading` text is unchanged, no `.bd-spin`, no `#bd-content` | the `S.loading` return removed (`relayout()` runs `renderLoading()`, J:639, and `.bd-spin` is back) |
| T10 | "a server span follows without echo" | page `live`; server pushes `build:url` `{state:{span:21}}` → Month `.on`, `5%`, `--dot` `14.0px`; zero `build:url` pushes from the hook | the `render.js` `--dot` line removed (stays `30.0px`) |
| T11 | "keyboard focus survives the re-render" | page `live`; focus `−` with Tab, press Enter eight times → `document.activeElement` is `[data-z="1"]` after presses 1–7 and `[data-z="-1"]` after the eighth (span 30) | `restoreFocus` removed (`activeElement` is `body`) |
| T12 | "the change is announced" | page `live`; click `−` → `#bd-range-live` text is `2 days in view, zoom 50%`, and it is the same node before and after a second click | `announce` removed; the region placed inside `#bd-tools` (the node changes) |
| T13 | "range and zoom are labelled groups" | page `live` → `.bd-cal` and `.bd-zoom` have `role="group"`; each Range button has `aria-pressed` equal to its `.on` class at span 1, 3 and 21 | `aria-pressed` hard-coded, or computed from `S.span === value` (span 3: Week is `.on` but would not be pressed) |

**Mutation-check procedure** (AGENTS.md). In a separate worktree, assert
`git status --porcelain` is empty. Apply the mutation in the "Fails when" column,
run `env -C <worktree>/src/browser npm run test:build-home-span -- -g "<test name>"`,
and confirm that test fails. Restore, re-run, confirm it passes. Check that
`git status --porcelain` again shows only the intended revert at each step.
Record one line per test in the PR body, with the exact command.

### 8.2 Pixel parity

The specification is the design. C1-T02's runner proves it with the same data
and the same clock on both sides.

| ID | Check | Cells | Design elements |
| --- | --- | --- | --- |
| P-1 | `expectDesignParity(pair, { name: "range-span-N", region: ".bd-cal" })` and `region: ".bd-zoom"` | `live` × spans 1, 2, 7, 30 (by `?span=N` on both sides; the design reads it at J:310) × 1440 dark gruvbox, 1024 light aiur, 390 dark gruvbox | `.bd-seg`, `.bd-seg.ic`, `.bd-cal` buttons and `CALI` icons, `.on`, `.bd-zoom` buttons, `:disabled` at 1 and 30, `.bd-zv` |
| P-2 | Computed `background-size`, `background-image` and `transition` of `#bd-vp` equal on both sides | `live` × spans 1, 2, 3, 30 × dark and light | `.bd-vp` dot grid (C:1095–1099) and `--dot` (J:654) |
| P-3 | C1-T03 sequence `view.span` passes on the product (not `fixme`) | as C1-T03 defines | each Range button and − / + to both ends; same `span` in the URL, disabled ends, DOM state |
| P-4 | C2-T04 computed-style snapshot stays green for `.bd-cal`, `.bd-zoom`, `.bd-zv` | C2-T04 matrix | C:117–120, 151, 155, 418–423, 632–637, 715–716, 931–932 |

- The `role`, `aria-pressed` and `aria-label` attributes and the `.sr-only` node
  have no pixels, so P-1 and P-2 need no allowlist entry for them. If C1-T02's
  DOM-state comparison or C2-T04's census counts product-only nodes or
  attributes, add one `pending-sign-off` entry with `ref` = this ticket's
  Decision 3, and do not hide the node any other way.
- A focus ring screenshot is not part of this ticket. The ring is S-12, C12-T05.

### 8.3 Commands

```sh
env -C <repo>/src/browser npm run fixture:preflight
env -C <repo>/src/browser npm run test:build-home-span
env -C <repo>/src/browser npm run test:design-parity      # C1-T02; P-1, P-2 green
env -C <repo>/src/browser npm run test:build-home-motion  # C1-T03; view.span not fixme
env -C <repo>/src/browser npm run test:home-css           # C2-T04; P-4 green
```

Manual check: open `/build?span=7` in the fixture server and in the design
copy side by side at 1440 px, press − until it disables, then + until it
disables, and compare each step. This is a visual check, not the AGENTS.md
"manual testing" of agent chat. No agent path is involved.

## 9. Completion and handoff

**Acceptance checklist.**

- [ ] `span.js` exports `setSpan`, `calNear`, `calIc`, `dotSize`,
      `spanToolsHTML`, `wireSpanTools`, and registers `fx.spanToolsHTML` and
      `fx.wireSpanTools` (C10-T01's names). `wireSpanTools` adds one delegated
      listener per host through `ctx.life`, however often it is called.
- [ ] The Range and Zoom markup matches J:1136–1137 in classes, order, `title`
      texts, `−` (U+2212), icons and disabled ends. The only additions are the
      4.5 attributes.
- [ ] `relayout()` sets `--dot` from `dotSize(S.span)`; list view does not.
- [ ] A span change calls `writeURL`, `renderTools`, `relayout`, `jumpNow(true)`
      in the design's order. During loading it stops after the toolbar, and an
      unavailable board keeps its copy.
- [ ] Values outside `SPANS` and repeat values are ignored.
- [ ] Focus survives each click; the change is announced in a persistent live
      region; both groups have `role="group"`; Range buttons have `aria-pressed`
      that matches `.on`.
- [ ] T1–T8, T9a, T9b, T10–T13 pass, and each one fails with its mutation (one line per test in
      the PR body, with the command).
- [ ] P-1, P-2 and P-4 pass with no new allowlist entry, or with one
      `pending-sign-off` entry as described in 8.2.
- [ ] C1-T03 `view.span` runs on the product and passes.

**Dependent tickets.** C9-T11 (`fitTree` uses `SPANS` and the `--dot` line),
C12-T05 (Decision 4: no new reduced-motion rule, C12-T05 agrees), C12-T07 (one docs sentence),
C12-T08 (sign-off screenshots include P-1).

**Remaining blocker.** DESIGN-E8 only.

## Decisions made without the owner

1. **The `SPANS` guard in `setSpan`.** The design trusts its callers. With
   several modules and a server push path, a bad value would show a label the
   design never shows (`25%`). The guard costs one line and changes no valid
   behaviour.
2. **No relayout during loading** (4.3). In the design a relayout during loading
   only redraws the skeleton (J:639), and loading ends on a 600 ms timer. In the
   product the loading frame can show the server's "unavailable" copy, and a
   relayout would replace it with the spinner, so the board would say "loading"
   when the server said "unavailable" (S-9 rule: unavailable is never shown as
   something else). Stopping after the toolbar keeps the copy and costs one
   line.
3. **Four accessibility additions without pixels** (4.5: `role="group"`,
   `aria-pressed` and `aria-label`, focus restore, a polite live region). This
   follows plan §10 item 7 (screen-reader-only labels) and the product's own
   zoom control (`build_order_graph.ex:101-109`). The design is not changed
   visually. Kevin reviews them in the C12-T08 sign-off.
4. **No reduced-motion rule for the dot grid.** `build.css` does not turn the
   transition off (C:231, C:348, C:1095), and this ticket copies it unchanged.
   Users with `prefers-reduced-motion: reduce` still get no animation, because
   the product's global rule (`dashboard.css:6865-6874`) shortens every
   transition to 0.01 ms. C12-T05 records the same conclusion (its row
   "C9-T10 decision 4"). Sign-off item S-18.
5. **`aria-pressed` follows `.on` (the nearest range), not the exact span.** At
   span 10 the design shows Week as selected. The programmatic state matches
   what a sighted user sees. The exact value is in the live announcement and the
   `.bd-zv` title.
6. **No zoom keyboard shortcuts and no debounce on rapid clicks.** The design has
   neither. The buttons are keyboard-operable as native buttons.
7. **No automatic wider span for large repositories.** The design's `setDemo`
   sets span 3 for the mock `dense` dataset (J:1258). That is mock code, and it
   does not run on a first load with `?example=dense` either (J:1551–1567).
   Every repository opens at span 1 unless the link says otherwise.
8. **Two predecessors added to the README row** (C9-T03, C10-T01). See Interface
   notes 1 and 2. Neither is on the critical path: C10-T01 needs only C9-T01, and
   C9-T03 precedes C9-T05 already. C10-T01 says C9-T10 "may merge before or
   after" it; that holds for the `fx` contract, but this ticket's page tests and
   `sv` import need `tools.js` (C10-T01) and `icons.js` (C9-T01), so it waits.
9. **Delegated click listener instead of the design's per-button listeners.**
   C10-T01 asks for it (its 4.3 note), and C9-T01 rule 4 requires `ctx.life`.
   The behaviour is the same: disabled buttons send no click either way.

## Interface notes (for the neighbour tickets)

1. **README row vs C9-T03.** The row lists only C9-T02. `setSpan` calls
   `relayout()`, and the `--dot` line goes in `relayout()`. Both are in C9-T03's
   `render.js`. C9-T03 also owns J:642 (`ensureDays`) and already lists C9-T10
   among the tickets that wait for it. This ticket does not touch J:642, so J:642
   stays with one owner. C9-T03 also names "C9-T10 span change" as a caller of
   `takeAnchor()`/`restoreAnchor()`. This ticket does not call them: the design
   jumps to the live band after a span change (J:1231), so no scroll anchor is
   kept. Settled 2026-10-08: C9-T03 is in `blocked_by`, and C9-T03 drops C9-T10
   from its `takeAnchor` caller list.
2. **README row vs C10-T01.** C10-T01's row says it ports `renderTools`
   (J:1128–1150), "the right tools" included. That fragment contains this
   ticket's markup (J:1136–1137) and listeners (J:1146–1147). C10-T01 already
   resolved this (its 4.3 and note 5): it calls `fx.spanToolsHTML()` after
   `#bd-nowbtn` and `fx.wireSpanTools($("#bd-tools"))` after each write, and it
   asks for delegation. This ticket uses those names. Settled 2026-10-08: per
   R-G2, whichever of C10-T01 and this ticket merges first adds the two no-op
   defaults (`spanToolsHTML: () => ""`, `wireSpanTools() {}`) to C9-T01's `fx`.
3. **C1-T03 `view.span` selector.** Resolved in C1-T03: its `OWNER` entry
   uses anchor `.bd-zoom [data-z]`, the sequence is `.bd-cal [data-span]` then
   `.bd-zoom [data-z]`, and a selector that matches nothing (the CSS-only
   `.bd-zb`) is reported `unreachable`, not passed. No request.
4. **C9-T01 `onServerURL`.** It already calls `fx.jumpNow(true)` when `span`
   changes and re-renders the chrome. This ticket relies on that path for N6, and
   on `relayout()` for `--dot`. No change is needed. If `renderChrome()` does not
   call `fx.renderTools()`, the Range `.on` state would be stale after back or
   forward (T10 catches it).
5. **C2-T04 dead rules.** Settled 2026-10-08: `.bd-zb` and `#bd-fit` are on
   C2-T04's dead-rule list; this ticket depends on neither.
6. **README row scope.** The row lists `SPANS` and "J:1222–1248". `SPANS` is
   exported by `state.js` (C9-T01 module table) and J:1233–1248 is `scrollVP` /
   `jumpNow` (C9-T08, `band.js`). This ticket imports the first and calls the
   second through `fx`. Nothing is dropped; the row could say "J:1222–1232".

## Sources

- Design: J:32, 302–328, 358, 382–383, 642–654, 1128–1148, 1222–1248, 1251–1269,
  1549–1576; C:29, 117–120, 148–158, 231, 348, 415–425, 626–644, 706–723,
  925–934, 1092–1099; H:1910 (`#build-root`), H:5132 (`build.js`).
- Product at `58854d4c8`: `src/priv/static/build-order-grid-hook.js:40-131,
  185-195`; `src/lib/aiur_web/components/operator_control_center/build_order_graph.ex:98-109`;
  `src/priv/static/dashboard.css:215-225, 6865-6874`;
  `src/lib/aiur_web/components/layouts.ex:290`; `src/priv/static/time-brush-hook.js:94`;
  `src/browser/package.json:1-30`.
- Pack: [README row](README.md) (C9-T10), [chunks.md](../chunks.md) C9,
  [plan.md](../plan.md) §5, §8, §10;
  [MP-E8-C9-T01.md](MP-E8-C9-T01.md) (module table, `fx`, `url.js`),
  [MP-E8-C9-T03.md](MP-E8-C9-T03.md) (`ensureDays`, J:642),
  [MP-E8-C10-T01.md](MP-E8-C10-T01.md) (4.1 `renderControls`, 4.3 `fx.spanToolsHTML` / `fx.wireSpanTools`),
  [MP-E8-C12-T05.md](MP-E8-C12-T05.md) (row "C9-T10 decision 4"),
  [MP-E8-C3-T01.md](MP-E8-C3-T01.md) (`unavailable` and `hold` fixture names),
  [MP-E8-C3-T03.md](MP-E8-C3-T03.md) (`span` validation),
  [MP-E8-C1-T02.md](MP-E8-C1-T02.md) (region parity, allowlist),
  [MP-E8-C1-T03.md](MP-E8-C1-T03.md) (`view.span`, `OWNER`),
  [MP-E8-C2-T04.md](MP-E8-C2-T04.md) (§4.4 dead rules),
  [decisions.md](../decisions.md) E8-D13 (zoom changes the columns).

## Review log

Adversarial review, 2026-10-08, against the design source, the product at
`58854d4c8` and the neighbour tickets.

1. **Interface names aligned with C10-T01.** `rangeHTML` / `bindRange` renamed to
   C10-T01's `fx.spanToolsHTML` / `fx.wireSpanTools` (C10-T01 4.3 already calls
   them). Step 4 is now "no `tools.js` edit"; Interface note 2 rewritten.
2. **Listener model changed to one delegated `ctx.life` listener per host**, with
   a `WeakSet` reset by `onReset`, as C10-T01 4.3 and C9-T01 rules 3–4 require.
   The old text said rule 4 did not apply. Decision 9 added.
3. **`sv` imported from C10-T01's `icons.js`** instead of a second copy of J:32.
4. **Loading guard rationale corrected (4.3, Decision 2).** J:639 makes
   `relayout()` redraw the skeleton during loading; it never calls `viewport()`.
   The real reason for the guard is the server-unavailable loading frame. T9
   (whose mutation could not fail, and which used a `?delay=` fixture option
   that C3-T01 does not have) split into T9a (module) and T9b (`unavailable`
   fixture); N5b added.
5. **CSS value corrected:** `.bd-cal button svg` (C:931) loses on specificity to
   `.bd-seg.ic button svg`; the computed icon is 15 px, not 16 px.
6. **Reduced motion corrected (4.5, Decision 4).** `dashboard.css:6865-6874`
   already removes the transition under `reduce`; no C12-T05 follow-up is needed
   (C12-T05 agrees). Cited `layouts.ex:290` for `dashboard.css` being loaded.
7. **T4 mutation fixed.** "Clamp removed" cannot fail a test, because the
   `SPANS` guard masks it and a disabled button sends no click; N4 now says so.
8. **T7 mutation fixed.** C10-T01 also skips the call in list view, so the page
   part alone could not fail; a module assertion was added.
9. **N11 / T11 made consistent** (eight presses reach span 30, not three).
10. **Stale interface notes updated:** C1-T03 already uses `.bd-zoom [data-z]`
    (note 3, step 7); C9-T03 already lists C9-T10 as waiting (note 1); C9-T03's
    `takeAnchor` caller listing for C9-T10 flagged (note 1); README scope
    (`SPANS`, J:1233–1248) reconciled in non-goals and new note 6.
- Reconciliation 2026-10-08 (coordinator): stylesheet path `build-home/home.css`, `icons.js` owner is C9-T01 (R-G9), `pending-sign-off` spelling, S-18 for dot-grid reduced motion, `.bd-zb`/`#bd-fit` on C2-T04 dead-rule list, settled interface notes 1, 2 and 5 (C9-T03 anchor caller, `fx` defaults per R-G2, dead rules).
