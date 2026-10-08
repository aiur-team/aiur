---
ticket_id: MP-E8-C2-T04
feature_id: MP-E8
chunk_id: MP-E8-C2
bucket: 2-platform
title: Consolidated home stylesheet from build.css
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C1-T02, MP-E8-C2-T01, MP-E8-C2-T03]
complexity: 4
design_gate: DESIGN-E8
owns_edge_cases: [EC-28]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C2-T04: Consolidated home stylesheet from `build.css`

> **The design is the specification** ([../claude-design-source-of-truth.md](../claude-design-source-of-truth.md)).
> This ticket moves the design's CSS into the product. It must not change one
> computed value. "Clean up" here means: delete rules that never match, fix the
> file layout, remove declarations that can never win. It never means "restyle".

Abbreviations: `C` = `design-source/assets/build.css` (1193 lines),
`H` = `design-source/Aiur Dashboard.html`, `J` = `design-source/assets/build.js`.
Product paths are at `58854d4c8` under `src/`. **PROPOSED** marks a path that
does not exist yet.

## 1. Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C2
  (shell, tokens, palette, fonts, assets, CSS).
- **User value:** the home page gets the design's exact look from one
  maintained stylesheet. Every later visual ticket (C9, C10, C11) writes markup
  against these rules and does not port CSS itself.
- **Deliverable:**
  1. PROPOSED `src/priv/static/build-home/home.css`: every home-page rule
     from `C`, plus the `H` inline rules that match home-page elements (§4.3),
     in the design's cascade order, minus the dead rules (§4.4).
  2. A computed-style parity spec, PROPOSED
     `src/browser/tests/home-css-parity.browser.spec.mjs`. It proves that the
     product's stylesheets give each design element the same computed style
     as the design does.
  3. A census script, PROPOSED `src/browser/support/home-css-census.mjs`. It
     lists, for each rule, the elements it matches across the fixture matrix.
     It is the evidence for each deletion.
  4. A spec that proves other dashboard pages do not change when the sheet loads.
- **Non-goals:**
  - No markup, hook or LiveView. C9, C10 and C11 render the DOM. C3-T01 mounts the page.
  - No tokens, palettes, `body` wash or fonts. C2-T01 does these.
  - No shell rules (`.ax-top`, `.sidenav`, `.snav*`, `#decisions-banner`, `.page-head`).
    C2-T02 does these.
  - No new visual states: focus rings (S-12), forced colours (EC-19, C12-T05),
    unknown-value styling (C8-T01).
  - No change to the design's fallbacks `var(--ph, 60)` (12 sites),
    `var(--ph, 90)` (1 site) and `var(--pct, 0%)` (24 sites). All 37 are on
    lines this ticket owns (§4.2). See §6, row N-9.
  - No serving code and no layout link. C2-T03 creates the empty
    `build-home/home.css`, links it after `/dashboard.css` and tests the
    serving (its items 4 and T1/T2). This ticket only fills the file.

## 2. Dependencies and blockers

- **DESIGN-E8.** This is the gate for implementation (E8-D6). This ticket has no
  S-item of its own. It follows the S-1 default: the shell, tokens and Gruvbox
  apply app-wide.
- **MP-E8-C1-T02** (the side-by-side runner). This ticket uses these parts of it:
  - the design-page loader (static design files, `?example=<dataset>`,
    `switchTab("build")`);
  - frozen `Date`, `TZ=America/Los_Angeles`, local fonts and local d3;
  - the wait for the 600 ms boot timer (J:1565);
  - the allowlist of approved differences.
  The parity spec uses whatever C1-T02 exports, and does not copy it.
- **MP-E8-C2-T01** (tokens, Gruvbox, body, fonts). Every home rule reads
  `var(--…)` tokens. If C2-T01 is not merged, every colour is different.
- **MP-E8-C2-T03** (assets and the `build-home/` entry). That ticket adds the
  `build-home` entry to `@revalidated_static_paths`, creates the empty
  `build-home/home.css` ("C2-T04 fills it", its deliverable 4), adds the
  `<link>` after `layouts.ex:290` and after `fixture_server.exs:39`, and tests
  the 200/`text/css`/revalidation/auth and the link order (its T1, T2). This
  ticket fills the file (a `blocked_by` edge; see "Interface notes" in §9).
- **Not blocked by C2-T02** (shell restyle). The parity spec puts the home
  roots in a wrapper that carries the design's inherited values and width
  (§4.5). Thus the shell is not part of the comparison. The full-page check
  after C2-T02 and C9 is C1-T02's screenshot run.
- **May run concurrently with** C2-T02, C3-T01..T03, and the server track (C4–C8).
- **Successors:** C9-T01 (hook shell, row predecessor), and every C9, C10 and C11
  visual ticket. These tickets edit this file after this ticket merges, in the
  order the work-order gives (tickets/README.md "File conflicts").

## 3. Verified starting point (`58854d4c8`)

**How static CSS is served today**
- `src/lib/aiur_web/static_assets.ex:13-27` `@revalidated_static_paths`, which
  includes the `aiur-dom-svg-layout` directory entry (`:14`). `:28`
  `@long_lived_static_paths`. `:63` `@dashboard_css File.read!(...)`: the file
  is read at compile time and served from memory (`:70`). `:92-99`
  `served_path?/1` matches the first path segment against both lists.
- `src/lib/aiur_web/endpoint.ex:31` `plug(:authenticate_static_asset)`, then
  `:33-40` `Plug.Static` with `only: revalidated_static_paths()` and
  `cache_control_for_etags: "private, max-age=0, must-revalidate"`. `:80-85`
  `authenticate_static_asset/2` sends any `served_path?` request through
  `FinancialDataAccess.authenticate_request/2`. Result: a file under
  `priv/static/build-home/` is served from disk with auth and revalidation.
  It needs no route, no controller clause and no recompile.
- `src/lib/aiur_web/router.ex:114` `get("/dashboard.css", ...)` and
  `controllers/static_asset_controller.ex:12, 68-84` (`serve/3`,
  `cache_control/1`) are the fallback for the embedded copy.
- `src/lib/aiur_web/components/layouts.ex:290` `<link rel="stylesheet" href="/dashboard.css" />`
  is the only stylesheet link in the root layout.
- `src/test/browser/fixture_server.exs:39` links `/dashboard.css`. `:2315-2322`
  mounts the same `Plug.Static` (revalidated paths), so the browser harness
  serves `build-home/` with no change.

**`dashboard.css` (10,417 lines, 223 KB): rules that also hit home elements**
- `:147-149` `* { box-sizing }`, which is the same as H:126.
- `:151-155` `html { scroll-behavior: smooth }`. The design has none.
- `:171-174` `a { color: var(--accent-ink) }`. The design has `var(--accent)` and `a:hover` (H:146-147).
- `:176-179` `button, textarea { font: inherit }`. The design also has
  `cursor: pointer` (H:149).
- `:181-184` `button, a { -webkit-tap-highlight-color: transparent }`. The design
  has no such rule. Chromium reports this property in `getComputedStyle`, so the
  parity spec sees it on every home `a` and `button`.
- `:194-204` `.mono, …` with the font stack `"JetBrains Mono", "SFMono-Regular",
  Consolas, monospace`. The design's `.mono` (H:141-143) has
  `"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace`.
  `:206-209` `.num` has the same values as H:144.
- `:186-192` `:focus-visible` outline. This applies only when an element has focus.
- `:3396-3411` `.btn`, `:3413` `.btn:hover`, `:3418` `.btn.ghost`, `:3424`
  `.btn.danger`. These collide with the design's `.btn` family (H:1343-1362). The
  product's `.btn` also sets `justify-content: center`, `min-height: 2.25rem`,
  `font-weight: 650` and `var(--on-accent)` ink. The design's `.btn` does not.
- `:6865-6873` a global `prefers-reduced-motion` rule: `animation-duration` and
  `transition-duration` `0.01ms !important`, `iteration-count: 1`, and
  `scroll-behavior: auto`. The design has only targeted reduced-motion rules (C:348, `.bd-root.rm`).
- No `.bd-*`, `.cv-*`, `.bm-*`, `.lr*`, `.mm*`, `.tk-backdrop`/`.tk-modal` or
  `.ax-pop` selector exists in `dashboard.css`. `.tk-search*` (`:10104+`) is a
  different family.

**Guards in `src/test/aiur_web/dashboard_css_theme_test.exs`. The design breaks both inside `dashboard.css`:**
- `:169-175` refutes `dashed`, `stroke-dasharray` and `repeating-linear-gradient`.
  `C` uses `dashed` 28 times (for example, C:203 `.bd-mk.brk` and C:733
  `.lst.st-queued`). It uses `repeating-linear-gradient` on 7 lines (C:150, 203, 267, 352, 412, 733 and
  975), for the planned-card hatch and the break marker.
- `:29-43` with `:296-302` freezes literal `color: #hex` lines. `C` paints
  `color: #fff` at C:59 (`.ax-mono`), C:283 (`.bd-gl`, dead, §4.4), C:544
  (`.cv-new`) and C:564 (`.cv-send`). The regex is line-anchored, and `C` uses
  one-line rules, so the guard does not see these.
- `:183-198` asserts that `.btn` takes its ink from on-fill tokens. The design's `.btn`
  paints `#fff` on `--accent`.

**The design source**
- `C` sections: shell (C:5-47), APIs and models (49-81), build root (82-97),
  features, filters, toolbar, viewport, now band, cards, states, agent glow
  (98-301), tiers, skeleton, modal additions (303-349), then override passes
  v3-v10 (350-1026), a light pass (961-988), Gruvbox (1027-1158), and late
  fixes (1160-1193).
- At-rules: 9 `@keyframes` (`bdPulse` C:223, `bdRot` 295, `bdStuck` 296, `bdAg`
  400, `cvIn` 511, `cvFlash` 513, `cvDot` 550, `cvRec` 563, `bdTreeIn` 677).
  One `@property --bd-a` (C:226). 11 `@container` queries (named `bd`: 900, 820, 640, 560 and
  460 px; unnamed: 132, 150, 96, 980 and 640 px). `@media`: 1180 px (C:941,
  1024) and 720 px (C:604, 644, 723) on lines this ticket owns; 960/961 px only
  on shell lines (C:40, 928, 994, 1008, owned by C2-T02); 560 px only on the
  dead `.bd-m-grid` rule (C:347). `prefers-reduced-motion` at C:348 and C:610.
- 79 `!important`. 28 `:hover`, 4 `:has()`, 42 `::before`/`::after`,
  `::-webkit-scrollbar` (C:167, 508, 945). Two inline-SVG grain data URLs with
  `%23n` (C:1125-1139; `baseFrequency='1.1'`, opacity .09, `mix-blend-mode: overlay`;
  light mode uses `multiply` and `invert(1)`).
- `C` uses keyframes that it does not define: `khSpin` (C:323 `.bd-spin`), which
  is defined at H:720. The modal uses `tkin` (H:1599).
- Roots that `J` renders into: `#build-root` (H:1910), `#tk-backdrop`
  (H:2058-2063), and `body > .ax-pop` (J:1054, `document.body.appendChild`).
- Cascade order in the design: the inline `<style>` (H:12-1818), then
  `assets/build.css` (H:1819).

## 4. Chosen design

### 4.1 A separate file, linked after `dashboard.css` on every page

The sheet is PROPOSED `src/priv/static/build-home/home.css`. C2-T03
creates it empty and links it directly after `layouts.ex:290` (this ticket only
checks the order):

```heex
<link rel="stylesheet" href="/dashboard.css" />
<link rel="stylesheet" href="/build-home/home.css" />
```

Reasons, smallest first:
- **No new serving code.** The `build-home` directory entry from C2-T03 serves
  it through `Plug.Static`, with auth (endpoint.ex:31, 80-85) and
  revalidation (`:38`). It needs no route, no controller clause and no
  compile-time embed.
- **It keeps two existing guards true.** In `dashboard.css`, the design's dashes,
  hatches and `#fff` button ink fail `dashboard_css_theme_test.exs:169-175` and
  `:183-198`. Those guards express the existing pages' style. The home page
  follows its own approved design.
- **The design's order is kept.** The design loads its inline styles, then `build.css`.
  The product loads `dashboard.css` (which contains the C2-T01/T02 ports of the inline styles), then this sheet.
- **It loads on every page, not only on home.** Live navigation inside
  `live_session :dashboard` does not re-render the root layout. A link that
  depends on the page would therefore be missing after a live navigation into
  home, and a link in the LiveView body would load late and flash. One
  revalidated request (a 304 after the first load) costs less. §8 T-8 proves
  that the sheet changes nothing on other pages.

### 4.2 Line ownership in `C`

The split is by line range, so nothing is ported twice or dropped:

| Lines of `C` | Owner | Content |
| --- | --- | --- |
| 5-28, 34-47, 899-929, 991-1009, 1077, 1147; the `.ax-menu` selector at 983 | C2-T02 | Shell, top bar, cog menu, sidenav, drag, decisions banner and page head |
| 1027-1049, 1067-1076, 1141-1146 | C2-T01 | Gruvbox custom-property blocks, `--bg` overrides, `body` wash |
| **Everything else:** 29-32, 49-898, 930-990 (983 without `.ax-menu`), 1010-1026, 1050-1066, 1078-1140, 1148-1193 | **C2-T04** | All home elements, including the Gruvbox and light-theme rules that target `.bd-*`, `.ax-seg`, `.ax-mono`, `.ax-uc`, `.cv-ev`, `.bm-ep` and `.lr-ep` |

The element rules inside the Gruvbox block (C:1050-1066, 1148-1158) stay in
this sheet. Later rules override them with `!important` (for example, C:1187
`.bd-now, html[data-palette="gruvbox"] .bd-now`), so their order relative to
the rest of `C` is load-bearing. If they move into `dashboard.css`, they load
before C:49-1026, and that order changes.

### 4.3 The `H` inline rules that this sheet also carries

The census (step 2) finds every `H` inline rule that matches an element under
the three home roots. These rules are known now:
- **Ticket modal frame:** H:1595-1636 (`.tk-backdrop`, `.tk-backdrop.show`,
  `.tk-modal`, `.tk-head`, `.tk-close`, `.tk-title-row`, `.tk-body`, `.tk-section`,
  `.tk-h`, `.tk-desc`, `.tk-dep*`, `.tk-event*`, …) and `@keyframes tkin` (H:1599).
  C11-T01 builds the markup and the behaviour. The CSS is in this sheet.
- **`@keyframes khSpin`** (H:720), used by `.bd-spin` (C:323).
- **The `.btn` rules that match.** `J` emits `.btn` 4 times: the offline banner
  `#bd-retry` `.btn.secondary.sm` (J:1066, under `#build-root`), the blocking
  question card `.btn.sm` and `.btn.secondary.sm` (J:1406, modal conversation
  of an agent in state `command`), and "Add to queue" `.btn.secondary.sm`
  (J:1438, modal of an `nq` ticket). So the census is expected to match `.btn`,
  `html[data-theme="light"] .btn`, `html[data-theme="light"] .btn.secondary`,
  `.btn:hover`, `.btn svg`, `.btn.secondary`, `.btn.secondary:hover` and
  `.btn.sm` (H:1343-1350, 1352-1355, 1361). `.btn.ghost`, `.btn.danger`,
  `.btn.good` and `.btn:disabled` (H:1351, 1356-1360, 1362) match no design element and
  are **not** ported unless the census reports a match. A later ticket that
  emits one of them ports its rule.
- **Base rules** H:141-144 (`.mono`, `.num`; C2-T01 hands them to this ticket,
  its non-goals) and H:146-149 (`a`, `a:hover`, `button { cursor: pointer }`).
- Any other rule that the census reports. Its line goes into the census output
  and into the sheet, in `H` order, before the rules from `C`. If one of them is
  inside `@media (pointer: …)` or `@media (hover: …)` (H has these at
  H:617-681), the matrix gets the touch variant in §8.

Rules from `H` whose selector can match on other pages (element selectors, and
class names that `dashboard.css` also defines: `a`, `button`, `.btn*`, `.mono`,
`.num`) are scoped with zero added specificity, so the order of `C` is
unchanged. The `.tk-*` modal rules are ported verbatim: no product markup or
`dashboard.css` rule uses any of their class names (checked 2026-10-08; the
product's `tk-*` names are the `.tk-search*` table family).

```css
:where(.bd-root, .tk-backdrop, .ax-pop) a { color: var(--accent); text-decoration: none; transition: color 140ms ease; }
:where(.bd-root, .tk-backdrop, .ax-pop) .btn { /* H:1343-1347 verbatim */ justify-content: normal; min-height: auto; }
```

A product rule that sets a property the design never sets (`.btn`
`justify-content`, `min-height`; `a, button` `-webkit-tap-highlight-color`)
is reset to the design's computed value in the same scoped rule. The parity
spec finds these properties. Do not guess them.

### 4.4 Dead rules: delete, with evidence

A rule is deleted only when **both** are true: it is on the work-order list,
and the census shows that it matches zero elements in every captured state.
The one exception is `.bd-fd` (see its row). These are the work-order classes,
checked against `J` and `H` on 2026-10-08 (line lists from
`grep -nE '\.<class>([^a-zA-Z0-9_-]|$)'` on `C`):

| Class | Lines in `C` | Why it is dead |
| --- | --- | --- |
| `.bd-now-g` | 217-221, 298 (part) | Not emitted by `J` |
| `.bd-mock`, `.bd-tg`, `.bd-prop` | 29 (part), 86-91, 221 | Mock "Demo data" controls (plan §10 item 5); not emitted |
| `.bd-m-*` | 327-347 | Old modal tiles; not emitted |
| `.bd-now-strip` | 825-831, 887, 968, 986, 1011-1012, 1053, 1057 (parts) | Not emitted |
| `.bd-more` | 413, 1090 (part) | Not emitted |
| `.bd-gl` (**exact class**) | 283-286, 300, 312-313, 395 | Not emitted. **`.bd-glow` (287-299, 348, 462, 705, 972-973) is live**, because J emits `<span class="bd-glow">` |
| `.bd-fa` | 133-135 | Not emitted |
| `.bd-fd` | 238, 364 (part), 1183, and the comment at 1182 | **Exception to the zero-match rule:** J:829 emits it, so the census matches it. C:1183 hides it with `display: none !important`, and C9-T05 does not emit it ("No feature dot"). The census runs after the §4.5 step 2 removal of `.bd-fd` nodes, and T-5 skips this class |
| `.bd-card.compact` | 304-307 | `J` sets the tier as a class (`"bd-card " + det`, J:820), but the tiers are only `bar`, `mini`, `line` and `full` (J:389, J:809). `det === "compact"` at J:841 is dead code |
| `.bd-root.narrow` | 84 | Not emitted |
| `.lay-tiles`, `.lay-stack` | 802-805, 839-840 | `J` emits only `lay-cols`/`lay-rows` (J:1030) |
| `.bd-feats`, `.bd-fp` | 29 (part), 99-105 | Rendered only under `if (false)` (J:1072-1073) |
| `.bd-mk.wave` | 207-209 | Not emitted as a class |
| `.bd-zb` | 152-154, 418 and 425 (parts) | CSS-only; never in the DOM (the zoom buttons are `.bd-zoom [data-z]`) |
| `#bd-fit` | 638 | Not emitted |
| `.bd-card.line.gt` | 658 (part) | Not emitted; `.bd-card.line.tall` in the same list is live |

Rules for a selector list: remove the dead selector only, and keep the rest.
For example, C:29 keeps `.ax-acc span, .ax-uh span, .bd-fg, …` and loses `.bd-mock > *`,
`.bd-tg` and `.bd-fp`. C:298 keeps `.bd-root.rm .ag-stuck .bd-glow` and
`.bd-root.rm .bd-skel i`, and loses `.bd-root.rm .bd-now-g b i`.

If the census reports other zero-match rules, they are **not** deleted. A state
that the matrix does not capture can use them. The PR body lists them for C12-T03.

### 4.5 How the parity spec works (the DOM transplant)

Before C9 there is no product home DOM. The spec therefore tests the
**stylesheets** against the **design's own DOM**:

1. On the design page (C1-T02 loader), set a state from the matrix in §8. Then
   serialise:
   - the `outerHTML` of `#build-root`, `#tk-backdrop` and each `body > .ax-pop`;
   - the attributes of `<html>` (`data-theme`, `data-palette`, `class`) and the
     inline style of `<body>`;
   - from `#build-root.parentElement`: its content-box width and its inherited
     computed properties (`font-*`, `line-height`, `color`, `letter-spacing`,
     `text-*`, `visibility`, `cursor`, `direction`, `white-space`).
2. On the product origin (the fixture server, with auth), `page.route` returns a
   bare document. The document has only the `<link>`s of the product, in the
   layouts.ex order, and one wrapper `div` that carries the values from 1.
   The spec then injects the roots. It removes `.bd-fd` nodes, because the
   product never renders them (§4.4).
3. The two trees are the same clone, so the spec pairs elements by document
   order. It asserts equal node counts and equal tag names first.
4. For each pair, it compares:
   - every longhand that `getComputedStyle` returns;
   - `::before` and `::after` when `content` is not `none`;
   - the custom properties that either sheet declares (`--ec`, `--board-bg`,
     `--bd-a`, `--r`, `--sat`, …), read with `getPropertyValue`.
   Values are compared as strings. They are not normalised.
5. **Sheet-level checks:** the `cssText` of each `@keyframes` and
   `@property` rule that the home DOM uses is the same in both pages.
6. On a mismatch, the spec writes `home-css-diff.json` to the artifact
   directory (state, element path, class list, property, design value,
   product value). The failure message shows the first 50 differences.
   An entry passes only when it is on the C1-T02 allowlist (`approved`, or
   `pending-sign-off`, which passes in CI and fails only in the C12-T08
   `--gate` run). The spec reads C2-T01's six `design-style` AA hold entries
   and accepts the held value wherever an element's colour resolves from a
   held token.

### 4.6 Fold overrides only when it is provably safe

The override passes stay in their order, and the version headers ("v3" … "v10",
"v8 fixes") are renamed by subsystem. A declaration is removed only when a later
rule has the **same selector text**, the same `@media`/`@container` context and
equal or higher importance, and sets the same property. That later rule always
wins, so the earlier declaration can never apply. The census script lists these
"shadowed declarations". No rule moves to a different place in the file, because
the order is load-bearing (C:1085, 1115, 1122 and 1187 each set the `.bd-now`
background with `!important` under the same selector text, and only C:1187
wins in dark mode; the light-mode overrides at C:1086, 1116, 1123, 1157 and
1188 are a second chain).

## 5. Implementation steps

1. **Census script** (`src/browser/support/home-css-census.mjs`, PROPOSED).
   Input: a page in a matrix state. For each rule in `build.css` and in the `H` inline
   sheet, run `querySelectorAll` with the selector, with pseudo-elements and the
   user-action and state pseudo-classes (`:hover`, `:focus`, `:focus-visible`,
   `:focus-within`, `:active`, `:visited`, `:disabled`, `:checked`) removed.
   Keep the structural ones (`:not`, `:is`, `:where`, `:has`, `:first-child`,
   `:nth-*`, …), because `querySelectorAll` evaluates them and removing them
   changes what the selector means. Removing a state pseudo-class can only add
   matches, so a zero count is still proof. Rules inside `@media` and
   `@container` count whether or not they are active.
   Keep only matches under the three roots. Output: `{rule, source line, match count per state}`
   and the shadowed-declaration list from §4.6. Save the output to the artifacts. Do not commit it.
2. **Run the census** over the matrix. Confirm that each class in §4.4 has zero
   matches. Record the `H` rules that match (§4.3).
3. **Write `home.css`:** the `H` rules from step 2 (scoped as in §4.3, in
   `H` order), then the C2-T04 lines of `C` (§4.2) in order, without the dead
   selectors and the shadowed declarations. Header comment: the source etag
   1791431544512943, and the instruction "do not restyle; regenerate parity
   on every change".
4. **Check the link.** C2-T03 already links the file after `layouts.ex:290`
   and after `fixture_server.exs:39`. Do not add a second link. If the link is
   missing, C2-T03 is not merged and this ticket is still blocked.
5. **Parity spec** (`home-css-parity.browser.spec.mjs`, PROPOSED) as in §4.5.
   Add `"test:home-css"` to `src/browser/package.json`
   (`node scripts/run-browser-tests.mjs tests/home-css-parity.browser.spec.mjs`)
   and add it to the `"test"` chain (`package.json:10`).
6. **Other-pages spec** (in the same file). For each explicit fixture LiveView
   route (`fixture_server.exs:2270-2278`: `/`, `/commands`, `/units`,
   `/ticket-context`, `/provider-meters`, `/meter-row`, `/quota-panel`,
   `/fixture`), capture the computed styles of all elements twice: once with
   `/build-home/home.css` routed to an empty body, once with the real
   file. The two captures must be equal. The spec first asserts that at least
   one route renders a `.btn` and at least one renders an `a` (for example the
   Units "Reset Units filters" `.btn.ghost`,
   `components/operator_control_center/units_table.ex:155`; drive the fixture
   into the state that shows it). Otherwise it fails with "T-8 has no target",
   so the T-8 mutation cannot pass on an empty match.
7. **Theme guard for the new file.** In `dashboard_css_theme_test.exs`, add one
   test that freezes the literal hex inks in `home.css`. The frozen list
   is the set that the written file has, and each entry has a comment with its
   source line: `#fff` at C:59, C:544 and C:564, and the H `.btn` inks that are
   ported (H:1345, H:1349). The regex is not line-anchored and does not match
   `background-color:` or `border-color:`:
   `~r/(?<![\w-])color:\s*(#[0-9a-fA-F]{3,8})\b/`. Any new literal then fails,
   and the debt is visible. Do not change the existing guards.
8. **Serving.** No new test. C2-T03's T1 and T2 already assert 200, `text/css`,
   `cache-control: private, max-age=0, must-revalidate`, the auth rejection,
   and the link order for `build-home/home.css`. Run them unchanged.
9. **Mutation checks** (§8). Run them in a worktree and record them in the PR body.

## 6. Non-happy paths and edge cases

| # | Input | Expected | Test |
| --- | --- | --- | --- |
| N-1 | A selector list where only one selector is dead (C:29, C:298) | The live selectors keep their declarations. `.bd-root.rm .bd-skel i` keeps `animation-name: none` | T-1, state `rm` on the skeleton |
| N-2 | `.bd-gl` and `.bd-glow` share a prefix | Only the exact class `.bd-gl` is deleted. `.ag-active .bd-glow` keeps `opacity: 0.9` and the conic background | T-1 (`live`, active card) and T-3 |
| N-3 | `@property --bd-a` is left out | `--bd-a` on `.bd-glow` reads `0deg` in the design. Without the rule it reads empty, and the rotation stops | T-2 |
| N-4 | `khSpin` or `tkin` is not ported | `.bd-spin` has no animation. The modal opens with no `tkin` | T-2 (the keyframes set is equal) |
| N-5 | A product rule leaks into a home element (`.btn` `min-height: 2.25rem`, `a` colour, `button` cursor) | Reset in the scoped rule. The values match the design | T-1 (modal open, `.btn`); T-6 mutation |
| N-6 | A home rule leaks into another page (`.lr`, `.lh`, `.c-id`, `.c-tt`, `.c-ep`, `.c-ag`, `.c-dp`, `.cv`, `.mm` have no prefix guard, C:505-771) | No element on other pages changes. If T-8 finds a leak, scope that rule with `:where(.bd-root, .tk-backdrop, .ax-pop)` | T-8 |
| N-7 | Container-query boundaries (card at 150/96 px, lane at 132 px, root at 900/820/640/560/460 px) | Equal computed styles on both sides of each boundary | T-1 span set {1, 7, 30} and the widths in §8 |
| N-8 | Media boundaries 1180/1181 and 720/721 (the only `@media` widths on this ticket's `C` lines, §3), plus the width of any ported `H` `@media` rule | Equal on both sides | T-1 boundary widths |
| N-9 | An unknown progress value | Not handled here. This ticket keeps `var(--ph, 60)` and `var(--pct, 0%)` byte for byte, because they are the design. C8-T01 owns the unknown rule, and it must add a rule in this sheet (see §9) | T-1 keeps them equal. T-4 checks that the 37 fallback sites are present |
| N-10 | The grain data URL is re-encoded by an editor (`%23n` becomes `#n`) | The filter breaks: no grain on `.bd-now::after`, `.ax-uc::after` or `.bd-lanes::after` | T-1 compares the `background-image` string of `::after` |
| N-11 | The sheet is missing in a release, or the request is not authenticated | 404 or the auth rejection. The page renders without styles and does not hide it. A test makes this visible before release | C2-T03 T1/T2 (T-7) |
| N-12 | A stale cached sheet after an upgrade | `must-revalidate` causes a fetch of the new file at the next load | C2-T03 T1 checks the header (T-7) |
| N-13 | Reduced motion (`prefers-reduced-motion: reduce`) | The design's `.rm`, C:348 and C:610 rules apply. The product's global rule (dashboard.css:6865-6873) also sets durations to `0.01ms`. In the reduce variant only, the spec does not compare `animation-duration`, `animation-iteration-count`, `transition-duration` or `scroll-behavior`. Every other property must match | T-1 reduce variant. Frame parity is C1-T03 (EC-19) |
| N-14 | Theme and palette (EC-28): dark and light × Gruvbox and default | Equal in all four, including the Gruvbox `.bd-*` rules that have `!important` overrides | T-1 base matrix |
| N-15 | Skeleton before data (EC-01, `S.loading`) | The skeleton classes `.bd-skel*`, `.bd-loading` and `.bd-spin` match | T-1 state captured before the 600 ms timer |
| N-16 | Offline or stale dataset (`.bd-root.stale`, `.bd-offline`) | The grey glow `filter: grayscale(1) blur(5px)`, `opacity: .35`, paused animation | T-1 `offline` dataset |

Security: the sheet is static, and it is served behind the same auth as
`dashboard.css`. It has no `url()` other than the two `data:` SVGs. The router's
`put_secure_browser_headers` (router.ex:34, 38) sets no CSP, so nothing blocks
the data URLs.

## 7. Compatibility and rollout

- No config, CLI or environment change. No docs page changes. This is an
  internal stylesheet, and the home page docs come with C12.
- Every page loads one more revalidated stylesheet. The PR states its byte size
  (expected: below the 110,503 bytes of `build.css`, because dead rules are
  removed). It claims no saving. C12-T06 measures page weight.
- Until C3-T01 and C9 render home markup, the rules match nothing, so the
  change is inert on a live daemon.
- Rollback: revert the file to the empty C2-T03 version and the T-9 test. The link stays (C2-T03). Nothing else depends on the
  file until C9-T01 merges.

## 8. Verification

### Pixel parity

- **Design elements reproduced:** all of `C` except the C2-T01 and C2-T02 lines
  (§4.2), plus H:141-149, H:720, the matched `.btn` lines of H:1343-1361 (§4.3)
  and H:1595-1635. Values that must
  stay exact, and that T-1 checks one by one:
  - card motion `left/width .34s cubic-bezier(.22,1,.36,1)` and `opacity/filter .25s` (C:227);
  - the active glow `bdRot 9s linear infinite` with `blur(6px)`, opacity .9 (C:288);
  - the stuck glow `bdStuck 3.2s ease-in-out infinite` (C:289);
  - the pulse `bdPulse 2s ease-in-out infinite` on `.bd-now-h > b i` (C:382)
    and `.bd-live i` (C:719), and 1.4 s on the skeleton (C:318);
  - `cvIn .32s cubic-bezier(.22,1,.36,1)` (C:510), `cvFlash 1.2s` (C:512),
    `bdTreeIn .22s ease-out` (C:675) and `tkin` (H:1599);
  - the now band `position: sticky; top: 46px; z-index: 7` (C:215) and its final
    dark background `color-mix(in srgb, color-mix(in srgb, #000 12%, var(--board-bg)) 82%, transparent) !important`
    (C:1187; it overrides C:1085, 1115 and 1122);
  - the grain at opacity .09 with `overlay`, and in light mode `multiply` and
    `invert(1)` (C:1125-1139), then `display: none` in light mode (C:1158).
- **Check 1: computed-style parity (T-1).** This is the authoritative check for
  this ticket (plan K-7).
- **Check 2: C1-T02 element screenshots** of `.bd-vpw`, `.bd-now`, `.tk-modal` and
  `.ax-usage` on the transplanted page against the design, at C1-T02's
  anti-aliasing threshold. This catches what `getComputedStyle` cannot read:
  `::-webkit-scrollbar` (C:945) and the rendered result of `backdrop-filter` and blend modes.
- **The matrix:**
  - **Base:** datasets `live`, `dense`, `newrepo`, `noqueue`, `offline` × views
    `graph`, `gantt`, `list` × `dark`/`light` × `gruvbox`/default, at 1440 px
    (60 states).
  - **URL variants** on `live`, dark, Gruvbox, at 1440, 1024 and 390 px:
    `live=min`, `trees=1`, `models=2`, `models=7`, `span` 1/7/30,
    `feature=<first key>` with `fmode` `focus` and `compact`, one `epic` filter.
  - **Interaction states:** the modal open on the first `.bd-card.now`; the
    modal open with `?ticket=a3` (agent state `command`, J:206: the blocking
    question card with `.btn.sm`, J:1406); the modal open on the first `nq`
    ticket in the list view ("Add to queue" `.btn.secondary.sm`, J:1438); the
    first filter popover open; `.bd-lt` lock and tree view; the skeleton before
    600 ms. **Hover:** for each `:hover` rule (28 in `C`, plus the ported `H`
    ones), hover the first element that matches it, in both pages, and compare
    that element and its subtree.
  - **Boundary widths:** 1181/1180 and 721/720, on `live`, in the graph view and
    with the modal open, plus both sides of each `max-width` of a ported `H`
    `@media` rule. (960/961 and 560/561 have no `@media` rule on this ticket's
    lines, §3.)
  - **Touch variant:** only if a ported `H` rule is inside `@media (pointer: …)`
    or `(hover: …)`: `live`, dark, Gruvbox, 390 px with `isMobile` and
    `hasTouch` (C1-T02 cell options).
  - **Reduced motion:** the base matrix for `live` with `reducedMotion: 'reduce'` (N-13).

### Tests

| ID | Test | Expected | Fails without |
| --- | --- | --- | --- |
| T-1 | `home-css-parity` "computed styles match the design" (every matrix state) | Zero differences outside the allowlist | Any rule of the sheet missing or changed. Example mutation: delete the `.ag-stuck .bd-glow` rule, and the `live` stuck card fails on `box-shadow` and `animation-name` |
| T-2 | `home-css-parity` "keyframes and @property match" | The `cssText` sets are equal for the 9 + `khSpin` + `tkin` keyframes and for `@property --bd-a` | Removing `@property --bd-a`, or `@keyframes khSpin` |
| T-3 | `home-css-parity` "dead classes are absent" | No selector in `home.css` names a class from §4.4 (`.bd-gl` is matched as an exact class, so `.bd-glow` is not caught) | Restoring any deleted rule (for example `.bd-m-grid`) |
| T-4 | `home-css-parity` "design fallbacks are kept" | 13 `var(--ph, 60)`/`var(--ph, 90)` and 24 `var(--pct, 0%)` sites | Replacing one fallback |
| T-5 | Census guard (it passes on main; it guards the deletion list against a future re-import, and says so in its name) | Each class in §4.4 except `.bd-fd` matches 0 elements in the design DOM over the matrix | A design re-import that starts to use one of those classes |
| T-6 | `home-css-parity` "product rules do not leak into home elements" (a subset of T-1, named for review) | The offline `#bd-retry` `.btn.secondary.sm` and the `?ticket=a3` `.btn.sm` have the design page's `min-height` (`auto`), `justify-content` (`normal`), `font-size`, `font-weight` and `color`; each home `.mono` has the design's `font-family`; each home `a` has the design's `-webkit-tap-highlight-color` | Removing the reset from the scoped `.btn` rule (dashboard.css `:3401` then gives `2.25rem`); removing the scoped `.mono` rule (dashboard.css `:194-204` stack then wins) |
| T-7 | Not this ticket: C2-T03 T1/T2 cover serving, auth and link order | Unchanged and green | — (owned by C2-T03) |
| T-8 | `home-css-parity` "other pages are unchanged" | The computed styles on each fixture route are equal with the sheet empty and with the real sheet; the target precondition (§5 step 6) holds | Removing the `:where(…)` scope from the ported `.btn` rule (the product `.btn` then loses `min-height: 2.25rem` and `justify-content: center`) |
| T-9 | `dashboard_css_theme_test.exs` "home sheet literal inks are frozen" | The set of literal hex `color:` values equals the frozen list; `background-color: #…` does not count | Adding a new `color: #…` to the sheet |

**Mutation discipline (AGENTS.md).** For T-1, T-2, T-3, T-4, T-6, T-8 and T-9: in a
worktree, apply the mutation in the column, then run the test. It must fail.
Restore the change, and it must pass. Before each run, `git status --porcelain`
shows only that one mutation. Paste the commands into the PR body. T-5 is a
declared future guard, and it does not count as coverage.

**Commands:**

```bash
# browser (fixture server, Chromium). TZ is set by the C1-T02 runner
env -C /path/to/worktree/src/browser npm run test:home-css
# other pages' screenshots stay green (K-2)
env -C /path/to/worktree/src/browser npm run test:visual
# ExUnit, with HOME isolated (see the memory note "mix test clobbers agent-token")
env -C /path/to/worktree/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur_web/dashboard_css_theme_test.exs
# C2-T03's serving tests stay green (run its named file unchanged)
```

No manual TUI test applies: this ticket adds no Executor-visible behaviour.

## 9. Completion and handoff

- [ ] `home.css` exists. It holds the §4.2 lines and the §4.3 `H` rules, in order, with no dead selectors.
- [ ] C2-T03's link after `/dashboard.css` in `layouts.ex` and in `fixture_server.exs` is present (no second link added).
- [ ] T-1 to T-9 pass (T-7 is C2-T03's). Each mutation in §8 fails, and the PR body records it.
- [ ] The census output (its rule list, the zero-match list for C12-T03, the
      shadowed declarations it removed) is attached to the PR as an artifact.
- [ ] The PR body states the byte size of the file. It also lists the contrast of
      each white-on-fill control (`.btn` as `.btn.sm`, `.cv-new`, `.cv-send`, `.ax-mono`) in the 4
      theme × palette combinations, for the DESIGN-E8 sign-off (S-22, Decision 4).
- [ ] `npm run test:visual` is unchanged.
- **Dependents:** C9-T01 and every C9, C10 and C11 visual ticket. They add
  their own rules to this file. They do not edit the ported lines. If they must
  edit a ported line, they re-run T-1.

### Interface notes for neighbour rows

1. **C2-T03 → C2-T04.** Settled 2026-10-08: C2-T03 creates the empty
   `src/priv/static/build-home/home.css`, links it and tests the serving; this
   ticket's `blocked_by` has C2-T03.
2. **C2-T01 line range.** The row gives C2-T01 "C:1027-1076, 1141-1154". This ticket
   takes the element rules in that range (C:1050-1066, 1148-1154). C2-T01 keeps only the
   custom-property and `body` blocks (1027-1049, 1067-1076, 1141-1146). Reason:
   cascade order (§4.2).
3. **C2-T02 line range.** The row gives C2-T02 "991-1016". Lines 1010-1016 are
   home rules (progress hues, `.ax-seg`, `.bm-st`), and this ticket takes them.
   C2-T02 keeps 991-1009 and the `.ax-menu` selector of C:983.
4. **C2-T01 / C2-T02, base rules.** `html { overflow-x: hidden }` (H:153),
   `html { scrollbar-gutter: stable }` (H:154) and `::selection` (H:150) are
   page-level. This ticket does not port them. Settled 2026-10-08: C2-T02 owns
   H:150 and H:152–154 (and C:1147). C2-T01 hands
   H:140–148 (`.mono`, `.num`, `a`, `button`) to this ticket; this ticket takes
   them (§4.3).
5. **C11-T01.** Settled 2026-10-08: the modal CSS (H:1595-1636) and `tkin` are
   this ticket's; C11-T01 does the markup and behaviour only.
6. **C8-T01 / C9-T05 (unknown progress).** C8-T01 says "an unknown pct sets neither
   `--pct` nor `--ph`". With neither set, the CSS fallback `var(--ph, 60)` paints
   the amber tone, and `var(--pct, 0%)` shows an empty fill. The unknown state
   needs its own rule in this sheet, for example on a `data-pct="unknown"`
   attribute. That rule is a new visual (an S-item), not a port, so C8-T01 or
   C9-T05 must add it.
7. **C9-T05** must not emit `.bd-fd` (it already says "No feature dot"). This ticket
   deletes the rule that hides it.
8. **File name.** Settled 2026-10-08: the file is
   `src/priv/static/build-home/home.css` in every ticket (C2-T03 creates and
   links it; this ticket fills it).
9. **`.btn` variants not ported.** `.btn.ghost`, `.btn.danger`, `.btn.good` and
   `.btn:disabled` (H:1351, 1356-1360, 1362) match no design element, so they
   are not in this sheet (§4.3). A C10 or C11 ticket that emits one ports its
   rule with the same `:where(…)` scope and re-runs T-1 and T-8.

## Decisions made without the owner

1. **A separate file, loaded on every page** (§4.1), instead of a section in
   `dashboard.css`. The work-order asked the writer to choose. The existing
   dash, hatch and `.btn`-ink guards would fail inside `dashboard.css`, and live
   navigation does not re-render the root layout.
2. **The ownership of each line range** (§4.2) differs from the C2-T01 and C2-T02
   rows, so that the cascade order stays the same.
3. **The `H` rules are ported with `:where()` scoping** and reset only the
   properties that the product adds. The `.btn` family keeps the design's look
   on the home page and the product's look elsewhere.
4. **The design's white ink on fills is ported exactly,** although the product moved
   `.btn` to on-fill tokens for WCAG AA (`dashboard_css_theme_test.exs:177-182`
   records 3.51:1 for `#fff` on the old accent). The source-of-truth doc says:
   "If you think something in the design is wrong, raise it … Do not change it
   yourself." The PR measures each contrast, and the result goes into the DESIGN-E8 sign-off
   package as S-22 (`.btn` `#fff` contrast). If Kevin asks for AA, the fix is one token per control in this file.
5. **Reduced-motion durations are excluded from the comparison** (N-13). The
   product's global rule is an accessibility feature, and it stays. Frame parity under
   reduced motion is C1-T03 (EC-19).
6. **Only the listed dead rules are deleted,** and only with census evidence. Other
   zero-match rules are reported, not deleted.
7. **No override folding beyond shadowed declarations** (§4.6). No rule moves.
   This is the smallest change that still gives one ordered sheet.
8. **The parity spec transplants the design DOM** instead of waiting for the C9
   markup. It isolates the stylesheet from the shell (so C2-T02 is not a
   blocker) and from the hook port.
9. **`.bd-fd` is deleted although the design DOM contains it.** Its only rule
   that wins is `display: none !important` (C:1183), and C9-T05 never emits
   it. Deleting it is the one case where the census is not the evidence.
10. **Only the `H` rules that match a design element are ported** (census
    driven). The unmatched `.btn` variants wait for the ticket that emits them.
11. **No serving test of our own.** C2-T03 owns the file's existence, serving,
    auth and link; this ticket adds no duplicate ExUnit file.

## Sources

- Work-order row: [tickets/README.md](README.md) "MP-E8-C2-T04"; chunk
  [../chunks.md](../chunks.md) MP-E8-C2; plan [../plan.md](../plan.md) §5, §9 K-2/K-7, §10, §11.
- Design: `design-source/assets/build.css`, `design-source/Aiur Dashboard.html`
  (etag 1791431544512943, imported 2026-10-08), `design-source/assets/build.js`.
- Product: the paths in §3, at `58854d4c8`.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8` and `design-source/`.

1. Fallback counts: 12 `var(--ph, 60)` + 1 `var(--ph, 90)` + 24 `var(--pct, 0%)`; all on this ticket's lines.
2. Scope: C2-T03's ticket already creates the empty file, the link and the serving tests. Removed the duplicate link step and the new `build_home_css_test.exs` (T-7 now points to C2-T03 T1/T2). Kept C2-T03 in `blocked_by`.
3. §3: added two product leaks that the parity spec would hit: `button, a` tap highlight (`dashboard.css:181-184`) and `.mono` font stack (`:194-204`).
4. §3: C:544 is `.cv-new`, not `.cv-send`; C:283 (`.bd-gl`) is a fourth `#fff`, dead.
5. §3: `!important` count 64 → 79; `::-webkit-scrollbar` also at C:167, 508; second reduced-motion rule C:610; `@media` widths mapped to owners (960 px is shell only, 560 px is the dead `.bd-m-grid`).
6. §4.3: `J` emits `.btn` 4 times (J:1066, 1406 ×2, 1438), not 3 times in the modal. Only matched `.btn` rules are ported; ghost/danger/good/disabled are not. Added H:141-144 (`.mono`, `.num`). Scoping limited to selectors that can match other pages; `.tk-*` verbatim (no product overlap, checked).
7. §4.4 line lists corrected by grep: `.bd-more` 1090 (not 1086); `.bd-gl` 312-313 and 395 added, "parts of 297-299" removed; C:395 removed from the live `.bd-glow` list. `.bd-fd` marked as the one exception to the zero-match rule. `.bd-card.compact` reason corrected (J:820 does emit the tier as a class; tiers are bar/mini/line/full).
8. §4.6: the `.bd-now` override example cited C:1082/1107/1113 (a box-shadow rule, `.bd-now-sum .bad`, a blank line). Now C:1085/1115/1122/1187.
9. Census: strip only state pseudo-classes, keep structural ones.
10. T-8: `/analytics` and `/build-orders` are not fixture routes; replaced with `fixture_server.exs:2270-2278`. Added a target precondition, and a mutation that is sure to change a product `.btn`.
11. T-9: the regex `color:\s*#…` would also match `background-color:`; now uses a look-behind. Frozen list is the written file's set, with source lines.
12. N-8 and boundary widths: dropped 960/961 and 560/561 (no rule on this ticket's lines); added widths of ported `H` media rules and a conditional touch variant.
13. Pixel parity: `bdPulse 2s` cited the dead `.bd-now-g` (C:219); now C:382 and C:719. Final now-band background is C:1187, not "C:1113".
14. Matrix: added modal states that render `.btn` (`?ticket=a3`, an `nq` ticket); the first `.bd-card.now` modal has none.
15. T-6: the `.btn` the design emits is `.btn.secondary`/`.btn.sm`, so "#fff-based colour" was wrong; it now compares with the design page's values and covers `.mono` and tap highlight.
16. Interface notes: 1 updated; 4 corrected (H:150, 153-154; both C2-T01 and C2-T02 claim them); new 8 (file name `home.css` in 13 tickets) and 9 (unported `.btn` variants).
17. Contrast list in §9 matches the ported white-on-fill controls (`.btn.sm`, `.cv-new`, `.cv-send`, `.ax-mono`).

Residual risks: the census may find more `H` rules and product leaks than §3/§4.3 list (by design, the spec finds them); ownership of H:150/153-154 needs an Executor decision; the T-8 `.btn` target depends on a fixture state that shows one.
- Reconciliation 2026-10-08 (coordinator): stylesheet path `build-home/home.css` everywhere in the body (R-G8), dead-rule list adds `.bd-mk.wave` (C:207–209), `.bd-zb`, `#bd-fit`, `.bd-card.line.gt` (C:658), parity spec reads C2-T01's `design-style` hold entries and pending passes in CI, `.btn` `#fff` contrast = S-22, interface notes 1, 4, 5 and 8 settled (C2-T03 edge, H:150/152–154 to C2-T02, modal CSS and `tkin` here, file name).
