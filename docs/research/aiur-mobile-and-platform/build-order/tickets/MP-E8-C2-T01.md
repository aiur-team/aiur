---
ticket_id: MP-E8-C2-T01
feature_id: MP-E8
chunk_id: MP-E8-C2
bucket: 2-platform
title: Tokens, Gruvbox palette, body wash, self-hosted fonts
status: blocked
blocked_by: [DESIGN-E8, MP-E8-C1-T02]
complexity: 3
design_gate: DESIGN-E8
design_items: [S-1]
owner_questions: [OQ-E8-1]
owns_edge_cases: [EC-28]
base_sha: 58854d4c8
researched: 2026-10-08
---

# MP-E8-C2-T01 — Tokens, Gruvbox palette, body wash, self-hosted fonts

> **Read first:** [../claude-design-source-of-truth.md](../claude-design-source-of-truth.md)
> (pixel-perfect mandate). Design copy: [../design-source/](../design-source/)
> (etag 1791431544512943). `H` = `Aiur Dashboard.html`, `C` = `assets/build.css`,
> `J` = `assets/build.js`. Product paths are at `58854d4c8` under `src/`.
> PROPOSED marks paths that do not exist yet.

## Identity and outcome

- Bucket 2, feature MP-E8 (continuous build history home page), chunk C2 (shell,
  tokens, palette, fonts, assets, CSS).
- **User value:** every dashboard page uses the design's colour tokens, the
  Gruvbox palette as the default, the design's page background, and the
  design's typefaces from the dashboard itself. Before this ticket the dashboard
  names Space Grotesk and JetBrains Mono but never loads them, so most machines
  draw a fallback face. No later visual ticket can match the design without this.
- **Deliverable:**
  1. The design's dark and light tokens (H:22–124) in `dashboard.css` `:root` and
     `html[data-theme="light"]`, with two new tokens (`--pill-bd`, `--ack-soft`)
     and design-name aliases (`--attn*`, `--block*`).
  2. The Gruvbox token blocks and body wash (C:1028–1049, 1067–1076, 1141–1146)
     as the default palette, `data-palette="gruvbox"` on `<html>`.
  3. The design body rule (H:128–139). The page-level base rules next to it
     (H:150 `::selection`, H:152–154 `html { overflow-x: hidden;
     scrollbar-gutter: stable }`) belong to C2-T02 (see Decisions 11).
  4. Palette persistence: `localStorage["aiur-palette"]`, restored in the head
     before the stylesheet (no flash), and a `PaletteToggle` hook.
  5. An interim palette button beside the theme button in today's top bar.
     C2-T02 moves it into the cog menu.
  6. Space Grotesk and JetBrains Mono self-hosted as woff2 under `/fonts/`.
  7. The parity runner's design side serves the same Google Fonts response that
     the design really loads (H:9), not C1-T02's variable-range table (see
     Chosen design, "Design-side fonts").
- **Non-goals:**
  - Component rules that are palette-scoped but style elements (`.bd-card`,
    `.bd-now`, `.ax-seg`, `.ax-mono`, `.cv-ev`, `.bd-tn` … C:1050–1066,
    C:1147–1193). They go to C2-T04.
  - `.ax-top` (C:7, 903, 1077, 1147), `--navw` (C:992), the cog menu, H:150
    `::selection` and H:152–154 (`html` overflow / scrollbar-gutter). These go to C2-T02.
  - `--board-bg`. It is a scoped variable on `.bd-vpw` (C:1119–1120), not a
    root token. It goes to C2-T04 (see Decisions).
  - Button fills (`.btn`, `--accent-strong`) under Gruvbox. These go to C2-T02 and C2-T04.
  - The Stream Deck chassis pins (`dashboard.css:9667–9680`), which stay as they
    are (light theme only, as today; see Compatibility).
  - The rest of the design's base rules (H:140–148: `.mono`, `.num`, `a`,
    `button`). C2-T04 scopes them to the home roots.
  - Forced colours (EC-19, C12-T05).

## Dependencies and blockers

- **Blocked by DESIGN-E8** (Kevin's go) and **MP-E8-C1-T02** (the side-by-side
  runner and its page loaders, which this ticket's parity spec reuses).
- **OQ-E8-1 / S-1 is a default, not a blocker.** Default: the tokens and the
  palette apply app-wide (plan §10 item 21). If Kevin says "home page only", scope
  the palette blocks to the home page's root instead. The token values stay the same.
- **Successors that consume this ticket's interface:**
  - C2-T02 mounts `phx-hook="PaletteToggle"` on `#ax-palette` (H:1837) and
    removes the interim `#palette-toggle`. The hook sets `aria-checked` on a
    `role="menuitemcheckbox"` element and `aria-pressed` on a plain button, so
    C2-T02's request for `aria-checked` (its interface note 2) works unchanged.
  - C2-T04 ports the rest of `build.css` against these tokens. It must **not**
    re-declare C:1028–1049, 1067–1076, 1141–1146 (its §4.2 agrees).
- **Interface mismatches with neighbour tickets** (recorded, not silently fixed):
  - C:1147: Settled 2026-10-08: C2-T02 ports C:1147 (`.ax-top` in Gruvbox
    light); this ticket does not.
  - H:150 / H:152–154: Settled 2026-10-08: C2-T02 owns them (Decisions 11).
  - C1-T02 serves the design side's fonts from `routeFonts`
    (`website/tests/support/visual.ts:8–29`), which declares Space Grotesk as one
    `300 700` variable face. The design really loads Google's discrete
    400/500/600/700 faces (H:9). This ticket changes the design-side font route
    in C1-T02's PROPOSED `design-parity.mjs` (step 13).
- May run at the same time as C3-*, C4–C8. It may run with C2-T03, but both edit
  `static_assets.ex` and `layouts.ex` (different lines), so the second to merge
  rebases. Do not run it at the same time as C2-T02 or C2-T04: all three edit
  `dashboard.css` and the shell, so merge in order (tickets/README.md).

## Verified starting point (`58854d4c8`)

- **Tokens.** `src/priv/static/dashboard.css`:
  - `:1–9`: the Bungee `@font-face` (`/bungee.woff2`, `font-display: swap`).
  - `:11–80`: the dark `:root` block. Comparing it with H:22–74, every value
    matches except `--faint` (`#8b8f99` here, design `#676b74`; the comment at
    `:20–21` pins it to WCAG AA). `--pill-bd` and `--ack-soft` are missing.
  - Tokens only the product has: `--accent-strong`, `--on-accent`, `--on-blocking`,
    `--progress-fill`, `--progress-complete-fill`, `--shadow-md`,
    `--shell-measure`, `--progress-bar-height`.
  - `:82–145`: the light block. It is a sepia theme (`--bg #e7d6b2`), not the
    design's warm paper (`--bg #f3f1ec`, H:76–124). `--muted` and `--faint` were
    AA-tuned (comment `:89–104`).
  - Naming: the product uses `--attention*` and `--blocking*` (131 `var()` uses
    in `dashboard.css`, more in `lib/aiur_web/operator_control_center/analytics/charts.ex`
    and `styles.ex`).
    The design uses `--attn*` and `--block*`.
  - `:151–155` is `html` and `:157–167` is `body`. The body font fallback is
    `"Avenir Next", "Segoe UI"`; the design's is `system-ui, -apple-system, "Segoe UI"`.
    The transition is `0.35s`; the design's is `0.4s`. `body` has
    `overflow-x: hidden` (`:160`); the design puts it on `html` (H:153) and adds
    `scrollbar-gutter: stable` (H:154).
  - No `data-palette` exists anywhere in `src/`.
- **Contrast gate.** `src/test/aiur_web/dashboard_css_theme_test.exs`:
  - `:211–241` "the contrast-critical token pairs still clear WCAG AA" grades
    `:root` and the light block (AA 4.5:1, non-text 3:1).
  - `:85–106` pins the Stream Deck chassis to the dark `:root` values.
  - `:306–311` `css_rule/1` reads only the first rule with a given selector.
- **Theme pattern.** `src/lib/aiur_web/components/layouts.ex`:
  - `:17` is `<html lang="en" data-theme="dark">`.
  - `:25–34` is the inline head restore of `aiur-theme`. It only accepts
    `light`/`dark`, wraps the read in `try`, and has no `prefers-color-scheme`
    fallback. The design's `initTheme` (H:5017–5021) has one.
  - `:54` is `var Hooks = {}`.
  - `:159–177` is `Hooks.ThemeToggle` (scoped to `this.el`, guarded `setItem`).
  - `:290` is the stylesheet link. The restore runs before it, so there is no flash.
- **Shell.** `src/lib/aiur_web/components/operator_control_center/dashboard_shell.ex`:
  - `:46–53` is `.topbar-controls`, which holds the pause button and
    `<.theme_button id="theme-toggle" />`.
  - `:178–200` is `theme_button/1`.
  - `src/test/aiur_web/live/dashboard_live_test.exs:683–716` asserts exactly one
    `ThemeToggle` and unique control ids.
- **Font serving** (Bungee is registered in four places):
  - `src/lib/aiur_web/static_assets.ex:28`: `@long_lived_static_paths ~w(aiur-logo.png bungee.woff2)`.
  - `static_assets.ex:47–55`: `@runtime_static_assets` (`"/bungee.woff2" => {"font/woff2", …}`).
  - `src/lib/aiur_web/router.ex:125`: `get("/bungee.woff2", StaticAssetController, :bungee_font)`.
  - `src/lib/aiur_web/controllers/static_asset_controller.ex:51–52`: the controller action.
  - `src/lib/aiur_web/endpoint.ex:42–49`: `Plug.Static` with `public, max-age=31536000`
    over the long-lived paths. `:31` and `:81–85`: `authenticate_static_asset`
    runs before `Plug.Static` and puts every `served_path?/1` path
    (`static_assets.ex:89–95`) behind dashboard auth.
  - The browser fixture endpoint has the same two `Plug.Static` plugs
    (`src/test/browser/fixture_server.exs:2315–2331`, revalidated and long-lived
    lists), and only then forwards to the production router (`:2287–2291`).
    So `Plug.Static` serves a long-lived file in both endpoints. The Bungee route
    (added in `e1df4ecb3`) predates the long-lived `Plug.Static` (`69795b0e2`,
    #1893) and is only reached when the file is missing.
  - `Plug.Static` decodes each segment and raises `InvalidPathError`
    (`plug_status: 400`) for `..` or an encoded `/`
    (`deps/plug/lib/plug/static.ex:152–154, 208–212, 476–482`). A missing file
    passes through to the router, whose catch-all answers 404
    (`router.ex:198`, `ObservabilityApiController.not_found/2`).
  - Test: `src/test/aiur/extensions_test.exs:1151–1153` (`/bungee.woff2` returns 200, `font/woff2`).
- **`dashboard.css` is read at compile time** (`static_assets.ex:6, 57, 63`,
  `@external_resource`), so verification needs `mix compile`.
- **Browser harness.**
  - `src/browser/support/visual.mjs:28–50` (`openVisualRoute`) seeds `aiur-theme`
    and mirrors the head restore, because the fixture layout has none.
  - `src/test/browser/fixture_server.exs:9`: the fixture `<html data-theme="dark">`.
    `:65–79` is a copy of `ThemeToggle` (without the `setItem`). `RouteShellLive`
    (`:117–118`, layout `FixtureLayout`) renders `DashboardShell.dashboard_shell`
    at `:148–173`, and handles `toggle-nav` at `:141`.
  - `website/tests/support/visual.ts:8–12` is the `routeFonts` families table
    that C1-T02 reuses for the design side: `Space Grotesk` `300 700` and
    `JetBrains Mono` `100 800`, each one variable file from
    `website/tests/fixtures/fonts/` (google/fonts `a54f7446`, not the Google
    Fonts css2 subsets). Under that table the design draws 550 as a true 550.
  - `src/browser/tests/visual-shell.browser.spec.mjs` snapshots `/`, `/build-orders`
    and `/analytics` at 1440/1024/390 in light and dark (K-2).
  - `src/browser/tests/support/browser-helpers.mjs:68–77` has `expectAuditClean`
    (axe `color-contrast`).
- **Design facts** (read in the imported copy):
  - H:7–9 loads Bungee, Space Grotesk 400–700 and JetBrains Mono 400–700 from Google Fonts.
  - H:1820 is the unguarded `getItem("aiur-palette") || "gruvbox"`.
  - H:1837 is `#ax-palette`, `role="menuitemcheckbox"`, `aria-pressed`, with the
    label "Gruvbox palette". (`aria-pressed` is not a valid state on a
    `menuitemcheckbox`; `aria-checked` is. C2-T02 ports the item with
    `aria-checked`.)
  - H:1819 loads `build.css` after the inline `<style>` (H:12–1818), so the
    Gruvbox blocks win over `html[data-theme="light"]` (both specificity 0,1,1)
    by source order. The product keeps that order by placing them after the light block.
  - H:5076–5078 toggles between `gruvbox` and `aiur`, saves the choice and syncs `aria-pressed`.
- **Google Fonts response**, fetched 2026-10-07 with a Chrome user agent (the same
  URL as H:9):
  - 39 `@font-face` rules. Space Grotesk v22 has 3 subset files (latin 22,288 B,
    latin-ext 18,940 B, vietnamese 6,712 B). JetBrains Mono v24 has 6 subset
    files (1.6–31.4 KB, about 66 KB in all).
  - Each family is **one variable file per subset**. The response declares it
    four times, with the discrete weights 400, 500, 600 and 700.
  - The design's CSS uses weight 550 (3 times) and 650 (once). With discrete
    faces, the browser draws them as 600 and 700. A plain variable `@font-face`
    (`font-weight: 300 700`) would draw a true 550, which does not match.
  - Google's Bungee latin file (sha256 `126eec70…`) differs in bytes from
    `priv/static/bungee.woff2` (sha256 `12967d74…`).

## Chosen design

**Token placement and naming.** The product names stay canonical, so the 131
`var(--attention…)`/`var(--blocking…)` uses and every existing test keep working.
The design's names are added as aliases in `:root`:

```css
--attn: var(--attention); --attn-ink: var(--attention-ink); --attn-soft: var(--attention-soft); --attn-line: var(--attention-line);
--block: var(--blocking); --block-ink: var(--blocking-ink); --block-soft: var(--blocking-soft); --block-line: var(--blocking-line);
```

The aliases are declared on `html`, the same element the palette blocks
override, so `var()` resolves to the active palette's value. The Gruvbox blocks
are ported value for value. The only change is a mechanical prefix rename
(`--attn` to `--attention`, `--block` to `--blocking`), noted in a one-line
comment that cites C:1028.

**Values.** Every value comes from the design, except the AA holds:

| Theme × palette | Source in design | Product rule |
| --- | --- | --- |
| dark × aiur | H:22–74 | `:root` (values already match except the hold) |
| light × aiur | H:76–124 | `html[data-theme="light"]` (replaces the sepia values) |
| dark × gruvbox | C:1028–1038, then C:1068 `--bg: #18191a` | `html[data-palette="gruvbox"]` |
| light × gruvbox | C:1039–1049, then C:1076, then C:1142–1145 (the last block wins: `--bg #f1eee6`) | `html[data-palette="gruvbox"][data-theme="light"]`, the three blocks merged in cascade order into one rule |

**AA holds (accessibility is never cut; ponytail, AGENTS.md).** The design's
`--faint` fails the existing gate in all four combinations. `--attn-ink` fails in
both light combinations. Ratios measured 2026-10-08 with the test's own formula:

| Token | Theme | Design value | Ratio on surface / behind pill-bg / tinted panel | Held value | Held ratio |
| --- | --- | --- | --- | --- | --- |
| `--faint` | dark × aiur | `#676b74` | 3.05 / 2.77 | `#8b8f99` (today's) | 5.03 / 4.57 |
| `--faint` | light × aiur | `#9a958c` | 2.98 / 2.81 | `#777269` | 4.78 / 4.51 |
| `--faint` | dark × gruvbox | `#928374` | 4.02 / 3.64 | `#a19487` | 4.99 / 4.52 |
| `--faint` | light × gruvbox | `#928374` | 3.58 / 3.34 | `#7b6e61` | 4.82 / 4.51 |
| `--attention-ink` | light × aiur | `#94650a` | panel 3.83 | `#855b09` | 4.52 |
| `--attention-ink` | light × gruvbox | `#b57614` | panel 2.89 | `#8b5a0f` | 4.51 |

Ratios re-computed by the reviewer on 2026-10-08 with the gate's formula
(`dashboard_css_theme_test.exs:242–288`); every other pair of the gate clears AA
with the design values in all four combinations (lowest: dark × gruvbox
"button fill against surface" 3.21, non-text minimum 3.0).

Five held values keep the design colour's HSL hue and saturation and move only
lightness, to the first step that clears every pair in the gate. The dark × aiur
hold is today's product value `#8b8f99`, which is already AA-tuned
(`dashboard.css:20–22`); it is not derived from the design hue. Each one carries
a `/* AA hold: design <hex>, pending Kevin (S-19) */` comment. Each one is a
C1-T02 allowlist entry (`src/browser/support/design-parity-allowlist.json`,
PROPOSED) of kind `design-style`, `selector: "html"`, `css` the held-token rule
(`:root[data-theme=…][data-palette=…] { --<token>: <held hex> }`), `cells`
limited to its theme and palette, and `approval.status: "pending-sign-off"` with
`ref` pointing at Decisions 1. C1-T02's loader already accepts that kind and
status (C1-T02 "Allowlist"), so no change to C1-T02 is needed. A pending entry
passes in CI and fails only in the C12-T08 `--gate` run, so Kevin's answer is
due before C12-T08.

**Palette state machine** (on `<html>`, two states):
- Server render: `data-palette="gruvbox"`. With JavaScript off, or storage
  blocked, the page shows the default.
- The head restore sets `data-palette="aiur"` only when storage holds exactly
  `"aiur"`. Any other value, a missing value or a throw leaves `gruvbox`.
- `PaletteToggle` click: `gruvbox` → `aiur` or `aiur` → `gruvbox`. It then tries
  `setItem` and syncs the state attribute: `aria-checked` when
  `this.el.getAttribute("role") === "menuitemcheckbox"` (C2-T02's `#ax-palette`),
  otherwise `aria-pressed` (this ticket's interim button). The value is
  `"true"` when the palette is `gruvbox`.
- The root layout is not patched by LiveView, so the attribute survives live
  navigation.

**Theme restore** gains the design's fallback (H:5020): a stored
`light`/`dark` wins; otherwise `prefers-color-scheme: light` gives light. The
restore stays in its own `try`, separate from the palette `try`, so one failure
cannot skip the other.

**Fonts.** Copy the 36 Space Grotesk and JetBrains Mono `@font-face` rules from
the Google response verbatim (including `unicode-range` and `font-display: swap`).
Only `src` is rewritten, to `url(/fonts/<family>-<version>-<subset>.woff2)`.
There are 9 files in PROPOSED `src/priv/static/fonts/`, plus the two SIL OFL 1.1
license texts. The versioned names make the one-year public cache safe. These
are the Google Fonts css2 subset files. They are not the google/fonts variable
files in `website/tests/fixtures/fonts/`, which the website tests keep using.
Bungee stays as it is unless the specimen check below fails. In that case, use
Google's three Bungee v17 faces in the same `fonts/` directory and delete the
four `bungee.woff2` registrations.

**Serving** (one line of product code, no route):
- `fonts` joins `@long_lived_static_paths` (`static_assets.ex:28`). `Plug.Static`
  matches the first path segment, so this one entry covers the directory, as
  `aiur-dom-svg-layout` does in the revalidated list. Both the production
  endpoint (`endpoint.ex:42–49`) and the fixture endpoint
  (`fixture_server.exs:2324–2331`) then serve `/fonts/*` with
  `public, max-age=31536000`, and `served_path?(["fonts" | _])` puts it behind
  dashboard auth (`endpoint.ex:31`).
- No `@runtime_static_assets` entry, route or controller action is added. The
  Bungee route is a pre-#1893 fallback that `Plug.Static` already shadows; a
  second copy of that pattern adds code and no behaviour (ponytail).
- What `Plug.Static` serves is every regular file in the directory, so the
  directory holds only the woff2 files, their two OFL texts (which the licence
  requires to travel with the fonts) and the README. Nothing secret goes there.
  `..` or an encoded `/` gets 400 (`InvalidPathError`); an unknown name falls
  through to the router catch-all and gets 404.

## Implementation steps

1. **Fonts.** Fetch the H:9 css2 URL with a current Chrome user agent and
   download the 9 woff2 files. Record the URL, the date, the per-file sha256 and
   the licence in PROPOSED `src/priv/static/fonts/README.md`. Add the `@font-face`
   block after `dashboard.css:9`.
2. **`static_assets.ex:28`.** `@long_lived_static_paths ~w(aiur-logo.png bungee.woff2 fonts)`.
3. *(Removed by review: no route or action; see Serving.)*
4. **`dashboard.css` `:root`** (`:11–80`). Add `--pill-bd: rgba(221, 226, 235, 0.14)`,
   `--ack-soft: rgba(79, 214, 196, 0.14)` and the 8 aliases. Keep `--faint` as the hold.
5. **`dashboard.css` light block** (`:82–145`). Replace each design-named value with
   H:76–124, plus `--pill-bd`, `--ack-soft` and the two holds. Keep the product-only
   tokens. Rewrite the AA comments so they name the held tokens.
6. **Gruvbox blocks**, inserted right after `:145`, before any component rule:
   - `html[data-palette="gruvbox"] { … }` with C:1028–1038 renamed, `--bg: #18191a`
     (C:1068) and the `--faint` hold;
   - `html[data-palette="gruvbox"][data-theme="light"] { … }` with C:1039–1049,
     then C:1076, then C:1142–1145, merged in that order (the last `--bg`,
     `#f1eee6`, wins), plus both holds;
   - `html[data-palette="gruvbox"] body { … }` (C:1069–1075);
   - `html[data-palette="gruvbox"][data-theme="light"] body { … }` (C:1146, `!important` kept).
7. **`body`** (`:157–167`): change the font stack to H:136 and the transition
   to `0.4s` (H:138). Leave `overflow-x: hidden` (`:160`) and the `html` rule
   as they are: H:150 `::selection` and the H:152–154 `html` overflow / gutter
   move (which takes `overflow-x` off `body` so sticky bars keep working) are
   C2-T02's.
8. **`layouts.ex`.**
   - `:17`: add `data-palette="gruvbox"`.
   - `:25–34`: two `try` blocks (theme with the media fallback, then palette).
   - After `:177`: add `Hooks.PaletteToggle`, with `mounted` (sync, then click
     listener), `updated` (sync again, because a LiveView patch puts the
     server's `aria-pressed="true"` back) and `destroyed`. `sync` picks
     `aria-checked` or `aria-pressed` by the element's role (Chosen design).
9. **`dashboard_shell.ex`.** Add `palette_button/1` after `theme_button/1`:
   `id="palette-toggle"`, `class="tool-btn icon-only"`, `phx-hook="PaletteToggle"`,
   `aria-pressed="true"`, `aria-label` and `title` "Gruvbox palette", and the
   H:1837 SVG with `aria-hidden`. Render it in `.topbar-controls` after the
   theme button. Mark it `<%!-- interim: C2-T02 moves this into #ax-menu --%>`.
10. **Test fixture parity.**
    - `fixture_server.exs:9`: add `data-palette="gruvbox"`.
    - Add a `PaletteToggle` copy next to `:65–79`, so the fixture shell mounts
      without an unknown-hook error. A comment points to the production test below.
    - Add a probe route that renders through the **production** root layout:
      `live_session :production_root, root_layout: {AiurWeb.Layouts, :root}`
      with a minimal PROPOSED `Aiur.BrowserHarness.PaletteProbeLive`
      (`layout: false`). It renders `DashboardShell.dashboard_shell` with
      `RouteShellLive`'s assigns, handles `toggle-nav` like `:141`, and renders
      one extra `<button role="menuitemcheckbox" phx-hook="PaletteToggle"
      id="probe-palette-item">` for the menu-item row. This is the only place
      the production head restore runs in the browser suite.
11. **Tests and snapshots** (Verification). Rebuild the `visual-shell` baselines
    on purpose and list every changed image in the PR (K-2).
12. **Design-side fonts in the parity runner** (C1-T02's PROPOSED
    `src/browser/support/design-parity.mjs`). Replace the design side's
    `routeFonts` use with a route that serves the css2 response **verbatim**:
    - check in the response body as PROPOSED
      `src/browser/support/fixtures/google-fonts-css2.css` (the same fetch as step 1);
    - map each `fonts.gstatic.com` URL in it to a local file: the 9 Space Grotesk
      and JetBrains Mono URLs to `src/priv/static/fonts/` (one copy of the
      bytes), and the 3 Bungee URLs to PROPOSED
      `src/browser/support/fixtures/google-fonts/` (Google's Bungee v17 subsets);
    - keep C1-T02's rule that an unknown font URL throws.
    The website's `routeFonts` is not changed. This makes the design side draw
    exactly what Kevin's browser draws from H:9.
13. **Docs.** In `website/docs-app/guide/gui.md`, add one short paragraph:
    - the theme follows the OS until it is toggled;
    - the palette button switches between Gruvbox (the default) and the aiur palette;
    - both choices are kept per browser.
    There is no config key or CLI change.

## Non-happy paths

| Input | Expected | Proved by |
| --- | --- | --- |
| No stored palette | `data-palette="gruvbox"`; dark `--bg` computes to `rgb(24, 25, 26)` | probe spec "default is gruvbox" |
| Stored `"aiur"` | `aiur` before the first frame; the first rAF reads aiur `--bg` (`rgb(22, 23, 26)`) | probe spec "no flash" |
| Stored `"solarized"`, `""` or `"GRUVBOX"` | `gruvbox` (the design would leave an unknown value and show aiur colours; see Decisions) | probe spec, three cases |
| `Storage.prototype.getItem` throws | `gruvbox` + OS-derived theme; no `pageerror` | probe spec "blocked storage" |
| No stored theme, `page.emulateMedia({ colorScheme: 'light' })` | `data-theme="light"` before the first frame | probe spec "theme follows OS" |
| Stored theme `"blue"`, OS light | `light` (an unknown value is ignored, then the OS decides) | probe spec "theme follows OS" |
| Stored theme `"dark"`, OS light | `dark` (a stored choice wins) | probe spec "theme follows OS" |
| `setItem` throws on click | the palette still toggles; `aria-pressed` updates; no `pageerror` | probe spec |
| A LiveView re-render after the toggle (`toggle-nav`) | `aria-pressed` still matches the palette | probe spec "survives patch" |
| Hook mounted on an element with `role="menuitemcheckbox"` (C2-T02's `#ax-palette`) | it sets `aria-checked`, not `aria-pressed` | probe spec "menu item role" (the probe LiveView renders one extra `role="menuitemcheckbox"` button with the hook) |
| 390 px wide, the extra top-bar button | no horizontal page scroll (`document.documentElement.scrollWidth <= innerWidth`) | probe spec at 390 px, and the rebuilt `visual-shell` 390 baselines |
| Gruvbox light cascade order | the effective `--bg` is `#f1eee6`, not `#ece2c4` or `#f2e5bc` | token parity spec (light × gruvbox) |
| Weight 550 / 650 text | drawn as 600 / 700, the same as the design | token parity spec, "Faces" |
| A glyph outside the shipped subsets (CJK title) | falls back through the design's stack (`system-ui …`), the same as the design | token parity spec, "Faces", compares the computed `font-family` and the probe width |
| `/fonts/nope.woff2` | 404 from the router catch-all (`router.ex:198`) | `extensions_test.exs` |
| `/fonts/..%2Fdashboard.css`, `/fonts/%2E%2E/dashboard.css` | 400 (`Plug.Static.InvalidPathError`); no file outside `priv/static/fonts/` is read | `extensions_test.exs` with `assert_error_sent(400, fn -> … end)` |
| Font request without dashboard credentials (auth configured) | rejected by `authenticate_static_asset`, as for Bungee | `extensions_test.exs` asserts `served_path?(["fonts", "x.woff2"])` and a 401 |
| A second tab | keeps its palette until reload (same as the theme; no `storage` listener) | documented; not built (ponytail) |

Unknown, stale or unavailable data: none. This ticket renders no data values, so
the AGENTS.md unknown-path mutation rule does not apply.

## Compatibility and rollout

- **App-wide visual change (K-2, S-1):**
  - every page switches to Gruvbox, and light × aiur switches from sepia to the
    design's warm paper;
  - the fonts now really load, so text metrics change on machines that lacked
    them;
  - `visual-shell` baselines and the `website/docs-app` dashboard screenshots
    change (the screenshots are refreshed in C12-T07).
- **The Stream Deck progress contract is unchanged.** `--progress-fill` and
  `--progress-complete-fill` are defined only in `:root` and are never palette
  overrides (the `dashboard_css_theme_test.exs:141` contract stays green).
  The emulator's ink is not frozen, though: the chassis pins
  (`dashboard.css:9667–9680`) apply only in the light theme, so in dark × gruvbox
  the emulator's `--fg`, `--accent`, `--good` … follow Gruvbox. That is what the
  design does (its `.sd-device`, H:777, has no pins at all), so this ticket keeps
  it. In light × gruvbox the pins (on `.sd-device`) still win over the palette
  block (on `html`).
- No config, no migration, no new runtime dependency. About 115 KB of fonts in
  the release, and a page downloads only the subsets it uses.
- `background-attachment: fixed` costs repaints on phone WebViews. C12-T06 measures it (EC-27).
- **Rollback:** revert the PR. A leftover `aiur-palette` key is ignored.

## Verification

ExUnit, with an isolated HOME (memory note "mix test clobbers agent-token"):

| Test | Expected | Fails without |
| --- | --- | --- |
| `dashboard_css_theme_test.exs` "contrast-critical token pairs" extended to dark/light × aiur/gruvbox; tokens merged from every matching rule in source order (new `css_rules/1` that returns all matches) | all pairs ≥ AA in all four | the holds (putting the design's `--faint` back fails 4 of 4) |
| same file, "design aliases resolve to the product families" | `:root` declares `--attn: var(--attention)` … `--block-line: var(--blocking-line)` | the alias lines (a static guard only; the behaviour proof is the token parity spec, where a missing alias leaves `var(--attn)` unresolved and the probe colour differs from the design) |
| same file, "gruvbox never overrides the progress contract" | no gruvbox rule declares `--progress-fill`/`--progress-complete-fill` | guard against a future regression (passes on main; named as a guard) |
| `extensions_test.exs` beside `:1151` | every `url(/fonts/…)` named in the served `/dashboard.css` returns 200 with `font/woff2` and `public, max-age=31536000` (the test reads the URLs from the CSS, so a missing file or a wrong name fails); `/fonts/nope.woff2` is 404; the two traversal paths are 400 | `fonts` in `@long_lived_static_paths`, the files, the `@font-face` block |
| `extensions_test.exs` `:1042` "bootstraps" | `/` HTML has `<html … data-palette="gruvbox"`; the `aiur-palette` restore comes before `/dashboard.css` | the attribute, the restore |
| `dashboard_live_test.exs` beside `:711` | exactly one `[phx-hook="PaletteToggle"]`, in `.topbar-controls`, `aria-pressed="true"` | `palette_button/1` |

Browser (Playwright, `src/browser/`):
- PROPOSED `tests/palette-probe.browser.spec.mjs`, against the production root
  layout: every row of the Non-happy paths table marked "probe spec".
- PROPOSED `tests/build-home-tokens.browser.spec.mjs` (Pixel parity below).

Mutation checks. Run each in a worktree. `git status --porcelain` must show only
the one revert. Each must turn its test red:
1. remove `data-palette="gruvbox"` from `layouts.ex:17`;
2. delete the palette restore;
3. delete the Gruvbox dark block;
4. swap the C:1142 and C:1076 merge order;
5. remove `fonts` from `@long_lived_static_paths` (the `extensions_test.exs` font row must fail);
6. *(Moved to C2-T02 with H:152–154.)*
7. replace the discrete-weight faces with one `font-weight: 300 700` face (the
   "Faces" 550 check must fail, which it can only do once step 12 serves the
   design side the discrete faces);
8. remove `updated` from the hook;
9. make `sync` always set `aria-pressed` (the "menu item role" row must fail);
10. put back any one held design value;
11. drop the `prefers-color-scheme` fallback from the theme restore (the
    "theme follows OS" rows must fail).

Commands:

```bash
env -C /path/to/worktree/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix compile --warnings-as-errors
env -C /path/to/worktree/src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur_web/dashboard_css_theme_test.exs test/aiur/extensions_test.exs test/aiur_web/live/dashboard_live_test.exs
env -C /path/to/worktree/src/browser node scripts/run-browser-tests.mjs \
  tests/palette-probe.browser.spec.mjs tests/build-home-tokens.browser.spec.mjs
env -C /path/to/worktree/src/browser npm run test:units   # axe color-contrast on Units under the new tokens
env -C /path/to/worktree/src/browser node support/visual.mjs --docker --update-snapshots   # K-2 baselines, then review every diff
```

Manual check: open `aiurdev` with the dashboard. Toggle theme and palette on
Units, Commands and Analytics. Reload: there must be no flash. In DevTools, check
that no request goes to `fonts.googleapis.com` or `fonts.gstatic.com`.

## Pixel parity

Design elements reproduced: H:22–124 (tokens), H:128–139 (body), C:1028–1049,
1067–1076, 1141–1146 (Gruvbox tokens and wash), H:7–9 (faces), H:1820 and
H:5076–5078 (palette persistence and toggle), H:5017–5021 (theme fallback).

Checked with C1-T02's loaders: the design served as static files with
`localStorage` seeded and `switchTab("build")`; the product on the fixture
shell route. Each check runs in the 4 theme × palette combinations at 1440 px,
with a frozen clock:
1. **Token values.**
   - The token list is every custom property declared on a rule whose selector
     is `:root`, `html`, or `html` plus `[data-theme]`/`[data-palette]`. It is
     read from `document.styleSheets` on the design page, minus `--navw`.
   - Each token is resolved on both pages through a probe element (`color:
     var(--x)`, or `box-shadow`/`border-radius` for the shadow and radius tokens),
     so that `0.20` and `0.2` compare equal.
   - Values must be equal. The only exceptions are the six AA holds, which must
     equal the held hex.
2. **Body wash.** The computed `background-image`, `background-color`,
   `background-attachment`, `font-family`, `line-height` and `transition` of
   `body` are equal (the `html`/`body` overflow and gutter are C2-T02's). A full-viewport screenshot of an empty body (children
   hidden on both pages) passes C1-T02's anti-aliasing floor.
3. **Faces.**
   - `document.fonts.check('600 16px "Space Grotesk"')` and the same for
     JetBrains Mono are true on the product, and the resource entries come from
     the product's own origin.
   - The design side loads its faces through step 12's verbatim css2 route.
     Under C1-T02's unchanged `routeFonts` table the design would draw 550 as a
     true 550 and this check would compare against the wrong design.
   - On both pages, a probe span is measured with
     `getBoundingClientRect().width` at weights 400, 500, 550, 600, 650 and 700,
     in both families. The widths must be equal across the pages, and 550 must
     equal 600.
   - A Bungee specimen ("aiur", 40 px) is compared with C1-T02's element mode.
4. **Other pages (K-2).** Rebuild the `visual-shell` baselines. The PR lists
   each changed image as an intended S-1 change.

A difference not in the allowlist is a failing test.

## Decisions made without the owner

1. **The AA holds** (table above). The design's `--faint` and light
   `--attn-ink` fail the existing WCAG AA gate. Lowering the gate cuts
   accessibility, so the six values are held at their nearest AA lightness, are
   marked in the CSS, and are listed for Kevin. **Sign-off item S-19**
   (final in DESIGN-E8.md): "accept the held values, or choose others that
   clear AA".
2. **Product token names are canonical.** The design's names are aliases, and the
   Gruvbox blocks are renamed mechanically. This avoids touching 131 uses and the
   existing tests.
3. **The `@font-face` rules are copied from Google's response**, with discrete
   weights. The goal is to draw 550/650 exactly as the design does, not as a
   cleaner variable-range face would. All subsets are shipped, because a page
   downloads only the ranges it uses.
4. **Bungee stays as it is unless the specimen differs.** The bytes differ, and
   the pixels are the test.
5. **The theme falls back to `prefers-color-scheme`**, as the design's
   `initTheme` does. Today the product always starts dark.
6. **An interim palette button** goes in today's top bar. Once the default flips
   app-wide, users need a way back before C2-T02 ships the cog menu.
7. **Only the exact stored value `"aiur"` leaves Gruvbox.** A corrupted value
   shows the default, where the design would show aiur colours.
8. **The product-only tokens** (`--accent-strong`, `--on-accent`, `--on-blocking`,
   `--shadow-md`, `--progress-*`, `--shell-measure`) keep their values in both
   palettes. The button fill under Gruvbox is for C2-T02/C2-T04 to match against `.btn` (H:1343–1362).
9. **`--board-bg` is not a root alias**, even though the row lists it. The design
   scopes it to `.bd-vpw` (C:1119–1120), so it ships with C2-T04.
10. **The row's ranges C:1027–1076 and 1141–1158** also contain component rules.
    This ticket takes only the token and body lines and leaves the rest to C2-T04
    (and `.ax-top`, including C:1147, to C2-T02), as C2-T04 §4.2 assigns them.
11. **H:150 and H:152–154 go to C2-T02** (`::selection`, `html { overflow-x:
    hidden; scrollbar-gutter: stable }`). Moving `overflow-x` to `html` forces it
    off `body`, or sticky bars break, so it ships with C2-T02's sticky `.ax-top`.
12. **No `/fonts/:font` route or controller action.** `Plug.Static` serves the
    directory in both endpoints; the Bungee route is a pre-#1893 leftover, not a
    pattern to copy.
13. **The parity runner's design side gets Google's real css2 response**
    (step 12), not C1-T02's variable-range `routeFonts` table. The design as
    Kevin sees it loads H:9, so that is the specification.
14. **The emulator follows Gruvbox in dark × gruvbox**, as the design does. The
    chassis pins stay light-only.

## Completion and handoff

- [ ] Fonts served from `/fonts/` by `Plug.Static` with a one-year cache and dashboard auth. No CDN request on any page.
- [ ] The parity runner's design side serves the verbatim css2 response (step 12).
- [ ] The four token sets and the body wash match the design, except the six listed holds.
- [ ] The palette defaults to Gruvbox, persists, has no flash, and handles blocked storage.
- [ ] `PaletteToggle` keeps `aria-pressed` (button) or `aria-checked` (menu item) correct across patches.
- [ ] All tests above pass, and each fails under its mutation. The PR names the command for each.
- [ ] The `visual-shell` baselines are rebuilt, and the PR lists the images.
- [ ] `guide/gui.md` paragraph added.
- [ ] Six `design-style` entries with `approval.status: "pending-sign-off"` are in C1-T02's
      allowlist, one per AA hold (C1-T02 already supports that status).
- [ ] S-19 is in DESIGN-E8's sign-off table (C12-T08 verifies it).
- **Dependents:** C2-T02 (palette hook on `#ax-palette`; remove `#palette-toggle`;
  port C:1147, H:150, H:152–154), C2-T04 (tokens; excludes this ticket's lines; its computed-style
  compare must read the six `design-style` hold entries and accept the held value
  wherever an element's colour resolves from a held token), every C9–C11 visual
  ticket (fonts and tokens), C1-T02 (design-side font route, step 12).
- **Sources:** H, C and J line ranges as cited; the Google Fonts css2 response
  (2026-10-07); `dashboard_css_theme_test.exs`; plan.md §5, §8 EC-28, §9 K-2, §10
  item 21; questions.md OQ-E8-1; DESIGN-E8 S-1.

## Review log

Adversarial review, 2026-10-08, against `58854d4c8`, the design copy and the
neighbour tickets. Changes made in place:

1. **Fonts, design side.** C1-T02 serves the design's fonts from `routeFonts`
   (`website/tests/support/visual.ts:8–29`: one `300 700` variable face), which
   draws 550 as a true 550. The ticket's discrete-weight parity check would have
   compared against that wrong design. Added deliverable 7, step 12 (verbatim
   css2 route), Decisions 13, and removed "if C1-T02 vendored these bytes, move
   them here" (it did not; it uses different files).
2. **Serving.** The claim "the fixture endpoint does not use `Plug.Static`" was
   false (`fixture_server.exs:2315–2331`). Replaced the `@font_files` map, route
   and action with one `@long_lived_static_paths` entry (Decisions 12). Fixed the
   traversal expectation: 400 from `Plug.Static.InvalidPathError`, not 404.
3. **C1-T02 allowlist.** C1-T02 already supports `pending-sign-off` (spelled so).
   Removed the false "C1-T02 requires approval on every entry" completion item;
   the six holds are `property` entries; C12-T08 G5 makes them due before C12-T08.
4. **AA table.** Re-computed all four combinations with the gate's formula. Filled
   the dark × aiur held ratios (5.03 / 4.57) and stated that hold is today's value,
   not hue-derived.
5. **S-18 collision.** Noted that C12-T08 renumbers the several "S-18" proposals.
6. **Hook state attribute.** C2-T02 asks for `aria-checked` on its
   `menuitemcheckbox`. The hook now picks `aria-checked` or `aria-pressed` by role,
   with a probe row and a mutation.
7. **H:149–153 and the sticky hazard.** Took the unowned `html` overflow/gutter and
   `::selection` rules (C2-T04 note 4) and moved `overflow-x` off `body`: keeping
   both would turn `body` into a scroll container and break sticky bars. Added a
   test and a mutation.
8. **Stream Deck claim.** "Key faces unchanged" was too strong; in dark × gruvbox
   the emulator ink follows Gruvbox, as in the design. Corrected Compatibility.
9. **C:1147 ownership mismatch** with C2-T02's interface note recorded; C2-T02 owns it.
10. **Missing edge cases.** Added the theme OS-fallback rows, the 390 px top-bar
    overflow row, and the matching mutation.
11. **Citations.** Fixed `fixture_server.exs` lines (`:117–118`, `:141`, `:148–173`),
    `endpoint.ex` (`:31`, `:81–85`), the 131-uses count scope, the Gruvbox light
    merge order in step 6 (C:1076 was missing), and "font spec" naming.
12. **Concurrency.** C2-T03 also edits `static_assets.ex` and `layouts.ex`; noted.

Residual risks: Google may have changed the css2 response or font versions since
2026-10-07 (step 1 re-fetches and the README records what was fetched); whether
`scrollbar-gutter: stable` changes `visual-shell` pixels under Playwright's
headless scrollbars is unmeasured; the AA holds wait on Kevin (S-18).
- Reconciliation 2026-10-08 (coordinator): `pending-sign-off` spelling, AA holds are kind `design-style` (with `css`) and S-19, pending fails only in the C12-T08 `--gate` run, H:150 `::selection` and H:152–154 `html` overflow/gutter moved to C2-T02 (deliverable 3, step 7, sticky row, mutation 6, pixel parity, Decision 11), C:1147 and H:150/152–154 interface notes settled, H line citations corrected.
