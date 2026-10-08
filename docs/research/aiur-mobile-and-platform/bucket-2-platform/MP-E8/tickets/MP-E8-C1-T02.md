---
ticket_id: MP-E8-C1-T02
feature_id: MP-E8
chunk_id: MP-E8-C1
bucket: 2-platform
title: Side-by-side screenshot parity runner
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C1-T01]
complexity: 4
design_gate: DESIGN-E8
owns_edge_cases: [EC-20, EC-28]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C1-T02 — Side-by-side screenshot parity runner

> **Plan refresh.** This ticket cites code at `58854d4c8`. If the browser
> harness (`src/browser/`) has moved when work starts, re-resolve the paths
> below before you write code.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history), chunk C1 (parity harness
  and design fixtures).
- **User value.** "Pixel-perfect" becomes a check that a machine runs, not an
  argument in review (plan §9 K-1). Every visual MP-E8 ticket proves itself by
  rendering the design and the product with the same data, clock, time zone,
  fonts, viewport, theme and palette, and by diffing the two.
- **Deliverable.**
  1. A Playwright support module that opens a **parity pair**: the unmodified
     design HTML (served from disk through request interception) and the product
     fixture route, in two browser contexts with identical settings.
  2. `expectDesignParity(pair, { name, region?, fullPage? })`: a whole-viewport
     or one-element pixel comparison that uses Playwright's own screenshot
     comparator.
  3. A checked-in, validated **allowlist** of approved differences. Each entry
     cites Kevin's written approval, or is marked `pending-sign-off` and listed
     in every run's output.
  4. An enforced harness spec: calibration (design against design), mutation
     proofs and guards. It runs in `npm test`.
  5. A matrix spec for the whole page (5 datasets × 3 viewports × 2 themes ×
     2 palettes = 60 cells). It runs in report mode (`npm run parity:matrix`)
     until C12-T01 makes it a gate.
- **Non-goals.**
  - Motion, frame sequences and interaction scripts: C1-T03.
  - Computed-style snapshots: C2-T04 (it uses this ticket's allowlist).
  - The product route `/build` and the dataset switch `/build-fixture/:dataset`:
    C3-T01. This ticket only calls them.
  - The fixture JSON, `manifest.json` and the design-source copy: C1-T01.
  - No checked-in baseline PNGs. Both sides render live in the same browser in
    every run.
  - The read-only variant. The design has no read-only state on the home page
    (`setReadonly`, H:5023, is never called at load). Read-only states belong
    to C11 and C12-T05.

## Dependencies and blockers

- **Blocked by DESIGN-E8** (Kevin's go).
- **Predecessor: MP-E8-C1-T01.** This ticket reads two things from it:
  - the in-tree copy of the design source (C1-T01: PROPOSED
    `src/test/fixtures/build_home/design-source/`);
  - C1-T01's PROPOSED `src/test/fixtures/build_home/manifest.json`: `now`
    (`1791408000000`), `tz` (`America/Los_Angeles`) and `design_sha256` for
    `assets/build.js`, `assets/build.css` and `Aiur Dashboard.html`. The five
    dataset names are fixed (`live`, `dense`, `newrepo`, `noqueue`, `offline`).
    Ticket ids: C1-T01 exports the design's ids raw; the C3-T02 fixture
    mapper writes an `ids` map {design id -> payload id} into the manifest,
    and this harness reads it for the product side.
- **Product side.** C3-T01 (not a predecessor) defines the product interface:
  `GET /build-fixture/:dataset` selects the dataset for the whole fixture server
  (200, or 404 for an unknown name), and the page is `/build`. There is no
  `?example=` on the product (C3-T03 drops it). This ticket calls exactly that,
  through one helper, `productUrl(dataset)`. Before C3-T01 merges, every
  product cell **fails** with "product target unavailable" and is never skipped
  or green. The enforced spec uses no passing product cell, so `npm test` stays
  green. See "Interface notes" below.
- **May run at the same time as** C2-T03, C3-T01, C4-*, C5-*. It touches only
  `src/browser/` (`visual.mjs` gets one optional argument).
- **Consumers.** C1-T03, C2-T01, C2-T03 (optional floor), C2-T04, C3-T01 (B4,
  `phase: 'loading'`), every C9/C10/C11 visual ticket, C12-T01 (gate),
  C12-T04 (phone), C12-T08 (sign-off package).

## Verified starting point (`58854d4c8`)

Existing harness, all read in full or in the lines cited:

- `src/browser/playwright.config.mjs:3-7` requires `AIUR_BROWSER_PORT`;
  `:9` artifact root from `AIUR_BROWSER_ARTIFACT_DIR`; `:13` `outputDir` is that
  root; `:14`, `:18` `fullyParallel: false`, `workers: 1` (so C3-T01's
  server-global dataset switch is safe); `:17` `updateSnapshots: 'none'`;
  `:20-28` default `toHaveScreenshot` options `animations: 'disabled'`,
  `caret: 'hide'`, `maxDiffPixelRatio: 0.002`, `threshold: 0.2`; `:29`
  `snapshotPathTemplate`; `:35-43` `webServer` runs `npm run fixture:server`.
  There is no `reporter` key, so no HTML report is written today.
- `src/browser/scripts/run-browser-tests.mjs:45-78` `runBrowserTests(args)`
  allocates a port and an artifact root, passes extra args to
  `npx playwright test`, and sanitizes evidence (`:72`). `:74-76` deletes the
  artifact root after a green run unless `AIUR_BROWSER_SCREENSHOTS=1` or
  `AIUR_BROWSER_KEEP_ARTIFACTS=1`. `:13` `allocatePort`.
- `src/browser/scripts/artifact-sanitizer.mjs:7-8` keeps only `.json`, `.log`,
  `.md`, `.txt` (redacted) and `.png`, `.zip`; `:111-130`
  `sanitizeArtifactRoot` **deletes every other file**. A Playwright HTML report
  (`index.html` and its assets) would not survive; PNGs do.
- `src/test/browser/fixture_server.exs:1571-1599` `FixtureStreamdeckControl`:
  the per-server control endpoint pattern (200 text, 404 for an unknown mode)
  that C3-T01's `/build-fixture/:dataset` copies; `:2289-2291` unmatched paths
  are forwarded to `AiurWeb.Router`.
- `src/browser/scripts/start-fixture.mjs:10` runs
  `mix run --no-start test/browser/fixture_server.exs`.
- `src/browser/support/visual.mjs:28-52` `openVisualRoute(page, { theme, route,
  collapsed, mode })` signs in through `openFixture`, seeds `aiur-theme` and
  `aiur-nav-collapsed`, adds the early theme shim, navigates, and waits for the
  socket, `data-theme`, `data-nav-collapsed` and `document.fonts.ready`.
  `:78-83` `dockerConfig` writes a derived config that imports the base
  config and overrides fields. This ticket uses the same pattern.
- `src/browser/tests/visual-shell.browser.spec.mjs:7-11` the viewport set
  1440×900, 1024×768, 390×844; `:19-20` phone cells use `deviceScaleFactor: 3`,
  `isMobile`, `hasTouch`; `:89-110` **the mutation-proof pattern**: inject
  `+2px` padding, expect `toHaveScreenshot` to fail, and accept only a matcher
  error whose message matches `/pixels.*different/`.
- `src/browser/tests/support/browser-helpers.mjs:12` `openFixture(page, mode)`
  (`read_only` | `writable`); `:102` `settleAnimations`.
- `src/browser/tests/support/layout-worker.mjs:8` `dashboardCredentials`.
- `src/browser/package.json:10` the `npm test` chain; `:25` `test:parity` is
  already taken (DASH-033 `parity-composition`), so this ticket uses
  `test:design-parity`; `:38` `@playwright/test` `1.61.1`.
- The installed Playwright 1.61.1 types confirm the following
  (`node_modules/playwright/types/test.d.ts`, `playwright-core/types/types.d.ts`):
  - `testInfo.snapshotPath(name, { kind: 'screenshot' })`;
  - the `{snapshotDir}`, `{testFilePath}` and `{arg}` template tokens;
  - `page.clock.setFixedTime`;
  - `toHaveScreenshot`'s `scale` defaults to `"css"`, but `page.screenshot`'s
    defaults to `"device"`, so both sides must pass `scale` explicitly.
- `website/tests/support/visual.ts:8-12` the font families table (Bungee
  `400`, Space Grotesk `300 700`, JetBrains Mono `100 800`); `:14-29`
  `routeFonts` answers every `fonts.googleapis.com` request with one
  `@font-face` sheet (`font-display: block`) and serves `fonts.gstatic.com`
  from local files, throwing on an unexpected file. It is TypeScript in the
  `website/` package, so `src/browser/` (plain `.mjs`, its own package) copies it rather than
  importing across packages. The files are in `website/tests/fixtures/fonts/`
  (`Bungee-Regular.woff2`, `SpaceGrotesk-Variable.woff2`,
  `JetBrainsMono-Variable.woff2`, OFL licenses, `SOURCES.md` with sha256 values
  from google/fonts `a54f7446`).
- `src/priv/static/bungee.woff2` exists, and its bytes differ from the
  google/fonts copy above. `src/lib/aiur_web/static_assets.ex:28` lists
  `bungee.woff2` as long-lived. The product does not self-host Space Grotesk or
  JetBrains Mono today (C2-T01 adds them).
- `.github/workflows/ci.yml:645-654` the browser job runs `npm test`, then
  `npm run test:visual` twice.

Design source (`design-source/`, etag 1791431544512943):

- H:7-10 loads Google Fonts (Bungee, Space Grotesk 400–700, JetBrains Mono
  400–700) and `https://cdn.jsdelivr.net/npm/d3@7/dist/d3.min.js`. The home page
  never calls d3: `analytics.js` uses it only in `render()` on the analytics
  tab.
- H:1820 sets `data-palette` from `localStorage["aiur-palette"]`, default
  `gruvbox`. H:5078 toggles between `gruvbox` and `aiur`.
- H:5017-5021 `initTheme` reads `localStorage["aiur-theme"]`, else
  `prefers-color-scheme`. H:5083 reads `aiur-nav-collapsed` and treats `"1"`
  as collapsed.
- H:2731 `activeTab = "build"` is the default, and `init` calls
  `switchTab(activeTab)` (H:5113). H:3966-3982 `switchTab`, which calls
  `AiurBuild.render()` for `build` (H:3978). H:5075 `window.AiurHost.switchTab`.
  H:1910 `#build-root.bd-root` is in `.panel[data-panel="build"]`. H:2058-2064
  `#tk-backdrop` / `#tk-modal`.
- H:5036-5041 `tickClock` renders `new Date()` every second (H:5118).
- J:11 `NOW = new Date(2026, 9, 7, 14, 20)`, in local time.
- J:304-315 `readURL`: `example` (J:314) and the view parameters. `ticket` is
  read separately, after boot (J:1569).
- J:1251 the loading markup: `.bd-skel`, `.bd-loading`.
- J:1559-1574 `AiurBuild.render` runs a **600 ms** boot timer (J:1565). It
  then calls `viewport()` (J:604-606, which writes `#bd-content`),
  `jumpNow(true)`, and opens `?ticket=` on the next animation frame
  (J:1568-1570).
- J:882-885 the edge redraw loop runs on `performance.now()`, which the fixed
  clock does not freeze. `Math.random` is used only by the modal's mock
  conversation: J:1461 (`appendItem`), J:1497 (reply after a send) and
  J:1509-1525 `startLive`. `startLive` returns early unless the ticket is in
  `now`, its agent is `active` and the dataset is not `offline` (J:1511); else
  it appends mock items and raises `pct` on `setTimeout` steps that start
  1400 ms after the modal opens. `page.clock.setFixedTime` keeps timers
  running, so this stream is not frozen. No home-page load path without
  `?ticket=` calls `Math.random`.
- J:1142 / C:642 `.bd-exl`, the "Demo data" select. It is mock-only and is
  dropped in the product (plan §10 item 5). It has `margin-left: auto` and is
  the last item of `#bd-status`.
- C:219, 288-296, 318, 323, 382, 396-400, 548, 562, 719 infinite animations
  (`bdPulse`, `bdRot` on `@property --bd-a` C:226, `bdStuck`, `bdAg`, `khSpin`,
  `cvDot`, `cvRec`). C:1126-1139 the static `feTurbulence` grain on `.bd-now`,
  `.ax-uc` and `.bd-lanes`. Reduced motion: J:540 `rmOn()` and J:560 set
  `.bd-root.rm`, and C:297 then gives `.ag-active .bd-glow` a **static**
  ring (`background: none`, a box-shadow) instead of the conic glow; C:348,
  610 are the media-query rules. Breakpoints:
  C:40/928/1008 960 px, C:941/1024 1180 px, C:604/644/723 720 px.

## Chosen design

**Two live renders, one comparator.** For each case the runner screenshots
the design, writes the PNG to the path that `toHaveScreenshot` reads as its
baseline (`testInfo.snapshotPath(name, { kind: 'screenshot' })`, under a
per-run `snapshotDir` in the artifact root), and then calls
`expect(productPage or locator).toHaveScreenshot(name, opts)`. This reuses
Playwright's comparator, its retry-until-stable behaviour, and its
`-expected.png` / `-actual.png` / `-diff.png` failure artifacts (PNGs survive
the sanitizer). It needs no new dependency and
no checked-in baselines, so it does not depend on the platform (the reason for
`visual.mjs --docker` does not apply).

**Parity pair.** `openParityPair(browser, cell, { dataset, ticket?, query?, phase?,
productRoute? })` creates two contexts with identical options. `query` (a
search string) is applied on both sides. `phase` is
`'board'` (default: the drawn timeline), `'loading'` (the 600 ms skeleton, for
C3-T01) or `'shell'` (no build-root wait, for C2-T01's token and body checks on
a shell route). `productRoute` defaults to `/build`. `openDesign` and
`openProduct` are exported on their own for consumers that compare DOM or
computed style rather than pixels (C1-T03, C2-T04).

```js
{ viewport, deviceScaleFactor, isMobile, hasTouch,     // from the cell
  timezoneId: 'America/Los_Angeles', locale: 'en-US',
  colorScheme: theme, reducedMotion: cell.reducedMotion ?? 'no-preference' }
```

On each page, before the first navigation:

- `page.clock.setFixedTime(FIXTURE.now)`. This is
  `2026-10-07T14:20:00-07:00` (`1791408000000`), read from C1-T01's
  `manifest.json` and equal to J:11. Timers keep running, so the 600 ms boot
  timer fires. For `phase: 'loading'` the design side instead calls
  `page.clock.install({ time: FIXTURE.now })` and never advances it, so
  `S.loading` stays true (J:1565; C3-T01's "Pixel parity" asks for exactly
  this). The product side keeps `setFixedTime` and uses C3-T01's `hold`
  dataset.
- An init script that replaces `Math.random` with a seeded mulberry32 (seed 1).
  The design's own `analytics.js` already uses mulberry32 (lines 24-31). No
  home-page path without `?ticket=` calls `Math.random` today, so this is a
  guard for a future re-import, not coverage (see Verification).
- A network guard. See "Non-happy paths".
- A `pageerror` listener that fails the test (N14).

- **Design side.** Origin `http://design.parity.invalid`. The `.invalid` TLD
  never resolves (RFC 2606), so a missed interception fails instead of reaching
  the network. Interception rules:
  - files are served from C1-T01's design-source copy, after path
    normalisation;
  - Google Fonts CSS and font files are served from
    `website/tests/fixtures/fonts/`, with a copy of the `routeFonts` table and
    handlers (`visual.ts:8-29`) in `design-parity.mjs` and a comment that names
    the source;
  - the d3 URL gets an empty JavaScript body;
  - every other request is aborted and recorded.

  The runner seeds `aiur-theme`, `aiur-palette` and `aiur-nav-collapsed=0` on
  a blank page of the same origin, then opens
  `/Aiur%20Dashboard.html?example=<dataset>[&ticket=<id>][&<query>]`. It asserts that
  `.panel[data-panel="build"]` is `.is-active` (the design's own `init` calls
  `switchTab("build")`, H:5113), and calls `AiurHost.switchTab('build')` only
  if it is not.
  - `ticket` is refused with "ticket <id> runs the design's mock live stream"
    when the design would start `startLive` for it (sec `now`, agent
    `active`, dataset not `offline`; J:1511). That stream changes the modal on
    real timers, so no fixed-time capture of it is stable. A consumer that
    needs such a modal (C11) drives the clock itself, as C1-T03 does.
- **Product side.** `productUrl(dataset)` (exported) wraps C3-T01's
  fixture-only `GET /build-fixture/:dataset` and then opens `/build`. Inside it,
  `selectProductDataset(page, dataset)` calls
  `context.setHTTPCredentials(dashboardCredentials)` and then
  `page.request.get('/build-fixture/<dataset>')` (C3-T01). A status other than
  200 fails N7. Then `openVisualRoute(page, { theme, palette, route:
  productRoute + ('?ticket=<id>' and/or `query`), mode: 'writable' })`.
  Writable matches the design default. `aiur-palette` is seeded in the same
  step as `aiur-theme`, which needs a small addition to `openVisualRoute`: an
  optional `palette`. A `ticket` id is translated through the manifest `ids`
  map (identity until C3-T02 writes it).
- **Ready (the same rule on both sides).** All of these are true:
  - `document.fonts.ready` has resolved;
  - for each of Bungee, Space Grotesk and JetBrains Mono, `document.fonts`
    holds a `FontFace` of that family whose `status` is `'loaded'`. Do not use
    `document.fonts.check()` alone: it returns `true` when **no** face of that
    family is declared, so a missing stylesheet would pass;
  - `phase: 'board'`: `#bd-content` exists and `.bd-loading` does not; on the
    product side also `#build-root[data-bd-mounted]` (set by C9-T01) and
    `#build-root[data-bd-paging="idle"]` (C9-T03).
    `phase: 'loading'`: `.bd-loading` exists. `phase: 'shell'`: no
    build-root condition;
  - two animation frames have passed.

  Each wait has a 10 s budget and fails with its own message (N5, N15), never a
  bare timeout. The product reuses the design DOM, so the same rule applies,
  and C9 must keep these selectors. DOM-class comparisons (C1-T03, C2-T04)
  ignore `phx-*` classes and `data-phx-*` attributes.
- **Pre-capture checks (both sides).** The page passes these checks before
  the runner captures it:
  - `html[data-theme] === theme` and `html[data-palette] === palette`;
  - `Intl.DateTimeFormat().resolvedOptions().timeZone === 'America/Los_Angeles'`;
  - `Date.now() === FIXTURE.nowMs`.

  A failed check stops the cell with its own message, before any pixel
  compare.
- **Design capture.** Take `page.screenshot` (or `locator.screenshot`) with
  `{ animations: 'disabled', caret: 'hide', scale: 'device', mask, maskColor }`.
  Repeat until two captures in a row are byte-equal (at most 10 tries, 100 ms
  apart). If it does not settle, fail with "design did not settle". This covers
  the `performance.now()` edge loop (J:882-885).
- **Product compare.** Call `toHaveScreenshot` with the same `animations`,
  `caret`, `scale` and `maskColor`, a `mask` built from the **product** page's
  locators, and `{ threshold: 0, maxDiffPixels: PARITY_FLOOR }`. No ratio is
  used, because a ratio grows with the page. The base config's
  `maxDiffPixelRatio: 0.002` would otherwise be merged in, and Playwright
  takes the **minimum** of the two limits (`playwright-core/lib/coreBundle.js:7265-7271`),
  which on a small region rounds the floor down to 0. So the parity config
  replaces `expect.toHaveScreenshot` with
  `{ animations: 'disabled', caret: 'hide', threshold: 0 }` (no ratio key).
- **Region mode.** `region: '.bd-now'` asserts exactly one match on each side
  and fails with "region missing on product" or "on design" otherwise. It
  then compares the two locator screenshots. A size difference fails, because
  Playwright's comparator rejects images of different sizes.
- **Floor.** `PARITY_FLOOR` starts at 0. The implementer runs the calibration
  spec three times. If any run shows a non-zero design-against-design count,
  first find the source of nondeterminism and fix it. Only an anti-aliasing
  difference that cannot be removed may raise the floor, to the measured
  maximum per cell. Record it in `design-parity.mjs` with the date, the
  Chromium version and the three counts. The floor must stay low enough that
  the 1 px mutation still fails (see the test table).

**Matrix** (`PARITY_MATRIX`):

- viewports `1440×900@1`, `1024×768@1` and `390×844@3` (mobile, touch), the
  visual-shell set;
- themes `dark` and `light`;
- palettes `gruvbox` (the design default) and `aiur`;
- datasets `live`, `dense`, `newrepo`, `noqueue` and `offline`.

This gives 60 cells. Reduced motion is one extra cell (1440, dark, gruvbox,
live, `reduce`), because `.bd-root.rm` changes static output (C:297, set by
J:560). The 1024 px width is inside the 961–1180 px breakpoint band.
The 390 px width is below 720 px. Navigation is expanded. Collapsed navigation
is C2-T02's region test.

**Allowlist** (`src/browser/support/design-parity-allowlist.json`, PROPOSED):

```json
[{ "id": "demo-data-select",
   "kind": "design-removal",            // or "pixel-mask" | "design-style" | "property" | "motion" | "axe" | "copy"
   "selector": ".bd-exl",
   "css": null,                         // required only for kind "design-style"
   "property": null,                    // required only for kind "property" (C2-T04)
   "rule": null,                        // required only for kind "axe" (C12-T05)
   "cells": {},                         // optional filter: viewport/theme/palette/dataset
   "reason": "Mock-only Demo data select; the product drops it",
   "approval": { "status": "pending-sign-off",  // or "approved"
                 "by": null, "date": null,
                 "ref": "docs/.../MP-E8/plan.md#10-decisions-made-without-the-owner item 5" } }]
```

The comments are explanatory only; the checked-in file is plain JSON.

The loader (`loadAllowlist()`) validates every entry:

- `id` is unique;
- `kind` is one of the seven kinds (`design-removal`, `pixel-mask`,
  `design-style`, `property`, `motion` for C1-T03, `axe` for C12-T05, `copy`
  for C9-T03 and C9-T11);
- `selector` is non-empty;
- `css` is a non-empty string if and only if the kind is `design-style`;
- `property` is set if and only if the kind is `property`;
- `rule` (an axe rule id) is set if and only if the kind is `axe`;
- `path` (a C1-T03 record path, `*` the only wildcard) is set if and only if
  the kind is `motion`;
- there is no `approved: false` field: the status says it;
- for `approved`: `by` is `"Kevin"`, `date` is an ISO date, and `ref` is
  non-empty;
- for `pending-sign-off`: `ref` is non-empty;
- any other `status` value is rejected.

An invalid entry stops the whole run. In each cell that it covers:

- a `design-removal` entry removes its node on the design side, before
  capture;
- a `pixel-mask` entry masks its node on both sides, with the same
  `maskColor`;
- a `design-style` entry injects its `css` into the design page before
  capture (for example C2-T01's six AA colour holds,
  `:root[data-theme=…][data-palette=…] { --faint: <held hex> }`). A token
  hold changes every element that uses the token, so no selector mask can
  express it. `selector` names the element the stale check looks for
  (`html` for a token);
- a `property` entry is only read by C2-T04; a `motion` entry by C1-T03; an
  `axe` entry by C12-T05; a `copy` entry by C9-T03 and C9-T11.

An entry whose selector matches no element in a cell it covers fails that
cell as **stale**, because a dead mask hides nothing and would only seem to
work. Every run adds the `pending-sign-off` entries to the test annotations
and prints them. A `pending-sign-off` entry passes in CI and fails only in
the C12-T08 `--gate` run.

## Implementation steps

1. **`src/browser/support/design-parity.mjs`** (PROPOSED, about 200 lines):
   - constants: `DESIGN_ROOT` (C1-T01's path), `FIXTURE_META` (C1-T01's
     `manifest.json`), `PARITY_MATRIX`, `PARITY_FLOOR`;
   - `productUrl(dataset)` and `selectProductDataset(page, dataset)` (the only
     place that knows C3-T01's `/build-fixture/:dataset` URL);
   - `verifyDesignSource()`, which compares the sha256 of the three design files
     with `FIXTURE_META.design_sha256` and fails with "design source changed
     without re-export";
   - `routeDesign(context)`, `guardNetwork(page, allowedOrigins)`,
     `seedRandom(page)`;
   - `openDesign(page, cell, opts)`, `openProduct(page, cell, opts)`,
     `openParityPair(browser, cell, opts)` (opts `{ dataset, ticket?, query?,
     phase?, productRoute? }`; returns `{ design, product, close() }`);
   - `waitParityReady(page, phase)`, `assertCellState(page, cell)`;
   - `captureStable(target, opts)`;
   - `expectDesignParity(pair, { name, region, fullPage })`;
   - `loadAllowlist()`, `applyAllowlist(pair, cell)`.

   Reuse `openVisualRoute`, `openFixture` and `dashboardCredentials`. Copy
   the `routeFonts` families table and handlers (`website/tests/support/visual.ts:8-29`)
   into this module with a comment that names the source; the font files stay
   where they are.
2. **`src/browser/support/visual.mjs`**: add an optional `palette` argument to
   `openVisualRoute`, seeded beside `aiur-theme` (lines 32-35). Existing callers
   do not pass it, so they keep their behaviour.
3. **`src/browser/playwright.design-parity.config.mjs`** (PROPOSED): import
   the base config, as `dockerConfig` does (visual.mjs:81). Set
   `snapshotDir: <artifactRoot>/design-baselines`,
   `snapshotPathTemplate: '{snapshotDir}/{testFilePath}/{arg}{ext}'` and
   `expect: { ...config.expect, toHaveScreenshot: { animations: 'disabled',
   caret: 'hide', threshold: 0 } }` (no `maxDiffPixelRatio`; see "Product
   compare"). Keep `updateSnapshots: 'none'`. Add no HTML reporter: the
   sanitizer would delete it (`artifact-sanitizer.mjs:7-8, 111-130`).
4. **`src/browser/support/design-parity-allowlist.json`**: the one
   `.bd-exl` entry above.
5. **`src/browser/tests/design-parity-harness.browser.spec.mjs`** (enforced):
   the tests in the Verification table.
6. **`src/browser/tests/design-parity-matrix.browser.spec.mjs`** (report
   mode): one test per matrix cell, plus the reduced-motion cell. Each test
   calls `openParityPair` and `expectDesignParity({ name: cellName })`. Each
   cell also writes `design.png` and `product.png` to `testInfo.outputPath()`,
   so a green cell leaves a side-by-side pair too (PNG, kept by the
   sanitizer).
7. **`src/browser/package.json`**:
   - `"test:design-parity": "node scripts/run-browser-tests.mjs tests/design-parity-harness.browser.spec.mjs --config playwright.design-parity.config.mjs"`,
     appended to the `test` chain;
   - `"parity:matrix": "AIUR_BROWSER_KEEP_ARTIFACTS=1 node scripts/run-browser-tests.mjs tests/design-parity-matrix.browser.spec.mjs --config playwright.design-parity.config.mjs"`,
     not in the `test` chain. `AIUR_BROWSER_KEEP_ARTIFACTS=1` keeps the
     artifact root after a green run (`run-browser-tests.mjs:74-76`).
8. **Docs**: a comment block at the top of `design-parity.mjs` (`src/browser/`
   has no README at `58854d4c8`, and this ticket does not start one). It explains how a visual ticket adds a
   region check, and that an allowlist entry needs Kevin's written approval.
   The user-facing docs (`website/docs-app/`) do not change; this is test
   tooling (AGENTS.md "Docs ship with the change": test-only).

Pseudocode for the comparison:

```js
export async function expectDesignParity(pair, { name, region, fullPage = false }) {
  const base = { animations: 'disabled', caret: 'hide', scale: 'device',
                 maskColor: '#ff00ff', fullPage }
  // removals and design-style CSS on design; returns one mask list per page;
  // throws "stale allowlist entry <id>"
  const { designMask, productMask } = await applyAllowlist(pair, pair.cell)
  const d = region ? await one(pair.design, region, 'design') : pair.design
  const p = region ? await one(pair.product, region, 'product') : pair.product
  const png = await captureStable(d, { ...base, mask: designMask }) // throws "design did not settle"
  const file = test.info().snapshotPath(`${name}.png`, { kind: 'screenshot' })
  await mkdir(dirname(file), { recursive: true }); await writeFile(file, png)
  await expect(p).toHaveScreenshot(`${name}.png`,
    { ...base, mask: productMask, threshold: 0, maxDiffPixels: PARITY_FLOOR })
}
```

## Non-happy paths

Each case gives the input, the expected behaviour, and the test that proves
it.

| # | Input | Expected | Test |
| --- | --- | --- | --- |
| N1 | Clock not frozen (the `setFixedTime` call is removed) | The cell fails with "clock not frozen: Date.now() != 1791408000000". This is EC-20. | `clock guard` |
| N2 | The context has a different time zone (`timezoneId: 'UTC'`) | The cell fails with "time zone UTC, expected America/Los_Angeles" before capture. EC-20. | `time zone guard` |
| N3 | Seeded palette `aiur`, but the page reports `gruvbox` (or has no attribute: the product before C2-T01) | The cell fails with "palette not applied". The cell never compares against the wrong palette. EC-28. | `palette guard` |
| N4 | Seeded theme `light`, page in `dark` | The cell fails with "theme not applied". EC-28. | `theme guard` |
| N5 | A font fails to load (font route returns 404) | The cell fails with `font not loaded: "Space Grotesk"`, not with a pixel diff that a fallback font could hide. | `font guard` |
| N6 | The design or product page requests an origin outside the allowlist (for example a CDN the design adds later) | The request is aborted and the test fails with the URL. A run is never green with a request that was not served. | `network guard` |
| N7 | The dataset switch answers non-200 (C3-T01 not merged, or an unknown dataset), or the LiveView socket never connects | The cell fails with "product target unavailable: GET /build-fixture/<dataset> → 404" (or "… socket not connected"). The cell is never skipped and never green. | `product target missing` (uses dataset `__missing__`, which is a 404 both before and after C3-T01) |
| N8 | The design keeps changing (the edge loop never stops) | "design did not settle after 10 captures" | `settle guard` (injects a `setInterval` that toggles a 1 px outline) |
| N9 | The region selector matches 0 or 2 elements on one side | "region missing on product" / "region not unique on design" | `region guard` |
| N10 | An allowlist entry has no `ref`, an unknown kind, a duplicate id, or `approved` without `by: "Kevin"` | The loader throws and no cell runs | `allowlist validation` (table-driven, one row per defect) |
| N11 | An allowlist selector matches nothing in a cell it covers | That cell fails as "stale allowlist entry <id>" | `stale allowlist entry` |
| N12 | The design files differ from C1-T01's recorded sha256 | "design source changed without re-export" | `design source hash` |
| N13 | A design file path tries traversal. Browsers normalise a literal `/../`, so the test sends the encoded form (`/%2e%2e/%2e%2e/mix.exs`) and also calls the route handler's path resolver directly with `../../mix.exs` | 404. Paths are decoded, resolved, and must stay under `DESIGN_ROOT`. | `design route containment` |
| N14 | A page error (uncaught exception) on either side, for example a d3 call | The test fails with the error. A broken page is never compared. | `page error guard` |
| N15 | The page never reaches the phase (the product `/build` stays in the skeleton before C9-T01 draws `#bd-content`) | "product not ready: .bd-loading still present after 10 s", not a bare timeout | `ready guard` (design page with `phase: 'board'` and the clock installed but not advanced) |
| N16 | `ticket` names a ticket for which the design starts its mock live stream (J:1511) | "ticket <id> runs the design's mock live stream" before any capture | `live-stream ticket refused` (dataset `live`, the first `now` ticket with an `active` agent from C1-T01's fixture) |

**Unknown is never a pass.** Every case where the runner cannot compare
(N1–N16) ends as a failed test with a reason. None of them is a skip, a pass,
or a zero-difference result. The matrix spec in report mode uses the same
code, so a cell that did not run shows as failed in the list reporter output
and in the exit code.

Security: the runner runs only against the synthetic fixture server, with the
existing synthetic credentials (`dashboardCredentials`). The design origin is
fake and isolated by context. It reads no real `~/.aiur` state. Failure
evidence goes through the existing sanitizer (`run-browser-tests.mjs:72`).

## Compatibility and rollout

- No product code, config key, CLI flag or environment variable changes.
  One optional argument is added to `openVisualRoute`, and existing callers
  keep their behaviour.
- **CI.** `test:design-parity` joins `npm test` in the existing browser job
  (`ci.yml:648`). The expected cost is under 2 minutes. The implementer
  measures it and records it in the PR. It has no checked-in baselines, so
  it has no docker-pinned rasterizer step. The full matrix is not in CI until
  C12-T01.
- **Rollback.** Delete the two specs and the script entries. Nothing else
  depends on them at merge.

## Verification

All tests are in `src/browser/tests/design-parity-harness.browser.spec.mjs`
unless stated otherwise.

| Test | Expected | Fails without |
| --- | --- | --- |
| `calibration: design equals design` (live × 3 viewports × 2 themes × gruvbox, plus aiur and dense at 1440 dark, plus `phase: 'loading'` at 1440 dark) | Two fresh design contexts compare with 0 differing pixels (or the recorded floor) | A positive control: it proves the runner reports no false difference, and it measures the floor. Its revert check: remove the `waitParityReady` call so one side may be captured in the 600 ms skeleton; record whether it fails. It does not count as coverage of the clock, seed or font code; the guards below cover those. |
| `mutation: +1px padding on .bd-card fails` | Read the computed `padding-left` of the first `.bd-card`, then inject that value + 1px with `!important` into the "product" side (a second design page). `expectDesignParity` throws a `toHaveScreenshot` matcher error matching `/pixels.*different/`, as in the visual-shell `:89-110` pattern. Other errors are rethrown. | `threshold: 0` / `PARITY_FLOOR` (with the base config's 0.002 ratio the mutation passes; check this while implementing and record it) |
| `mutation: region .bd-now catches a 1px shift` | Same as above, in region mode | the region path |
| `mutation: palette swap fails` | Design `gruvbox` against design `aiur` with the guard turned off. A pixel diff is reported. | the palette axis (both sides would render the same palette) |
| `clock guard` | N1 | the `Date.now()` check |
| `time zone guard` | N2 | the time-zone check |
| `theme guard`, `palette guard` | N3, N4 | the attribute checks |
| `font guard` | N5, two rows: (a) the font file route answers 404; (b) the `fonts.googleapis.com` route answers an empty stylesheet, so no face is declared | the `FontFace` status step. Row (b) also fails if the step is replaced by `document.fonts.check()` alone, which returns true when no face is declared |
| `network guard` | N6. Route a test page to request `https://example.com/x.js` | `guardNetwork` |
| `product target missing` | N7: `openProduct` with dataset `__missing__` fails with the "product target unavailable" message, and not with a timeout | the status check in `selectProductDataset` |
| `ready guard` | N15 | the per-phase wait and its message |
| `live-stream ticket refused` | N16 | the `startLive` precondition check |
| `loading phase holds the skeleton` | `openDesign` with `phase: 'loading'`: `.bd-loading` is present 2 s after load, and two captures 1 s apart are byte-equal | `clock.install` for the loading phase (with `setFixedTime` the 600 ms timer fires and `.bd-loading` is gone) |
| `settle guard` | N8 | `captureStable` |
| `region guard` | N9 | the exactly-one check |
| `allowlist validation` | N10, one row per defect, including `css` missing on a `design-style` entry, `css` set on another kind, and the status `pending-signoff` (wrong spelling) | `loadAllowlist` validation |
| `stale allowlist entry` | N11 | the match check |
| `allowlist removal applies` | With the `.bd-exl` entry, design (removal applied) against design (removal applied) has 0 diff. Removing the node and capturing without the entry gives a diff against the unremoved design, which proves the entry takes effect. | `applyAllowlist` |
| `design-style entry applies` | A temp allowlist with one `design-style` entry (`:root { --accent: #ff0000 }`) applied to one design side gives a pixel diff against a design side without it; applied to both, 0 diff | the `design-style` branch of `applyAllowlist` |
| `design source hash` | N12, using a temp copy of the design root with one byte changed | `verifyDesignSource` |
| `design route containment` | N13 | the path normalisation |
| `page error guard` | N14 | the `pageerror` listener |
| `pending sign-off entries are reported` | The run's annotations list `demo-data-select`, marked pending | the annotation step |

`seedRandom` has no test: no home-page path without `?ticket=` calls
`Math.random` at `58854d4c8` (and N16 refuses the one that does), so no
test can fail without it. It is kept as a cheap guard for a future
re-import, and the PR says so; it does not count as coverage.

Mutation discipline (AGENTS.md): for every guard test, remove the guarded
line in a worktree, run the test, and confirm it fails. Then restore the line
and confirm it passes. Before the run, check that `git status --porcelain`
shows only the intended change. Name each result in the PR body.

Commands (from `src/browser`):

```bash
npm ci && npx playwright install chromium
npm run fixture:preflight
npm run test:design-parity          # enforced; run it 3x to measure the floor
npm run parity:matrix               # report mode; red until C3-T01 and the C2/C9 work land
```

Manual check: after `npm run parity:matrix`, open the kept artifact root (the
path is printed on failure; it is kept on success because of
`AIUR_BROWSER_KEEP_ARTIFACTS=1`). Each cell folder holds `design.png` and
`product.png`, and a failed cell also holds Playwright's `-expected.png`,
`-actual.png` and `-diff.png`. Look at the PNGs, not only the exit code.
C12-T08 builds the side-by-side package for Kevin from these files. This is the evidence for "Kevin signs off
on the side-by-side comparison" (claude-design-source-of-truth.md).

## Pixel parity

- **Elements.** The whole page in the matrix: H:1910 `#build-root` and
  everything around it in the design shell (`.ax-top`, `.sidenav`). H:2058-2059
  `#tk-backdrop` and `#tk-modal` through `?ticket=` (J:1568-1570), for tickets
  that do not start the mock live stream (N16). Region mode
  is available for any selector (for example `.bd-now`, `.bd-toolbar`,
  `.ax-uc`).
- **What must match exactly.** Every pixel at `scale: 'device'`, with
  `threshold: 0` and `maxDiffPixels: PARITY_FLOOR` (target 0):
  - the static grain (C:1126-1139, `feTurbulence` 160 px tile, opacity .09
    with overlay blending in dark, and the light-theme overrides that end in
    `display: none`, C:1158);
  - the first frame of each infinite animation (`animations: 'disabled'`
    resets infinite animations on both sides in the same way);
  - all three breakpoint bands.
- **How it is checked.** This runner is the check. Other tickets call
  `expectDesignParity` with a region. The only differences allowed are the
  allowlist entries, and each entry names Kevin's approval or is reported as
  pending.

## Decisions made without the owner

1. **Live design render, not stored baselines.** The design is rendered in
   the same Chromium in every run. Stored PNGs would add platform drift and a
   step to refresh them.
2. **Fonts for the design side come from `website/tests/fixtures/fonts/`.**
   These are the google/fonts files, the source Google Fonts serves. The
   product's own `bungee.woff2` is not used for the design side. If it renders
   differently from the google/fonts Bungee, the parity check shows it, and
   C2-T01 decides.
3. **d3 is stubbed with an empty script** on the design side. The home page
   never calls it. The page-error guard catches any call that a later
   design version adds.
4. **`.bd-exl` ("Demo data") is removed on the design side**, as a
   `pending-sign-off` allowlist entry (plan §10 item 5). It is reported in every
   run until Kevin confirms it.
5. **Writable mode on the product side**, because the design home page has no
   read-only state.
6. **`threshold: 0` with a pixel count and no ratio**, so that drift on a large
   page is not hidden by its size.
7. **Palettes are named `gruvbox` and `aiur`** (H:5078). The brief calls the
   second one "default".
8. **The matrix is report-only until C12-T01.** A permanently red gate during
   wave 0b would stop every unrelated PR. Each visual ticket adds its own
   enforced region test.
9. **The browser time zone is set with `timezoneId`, not the process `TZ`.**
   The row says "sets `TZ=America/Los_Angeles`". Both pages compute dates in
   the browser, so the context option is the setting that matters; N2 checks
   it inside each page.
10. **An allowlist kind `design-style`** (with `motion`, `axe` and `copy`, seven kinds in all). C2-T01 ships six AA colour
    holds as allowlist entries. A token hold changes every element that uses
    the token, so the three original kinds cannot express it in a pixel
    compare: a mask would hide most of the page. Injecting the held value on
    the design side keeps the rest of the page under test. It is reported as
    `pending-sign-off` like any other entry.
11. **The status is spelled `pending-sign-off`**, the spelling C2-T01 uses.
12. **`?ticket=` is refused for tickets that start the design's mock live
    stream** (N16). Freezing that stream needs a fully faked clock, which
    breaks nothing on the design but may stall LiveView timers on the
    product. C1-T03 owns clock-driven sequences.
13. **The id map comes from C3-T02; no HTML report.** C1-T01 exports the
    design's ids raw; the C3-T02 fixture mapper writes the manifest `ids` map,
    which the harness reads. The sanitizer deletes HTML files, so the
    evidence is PNG pairs.

## Interface notes for neighbour rows

- **C1-T01 → C1-T02 (agreed).** C1-T01's ticket already provides what this
  ticket reads: the byte-for-byte copy at PROPOSED
  `src/test/fixtures/build_home/design-source/` and `manifest.json` with
  `now`, `tz` and `design_sha256`. Settled 2026-10-08: the `ids` map is written
  into the manifest by the C3-T02 fixture mapper.
- **C3-T01 → C1-T02 (agreed).** C3-T01's ticket defines
  `GET /build-fixture/:dataset` (200, or 404 for unknown) and the page `/build`,
  with no `?example=`, plus the `hold` and `unavailable` datasets. This
  ticket calls exactly that through `productUrl(dataset)`. Until C3-T01
  merges, product cells fail on purpose (N7). Settled 2026-10-08: C3-T01's
  `blocked_by` includes C1-T02, so its B4 test can use this ticket's element
  mode with `phase: 'loading'`.
- **C2-T03 (resolved there).** C2-T03 has its own B6 downscale check that uses
  C1-T02's floor only if C1-T02 has merged, and re-checks with element mode
  after C9-T06 and C10-T04. No new option is needed here.
- **C2-T01.** The product needs `aiur-palette` restored before first paint in
  the layout that the fixture server renders. Otherwise N3 fails. Self-host the
  same google/fonts files that this ticket uses for the design side, so that
  both sides render the same font bytes. Its six AA holds are allowlist
  entries of kind `design-style` (pixels) and `property` (C2-T04), with status
  `pending-sign-off` and `ref` citing S-19. Its token and body checks on a
  shell route use `phase: 'shell'` and `productRoute`.
- **C2-T04.** Use the allowlist's `property` kind, `loadAllowlist()` and
  `openDesign`. Do not start a second list.
- **C1-T03.** Its ticket names `openDesign`, `openProduct`, `compareElement`
  and `ALLOWLIST`. The names this ticket ships are `openDesign`,
  `openProduct`, `expectDesignParity(pair, { region })` (element mode) and
  `loadAllowlist()`. Reuse `waitParityReady` and the network guard. Motion
  needs real timers, so C1-T03 calls `page.clock.install` where this ticket
  calls `setFixedTime`.

## Completion and handoff

- [ ] `design-parity.mjs`, the config, the allowlist and the two specs exist.
      `openVisualRoute` takes `palette`.
- [ ] `npm run test:design-parity` passes three runs in a row. The floor and
      the three counts are recorded.
- [ ] Every test in the Verification table except the calibration control
      fails when its guarded line is removed. The PR body names each result,
      the calibration revert result, and the exact command.
- [ ] `npm test` includes `test:design-parity`. The CI browser job is green,
      and the added time is measured and stated.
- [ ] `npm run parity:matrix` runs all 61 cells and keeps `design.png` and
      `product.png` per cell (plus Playwright's expected/actual/diff PNGs on
      failure). Product cells fail with N7 until C3-T01 lands, then with N15
      until C9-T01 draws the board.
- [ ] The `demo-data-select` entry appears as pending in the run output.
- **Dependents.** C1-T03, C2-T01, C2-T04, C2-T03 (optional floor), C3-T01
  (B4, `phase: 'loading'`), every
  visual C9/C10/C11 ticket, C12-T01 (adds the matrix to `npm test`), C12-T04,
  C12-T08.
- **Sources.** tickets/README.md C1-T02 row; chunks.md C1; plan §8 (EC-20,
  EC-28), §9 K-1, §10 item 5, §11; claude-design-source-of-truth.md "How done
  is verified"; design-source IMPORTED.md.
- **Remaining blocker.** DESIGN-E8 only.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8`, the design source, the
README row and the neighbour tickets.

1. Product interface: replaced the PROPOSED `/fixture-build/<dataset>` with
   C3-T01's actual `GET /build-fixture/:dataset` + `/build`
   (`selectProductDataset`); recorded that C3-T01's B4 needs C1-T02 in its
   `blocked_by`.
2. C1-T01 interface: read `manifest.json` (`now`, `tz`, `design_sha256`);
   dropped the id map, which C1-T01 does not produce and the data does not need.
3. Comparator limit: the base config's `maxDiffPixelRatio` is merged and
   Playwright takes the minimum (`coreBundle.js:7265-7271`); the parity config
   now replaces `toHaveScreenshot` defaults without a ratio.
4. Evidence: the sanitizer deletes HTML (`artifact-sanitizer.mjs:7-8,
   111-130`) and the artifact root is removed on green (`run-browser-tests.mjs:74-76`);
   replaced the HTML report with per-cell PNG pairs and
   `AIUR_BROWSER_KEEP_ARTIFACTS=1` on `parity:matrix`.
5. Font guard: `document.fonts.check()` is true when no face is declared;
   the ready rule now requires a loaded `FontFace` per family, with a test row
   for a missing stylesheet.
6. Mask lists are per page in the pseudocode (a locator belongs to one page).
7. Added `phase` (`board` / `loading` / `shell`) and `productRoute`, which
   C3-T01 (loading skeleton) and C2-T01 (shell route) rely on, with tests.
8. Added the `design-style` allowlist kind for C2-T01's AA token holds, and the
   status spelling `pending-sign-off` that C2-T01 uses.
9. `?ticket=` with an active `now` ticket: the design's `startLive` mock
   stream runs on real timers under `setFixedTime` (J:1509-1525); added N16
   to refuse it, and N15 for a page that never leaves the skeleton.
10. Honest coverage: the calibration test is a positive control, not coverage
    of the clock, seed or fonts; `seedRandom` has no failing test today and is
    labelled a future guard.
11. Citations corrected: H:2058 (`#tk-backdrop`), H:5113 / H:3978 (init calls
    `switchTab`, which renders), J:1559-1574 (render), J:314 / J:1569
    (`example` vs `ticket`), C:1158 (`display: none`), C:297 + J:540/560
    (reduced-motion static ring, not C:348), `playwright.config.mjs:20-28`.
12. N13 traversal test uses the encoded path, because browsers normalise
    `/../`. `routeFonts` is copied, not imported (TypeScript in another
    package). No `src/browser/` README exists, so docs are a module comment.
13. Front matter gained `owns_edge_cases: [EC-20, EC-28]`, as in the
    neighbour tickets.

- Reconciliation 2026-10-08 (coordinator): allowlist kinds `motion`, `axe` (+`rule`), `copy` added (seven kinds; `path` for `motion`), no `approved: false`, pending passes in CI and fails only in the C12-T08 `--gate` run, `productUrl(dataset)` over `GET /build-fixture/:dataset`, `openParityPair` `query` option, product ready waits for `data-bd-mounted` and `data-bd-paging="idle"`, DOM-class compares ignore `phx-*`/`data-phx-*`, manifest `ids` map from the C3-T02 mapper (Decision 13, interface note settled), C2-T01 holds cite S-19, C3-T01 B4 gap settled (C1-T02 is in its `blocked_by`).
