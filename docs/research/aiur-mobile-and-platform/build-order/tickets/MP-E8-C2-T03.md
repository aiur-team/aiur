---
ticket_id: MP-E8-C2-T03
feature_id: MP-E8
chunk_id: MP-E8-C2
bucket: 2-platform
title: Static assets and the four-place hook registration
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C1-T01]
complexity: 2
design_gate: DESIGN-E8
owns_edge_cases: []
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C2-T03 — Static assets and the four-place hook registration

## Identity and outcome

- Bucket 2, feature MP-E8 (Continuous build history home page), chunk C2
  (shell, tokens, palette, fonts, assets, CSS). Level 0 in the work-order: it
  starts as soon as DESIGN-E8 is signed off.
- **User value.** None directly visible. This ticket gives every later home-page
  ticket a place to put code, styles and logos without editing `layouts.ex`,
  `StaticAssets`, the router or the fixture layout again. It also ships the two
  model logos the design uses and the product does not have.
- **Deliverable.**
  1. One directory, PROPOSED `src/priv/static/build-home/`, served, cached and
     authenticated through **one** entry in `@revalidated_static_paths`.
  2. A classic loader script, PROPOSED `build-home/loader.js`, that exposes
     `window.AiurBuildHome.createLiveViewHook()`. It imports the ES module
     PROPOSED `build-home/hook.js` and forwards every LiveView hook callback.
  3. A stub `build-home/hook.js` that C9-T01 replaces, with a fixed health
     attribute contract (below).
  4. An empty stylesheet, PROPOSED `build-home/home.css`, linked from the root
     layout after `dashboard.css`. C2-T04 fills it.
  5. The logos: `build-home/logos/kimi-logo.png` (byte copy of the design file),
     `build-home/logos/deepseek-logo.png` (re-encoded, see Pixel parity), and a
     frozen key → logo table, PROPOSED `build-home/logos.js`.
  6. The four registrations in the product root layout, mirrored in the browser
     fixture layout.
- **Non-goals.**
  - No route, no LiveView, no `#build-root` element (C3-T01).
  - No home CSS rules (C2-T04). No tokens, palette or fonts (C2-T01).
  - No hook behaviour beyond the loader contract (C9-T01 owns the hook shell).
  - No change to `/provider-assets/*`, the provider descriptors or the token
    SVGs. Other pages keep their files as they are.
  - No server-side model → logo mapping (C8-T01).

## Dependencies and blockers

- **Blocked by DESIGN-E8.** Sign-off item **S-13** (logo for a model the design
  does not include: muse, openrouter, unknown) is followed at its written
  default: the `.ax-mono` letter circle. This ticket implements its part of that
  default by leaving those keys out of `LOGOS` (so consumers fall to the
  fallback). Kevin's answer to S-13 may reopen this ticket.
- **Predecessor: MP-E8-C1-T01** (a `blocked_by` edge): B6 reads the
  original DeepSeek PNG from C1-T01's in-tree design copy (Verification,
  interface note 5). This does not lengthen the critical path, because C3-T01
  already waits for both.
- **Successors that depend on this ticket's interfaces:**
  - C3-T01 renders `<div id="build-root" ... phx-hook="BuildHome" phx-update="ignore">`
    and the fixture route. It uses the hook name `BuildHome` and may style
    `data-build-home-hook="failed"`.
  - C2-T04 writes its consolidated stylesheet into `build-home/home.css`. No
    `StaticAssets` or layout change is needed for it (the `<link>` is added here).
  - C9-T01 replaces the body of `build-home/hook.js`, keeps the export
    `createBuildHomeHook` and the health attribute, and adds sibling modules
    under `build-home/`.
  - C8-T01, C8-T02, C9-T05, C9-T06, C9-T12, C10-T02, C10-T04, C11-T01, C11-T03
    and C11-T07 read the logo keys from `LOGOS`.
- **May run concurrently with:** C4-T01, C5-T01 (different files). C2-T01 and
  C2-T02 edit `dashboard.css` and the shell, not the files
  here. C2-T01 may also add font files; it does that under its own paths.
- Shared contracts: none outside MP-E8.

## Verified starting point (`58854d4c8`)

Live code root: `src/` at `origin/main` `58854d4c8`.

**How a hand-served asset is served today (no bundler).**
- `src/lib/aiur_web/static_assets.ex:13-27` `@revalidated_static_paths` lists
  first path segments. `:14` already holds the *directory* `aiur-dom-svg-layout`.
  `:77-78` `revalidated_static_paths/0`. `:92-99` `served_path?/1` returns true
  when the first segment is in that list.
- `src/lib/aiur_web/endpoint.ex:31` `plug(:authenticate_static_asset)`;
  `:33-40` `Plug.Static` with `only: AiurWeb.StaticAssets.revalidated_static_paths()`
  and `cache_control_for_etags: "private, max-age=0, must-revalidate"`;
  `:80-85` `authenticate_static_asset/2` calls
  `AiurWeb.FinancialDataAccess.authenticate_request/2` for every `served_path?`
  path. So one list entry gives serving, caching **and** dashboard auth.
- `Plug.Static` (plug 1.20.3, `deps/plug/lib/plug/static.ex`): `:239-247`
  `path_status/2` matches only the **first** segment against `:only`, so a
  directory entry covers every file under it. `:208-212` decodes segments and
  raises `InvalidPathError` (`:152-154`, `plug_status: 400`) when
  `invalid_path?/1` (`:476-481`) sees `.`, `..`, empty, or a segment holding
  `/ \ : \0`. A missing file falls through (`:217-218`).
- The served-by-`Plug.Static`-only pattern already exists: `conversation-drawer-hook.js`
  and `conversation-voice-controller.js` are in the list (`static_assets.ex:18-19`)
  and in `layouts.ex:40-41`, with no router route and no controller action.
- The `aiur-dom-svg-layout` precedent also has router routes
  (`router.ex:120-122`) and a module map (`static_assets.ex:36-44`,
  `:146-151`). Those exist for its compile-time-embedded adapter
  (`static_assets.ex:7, 64, 71`). This ticket does **not** need them.

**Root layout** `src/lib/aiur_web/components/layouts.ex`:
- `:35-45` the `<script defer>` list; `:38` the DOM-SVG loader; `:45` the last
  hook script (`sortable-table-hook.js`).
- `:54` `var Hooks = {};` `:252-254` the loader-style registration
  `if (window.AiurDomSvgLayout) { Hooks.DomSvgLayout = window.AiurDomSvgLayout.createLiveViewHook(); }`;
  `:268-270` the last registration (`SortableTable`); `:272-283` `LiveSocket`.
- `:290` `<link rel="stylesheet" href="/dashboard.css" />`.

**Loader precedent** `src/priv/static/aiur-dom-svg-layout-loader.js:1-56`:
`:2-12` validates a URL read from `data-layout-adapter-url`; `:14-18`
`fallback/1` sets `data-layout-health="fallback"`; `:20-53`
`createLiveViewHook` dynamic-imports the adapter, guards a destroy that happens
before the import resolves (`:23, :33, :49`), and forwards `beforeUpdate`,
`updated`, `destroyed`. It does **not** forward `disconnected`/`reconnected`.
`:55` `window.AiurDomSvgLayout = { createLiveViewHook }`.

**Browser fixture** `src/test/browser/fixture_server.exs`:
`:30` DOM-SVG loader script; `:37` sortable hook; `:39` `dashboard.css` link;
`:97-99` `SortableTable` registration into `window.BrowserHarnessHooks`;
`:101-104` `LiveSocket`; `:2315-2321` `Plug.Static` with the same
`revalidated_static_paths()`. So fixture serving is free; only the layout tags
and the registration must be mirrored. `src/test/browser/assets/browser_harness.js:29-49`
builds `window.BrowserHarnessHooks` (`:49`).

**Router fallback** `src/lib/aiur_web/router.ex:185-199`: the last scope pipes
through `:dashboard_auth` and ends with `match(:*, "/*path", ObservabilityApiController, :not_found)`
(`:198`; JSON 404, `observability_api_controller.ex:149-151`). So a path that
`Plug.Static` does not serve still gets 401 without credentials and 404 with
them. This matters for which test can detect a missing list entry (Verification).

**LiveView client** (`deps/phoenix_live_view` 1.1.33,
`priv/static/phoenix_live_view.js`): `:4092-4106` hook `pushEvent`;
`:5421-5430` `pushHookEvent` returns a rejected promise (it does not throw)
when the view is not connected.

**Tests that already cover the asset surface** `src/test/aiur/extensions_test.exs`:
- `:1042` test "dashboard bootstraps liveview from embedded static assets":
  `:1059-1071` asserts each script path is in the HTML; `:1100-1104` shows
  `Plug.Static` serves `.js` as `text/javascript`.
- `:1490` test "http server serves embedded assets, accepts form posts, and
  rejects invalid hosts": `:1542-1545` loops over asset paths and asserts 401
  without credentials.
- Browser specs: `src/browser/tests/*.browser.spec.mjs`, run by
  `src/browser/package.json:10` (`test` chain) through
  `scripts/run-browser-tests.mjs`; `tests/support/browser-helpers.mjs:12`
  `openFixture(page, mode)`.

**Logos.**
- Product: `src/lib/aiur/coding_agent/providers/claude.ex:52` logo
  `/provider-assets/claude-symbol.svg` (`:53` token icon `codex-token.svg`);
  `src/lib/aiur/coding_agent/providers/codex.ex:54` `/provider-assets/codex-color.svg`
  (`:55` token icon `claude-token.svg`). The live descriptors already cross the
  token names. `src/lib/aiur/open_ai_compat/registry.ex:144-145` `/provider-assets/#{slug}.svg` and
  `#{slug}-token.svg`. `priv/static/kimi.svg` is a 224-byte letter circle and
  `priv/static/deepseek.svg` wraps an embedded PNG. Neither is the design's file.
- Design (`design-source/assets/`, IMPORTED.md etag 1791431544512943):
  `MODELS` (J:82-87) uses `claude-symbol.svg`, `codex-color.svg`,
  `deepseek-logo.png` (`fill: true`), `kimi-logo.png` (`fill: true`).
  J:989 the usage strip uses the same four.
- Byte comparison, run 2026-10-08:

  | File | Design | Live | Result |
  | --- | --- | --- | --- |
  | `aiur-logo.png` | 594,166 B, sha `5f3b8f3d…` | same | identical, nothing to do |
  | `claude-symbol.svg` | 1,124 B | 1,125 B | only a trailing newline differs (`diff`) |
  | `codex-color.svg` | 1,554 B | 1,555 B | only a trailing newline differs |
  | `kimi-logo.png` | 512×512 RGBA, 12 KB, sha `b6ca346a6593…0a137fbf` | missing | add |
  | `deepseek-logo.png` | 3840×3823 RGBA, 413 KB, sha `eff4b0f8…7dd0ae` | missing | add, re-encoded |
  | `claude-token.svg`, `codex-token.svg` | differ | differ | **not used by the home page** |

  The token SVGs are named crosswise between the two trees (the design's
  `claude-token.svg` has the same paths as the live `codex-token.svg`), but
  `build.js`, `build.css` and the HTML reference neither file (grep: 0 hits).
  So the home page ships no token SVG.

## Chosen design

**One directory, one entry.** Add `build-home` to `@revalidated_static_paths`.
Every file under `src/priv/static/build-home/` is then served by `Plug.Static`
with ETag revalidation and behind dashboard auth. No router route, no
controller action, no compile-time read. Later tickets add files and do nothing
else.

**Files (all PROPOSED).**

```text
src/priv/static/build-home/
  loader.js        classic script; defines window.AiurBuildHome
  hook.js          ES module; export createBuildHomeHook()  (stub; C9-T01 owns the body)
  logos.js         ES module; export const LOGOS (frozen)
  home.css   empty; C2-T04 owns the content
  logos/kimi-logo.png
  logos/deepseek-logo.png
```

**Loader contract (`loader.js`).**
- The module URL is a constant, `"/build-home/hook.js"`. The loader reads no
  URL from the DOM (the DOM-SVG loader must validate one; this one has nothing
  to validate).
- `createLiveViewHook()` returns an object with `mounted`, `beforeUpdate`,
  `updated`, `destroyed`, `disconnected`, `reconnected`. Each one, after the
  import resolves, calls the same method of the module's hook with
  `.call(this)`, so `this.el`, `this.pushEvent` and `this.handleEvent` are the
  LiveView ones. `disconnected`/`reconnected` are forwarded so C9-T01 can do
  EC-06 and EC-11 without editing the loader.
- Health attribute on the hook element, `data-build-home-hook`:
  - `"loading"`: set synchronously in `mounted`, before the import.
  - `"mounted"`: set by the module's `mounted` (the stub sets it; C9-T01 keeps
    setting it).
  - `"failed"`: set when the import rejects or the module has no
    `createBuildHomeHook` export. The loader never sets `"mounted"` itself.
  The words mean "the code loaded", not "the data is ready". No value of this
  attribute means data is ready.
- Destroy before the import resolves: the module hook is never created and
  nothing is written to the element (pattern from
  `aiur-dom-svg-layout-loader.js:23, 33, 49`).
- Callbacks that arrive before the import resolves (other than `mounted` and
  `destroyed`) are dropped. Because of that, **the server must not push data to
  the hook before the hook asks**: C9-T01's `mounted` sends the first request,
  and C3-T02's initial snapshot is a reply to it. See the interface note in
  Completion and handoff.

Sketch:

```js
(() => {
  const MODULE_URL = "/build-home/hook.js"
  const CALLBACKS = ["beforeUpdate", "updated", "disconnected", "reconnected"]
  const fail = (el) => { el.dataset.buildHomeHook = "failed" }
  const createLiveViewHook = () => {
    const hook = {
      mounted() {
        const ctx = this
        ctx.__buildHomeDestroyed = false
        ctx.el.dataset.buildHomeHook = "loading"
        import(MODULE_URL)
          .then((m) => {
            if (ctx.__buildHomeDestroyed) return
            if (typeof m.createBuildHomeHook !== "function") return fail(ctx.el)
            ctx.__buildHome = m.createBuildHomeHook()
            ctx.__buildHome.mounted?.call(ctx)
          })
          .catch(() => { if (!ctx.__buildHomeDestroyed) fail(ctx.el) })
      },
      destroyed() {
        this.__buildHomeDestroyed = true
        this.__buildHome?.destroyed?.call(this)
        this.__buildHome = null
      }
    }
    for (const name of CALLBACKS) hook[name] = function () { this.__buildHome?.[name]?.call(this) }
    return hook
  }
  window.AiurBuildHome = { createLiveViewHook }
})()
```

Stub `hook.js`:

```js
// MP-E8-C2-T03 stub. C9-T01 replaces the body; keep the export name and the health attribute.
export function createBuildHomeHook() {
  return { mounted() { this.el.dataset.buildHomeHook = "mounted" } }
}
```

**Logo table (`logos.js`).** The keys and `fill` flags are the design's
`MODELS` (J:82-87). Only the image fields are kept; the design's `name` and
`full` strings are mock data and the real names come from the payload.

```js
// Null prototype: a payload key such as "constructor" or "__proto__" must not
// find Object.prototype members (C9-T05 reads LOGOS[k] without Object.hasOwn).
export const LOGOS = Object.freeze(Object.assign(Object.create(null), {
  claude:   Object.freeze({ src: "/provider-assets/claude-symbol.svg", fill: false }),
  codex:    Object.freeze({ src: "/provider-assets/codex-color.svg",   fill: false }),
  deepseek: Object.freeze({ src: "/build-home/logos/deepseek-logo.png", fill: true }),
  kimi:     Object.freeze({ src: "/build-home/logos/kimi-logo.png",     fill: true })
}))
```

- Any key not in `LOGOS` (muse, openrouter, unknown, missing, and
  `Object.prototype` names such as `constructor`, `toString`, `__proto__`)
  gives `undefined`. The consumer then renders the `.ax-mono` letter circle (S-13
  default; C9-T05, C9-T06, C9-T12, C10-T02, C10-T04, C11-T01, C11-T03, C11-T07). There is no default entry, so an unknown
  model can never show another model's logo.
- Claude and Codex reuse the live provider assets because their content is the
  design's (only a trailing newline differs). This avoids a second copy that can
  drift.

**Stylesheet.** `build-home/home.css` is linked in the root layout directly
after `/dashboard.css`, so the home rules (C2-T04) win at equal specificity and
there is no unstyled flash when a user navigates to the home page by live
navigation. Its first line is a comment naming C2-T04 as the owner.

**The four registrations** (product root layout; the fixture layout mirrors
1, 3 and 4):
1. `static_assets.ex:13-27`: add `build-home` (alphabetical, after
   `aiur-dom-svg-layout-loader.js` at `:16`, before `build-order-grid-hook.js` at `:17`).
2. `layouts.ex:45`: add `<script defer src="/build-home/loader.js"></script>`.
3. `layouts.ex:290`: add `<link rel="stylesheet" href="/build-home/home.css" />`
   after the `dashboard.css` link.
4. `layouts.ex:270`: add
   `if (window.AiurBuildHome) { Hooks.BuildHome = window.AiurBuildHome.createLiveViewHook(); }`.

## Implementation steps

1. Create `src/priv/static/build-home/` with `loader.js`, `hook.js`, `logos.js`
   and `home.css` as above.
2. Copy `design-source/assets/kimi-logo.png` to
   `src/priv/static/build-home/logos/kimi-logo.png` unchanged (sha256 must stay
   `b6ca346a6593c2e5094f806a96e3c4b09ebf0ea8f9c4adaa262701040a137fbf`).
3. Re-encode DeepSeek (ImageMagick 7.1.2-27 is on the dev host; record the version
   in the PR):

   ```bash
   magick design-source/assets/deepseek-logo.png -filter Lanczos -resize 74x74 \
     -strip -define png:color-type=6 -define png:compression-level=9 \
     src/priv/static/build-home/logos/deepseek-logo.png
   ```

   74 px = 3 × the largest slot (24.05 px, see Pixel parity), rounded up to an
   even number. 3×, not the row's 2×, because this pack targets phones, which
   are commonly `devicePixelRatio` 3; a 2× file would be upscaled there.
   Reviewer trial (2026-10-08, ImageMagick 7.1.2-27): output 74×74, 8-bit RGBA,
   3,660 B (the 3840×3823 source rounds to 74 on both axes). `png:color-type=6`
   keeps full RGBA; without it ImageMagick
   writes an 8-bit palette (seen in a trial run, 1,870 B), which can band the
   alpha edge. If the parity check below fails, re-encode at 100×100 and
   re-run; record which size passed and update T1's IHDR assert.
4. `static_assets.ex`: add `build-home` to `@revalidated_static_paths`.
5. `layouts.ex`: the three edits at `:45`, `:270`, `:290`.
6. `fixture_server.exs`: add the loader script after `:37` (before
   `browser_harness.js` at `:38`), the stylesheet link after `:39`, and after `:99`
   `if (window.AiurBuildHome) { window.BrowserHarnessHooks.BuildHome = window.AiurBuildHome.createLiveViewHook(); }`.
7. Tests (Verification). Add the browser spec to `src/browser/package.json`
   as `test:build-home-assets` and append it to the `test` chain (`:10`).
8. No docs: no config key, CLI flag, env var or user-visible surface changes
   (AGENTS.md "Docs ship with the change"). The home page docs land with C12.

## Non-happy paths

| Case (concrete input) | Expected behaviour | Proved by |
| --- | --- | --- |
| Credentials configured, no `Authorization` header, `GET /build-home/loader.js` | 401, body not served | ExUnit T2 (regression guard; see T2 note) |
| Same, for a file that does not exist: `GET /build-home/nope.js` | 401 (auth runs first; no existence oracle) | ExUnit T2 (regression guard) |
| Authenticated `GET /build-home/nope.js` | 404 | ExUnit T1 |
| Encoded traversal `GET /build-home/..%2Fdashboard.css` | 400 from `Plug.Static.InvalidPathError` (`static.ex:208-212`; the one segment decodes to `../dashboard.css`, which holds `/`); nothing served | ExUnit T1, through `assert_error_sent 400` (`Phoenix.ConnTest` re-raises the exception; the test module imports it at `extensions_test.exs:4`) |
| `hook.js` returns 500 or does not parse | `data-build-home-hook="failed"`, never `"mounted"` | Browser B2 |
| `hook.js` loads but has no `createBuildHomeHook` export | `"failed"` | Browser B3 |
| The module's `mounted` throws (a C9-T01 bug) | `"failed"` (the throw rejects the `.then` chain into `.catch`) | Browser B3 |
| LiveView destroys the element before the import resolves | no module hook created, no attribute written after destroy | Browser B4 |
| `disconnected` / `reconnected` before the module is ready | no error thrown; dropped. Safe because the module's `mounted` always sends `build-resync` (C9-T01): if the socket is still down then, `pushHookEvent` rejects (LV `:5421-5430`, no throw) and the later forwarded `reconnected` resyncs; if it is back up, the `mounted` resync succeeds | Browser B4 |
| Model key `muse`, `openrouter`, `"gemini"`, `undefined`, `"constructor"`, `"toString"`, `"__proto__"` | `LOGOS[key] === undefined` (consumer shows `.ax-mono`) | Browser B5 |
| A consumer tries to change `LOGOS` at run time | no effect (`Object.isFrozen`) | Browser B5 |
| Read-only dashboard | not applicable: the directory has no write path, and serving does not read `dashboard_writable` | none needed |
| Loader script blocked entirely (no `window.AiurBuildHome`) | `Hooks.BuildHome` is absent; the element keeps the server skeleton. This ticket cannot mark it. | Handoff to C3-T01 (EC-01) |
| Browser cache after a deploy | ETag revalidation (`must-revalidate`) on every file in the directory | ExUnit T1 asserts the header |

Privacy and security: the directory holds only static code and images. No
user data, no secrets. The directory is behind the same auth as `dashboard.css`.
The loader takes no URL from the DOM, so there is no URL to validate.

## Compatibility and rollout

- No config, no migration, no feature flag. Nothing renders `phx-hook="BuildHome"`
  until C3-T01, so after this ticket the only effect on existing pages is one
  extra deferred script and one empty stylesheet per full page load (both 304
  after the first load).
- Existing `/provider-assets/*` files, provider descriptors and token SVGs are
  unchanged.
- Release packaging: `src/priv/static/**` already ships in the release
  (`from: :aiur`); there is no file manifest to update (grep for
  `sortable-table-hook` finds only the six files cited above).
- Rollback: revert the commit. No state is written.

## Pixel parity

This ticket renders no element of the design itself. Its parity obligations are
the bytes and the downscale of the logos.

| Design element | Product asset | Check |
| --- | --- | --- |
| `assets/kimi-logo.png` (J:86, J:989) | `/build-home/logos/kimi-logo.png` | served bytes sha256 equal to the design file (T1) |
| `assets/claude-symbol.svg` (J:83) | `/provider-assets/claude-symbol.svg` | served body equals the design file after removing one trailing newline (T1) |
| `assets/codex-color.svg` (J:84) | `/provider-assets/codex-color.svg` | same as above (T1) |
| `assets/deepseek-logo.png` (J:85, J:989) | `/build-home/logos/deepseek-logo.png` (74×74) | rendered-slot comparison (B6), then C1-T02 element mode |
| `.ax-mono` (J:1018; C:58-59, 782, 895, 1065) | no asset; CSS from C2-T04 | not in this ticket; `LOGOS` leaves unknown keys out so it is reached |

**Largest display size of a `fill` logo** (sets the re-encode size):
- `.bd-ag` is `width: 1.85em` (C:280) and `.bd-ag.fill img` is `100%`
  (C:816-817). The card font size is `L.fs = 13` px, a constant (J:358, J:416,
  J:672). So the slot is 1.85 × 13 = **24.05 CSS px**. This is an upper bound:
  `.bd-ag` has a 1 px border (C:280) and the design sets `box-sizing:
  border-box` on `*` (H:126), so the image box is 22.05 px.
- Other slots are smaller: `.ax-who img` 20 px (C:895, overrides 18 px at
  C:58), `.bm-agent img` and `.cv-say img` 16 px (C:493, 516), `.c-ag img`
  15 px (C:759), `.bd-opt img` 14 px (C:139), `.bd-lg` 1.05em = 13.65 px
  (C:655). `.hist .bd-ag` is 1.6em (C:282).
- The writer confirms 24.05 px in the design page at 1440 px with
  `getBoundingClientRect()` on every `img[src$="deepseek-logo.png"]` (dense
  dataset) and records the maximum in the PR. If it is larger, the re-encode
  size is 3 × that maximum, rounded up to even.

**B6, the DeepSeek downscale check (no new npm dependency).** In a fixture page
at `deviceScaleFactor: 3`, render the original design PNG and the product PNG
into the
same two slots, each as the design styles them: a 24.05 px circle with
`object-fit: cover` (`.bd-ag.fill img`) and a 20 px circle with
`border-radius: 50%; object-fit: cover` (`.ax-who img.fill`, C:782, 895).
Take `locator.screenshot()` of each, decode both in the page through
`createImageBitmap` and a canvas, and compare per pixel.
- The original is read from C1-T01's in-tree design copy, PROPOSED
  `src/test/fixtures/build_home/design-source/assets/deepseek-logo.png`, and
  served with `page.route(..., route.fulfill({ path }))`. The research pack
  (`docs/research/...`) is not on `main`, so the test must not read it. If the
  file is missing, B6 fails with a message naming the path; it does not skip.
- Pass: no more than 2% of slot pixels with any channel delta above 8/255. One
  fixed threshold, not one that depends on which tickets have merged. Record
  the measured numbers in the PR, together with the measured numbers for the
  8×8 mutation below; the mutation must exceed the threshold by at least 2×,
  or the threshold is too loose and the writer tightens it before merge.
- C1-T02's element-level mode re-checks `.bd-ag.fill` and `.ax-who` against the
  design once C9-T06 and C10-T04 render them. A failure there is a failure of
  this asset, and the fix is a larger re-encode, not a CSS change.

## Verification

ExUnit (in `src/test/aiur/extensions_test.exs`, extending the two existing tests):

| # | Test | Expected | Fails without |
| --- | --- | --- | --- |
| T1 | "dashboard bootstraps liveview from embedded static assets" (`:1042`), extended | HTML contains `/build-home/loader.js` and `/build-home/home.css`, and `home.css` comes after `/dashboard.css` in the HTML. `GET /build-home/loader.js` is 200, body `=~ "AiurBuildHome"`, content type `text/javascript`, cache-control `private, max-age=0, must-revalidate`. Same 200 + header for `hook.js`, `logos.js`, `home.css` (`text/css`), both PNGs (`image/png`). Kimi body sha256 = `b6ca346a6593c2e5094f806a96e3c4b09ebf0ea8f9c4adaa262701040a137fbf`; DeepSeek body is a PNG with IHDR 74×74 and color type 6. The two provider SVG bodies, after `String.trim_trailing/1`, have the design files' sha256: `claude-symbol.svg` `be2ee702a76d5ecffa52a7a1c47224e7ad37c13f459cdb25fd9a578dd90287e9`, `codex-color.svg` `bbae2b981aa4c2c79e8dcf79d56cbdb1ee58a4ebee9b19fb4def152f54da8a34` (measured 2026-10-08 on the design files, which have no trailing newline). `GET /build-home/nope.js` → 404 (router fallback); `assert_error_sent 400, fn -> get(build_conn(), "/build-home/..%2Fdashboard.css") end` | the `build-home` entry (every 200 becomes the router's JSON 404); the layout edits (HTML asserts); the files |
| T2 | "http server serves embedded assets…" (`:1490`), loop at `:1542-1545` extended | `/build-home/loader.js`, `/build-home/logos/kimi-logo.png` and `/build-home/nope.js` return 401 without credentials | **Regression guard, not coverage of this change** (name it so in a comment). Without the `build-home` entry the request still gets 401, from the router's `:dashboard_auth` catch-all (`router.ex:185-199`). It fails only if a future change serves `build-home/` before the auth plug. |
| T3 | new `test "every logo LOGOS advertises is served"` | parse every `src: "…"` in `src/priv/static/build-home/logos.js`; each one GETs 200 with an `image/*` type; the key set is exactly `claude codex deepseek kimi` | a missing logo file, a wrong path, or an added key with no file |

T1 compares against sha256 constants of the design files, with a comment that
names `design-source/assets/` and IMPORTED.md etag 1791431544512943. It does
not read `docs/research/...`: that folder is on the research branch, not on
`main`, so a test that reads it is red on `main`. (`:1144` reads
`website/public/assets/aiur-logo.png`, which is on `main`.)

Browser (PROPOSED `src/browser/tests/build-home-assets.browser.spec.mjs`, on the
existing fixture via `openFixture(page)`; the hook is driven directly with
`window.AiurBuildHome.createLiveViewHook()` on a detached `div`, because no
LiveView renders `BuildHome` until C3-T01). Each case, and each of B2's two
runs, uses a fresh page: the browser's module map caches `/build-home/hook.js`
for the life of the page, so a second routed body in the same page is never
fetched. Install the `page.route` for `hook.js` before the first `mounted`
call.

| # | Case | Expected | Fails without |
| --- | --- | --- | --- |
| B1 | happy path | `window.BrowserHarnessHooks.BuildHome` exists and has the six callbacks; `mounted` sets `"loading"` then `"mounted"`; `updated`, `disconnected`, `reconnected` reach a spy module (route `hook.js` to a module that records calls) with `this.el` equal to the element | the forwarding loop |
| B2 | route `hook.js` → 500, then a second run with a syntax error | `"failed"`; never `"mounted"` | the `.catch` branch |
| B3 | route `hook.js` → (a) module with no export; (b) module whose `mounted` throws | `"failed"` in both | the export check; the `.catch` branch |
| B4 | call `destroyed` before the routed import resolves (hold the route, then release it); call `disconnected` before resolve | spy module's `mounted` never called; attribute stays `"loading"`; no page error | the destroyed guard; optional chaining |
| B5 | `import("/build-home/logos.js")` | keys deep-equal `["claude","codex","deepseek","kimi"]`; `fill` is true only for deepseek and kimi; `LOGOS.muse`, `LOGOS.openrouter`, `LOGOS.gemini`, `LOGOS[undefined]`, `LOGOS.constructor`, `LOGOS.toString`, `LOGOS["__proto__"]` are `undefined`; `Object.getPrototypeOf(LOGOS) === null`; `Object.isFrozen(LOGOS)` and each entry frozen | adding a fallback entry; dropping `freeze`; a plain `{}` literal (the prototype names then resolve) |
| B6 | DeepSeek downscale parity (Pixel parity) | within the threshold | a bad re-encode (for example `-resize 8x8`) |

Mutation checks (AGENTS.md; run in a worktree, `git status --porcelain` shows
only the revert):
- Remove `build-home` from `@revalidated_static_paths`: T1 serving asserts and
  T3 fail. T2 still passes (router 401); that is expected for a guard.
- Remove the `Hooks.BuildHome` / fixture registration line: B1 fails.
- Replace the loader's `.catch` body with nothing: B2 fails (attribute stays
  `"loading"`, not `"failed"`).
- Add a `muse` entry that points at the Claude logo: B5 and T3 fail.
- Build `LOGOS` from a plain `{}` instead of `Object.create(null)`: B5 fails.
- Re-encode DeepSeek at 8×8: B6 fails, by at least 2× the threshold.

Commands (isolated HOME, per the "mix test clobbers agent-token" note):

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- \
  mix test test/aiur/extensions_test.exs
env -C src/browser npm run test:build-home-assets
```

Manual check: none required. The assets are inert until C3-T01; their first
user-visible proof is C3-T01's and C9-T06's manual run.

## Completion and handoff

- [ ] `build-home/` served, revalidated and authenticated through one list entry;
      no router or controller change.
- [ ] Loader, stub hook, `LOGOS`, empty `home.css` and both PNGs in place;
      Kimi byte-identical; DeepSeek re-encoded with the size and numbers recorded.
- [ ] Root layout and fixture layout carry the script, the stylesheet link
      (after `dashboard.css`) and the `BuildHome` registration.
- [ ] T1, T3 and B1–B6 pass, and each fails under its mutation above; T2 passes
      and is marked as a regression guard.
- [ ] No docs change (reason in step 8).
- **Dependents:** C3-T01 (hook name `BuildHome`, health attribute), C2-T04
  (`build-home/home.css`), C9-T01 (`build-home/hook.js`, export
  `createBuildHomeHook`, sibling modules under `build-home/`), C8-T01, C8-T02,
  C9-T05, C9-T06, C9-T12, C10-T02, C10-T04, C11-T01, C11-T03, C11-T07 (`LOGOS`
  keys; unknown → `.ax-mono`).
- **Interface notes for neighbours (raise in their docs):**
  1. Settled 2026-10-08: the hook file is `src/priv/static/build-home/hook.js`
     (export `createBuildHomeHook`, hook name `BuildHome`).
  2. C2-T04's brief says "decide whether the section lives in `dashboard.css`
     or a second file; a second file must be registered in `StaticAssets`". This
     ticket makes that choice: `build-home/home.css`, already registered and
     linked. Settled 2026-10-08: the path is `src/priv/static/build-home/home.css`;
     this ticket creates and links it, and C2-T04 only fills it (its §4.1
     `<link>` edit at `layouts.ex:290` is not added a second time; its "links in
     order" serving assert stays valid).
  3. C3-T02 must send the initial snapshot as a reply to the hook's first
     request, not as an unprompted `push_event` after mount. The hook's
     `handleEvent` listeners exist only after the module import resolves.
  4. C3-T01's loading skeleton (EC-01) must show a failure state for
     `data-build-home-hook="failed"`, and it cannot rely on that attribute when
     the loader script itself never ran.
  5. **C1-T01 → C2-T03.** Settled 2026-10-08: this is a `blocked_by` edge. B6
     reads the original DeepSeek PNG from C1-T01's in-tree copy, and C3-T01
     needs both, so the critical path does not change.
  6. C1-T02's "C2-T03 (mismatch)" note asks C2-T03 either to take C1-T02 as a
     blocker or to drop the C1-T02 proof. This ticket drops it: B6 is the proof
     here, and the element-level re-check runs in C9-T06/C10-T04 through
     C1-T02 once those slots exist. This ticket does **not** add the
     `designAssetOverrides` option C1-T02 mentions.
  7. `LOGOS` has a null prototype, so a consumer may read `LOGOS[k]` for any
     payload key without `Object.hasOwn`. C9-T06's `Object.hasOwn` check is
     still correct.
- **Sources:** `../plan.md` §5 (Assets), `../chunks.md` MP-E8-C2,
  `README.md` row MP-E8-C2-T03, `../../../owner-design-tasks/DESIGN-E8.md` S-13,
  `../design-source/IMPORTED.md`, `../claude-design-source-of-truth.md`.

## Decisions made without the owner

1. **Token SVGs are out of scope.** The row says the home page uses the
   design's token SVGs under their own names. The home page does not use any
   token SVG (0 references in `build.js`, `build.css` and the HTML), so none is
   shipped. The crosswise naming between the trees is recorded above for
   whoever next touches the provider token icons.
2. **Claude and Codex reuse `/provider-assets/*`.** Their content equals the
   design's except for one trailing newline. A second copy would only add drift.
3. **Logos and the stylesheet live inside `build-home/`,** so the single list
   entry covers them. PNGs therefore revalidate (ETag) instead of using the
   one-year cache that `aiur-logo.png` gets. The cost is one 304 per logo per
   full page load; the gain is no second registration.
4. **The loader URL is a constant,** not a data attribute as in the DOM-SVG
   loader. Nothing needs to vary it, and a constant removes a validation path.
5. **The loader also forwards `disconnected` and `reconnected`,** which the
   DOM-SVG loader does not, so C9-T01 never edits the loader.
6. **Health attribute words are `loading`, `mounted`, `failed`,** never
   `ready`, so no value can be read as "data ready".
7. **`home.css` is loaded on every page,** like `dashboard.css`, to avoid a
   style flash on live navigation. It is empty until C2-T04.
8. **DeepSeek is re-encoded at 74×74 RGBA** (3 × 24.05 px, rounded up to even),
   not at the row's 2× (50×50): phones commonly render at `devicePixelRatio` 3,
   and this pack targets phones. The file is about 3.7 KB, so the cost is
   nothing. If B6 fails, 100×100.
   Kimi (12 KB) is not re-encoded: its size does not justify any parity risk.
9. **Complexity 2, not 1.** The row's 1 assumed file drops only. The loader
   contract, its six browser cases and the downscale check are about half a day.
10. **`LOGOS` has a null prototype.** Payload keys are server data; with a
    plain object, `LOGOS["constructor"]` is truthy and a consumer that reads
    `LOGOS[k]` (C9-T05's sketch does) would render a broken `<img>` instead of
    the S-13 letter circle.
11. **Stylesheet path `build-home/home.css`,** the name C2-T04 (which owns
    the content) and C9-T01 use.
12. **Blocked by C1-T01.** B6 needs the original DeepSeek PNG on `main`.
    C1-T01 already commits the design copy; a second 413 KB copy in this
    ticket would only add drift.
13. **T2 is kept as a regression guard.** It cannot fail when the `build-home`
    entry is removed, because the router's `:dashboard_auth` catch-all also
    answers 401. It is marked as a guard and not counted as coverage.

## Review log

Adversarial review, 2026-10-08, against `runtime/src` at `58854d4c8` and
`design-source/` (etag 1791431544512943).

1. T2's "fails without" claim was false: without the entry, `router.ex:198`
   (under `:dashboard_auth`) still answers 401. T2 is now a marked regression
   guard; the mutation list no longer claims T2 fails. Router fallback added to
   the starting point.
2. Traversal 400: `Phoenix.ConnTest` re-raises `InvalidPathError`, so T1 now
   uses `assert_error_sent 400`.
3. T1 read the design files from `docs/research/...`, which is not on `main`.
   It now asserts sha256 constants (Kimi full hash; the two SVG hashes
   computed in this review).
4. B6 read the original PNG from the same research path. It now reads C1-T01's
   in-tree copy; added the merge-order note (dependencies, interface note 5,
   decision 12).
5. Stylesheet renamed `home.css` → `build-home.css` to match C2-T04, which
   owns the content and plans to add the same `<link>`; interface note 2 now
   tells C2-T04 not to add it again and C9-T01 to fix its name.
6. DeepSeek re-encode 50×50 at DPR 2 → 74×74 at DPR 3 (phones). Trial encode
   with ImageMagick 7.1.2-27 gave 74×74 RGBA, 3,660 B. Added the border-box
   note on the 24.05 px slot.
7. B6 threshold made fixed (no "if C1-T02 has merged" branch); the mutation is
   now 8×8 and must exceed the threshold by 2×, so the check cannot pass
   vacuously.
8. `LOGOS` given a null prototype; B5 now checks `constructor`, `toString`,
   `__proto__` and the prototype; new mutation. C9-T05 reads `LOGOS[k]`
   without `Object.hasOwn`.
9. B1 named a non-existent `window.BuildHome`; now
   `window.BrowserHarnessHooks.BuildHome`. Browser cases now use a fresh page
   each (module map cache would make B2's second run and B3 vacuous).
10. Added the "module `mounted` throws" case to B3 and the non-happy table; the
    disconnect-before-ready row now explains why dropping is safe
    (`pushHookEvent` rejects, LV 1.1.33 `:5421-5430`).
11. Read-only row no longer claims T1 covers it (not applicable).
12. Citation fixes: provider descriptor paths are
    `lib/aiur/coding_agent/providers/{claude,codex}.ex` (and their token icons
    are crossed live, `:53`, `:55`); `browser_harness.js:29-49`; design
    `MODELS` lines claude J:83, codex J:84; alphabetical slot `:16`/`:17`;
    fixture loader goes before `browser_harness.js` (`:38`).
13. Dependents list completed with C8-T02, C9-T05, C9-T12, C10-T04, C11-T03,
    C11-T07 (all read `LOGOS`); C1-T02's mismatch note answered (interface
    note 6). Front matter gains `owns_edge_cases: []` like its siblings.

Verified unchanged: `static_assets.ex:13-27, 77-78, 92-99, 146-151`;
`endpoint.ex:31, 33-40, 80-85`; `Plug.Static` 1.20.3 `:152-154, 208-212,
217-218, 239-247, 476-482`; `layouts.ex:38, 40-41, 45, 54, 252-254, 268-270,
290`; `fixture_server.exs:30, 37, 39, 97-99, 101-104, 2315-2321`;
`extensions_test.exs:1042, 1059-1071, 1144, 1490, 1542-1545`;
`package.json:10`; `browser-helpers.mjs:12`; Kimi and DeepSeek sizes and
hashes; the SVG trailing-newline diff; 0 token-SVG references in the design;
C:58, 139, 280, 282, 493, 516, 655, 759, 782, 816-817, 895, 1065; J:82-87, 358,
672, 989, 1018.
- Reconciliation 2026-10-08 (coordinator): stylesheet path `build-home/home.css` everywhere in the body (R-G8; Decision 11), C1-T01 -> C2-T03 is a `blocked_by` edge (predecessor line, concurrency line, interface note 5, Decision 12), interface notes 1, 2 and 5 settled.
