# aiur-style: one component library for the Aiur family of sites

Status: **plan only**. Nothing here changes product code. The tickets in
[§12](#12-tickets-and-migration-order) carry out the plan, one agent PR each.

**Operator request:**
> I'm noticing us recreating these components on the website with every new
> page. Consolidate all of the Aiur dashboard and website components into a
> library-style package (something like `aiur-style` as the name). Pull all
> these components in, then import them into the websites and the Aiur
> dashboard. I expect this to be a relatively large effort, so plan
> accordingly.

**Operator addition:** on aiur.team, the Prompt/npm/bun/pnpm/yarn box keeps a
backing sized for its widest tab. The backing, and the canvas keepout that
hugs content, must resize to the selected tab's content. This is requirement
**R-TAB-1** in [§9.6](#96-command-box-and-tabs-aiur-command-aiur-tabs), and
ticket **AS-05** fixes it on aiur.team straight away.

Grounding: every path below was read at these commits:
- aiur-team/aiur `origin/main` `19d64e57`
- aiur-team/archon `origin/main` `1c3e8c0`
- aiur-team/khala `origin/main` `eb6665f`

---

## 0. Decisions at a glance

| # | Decision | Choice |
|---|---|---|
| D1 | Package name | **`aiur-style`**, unscoped on npm. It matches `aiur-cli` and `aiur-archon`; `@aiur/*` scope ownership is unverified. The name is free on npm as of 2026-09-24. |
| D2 | Where it lives | A workspace package at `packages/aiur-style/` in **aiur-team/aiur**, next to `packages/streamdeck`. Not a separate repo. |
| D3 | What it is | 1. Framework-agnostic **CSS design tokens and component CSS**, using `aiur-*` classes in `@layer aiur`. 2. **Plain ES-module behaviours** that progressively enhance server-rendered markup. 3. One **classic pre-paint script**. 4. **Self-hosted fonts and brand assets**. 5. A thin **React** wrapper subpath for Khala's app shell. 6. A **VitePress adapter stylesheet**. There are no custom elements and no Vue wrappers. The dashboard keeps its own HEEx components and uses the CSS classes. |
| D4 | Build output | `dist/` is **committed** and guarded by a byte-for-byte `check-dist` CI job. The dashboard (no Node build) and the aiur.team `file:` consumers read it directly, and npm ships the same bytes. |
| D5 | Distribution | **In-repo consumers** (aiur.team, docs): `"aiur-style": "file:../packages/aiur-style"` (docs: `file:../../packages/aiur-style`). **Dashboard**: a sync script copies `dist/` into `src/priv/static/aiur-style/`, and an ExUnit byte-equality test blocks drift. **archon and khala**: the npm package `aiur-style@^0.x` with exact-version pins. |
| D6 | Theme contract | `data-theme="light\|dark"` on `<html>`; **absent means follow `prefers-color-scheme`**. The per-site default is set with a `data-default` attribute on the init script (aiur.team and the dashboard stay dark by default). One storage key, `aiur-theme`, with a one-time legacy-key migration. A pre-paint **external** classic script is used, never inline, so Khala's `script-src 'self'` is satisfied everywhere. |
| D7 | Canonical visuals | The **aiur.team** banner close X; **white on `#1f57c4`** for every filled button in both themes (hover `#1a4aa8`, pressed `#163e8c`); focus ring `2px solid var(--aiur-color-focus)`, offset 3px; the **dashboard's** left-nav shell. See [§4](#4-drift-and-how-it-resolves). |
| D8 | archon `templates/base` | **Out of scope.** It is the document renderer shipped inside the `aiur-archon` npm package. It uses its own palette, must stay self-contained under `check-dist`, and is inlined into every consumer's generated doc. Coupling it would change third-party output bytes. See [§14](#14-out-of-scope). |
| D9 | Safety net | Before any migration, each consumer gets committed Playwright `toHaveScreenshot` baselines (light/dark × desktop/phone, reduced motion). A migration PR must leave them unchanged, except for the drift fixes listed in §4, each shown as a reviewed diff. |

---

## 1. Consumers and their constraints

| Consumer | Repo · path | Stack | Deploy | CSP | Tests today |
|---|---|---|---|---|---|
| **aiur.team** marketing | aiur · `website/` | Vite 6 + TS, bun on Netlify / `npm ci` in CI | Netlify, base `website/` (`website/netlify.toml`) | **none** | `website/tests/brand.spec.ts` (theme, contrast), `scripts/assert-sim.ts` text golden; `.github/workflows/website.yml` |
| **aiur.team/docs** | aiur · `website/docs-app/` | VitePress 1.6 + Vue; `ProductSwitcher.vue` replaces `VPNavBarTitle` | same Netlify site, `dist/docs` | none | same `brand.spec.ts` |
| **Aiur dashboard** | aiur · `src/lib/aiur_web/**`, `src/priv/static/dashboard.css` (10,273 lines) | Phoenix 1.8 + LiveView 1.1 + HEEx `~H`. **No esbuild, no Tailwind, no bundler.** Static files are embedded at compile time by `src/lib/aiur_web/static_assets.ex` | local 127.0.0.1:4000 / :4002 behind basic auth | none; two inline scripts in `layouts.ex` | `src/browser/` Playwright harness (23 specs, axe), `src/test/aiur_web/dashboard_css_theme_test.exs`; `ci.yml` job `browser` |
| **archon.aiur.team** | archon · `site/index.html`, `site/404.html`, `netlify/public/welcome/index.html`, assembled by `templates/docbuild/src/site.ts` (`templates/build --site`) | hand-written HTML with inline `<style>` and `<script>`. **"must not grow a build step"** (`site/index.html:857`) | Netlify, edge function `gate` | landing pages: `script-src 'self' 'unsafe-inline'`, `style-src 'self' 'unsafe-inline' fonts.googleapis.com`, **`font-src https://fonts.gstatic.com` only** (`netlify/lib/edge-host.mjs:743`); 404 page has no `script-src` | node:test text assertions (`netlify/test/*.test.mjs`); **no Playwright config** |
| **khala.aiur.team** splash | khala · `apps/web/src/landing/` | Vite 7 + plain TS/CSS, pnpm workspace | Netlify (`netlify.toml`) | **`default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:`**. No inline script, no third-party fonts (`netlify.toml:88-94`) | vitest `landing.test.ts`, node:test + Playwright `landing.browser.spec.ts`; no screenshots |
| **Khala app shell** | khala · `apps/web/src/shell/` (`AiurShell.tsx`, `KhalaPageFrame.tsx`, `shell.css`), `apps/web/src/brand/tokens.css` | React 19 | same site (SPA entry not yet built) | same | `shell.test.ts`, `AiurShell.test.tsx`, `shell.browser.spec.ts` |

What the constraints force:
- **Khala's CSP** rules out inline scripts, CDN fonts and `eval`-based CSS-in-JS. The pre-paint script must be a same-origin file, and fonts must be self-hosted.
- **archon's "no build step"** rules out bundler-only output. The CSS and JS must be plain files that `site.ts` can copy verbatim.
- **The dashboard's lack of a Node pipeline** rules out anything that needs compiling at dashboard build time. It must consume committed `dist/` files.
- **Four frameworks** (vanilla, Vue/VitePress, HEEx, React) mean the source of truth has to be **HTML plus CSS**. JS only enhances markup that already exists.

---

## 2. Inventory: component × consumer × file × differences

Legend for consumer columns:
- **W** = aiur.team `website/`
- **D** = docs `website/docs-app/`
- **B** = dashboard `src/`
- **A** = archon `site/`
- **KS** = khala splash `apps/web/src/landing/`
- **KA** = khala app `apps/web/src/shell/`

"—" means the consumer does not have the component.

| Component | Consumer · file | Implementation today | Differences (drift) |
|---|---|---|---|
| **Announcement banner** | W · `index.html:45-53`, `src/styles.css:43-106`, `src/main.ts:154-159`, pre-paint `index.html:16-27` | `aside.announce#archonBanner` promotes *Archon*; background `var(--pill-bg)` (translucent) | Key `aiur-archon-banner`=`dismissed` → `html[data-archon-banner]` pre-paint (inline script) |
| | A · `site/index.html:95-144, 535-539, 838-852` | `aside.banner#aiur-banner hidden` promotes *Aiur*; solid band `linear-gradient(pill-bg,pill-bg), var(--bg)` | Key `archon.banner.aiur.dismissed`=`1`; ships `hidden` and JS reveals it (flash-free but JS-dependent) |
| | KS · `index.html:22-26`, `landing.css:136-186`, `banner.ts`, `public/banner-init.js` | `aside#aiurBanner` promotes *Aiur*; solid band like A; `z-index:3` | Key `khala.aiur-banner.dismissed`=`1` → `html[data-aiur-banner=dismissed]` via external pre-paint file |
| | D, B, KA | — (dashboard has unrelated `.readonly-banner` / `.decisions-banner` status banners, `dashboard.css:2145-2188`) | |
| **Banner close "X"** | W · `styles.css:~80-106` | **Ghost** button: 26×26, radius 7px, transparent, `--muted`; hover `--fg` + `color-mix(fg 8%)`; **SVG X** (`M6 6l12 12M18 6L6 18`, stroke 1.8, 14px, `aria-hidden`); `right:8px`; label "Dismiss the Archon announcement"; focus `2px accent / 3px` | **Canonical (operator).** |
| | A · `site/index.html:123-144` | **Filled** blue circle (`--btn-bg`), radius 999px, `&#215;` glyph at 15px; `right:10px`; hover/active states; focus offset 2px | Different shape, fill, glyph, offset |
| | KS · `index.html:22-26`, `landing.css:174-184` | Reuses `.button` → **filled blue pill**, `&times;` at 16px mono, no `:active` | Different again; no pressed state |
| **Top bar / nav** | W · `index.html:55-72`, `styles.css:122-215`, `main.ts:121-181` | Sticky `header.topbar`, padding 22px/26px, `pointer-events:none` shell; `.pinned` once the banner scrolls off | Only consumer with a nav **logo** |
| | A · `site/index.html:149-315, 541-583` | `.site-signin` right-aligned row: Docs, theme toggle, Sign in, account menu (duplicated in `netlify/public/welcome/index.html`, parity-tested) | No logo; Sign-in/account menu are archon-only |
| | KS · `index.html:27-33`, `landing.css:188-227` | `.topbar` right-aligned, 50px high | No logo |
| | D · VitePress nav + `custom.css` | Blurred bar, Bungee 17px title, 28px logo with accent drop-shadow, `ProductSwitcher.vue` | VitePress-owned |
| | B · `dashboard_shell.ex:33-55`, `dashboard.css:1865-1911` | Sticky topbar with logo (2.15×1.9rem) + Bungee "aiur" wordmark + status badge + pause/theme tool buttons | App chrome, see Shell |
| **Scroll-reveal logo** | W · `main.ts:121-150`, `styles.css:165-175` | IntersectionObserver on `.hero` with `rootMargin:-barHeight`; tucked = `translateY(-160%)`, opacity 0, `aria-hidden` + `tabindex=-1` + blur-if-focused | Only on W; A and KS show the logo only in the hero |
| **Docs button** | W · `index.html` `a.topbar-link` | **Text link**, mono 13px, `--muted` | Not a button |
| | A · `site/index.html:197-222` | **Filled pill** #1f57c4, Space Grotesk 500 .95rem, padding .55rem 1rem | |
| | KS · `index.html:28`, `landing.css:199-202` | **Filled pill** `.button.docs`, padding .6rem 1.1rem, 15px | Padding differs from A |
| **Theme toggle** | W · `index.html:62-71`, `styles.css:176-208`, `main.ts:25-37` | 42px ghost circle, `--pill-bd` border, 360° rotate in light; sun shows in dark; label "Toggle color theme"; **no `aria-pressed`, SVGs not `aria-hidden`** | a11y gaps |
| | A · `site/index.html:209-219, 543-546, 765-788` | Filled blue circle ≈ 2.05rem+2px; `aria-pressed`; `hidden` until JS; fires `archon:themechange` | |
| | KS · `index.html:29-32`, `landing.css:204-227`, `theme.ts` | Filled blue 38px circle, `aria-label="Dark mode"`, `aria-pressed` | |
| | B · `dashboard_shell.ex:180-199`, `layouts.ex:159-177`, `dashboard.css:2028-2042` | `.tool-btn.icon-only` 2.05rem pill, LiveView hook `ThemeToggle` | |
| | KA · `AiurShell.tsx`, `shell/theme.ts` | Plain text button "Use {light\|dark} theme", **defaults dark** | Unstyled |
| | D · VitePress `.VPSwitchAppearance` | VitePress control | |
| **Theme init before paint** | W · `index.html:6-15` (inline) | key `aiur-theme`, default **dark** (`brand.spec.ts` asserts it) | inline |
| | D · `.vitepress/config.ts:73-84` (inline), `theme/index.ts` | mirrors `aiur-theme` → `vitepress-theme-appearance` + `.dark`; **storage access not try/caught** | |
| | B · `layouts.ex:25-34` (inline) | key `aiur-theme`, default dark, ignores `prefers-color-scheme` | |
| | A · `site/index.html:16-28` (inline) | key `archon.theme`, absent → system | |
| | KS · `public/theme-init.js` (**external**, CSP) | key `khala.theme`, absent → system | Only CSP-safe variant |
| **Buttons** | A · `site/index.html:44-51, 482-513` | `--btn-bg #1f57c4 / hover #1a4aa8 / active #163e8c`, fg #fff, both themes; pill; CTA `padding 13px 22px`, arrow nudges 3px on hover; focus offset 2px (4px on CTA) | **Reference values** |
| | KS · `landing.css:23-31, 104-132` | `--button-bg #1f57c4`, **hover `#1a4aa6`** (≠ `#1a4aa8`), **no `:active`, no `:disabled`**; focus offset 3px | 2-digit hex drift; missing states |
| | D · `custom.css:25-56, 234-250, 352-356` | brand light `#1f57c4`, **dark `#1f6fcf`**, light hover **`#2a2520` (near-black)**, dark hover `#165eae`; radius 9px; mono 13px; hover lift -2px; focus offset 4px | Most divergent |
| | B · `dashboard.css:3396-3428` | `.btn`: `--accent-strong` = **`#0070f0` dark** / `#1f57c4` light; radius 10px; .82rem/650; hover lift -1px + shadow; variants `.ghost`, `.danger` | Dark fill differs |
| | W | — (no filled buttons on the marketing page) | |
| **Focus ring** | W 2px accent / **4px**; A 2px / **2px**; KS 2px `--focus` / **3px**; D 2px / **4px** `!important`; B **3px `--accent-line`** / 3px; KA **3px** accent / 3px | | Six variants |
| **Copy prompt box** | W · `index.html:85-114`, `styles.css:304-425`, `main.ts:42-114` | `.install-box` (pill-bd border, pill-bg, radius 11, blur 3px) with tabs; `$` prompt hidden on Prompt tab; copy 28×28 radius 7; `.copied` for 1300ms; next-steps drop-down | **Keepout goes stale on tab switch (R-TAB-1)**; no live region |
| | A · `site/index.html:393-464, 736-749, 796-830` | Same box, **no tabs**, `>` prompt, "tell your agent:" hint, "Copied" tooltip | |
| | KS · `index.html:43-58`, `landing.css:599-628`, `copy-prompt.ts` | Same box, no tabs, **greyed "Coming soon"** state (`opacity .42`, grayscale, `aria-disabled`); 1600ms confirmation | Timing differs (1300 vs 1600) |
| **Tabs** | W · `index.html:87-92` | `role=tablist/tab`, `aria-selected`; **no `aria-controls`, no tabpanel, no arrow keys, no `type=button`, no focus-visible style** | Only consumer |
| **Scroll cue** | W · `index.html:118-121`, `styles.css:427-457` | fixed, `--term-dim` colour (**2.75:1 in light, fails AA**), `.gone` at scrollY>60 | |
| | KS · `index.html:60-63`, `landing.css:372-406`, `main.ts` | ported copy | |
| **Fading diagonal lines + flow field** | W · `src/flowField.ts` (200 lines), `styles.css:231-240` | −118°, spacing 23, step 7, gap 9, fade 260px mask; keepouts = `.keepout` rounded-rect SDF; rebuilt on **resize + fonts.ready only**; canvas **not `aria-hidden`** | Reference algorithm |
| | A · `site/index.html:339-349, 861-1054` | plain-JS port; rebuild on **`ResizeObserver(body)`**, fonts, `archon:themechange`; mask 220px | Fork #2 |
| | KS · `flow-field.ts` | TS port + **`.hug` keepouts via `Range.getClientRects()`** (per-line text hugging); canvas `top:-50px` | Fork #3; best keepouts |
| | D · `custom.css:175-194` | **CSS-only** `repeating-linear-gradient(112deg)` imitation behind `.VPHomeHero` | Different technique |
| **Feature-card grid** | W · `index.html:142-191`, `styles.css:696-747` | `.features` > 6 × `.feat` (26px accent SVG icon, `.idx` 01–06, h3 Space Grotesk 600, p muted 32ch); 3/2/1 cols at >640 / ≤640 / ≤440 | |
| | KS · `index.html`, `landing.css` | 6 × `article.feature-card`, 3/2/1 cols at >720 / **≤720** / ≤440 | Breakpoint differs |
| **Section subtext + accent highlight** | W · `.summary` + `.hl` (`styles.css:682-694`), `.signoff` (749-767) | Space Grotesk 500 `clamp(25px,3.6vw,42px)`, `.hl` = accent | |
| | A · `.what` highlight "Claude Artifacts" | accent span | |
| | KS · intro line + "Hailing frequencies open." sign-off | ported | |
| **Footer** | W · `index.html:198-210`, `styles.css:769-815` | brand dot (7px, accent glow) + "aiur" + Docs + GitHub icon; **no "built with Aiur"** | |
| | A · `site/index.html:515-523, 756` | `p.aside.keepout` "built with [Aiur]", mono 12px, muted 78% | welcome page links GitHub instead |
| | KS · `footer.aside` | "built with Aiur", mono 12px | |
| | D | VitePress footer message per product (`config.ts:52-55, 66-69, 172-175`) | |
| **Wordmark / hero lockup** | W · `styles.css:242-300` (logo `clamp(120px,18vw,224px)`, Bungee `clamp(40px,8vw,96px)`, per-letter rise) | | |
| | A · lines 363-388 (logo `clamp(70px,15vw,150px)`, `clamp(38px,9vw,92px)`) | | Sizes differ per product (acceptable: size tokens) |
| | KS · `index.html:37-40` | "KHALA", `alt=""` | Aiur `h1` is split into spans (screen readers may spell it) |
| **Favicons / logo** | W · `public/` (ico, 16/32/48/96, apple 180, android 192/512, webmanifest `#1a1b1e`); logo `public/assets/aiur-logo.png` 1215×1068 **594 KB** | | 48/96 unlinked |
| | A · `site/` ico/16/32/apple; same 594 KB logo | | |
| | KS · `landing/public/` copied byte-for-byte from archon (`brand/SOURCES.md`) | | |
| | B · `src/priv/static/aiur-logo.png` used as **favicon** too | | No .ico |
| **Fonts** | W, D, A: **Google Fonts** (`Bungee`, `Space Grotesk 400–700`, `JetBrains Mono 400/500`); A's 404 and welcome pages load subsets | | Third-party request; blocked by the Khala CSP |
| | KS/KA · `src/brand/fonts.css` + `fonts/*.woff2` (**self-hosted**, OFL, SHA-256 tested) as `'Khala Bungee'`, `'Khala Space Grotesk'`, `'Khala JetBrains Mono'` | | Prefixed family names |
| | B · `dashboard.css:3-9` bundles **Bungee only**; Space Grotesk and JetBrains Mono **never load** → falls back to Avenir/Segoe/SFMono | | Real rendering bug |
| **Colour tokens** | W `styles.css:1-24, 488-519` (`--bg --fg --muted --line --accent --hairline --pill-bd --pill-bg`, + 14 `--term-*`); D `custom.css:1-58` (`--aiur-*` + `--vp-*` mapping); B `dashboard.css:11-145` (≈45 tokens incl. surfaces + 5 status families); A `site/index.html:34-76`; KS `landing.css:10-64`; KA `brand/tokens.css` (`--khala-*`, **scoped to `.aiur-shell`, no `:root`**) | | See §4 |
| **Left nav + page frame** | B · `dashboard_shell.ex` (shell 32-140, nav items 230-277), `dashboard.css` 227-400, 1865-2063, 6055-6234 | 15rem nav (2.6rem collapsed), 75rem measure, 960px breakpoint, bottom-pill nav ≤959px, collapse state server-owned + `aiur-nav-collapsed` | **Reference** (operator: "match the Aiur dashboard left-nav page design") |
| | KA · `AiurShell.tsx`, `KhalaPageFrame.tsx`, `shell.css` | copies the measurements; **no icons, no logo, no bottom pill, no button styling, active = 1px outline** (B: `--accent-soft` fill + `--accent-ink`) | Visibly different |

---

## 3. What is actually shared (the extraction set)

Every item below is currently copied or forked in two or more consumers. Each becomes one package module:

| Package module | Replaces |
|---|---|
| `tokens` | 6 token sets |
| `fonts` + `assets` | 3 Google Fonts links, 1 self-hosted set, 1 partial set, 4 favicon copies, 4 logo copies |
| `theme` (pre-paint init + toggle) | 5 init scripts, 6 toggles |
| `button` + focus ring | 4 button skins, 6 focus rings |
| `banner` | 3 banners, 3 close buttons |
| `topbar` (+ brand reveal, Docs button) | 4 top bars |
| `command` + `tabs` (copy box) | 3 boxes, 1 tab set |
| `scrollcue`, `features`, `prose` (summary / highlight / signoff) | 2–3 copies each |
| `footer` | 3 footers |
| `field` (flow field + diagonal-lines CSS) | 3 JS forks, 1 CSS imitation |
| `shell` + `page` | the dashboard original and the Khala copy |

---

## 4. Drift and how it resolves

A migration PR may change pixels **only** for the rows below. Each such change must appear as an updated screenshot baseline in that PR, with the row ID in the commit message.

| ID | Drift | Resolution | Who sees a change |
|---|---|---|---|
| DR-1 | Three banner close buttons | aiur.team's ghost SVG X everywhere: 26×26, radius 7px, transparent, `--aiur-color-muted`, hover fg + 8% fg wash, 14px SVG with stroke 1.8, `right: 8px` | archon, khala splash |
| DR-2 | Button fill `#1a4aa6` vs `#1a4aa8`; missing pressed/disabled states; docs dark `#1f6fcf` with near-black light hover; dashboard dark `#0070f0` | One filled button: fg `#ffffff` on `#1f57c4` / hover `#1a4aa8` / pressed `#163e8c`, **identical in both themes** (6.5:1 / 8.1:1 / 10:1). Disabled = 45% opacity + `cursor:not-allowed` | khala (hover ±2 in one channel), docs, dashboard dark `.btn` |
| DR-3 | Six focus rings | `outline: 2px solid var(--aiur-color-focus); outline-offset: 3px`. Focus is `#1f57c4` in light and `#2f86ff` in dark; both are ≥3:1 against their bg | every consumer, keyboard-only |
| DR-4 | Docs button is a text link on aiur.team but a pill on archon/khala | Docs is a `aiur-button aiur-button--sm` filled pill everywhere (matches archon #259 "every site button the Example Doc skin"). **Open question Q3** | aiur.team |
| DR-5 | Theme toggle: ghost 42px (W), filled circles (A, KS), tool pill (B), text (KA) | One `aiur-theme-toggle`: a `--sm` filled icon button (38px) on sites, and the dashboard `tool` variant in the app shell. Always `aria-pressed` (true = dark), `aria-label="Dark mode"`, SVGs `aria-hidden` | aiur.team (ghost → filled), khala app |
| DR-6 | Muted text `#8c8d93`/`#5f5645` on sites vs `#969aa4`/`#635a48` on the dashboard | Site values win for brand surfaces. The dashboard keeps `--aiur-color-muted-app` until its phase-2 migration, then swaps in a reviewed PR. Both pass 4.5:1 | dashboard (phase 2) |
| DR-7 | Page background: sites `#1a1b1e` (dark) vs dashboard `#16171a` | Both kept as tokens: `--aiur-color-bg` = `#1a1b1e` (site canvas) and `--aiur-color-bg-app` = `#16171a` | none |
| DR-8 | Scroll cue light contrast 2.75:1 | Use `--aiur-color-muted` (≥4.5:1) | aiur.team, khala |
| DR-9 | Keepouts stale after layout change (R-TAB-1); archon observes `body`, khala hugs text lines, aiur.team does neither | One field module: `ResizeObserver` on **each** keepout **and** the host, `MutationObserver` for keepouts added or removed, `.aiur-hug` per-line text rects, theme-event redraw | aiur.team (fixed band), archon, khala |
| DR-10 | Fonts: Google (W, D, A) vs self-hosted with `Khala` prefix (K) vs Bungee-only (B) | Self-hosted woff2 in the package, plain family names `Bungee` / `Space Grotesk` / `JetBrains Mono`. Drop Google Fonts. The dashboard finally renders Space Grotesk and JetBrains Mono | dashboard (visible: body font), others none if files match |
| DR-11 | Feature grid breakpoint 640 vs 720 | 720px → 2 columns, 440px → 1 column | aiur.team 641–720px only |
| DR-12 | Khala shell active item = 1px outline, no icons, no bottom pill | Dashboard look: `--aiur-color-accent-soft` fill + `--aiur-color-accent-ink` text, 18px icon slot, bottom pill ≤959px | khala app |
| DR-13 | Theme toggle / canvas / copy button a11y gaps | `aria-pressed`, `aria-hidden` on decorative SVG and canvas, a `role=status` live region "Copied", `type=button` everywhere | none visual |
| DR-14 | Theme default: aiur.team and dashboard force dark; archon and khala follow the system | Keep each site's current default via `data-default` (no behaviour change). **Open question Q2** | none |
| DR-15 | Copy confirmation 1300ms vs 1600ms | 1500ms | none visual at rest |
| DR-16 | Banner background: translucent (W) vs solid band (A, KS) | Solid band `linear-gradient(pill-bg,pill-bg), var(bg)` (reads the same where no field runs behind it) | none measurable on W |

---

## 5. Architecture decision

### 5.1 Options considered

| Option | For | Against | Verdict |
|---|---|---|---|
| **A. CSS tokens + component CSS + plain ES-module behaviours on server-rendered markup** (+ thin React wrappers, a VitePress adapter CSS, and HEEx that uses the classes) | Works in all four frameworks. No hydration or FOUC: the HTML is already there. Fits archon's no-build rule (copy files) and the dashboard's no-Node rule (committed `dist/`). CSP-clean (external files only). Visual parity is testable from a static gallery page | The markup contract is duplicated per framework (a HEEx template, a React component and plain HTML must emit the same classes). Mitigated by the shared `markup/*.html` fixtures plus a contract test in each consumer | **Chosen** |
| B. Custom elements (`<aiur-banner>`) with shadow DOM | One implementation of markup and behaviour | Shadow DOM breaks the canvas keepout measurement and global theming, and needs `::part` for everything. Nothing renders before JS (FOUC, or the pre-paint banner hide fails). Awkward in LiveView (DOM patching vs shadow roots) and VitePress SSR | Rejected |
| B'. Light-DOM custom elements | No shadow DOM | Still render-on-upgrade, so the no-JS page shows nothing. The dashboard and VitePress already render server-side, so it would fight them | Rejected (a behaviour module gives the same result) |
| C. React component library, used everywhere | Rich API | archon (no build) and the dashboard (HEEx) cannot run it; the static sites would ship React | Rejected |
| D. Tailwind preset / utility CSS | Popular | No consumer uses Tailwind. It would rewrite the 10k-line dashboard.css. It cannot express the canvas field | Rejected |
| E. Keep copying, with a "source of truth" doc | Zero setup | This is the status quo that produced six token sets and three flow-field forks | Rejected |

### 5.2 Monorepo package vs separate repo

| | `packages/aiur-style` in aiur-team/aiur | New repo `aiur-team/aiur-style` |
|---|---|---|
| aiur.team + docs + dashboard (3 of 6 consumers) | Atomic PRs: package change + consumer update + screenshot baselines in one PR; `file:` dependency, no publish wait | Every change needs publish → bump → PR in aiur |
| archon, khala | npm, pinned | npm, pinned (same) |
| CI | Reuses `website.yml` / `ci.yml`. A new `aiur-style.yml` runs on path `packages/aiur-style/**` | New CI, new labels, new Aiur workspace |
| Ownership signal | The package sits with the dashboard it is extracted from | Cleaner if the org grows many design consumers |
| Release | Tag `aiur-style-v*` → OIDC trusted publishing, separate from `release-npm.yml` (aiur-cli) | Same |

**Chosen: monorepo package.** Half the consumers and the reference implementation (the dashboard shell and the aiur.team marketing components) live in aiur, so co-locating them turns the riskiest migrations into single atomic PRs. It can move to its own repo later with `git subtree split` if needed.

### 5.3 Versioning

- SemVer, starting at `0.1.0`. While `0.x`, a **minor** bump may change visuals.
- A PR that changes any gallery screenshot must bump the version and add a `CHANGELOG.md` entry naming the changed components.
- archon and khala pin **exact** versions (`"aiur-style": "0.3.1"`), and each upgrade is its own PR with screenshot diffs.
- aiur.team, docs and the dashboard always track the in-repo source.

---

## 6. Package layout

```
packages/aiur-style/
  package.json            name "aiur-style", type module, sideEffects ["*.css"], exports map (§6.1)
  README.md               usage per consumer (§10), theming contract (§8)
  CHANGELOG.md
  LICENSE                 MIT; fonts/ keeps OFL texts
  src/
    tokens/tokens.json    single source of truth: {name, light, dark, description}
    tokens/build.mjs      tokens.json → dist/tokens.css + dist/tokens.js + dist/tokens.d.ts
    css/                  one file per component, all in @layer aiur
      base.css            box-sizing, body font, ::selection, focus ring, reduced-motion
      button.css banner.css topbar.css theme-toggle.css command.css tabs.css
      scrollcue.css features.css prose.css footer.css field.css shell.css page.css
      vitepress.css       adapter: --vp-* ← --aiur-*
    js/                   TypeScript, compiled to dist/js/*.js ES2020 modules, no dependencies
      storage.ts theme.ts banner.ts brand-reveal.ts command.ts tabs.ts
      scrollcue.ts field.ts auto.ts (data-attribute auto-init)
    init/theme-init.js    hand-written ES5 classic script (no build), copied to dist/
    react/                AiurShell.tsx PageFrame.tsx ThemeToggle.tsx Button.tsx index.ts
  fonts/                  Bungee-Regular.woff2, SpaceGrotesk-Variable.woff2,
                          JetBrainsMono-Variable.woff2, *-OFL.txt, fonts.css
                          (seeded from khala apps/web/src/brand/fonts, same SHA-256)
  assets/                 aiur-logo.png (original) + aiur-logo-512.png/.webp (optimised),
                          favicon.ico, favicon-{16,32}.png, apple-touch-icon.png,
                          android-chrome-{192,512}.png
  markup/                 canonical HTML per component (the markup contract)
  gallery/index.html      every component × variant, ?theme=light|dark, no network
  dist/                   COMMITTED build output (check-dist enforced)
    aiur-style.css        tokens + base + all components (one file for archon/dashboard)
    tokens.css  fonts.css  css/*.css  vitepress.css
    js/*.js  js/*.d.ts  init/theme-init.js
    react/*.js react/*.d.ts
    fonts/*  assets/*
  scripts/build.mjs       tsc + token build + concat, deterministic (sorted, no timestamps)
  scripts/check-dist.mjs  rebuild into tmp and byte-compare with dist/
  scripts/sync.mjs        copy dist/ → a target dir (used by the dashboard, archon, khala)
  test/                   vitest (jsdom) unit tests, Playwright gallery screenshots + behaviour
  playwright.config.ts
```

### 6.1 `exports`

```json
{
  ".":                 "./dist/js/index.js",
  "./aiur-style.css":  "./dist/aiur-style.css",
  "./tokens.css":      "./dist/tokens.css",
  "./tokens":          "./dist/tokens.js",
  "./fonts.css":       "./dist/fonts.css",
  "./css/*":           "./dist/css/*",
  "./vitepress.css":   "./dist/vitepress.css",
  "./theme":           "./dist/js/theme.js",
  "./field":           "./dist/js/field.js",
  "./command":         "./dist/js/command.js",
  "./banner":          "./dist/js/banner.js",
  "./topbar":          "./dist/js/brand-reveal.js",
  "./auto":            "./dist/js/auto.js",
  "./init/theme-init.js": "./dist/init/theme-init.js",
  "./react":           "./dist/react/index.js",
  "./fonts/*":         "./dist/fonts/*",
  "./assets/*":        "./dist/assets/*",
  "./package.json":    "./package.json"
}
```

- `react` is an **optional peer dependency**, and nothing else has dependencies.
- `files`: `["dist", "README.md", "CHANGELOG.md", "LICENSE"]`.

---

## 7. Tokens

**Naming:** `--aiur-{group}-{role}[-{variant}]`.
- Groups: `color`, `font`, `text`, `space`, `radius`, `shadow`, `motion`, `layout`, `z`.
- Component-private custom properties use `--aiur-{component}-{prop}`, for example `--aiur-button-bg`. Consumers may override them per instance.

**Legacy names:** they are provided only as aliases in consumer glue during migration, and the dedupe tickets delete them. Examples: `--bg`, `--accent`, `--khala-*`, `--aiur-bg` in docs.

### 7.1 Colour (light → dark)

| Token | Light | Dark | Source / note |
|---|---|---|---|
| `--aiur-color-bg` | `#e7d6b2` | `#1a1b1e` | sites |
| `--aiur-color-bg-2` | `#e2cfa6` | `#161719` | W `--bg-2`, D bg-soft |
| `--aiur-color-bg-app` | `#e7d6b2` | `#16171a` | dashboard `--bg` |
| `--aiur-color-surface` | `#f4ecd9` | `#1e2025` | dashboard |
| `--aiur-color-surface-2` | `#efe5cd` | `#23262c` | dashboard |
| `--aiur-color-surface-3` | `#e9dcbf` | `#292d34` | dashboard |
| `--aiur-color-fg` | `#2a2520` | `#edeef0` | all |
| `--aiur-color-muted` | `#5f5645` | `#8c8d93` | sites (DR-6) |
| `--aiur-color-muted-app` | `#635a48` | `#969aa4` | dashboard, removed in AS-43 |
| `--aiur-color-faint` | `#6d6450` | `#8b8f99` | dashboard, ≥4.5:1 |
| `--aiur-color-hairline` | `rgba(42,37,26,.12)` | `rgba(221,226,235,.10)` | sites |
| `--aiur-color-line` | `rgba(42,37,26,.16)` | `rgba(221,226,235,.12)` | borders (dashboard `--line`) |
| `--aiur-color-line-strong` | `rgba(42,37,26,.28)` | `rgba(221,226,235,.20)` | dashboard |
| `--aiur-color-pill-bd` | `rgba(42,37,26,.16)` | `rgba(221,226,235,.13)` | sites |
| `--aiur-color-pill-bg` | `rgba(42,37,26,.035)` | `rgba(221,226,235,.03)` | sites |
| `--aiur-color-field-line` | `rgba(42,37,26,.17)` | `rgba(221,226,235,.14)` | canvas stroke (was `--line` on sites) |
| `--aiur-color-accent` | `#1f57c4` | `#2f86ff` | all |
| `--aiur-color-accent-ink` | `#1a4aa8` | `#8fbcff` | accent text on surfaces |
| `--aiur-color-accent-soft` | `rgba(31,87,196,.11)` | `rgba(47,134,255,.15)` | active nav fill |
| `--aiur-color-accent-line` | `rgba(31,87,196,.30)` | `rgba(47,134,255,.34)` | |
| `--aiur-color-focus` | `#1f57c4` | `#2f86ff` | DR-3 |
| `--aiur-color-on-fill` | `#ffffff` | `#ffffff` | |
| `--aiur-color-fill` | `#1f57c4` | `#1f57c4` | DR-2, theme-independent |
| `--aiur-color-fill-hover` | `#1a4aa8` | `#1a4aa8` | |
| `--aiur-color-fill-pressed` | `#163e8c` | `#163e8c` | |
| `--aiur-color-{good,attention,blocking,super}` | copied from `dashboard.css:82-145` | copied from `dashboard.css:11-80` | + `-ink`, `-soft`, `-line`; `--aiur-color-on-blocking` (`#fff` / `#2a0906`) |
| `--aiur-color-ack` | copied from the `dashboard.css` light block | `#4fd6c4` | |

AS-11 copies the dashboard's status-family values exactly from `dashboard.css:11-145`. The table names the source rather than repeating ~40 values.

### 7.2 Type, space, shape, motion, layout

| Token | Value |
|---|---|
| `--aiur-font-display` | `"Bungee", system-ui, sans-serif` |
| `--aiur-font-body` | `"Space Grotesk", "Avenir Next", "Segoe UI", system-ui, sans-serif` |
| `--aiur-font-mono` | `"JetBrains Mono", ui-monospace, SFMono-Regular, Consolas, monospace` |
| `--aiur-text-xs / sm / md / lg` | `12px / 13px / 15px / 17px` |
| `--aiur-text-banner` | `clamp(11px, 1.5vw, 13px)` |
| `--aiur-text-summary` | `clamp(25px, 3.6vw, 42px)` |
| `--aiur-text-signoff` | `clamp(27px, 4.4vw, 52px)` |
| `--aiur-space-1…8` | `4, 8, 12, 16, 20, 24, 32, 48px` |
| `--aiur-radius-sm` | `7px` (icon buttons, copy, banner X) |
| `--aiur-radius-md` | `10px` (app buttons, nav items) |
| `--aiur-radius-box` | `11px` (command box) |
| `--aiur-radius-lg / xl` | `16px / 24px` (panels, dialogs) |
| `--aiur-radius-pill` | `999px` |
| `--aiur-shadow-sm / md / lg` | dashboard values |
| `--aiur-motion-fast` | `.2s` |
| `--aiur-ease-rise` | `cubic-bezier(.2,.85,.3,1)` |
| `--aiur-ease-standard` | `cubic-bezier(.4,0,.2,1)` |
| `--aiur-layout-nav` / `--aiur-layout-nav-collapsed` | `15rem` / `2.6rem` |
| `--aiur-layout-measure` | `75rem` |
| `--aiur-layout-page-max` | `1440px` |
| `--aiur-z-topbar / banner / stage` | `20 / 3 / 6` |

The breakpoints can't be custom properties inside media queries, so they are documented constants, and `tokens.js` exports them for JS and tests:

| Constant | Value | Controls |
|---|---|---|
| `BP_SHELL` | 960px | desktop shell vs bottom pill |
| `BP_FEATURES_2` | 720px | feature grid to 2 columns |
| `BP_FEATURES_1` | 440px | feature grid to 1 column |

`tokens.js` also exports every colour pair that §7.3 checks.

### 7.3 Contrast pairs (asserted by AS-11)

These pairs are enforced at ≥4.5:1 for text and ≥3:1 for non-text, in both themes:
- fg / muted / faint / accent / accent-ink on bg, bg-2, bg-app, surface and surface-2
- on-fill on fill, fill-hover and fill-pressed
- focus on bg and bg-app (3:1)
- `on-blocking` on blocking

**Known failure to resolve inside AS-11:** light accent `#1f57c4` on bg-2 `#e2cfa6` is 4.26:1. Decision: accent-coloured *text* must use `--aiur-color-accent-ink` (`#1a4aa8`, which passes) on bg-2. The test encodes that rule.

---

## 8. Theming contract

1. **State lives on `<html>`:**
   - `data-theme="light"` or `"dark"` is an explicit choice.
   - **No attribute** means follow `prefers-color-scheme`.
   - `tokens.css` implements this as three blocks: bare `:root` holds the light values, `@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {…dark} }`, and `:root[data-theme="dark"] {…dark}`. Each block also sets `color-scheme`.
2. **Pre-paint init is a classic, render-blocking, same-origin file.** It is `aiur-style/init/theme-init.js`, copied to each site's public root and referenced as `<script src="/aiur-style/theme-init.js" data-default="dark" data-legacy-keys="khala.theme"></script>` as the first child of `<head>` (before stylesheets). It never runs inline, so it is valid under Khala's CSP. It reads `document.currentScript.dataset`:
   - `data-default="system|dark|light"`, default `system`. aiur.team, the docs and the dashboard use `dark`.
   - `data-storage-key`, default `aiur-theme`.
   - `data-legacy-keys`: space-separated keys read once, copied into the new key, then deleted.
   - `data-banner`: the id of the page's one announcement banner (a page has at most one). If storage key `aiur-banner:<id>` is `dismissed`, it sets `html[data-aiur-banner="dismissed"]`, and `banner.css` hides `.aiur-banner` under that attribute. This is khala's proven pattern: flash-free, with no `hidden` attribute and no JS reveal.
   - Every storage access is `try`/`catch` guarded.
   - Size budget: 1 KB minified.
3. **Runtime** (`aiur-style/theme`):
   - `getTheme()`, `setTheme(t)`: persists the choice and sets the attribute.
   - `onThemeChange(cb)`.
   - `initThemeToggle(button)`.
   - `setTheme` dispatches `aiur:themechange` on `document` (`detail: {theme}`); the field and VitePress sync listen for it.
   - A toggle while in "system" mode flips relative to the current resolved theme and stores the result.
4. **VitePress** keeps its own `.dark` class. `vitepress.css` maps `--vp-*` onto `--aiur-*` under both `html.dark` and `[data-theme="dark"]`, and the docs theme `Layout` (existing MutationObserver in `theme/index.ts`) keeps `data-theme` and `.dark` in step. The existing `aiur-theme` / `vitepress-theme-appearance` bridge moves from the inline script in `config.ts` into `aiur-style/init/theme-init.js` via `data-vitepress="true"`.
5. **Dashboard:** LiveView keeps `data-theme` on `<html>` (never patched by LiveView, since it sits outside the LV root). The `ThemeToggle` hook calls `setTheme` from `/aiur-style/js/theme.js` (loaded as a module script).
6. **Per-origin storage:** aiur.team + docs share an origin; archon, khala and 127.0.0.1 each have their own. So one key name is safe, and a choice does not sync across products. That is expected.

---

## 9. Component APIs

Each component has these parts:
- **CSS** in `css/<name>.css`.
- **Canonical markup** in `markup/<name>.html`.
- An optional **behaviour** exported from the named module. Signatures are TypeScript. Every `init*` is idempotent (a second call on the same element is a no-op), returns `{ destroy(): void }`, and never throws when optional parts are missing.

`aiur-style/auto` scans `[data-aiur]` on `DOMContentLoaded` and calls the matching `init*`. Static sites use it; React, Vue and LiveView call `init*` themselves (in `useEffect`, `onMounted` or a hook's `mounted`).

### 9.1 Button (`aiur-button`)

```html
<a class="aiur-button" href="…">Example Doc <svg class="aiur-button__icon" aria-hidden="true">…</svg></a>
<button type="button" class="aiur-button aiur-button--sm">Docs</button>
<button type="button" class="aiur-button aiur-button--ghost">Cancel</button>
<button type="button" class="aiur-button aiur-button--icon" aria-label="Copy"><svg aria-hidden="true">…</svg></button>
```

| Part | Values |
|---|---|
| Variants | default (filled), `--ghost`, `--danger` (dashboard), `--tool` (dashboard 1.9rem mono pill) |
| Sizes | `--sm` (Docs; padding .55rem 1rem, .95rem), default (15px, padding .6rem 1.1rem), `--lg` (CTA; padding 13px 22px) |
| Shape | `--rounded` (radius-md, app), `--icon` (square/circle icon-only; requires `aria-label`) |
| States | `:hover` → fill-hover; `:active` / `[aria-pressed=true]` → fill-pressed; `:focus-visible` → ring (DR-3); `:disabled` / `[aria-disabled=true]` → 45% opacity, `cursor:not-allowed`, no hover change |
| Motion | `--lg` arrow icon nudges 3px on hover; no hover lift; `prefers-reduced-motion` removes transitions |

**React:** `<Button variant size shape as="a"|"button" …>` renders the same classes.

### 9.2 Banner (`aiur-banner`)

```html
<aside class="aiur-banner" data-aiur="banner" data-aiur-banner="archon-launch" aria-label="Announcement">
  <p class="aiur-banner__text"><strong>Introducing Archon:</strong> Always-on Architecture Docs.</p>
  <a class="aiur-banner__link" href="https://archon.aiur.team">Learn More</a>
  <button type="button" class="aiur-banner__close" aria-label="Dismiss announcement">
    <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>
  </button>
</aside>
```

- **JS:** `initBanner(el, { storageKeyPrefix?: 'aiur-banner:' }): {destroy}`. On close it:
  1. sets storage `aiur-banner:<id>` = `dismissed`;
  2. sets `html[data-aiur-banner="dismissed"]`;
  3. moves focus to the next focusable element after the banner, or to `<main>`;
  4. dispatches `aiur:bannerdismiss`.
- **CSS:**
  - The band is `linear-gradient(pill-bg,pill-bg), var(--aiur-color-bg)` with a `--aiur-color-hairline` bottom border.
  - Text is mono `--aiur-text-banner`.
  - The close button follows DR-1.
  - `:root[data-aiur-banner="dismissed"] .aiur-banner { display: none }`. The init script only sets the attribute when the stored id equals the page's `data-banner` id, so a new campaign id re-shows the banner.
- **Ids:** one id per campaign. A new campaign re-shows the banner, and legacy keys are migrated by `data-legacy-keys` only for the current campaign.

### 9.3 Top bar, brand and scroll-reveal (`aiur-topbar`)

```html
<header class="aiur-topbar" data-aiur="topbar" data-aiur-reveal-after=".hero">
  <a class="aiur-brand" href="/" aria-label="Aiur home"><img class="aiur-brand__logo" src="/aiur-style/assets/aiur-logo-512.png" alt=""><span class="aiur-brand__word">aiur</span></a>
  <nav class="aiur-topbar__actions" aria-label="Primary">
    <a class="aiur-button aiur-button--sm" href="/docs/">Docs</a>
    <button type="button" class="aiur-theme-toggle aiur-button aiur-button--icon aiur-button--sm" data-aiur="theme-toggle" aria-label="Dark mode" aria-pressed="true">…sun/moon svgs aria-hidden…</button>
  </nav>
</header>
```

| Part | Detail |
|---|---|
| Modifiers | `--sticky` (aiur.team), `--end` (right-aligned, no brand: archon, khala) |
| `initBrandReveal(topbar, { after: Element \| string })` | Ports `main.ts:121-150` exactly: IntersectionObserver with `rootMargin:-barHeight`; synchronous initial state; `aria-hidden` + `tabindex=-1` while tucked; blur if focused. Without IO → brand visible |
| `initTopbarPin(topbar, { banner })` | Ports the `.pinned` behaviour (`main.ts:168-181`) |
| Slots | archon's Sign-in/account menu stays archon-owned markup inside `aiur-topbar__actions`, after the package controls |

### 9.4 Theme toggle (`aiur-theme-toggle`)

- **Markup:** the button in §9.3.
- **CSS:** shows the moon when `aria-pressed=false` (light) and the sun when `true` (dark).
- **JS:** `initThemeToggle(btn)`:
  - syncs `aria-pressed` to the resolved theme, including system changes via `matchMedia` listeners;
  - on click, calls `setTheme(opposite)`;
  - removes `hidden` if the button ships hidden (archon's pattern).
- **React:** `<ThemeToggle />`.
- **Dashboard:** the existing hook calls `initThemeToggle(this.el)`.

### 9.5 Footer (`aiur-footer`)

```html
<footer class="aiur-footer">
  <span class="aiur-footer__brand"><span class="aiur-footer__dot" aria-hidden="true"></span>aiur</span>   <!-- aiur.team only -->
  <nav class="aiur-footer__links" aria-label="Footer">…</nav>                                              <!-- optional -->
  <p class="aiur-footer__credit aiur-keepout">built with <a href="https://aiur.team">Aiur</a></p>             <!-- products -->
</footer>
```

- The credit sits on the flow field, so it is a keepout.
- aiur.team omits the credit (Q5).

### 9.6 Command box and tabs (`aiur-command`, `aiur-tabs`)

```html
<div class="aiur-command aiur-keepout" data-aiur="command">
  <div class="aiur-tabs" role="tablist" aria-label="Get started">
    <button type="button" role="tab" id="t-prompt" aria-selected="true"  aria-controls="cmd-panel" data-aiur-text="Let's run parallel agents with: https://aiur.team/" data-aiur-kind="prompt">Prompt</button>
    <button type="button" role="tab" id="t-npm"    aria-selected="false" aria-controls="cmd-panel" tabindex="-1" data-aiur-text="npm i -g aiur-cli">npm</button>
    …
  </div>
  <div class="aiur-command__row" id="cmd-panel" role="tabpanel" aria-labelledby="t-prompt">
    <span class="aiur-command__prompt" aria-hidden="true">$</span>
    <code class="aiur-command__text">Let's run parallel agents with: https://aiur.team/</code>
    <button type="button" class="aiur-command__copy aiur-button aiur-button--ghost aiur-button--icon" aria-label="Copy prompt">…</button>
    <span class="aiur-visually-hidden" role="status" aria-live="polite"></span>
  </div>
</div>
```

**JS:** `initCommand(el, { onCopy?(text, kind), copiedMs = 1500, labels?: {prompt, command} })`.
- **Tabs:** roving tabindex, ←/→/Home/End, activation on click, Enter or Space.
- **Copy:** the Clipboard API with the textarea fallback (ported from `main.ts:78-101`). The status region announces "Copied".
- **Prompt symbol:** the `$` is hidden when `data-aiur-kind="prompt"`, and the prompt character (`$` / `>`) is set by `data-aiur-prompt`.
- **Coming soon:** `aria-disabled="true"` on the root plus `.aiur-command--soon` renders the greyed state with a `.aiur-command__soon` label. Copy and tab buttons are then `disabled`.
- **Next steps:** the aiur.team next-steps drop-down stays aiur.team markup. It is driven by `onCopy`.

**R-TAB-1 (operator requirement): the box follows the selected tab.**
1. `.aiur-command` is `display:inline-flex; flex-direction:column; width:max-content; max-width:100%`. Its rendered width is `max(tablist intrinsic width, current row intrinsic width)`, recomputed on every tab change. No width, `min-width` or grid track may be pinned to the widest tab.
2. Tabs are `flex: 1 0 auto`. The tablist never exceeds the row unless its own content is wider.
3. On tab change the command dispatches `aiur:layoutchange` on the element. The field module (§9.8) also observes every keepout with `ResizeObserver`. So the canvas keepout re-hugs the box **within one animation frame** of the resize, with no wait for a window resize.
4. Tested at **each** tab:
   - `|box.width − max(tablist.scrollWidth, row.scrollWidth)| ≤ 1px`
   - for npm vs Prompt: `box(npm).width < box(Prompt).width − 40px` at a 1280px viewport
   - the field's obstacle for the box has `hx*2 − 2*padX` equal to `box.width` (±1px). The field exposes `field.debug().obstacles` only when `data-aiur-debug` is set on the canvas.

### 9.7 Scroll cue, features and prose

- **`aiur-scrollcue`:**
  - Markup: `<div class="aiur-scrollcue" data-aiur="scrollcue" aria-hidden="true"><span>scroll</span><svg class="aiur-scrollcue__chev">…</svg></div>`.
  - `initScrollCue(el, { hideAfter = 60, hideWhen?: () => boolean })`.
  - Colour is `--aiur-color-muted` (DR-8). Reduced motion removes the nudge and the fade.
- **`aiur-features`** > `article.aiur-feature`:
  - Children: `.aiur-feature__head` (`.aiur-feature__icon` 26px accent SVG + `.aiur-feature__index` "01"), `h3.aiur-feature__title`, `p.aiur-feature__body`.
  - `--aiur-features-cols` defaults to 3; the grid drops to 2 columns at ≤720px and 1 at ≤440px (DR-11).
- **Prose:** `p.aiur-summary`, `.aiur-hl` (accent highlight), `.aiur-signoff`, `.aiur-hint` ("tell your agent:").
- **Hero lockup** (`.aiur-lockup`, `.aiur-lockup__logo`, `.aiur-wordmark` with per-letter spans):
  - Sizes come from `--aiur-lockup-logo-size` and `--aiur-wordmark-size`, which each product overrides.
  - Screen-reader text: `aria-label` on the `h1` with the spans `aria-hidden` (DR-13).

### 9.8 Flow field and diagonal lines (`aiur-field`)

```html
<section class="aiur-hero">
  <canvas class="aiur-field" data-aiur="field" aria-hidden="true"></canvas>
  … elements with class aiur-keepout (and aiur-hug for per-line text) …
</section>
```

```ts
createFlowField(canvas: HTMLCanvasElement, opts?: {
  host?: HTMLElement;            // default canvas.parentElement
  keepouts?: string;             // default '.aiur-keepout, .keepout'
  hug?: string;                  // default '.aiur-hug, .hug'
  angleDeg?: number;             // -118
  spacing?: number;              // 23
  step?: number;                 // 7
  gap?: number;                  // 9
  fade?: number;                 // 260 (CSS mask via --aiur-field-fade)
  logoSelector?: string;         // '.aiur-lockup__logo, .logo' → pad 3/1, radius .95
  entranceMs?: number;           // 1500, 0 under prefers-reduced-motion
}): { redraw(): void; rebuild(): void; destroy(): void; debug(): { obstacles: Obstacle[] } }
```

The module merges the three forks:
- the aiur.team algorithm, bit-for-bit, verified by a pixel test against the old module at the same inputs;
- khala's `Range.getClientRects()` per-line hugging;
- archon's theme-event redraw;
- **plus** a `ResizeObserver` on every keepout and on the host, and a `MutationObserver` for keepouts added or removed (DR-9, R-TAB-1).

It reads `--aiur-color-field-line` live, caps DPR at 2, and draws once and stops (no idle rAF).

**CSS-only variant** `.aiur-lines`: the docs' `repeating-linear-gradient(112deg)` with a radial mask, for places that cannot run the canvas (VitePress home hero).

### 9.9 Shell and page frame (`aiur-shell`, `aiur-page`), extracted from the dashboard

```html
<div class="aiur-shell" data-nav-collapsed="false">
  <header class="aiur-shell__topbar">…aiur-brand, status slot, aiur-shell__controls…</header>
  <div class="aiur-shell__body">
    <aside class="aiur-shell__sidebar">
      <nav class="aiur-shell__nav" aria-label="Primary">
        <a class="aiur-shell__item" aria-current="page" href="…">
          <span class="aiur-shell__icon" aria-hidden="true"><svg…/></span><span class="aiur-shell__label">Units</span><span class="aiur-shell__count">3</span></a>
      </nav>
      <button type="button" class="aiur-shell__toggle" aria-pressed="false" aria-label="Collapse navigation">…</button>
    </aside>
    <main class="aiur-shell__main">
      <section class="aiur-page" aria-labelledby="page-title">
        <header class="aiur-page__header"><h1 id="page-title" class="aiur-page__title"><span class="aiur-page__icon">…</span>Units</h1><p class="aiur-page__description">…</p></header>
        <div class="aiur-page__banner" role="status">…</div>
        <div class="aiur-page__body">…</div>
      </section>
    </main>
  </div>
  <nav class="aiur-shell__nav aiur-shell__nav--pill" aria-label="Primary">…same items…</nav>   <!-- ≤959px -->
</div>
```

- **CSS:** lifted from `dashboard.css` lines 227-400, 1865-2063 and 6055-6234, with the values unchanged (15rem / 2.6rem, 75rem measure, bottom pill max 26rem, radius 16px, 960px breakpoint).
- **JS:** `initShellNav(shell, { storageKey = 'aiur-nav-collapsed', onToggle?(collapsed) })`. The dashboard keeps its server-owned state and calls only the storage part through its hook.
- **React** (`aiur-style/react`):
  - `<AiurShell brand navItems={[{href,label,icon?,count?,attention?,current?}]} controls collapsed? onCollapsedChange? mode?: 'standalone'|'hosted-content'>`
  - `<PageFrame title icon? description? banner?>`
  - These replace Khala's `AiurShell.tsx` and `KhalaPageFrame.tsx`. The props are a superset of Khala's existing `types.ts`, so call sites change only their imports.
- **HEEx:** `dashboard_shell.ex` keeps its function component and switches to the `aiur-shell__*` classes.

### 9.10 Assets and fonts

- `fonts.css` declares `@font-face` for `Bungee` (400), `Space Grotesk` (300–700 variable) and `JetBrains Mono` (100–800 variable) with `font-display: swap`. URLs are relative (`./fonts/…`), so the file works wherever `dist/` is copied.
- The favicon set and `site.webmanifest` template are in `assets/`.
- **Logo:** the original `aiur-logo.png` is 594 KB and is loaded by four products. AS-12 adds `aiur-logo-512.png` and `aiur-logo-512.webp`. They pass a pixel test at rendered sizes ≤224px against the original (max ΔE < 2), so swapping the logo is a no-visual-change PR.

---

## 10. How each consumer uses it

| Consumer | Install | CSS | JS | Pre-paint | Fonts/assets |
|---|---|---|---|---|---|
| aiur.team (`website/`) | `"aiur-style": "file:../packages/aiur-style"` in `website/package.json`. Netlify clones the whole repo, so `../packages` exists; `bun install` and `npm ci` both resolve `file:` | `import "aiur-style/aiur-style.css"` in `main.ts` | `import { createFlowField } from "aiur-style/field"`, `initCommand`, `initBanner`, `initBrandReveal`, `initThemeToggle` | `website/scripts/sync-aiur-style.mjs` (runs in `prebuild` and `predev`) copies `dist/init/theme-init.js`, `dist/fonts`, `dist/assets` → `website/public/aiur-style/` (gitignored); `<script src="/aiur-style/theme-init.js" data-default="dark" data-banner="archon-launch" data-legacy-keys="aiur-archon-banner">` | via sync |
| docs (`website/docs-app/`) | `file:../../packages/aiur-style` | `import 'aiur-style/tokens.css'`, `'aiur-style/fonts.css'`, `'aiur-style/vitepress.css'` in `.vitepress/theme/index.ts`; `custom.css` keeps only docs-specific rules | none (VitePress controls) | `config.ts` `head: [['script', { src: '/aiur-style/theme-init.js', 'data-default': 'dark', 'data-vitepress': 'true' }]]`. The docs share `publicDir: '../public'`, so the aiur.team sync covers it | Google Fonts `<link>`s removed |
| Dashboard (`src/`) | `scripts/sync-aiur-style` (and `mix aiur.style.sync`) copies `packages/aiur-style/dist/{aiur-style.css,tokens.css,fonts,assets,js,init}` → `src/priv/static/aiur-style/`, **committed** | `<link rel="stylesheet" href="/aiur-style/aiur-style.css">` before `/dashboard.css` in `layouts.ex` | `<script type="module" src="/aiur-style/js/theme.js">` + hooks importing from it | Replace the inline script at `layouts.ex:25-34` with `<script src="/aiur-style/init/theme-init.js" data-default="dark">` | Add all to `static_assets.ex`, the router static routes and the `Plug.Static` `only:` list. `bungee.woff2` moves under `/aiur-style/fonts/` |
| archon (`site/`) | Root `package.json` `devDependencies: {"aiur-style": "0.x.y"}` (exact) | `templates/docbuild/src/site.ts` `copyServedContent` also copies `node_modules/aiur-style/dist` → `_site/aiur-style/`. `site/index.html` swaps its inline `<style>` component rules for `<link rel="stylesheet" href="/aiur-style/aiur-style.css">`; only archon-specific rules (sign-in, account menu) stay inline | `<script type="module" src="/aiur-style/js/auto.js">` + a small archon inline module | `<script src="/aiur-style/init/theme-init.js" data-banner="aiur-launch" data-legacy-keys="archon.theme archon.banner.aiur.dismissed">` | **CSP change** in `netlify/lib/edge-host.mjs`: landing and 404 need `font-src 'self'`. Google Fonts hosts can then be removed from `style-src` / `font-src` / `connect-src` |
| khala splash (`apps/web/src/landing/`) | `apps/web/package.json` `"aiur-style": "0.x.y"` (exact) | `import 'aiur-style/aiur-style.css'` in `main.ts` | ES imports from `aiur-style/*` (bundled by Vite, same origin) | `apps/web/scripts/sync-aiur-style.mjs` copies `init/theme-init.js` into `src/landing/public/aiur-style/` at build time; `<script src="/landing/aiur-style/theme-init.js" data-banner="aiur-launch" data-legacy-keys="khala.theme khala.aiur-banner.dismissed">`. Replaces `public/theme-init.js` + `banner-init.js` | `brand/fonts` replaced by `aiur-style/fonts.css` (same files, so no visual change) |
| Khala app (`apps/web/src/shell/`) | same | `import 'aiur-style/css/shell.css'`, `'aiur-style/css/page.css'`, `'aiur-style/css/button.css'` | `import { AiurShell, PageFrame, ThemeToggle } from 'aiur-style/react'` | same init file | same |

---

## 11. Visual-regression safety net

**Principle:** no migration PR runs before its consumer has committed screenshot baselines. Baselines are captured from `main` as it is today, by tickets AS-01 to AS-04. Every later PR must keep them green or update them deliberately.

### Capture recipe (shared by every consumer)

- **Runner:** Playwright Test ≥ 1.54 with `expect(page).toHaveScreenshot()`, Chromium only.
- **Container:** run inside the pinned **`mcr.microsoft.com/playwright:v<same-version>-noble`** image (in CI and via `npm run test:visual:docker` locally), so font rasterisation matches.
- **Snapshot location:** snapshots live next to the spec (`*-snapshots/`). The platform suffix is linux.
- **Matrix:**

  | Dimension | Values |
  |---|---|
  | Theme | `light`, `dark` (set via `localStorage` + the init script, not by clicking) |
  | Viewport | `1280×800`, `390×844` (DPR 3, `isMobile`) |
  | Extra (sites with the field) | `844×390` |

- **Determinism:**
  - `reducedMotion: 'reduce'`, which draws the field's final state with no entrance.
  - `await document.fonts.ready`.
  - `animations: 'disabled'`, `caret: 'hide'`.
  - Mask truly dynamic regions: the aiur.team terminal sim `#termScreen` (it has its own text golden), timestamps and live data on the dashboard (the fixture server already fixes data).
  - Fonts must be served locally or routed: `page.route('https://fonts.g*/**')` serves files from `node_modules/aiur-style/dist/fonts` until the consumer migrates, so Google Fonts latency cannot flake baselines.
- **Tolerance:** `maxDiffPixelRatio: 0.002`, `threshold: 0.2`. Tighter is flaky on the canvas's anti-aliased lines; looser hides 1px spacing drift.
- **Element shots** in addition to full page, for each component on the page (banner, topbar, command box per tab, feature grid, footer, shell nav, expanded and collapsed). This localises a diff to one component.

### Per consumer

| Consumer | Where | Pages / states | Runs in |
|---|---|---|---|
| aiur.team + docs | `website/tests/visual.spec.ts` (+ `website/playwright.config.ts` `projects`) | `/` (top, scrolled past hero, banner dismissed, each of 5 tabs, next-steps open), `/docs/`, `/docs/guide/quick-start`, product switcher open | `website.yml` (new step `npm run test:visual`) |
| Dashboard | `src/browser/tests/visual-shell.browser.spec.mjs` (fixture server) | `/`, `/build-orders`, `/analytics`; nav expanded and collapsed; ≤959px bottom pill | `ci.yml` job `browser` |
| archon | new `site/tests/visual.spec.mjs` + `playwright.config.mjs` serving `_site/` after `templates/build --site` (offline; stub the edge gate by serving static) | `/` signed-out, banner dismissed, `/404.html`, `/welcome/` | `check.yml` new job `site-visual` |
| khala | new `apps/web/playwright.visual.config.ts` + `src/landing/landing.visual.spec.ts`, `src/shell/shell.visual.spec.ts` (serves `dist/landing` via `vite preview` + the existing shell browser-harness page) | splash top, scrolled, banner dismissed, coming-soon box; shell expanded, collapsed, mobile | `ci.yml` step after `test:browser` |
| package | `packages/aiur-style/test/gallery.visual.spec.ts` | every component × variant × state (hover/focus/pressed forced via `:hover` emulation and `.is-hover` test classes) × theme | `aiur-style.yml` |

### Rules for migration PRs (enforced by review and by the tickets' acceptance criteria)

1. Structural refactor PRs change **zero** baselines.
2. Intended drift fixes (§4) each come as a separate commit that only updates the named baselines. The PR description embeds the Playwright diff images (`test-results/**-diff.png`) for each.
3. Baselines are never regenerated wholesale (`--update-snapshots`) in a migration PR. Updates are per spec file (`--update-snapshots -g "<name>"`) and listed.
4. The package gallery baselines change **only** in package PRs, never in consumer PRs.

### Behavioural "fails against a wrong implementation" tests

Every ticket names at least one of these. Examples:
- R-TAB-1 fails if the keepout is only rebuilt on window resize.
- The pre-paint test fails if the theme is applied from a module script (the MutationObserver sees the wrong theme first; this is the existing `brand.spec.ts` technique).
- The CSP test fails if any inline script remains (khala: serve with the production CSP header in `vite preview` and assert zero `securitypolicyviolation` events).

---

## 12. Tickets and migration order

**Phases:**
1. Safety nets.
2. Package foundation.
3. Core components.
4. Backgrounds.
5. First release.
6. Consumer migrations: khala splash → archon → aiur.team → docs → dashboard. The shell work runs in parallel where dependencies allow.
7. Remove duplicates.

Each ticket is one agent PR. Issue links are in the umbrella issue.

| ID | Repo | Slug | Cx | Blocked by |
|---|---|---|---|---|
| AS-01 | aiur | `aiur-style-visual-baselines-aiur-team` | 3 | — |
| AS-02 | aiur | `aiur-style-visual-baselines-dashboard` | 3 | — |
| AS-03 | archon | `aiur-style-visual-baselines-archon-site` | 3 | — |
| AS-04 | khala | `aiur-style-visual-baselines-khala-web` | 3 | khala#163 (channel copy) |
| AS-05 | aiur | `aiur-team-command-box-follows-tab` | 2 | AS-01 |
| AS-10 | aiur | `aiur-style-package-scaffold` | 3 | — |
| AS-11 | aiur | `aiur-style-tokens` | 3 | AS-10 |
| AS-12 | aiur | `aiur-style-fonts-and-assets` | 2 | AS-10 |
| AS-13 | aiur | `aiur-style-theme-runtime` | 3 | AS-11 |
| AS-14 | aiur | `aiur-style-npm-publish-workflow` | 2 | AS-10 |
| AS-20 | aiur | `aiur-style-button-and-focus` | 2 | AS-11 |
| AS-21 | aiur | `aiur-style-banner` | 2 | AS-13, AS-20 |
| AS-22 | aiur | `aiur-style-topbar-and-theme-toggle` | 3 | AS-12, AS-13, AS-20 |
| AS-23 | aiur | `aiur-style-footer` | 1 | AS-11 |
| AS-24 | aiur | `aiur-style-command-box-and-tabs` | 3 | AS-20, AS-05 |
| AS-25 | aiur | `aiur-style-content-sections` | 2 | AS-11 |
| AS-26 | aiur | `aiur-style-shell-and-page-frame` | 4 | AS-13, AS-20 |
| AS-27 | aiur | `aiur-style-react-wrappers` | 3 | AS-26, AS-22 |
| AS-28 | aiur | `aiur-style-vitepress-adapter` | 2 | AS-13, AS-20 |
| AS-30 | aiur | `aiur-style-flow-field` | 4 | AS-13, AS-05 |
| AS-35 | aiur | `aiur-style-release-0-1-0` | 1 | AS-14, AS-21, AS-22, AS-23, AS-24, AS-25, AS-26, AS-27, AS-28, AS-30 |
| AS-44 | khala | `khala-splash-adopts-aiur-style` | 3 | AS-04, AS-35 |
| AS-46 | archon | `archon-site-adopts-aiur-style` | 4 | AS-03, AS-35 |
| AS-40 | aiur | `aiur-team-adopts-aiur-style` | 4 | AS-01, AS-21, AS-22, AS-23, AS-24, AS-25, AS-30 |
| AS-41 | aiur | `aiur-docs-adopt-aiur-style` | 3 | AS-40, AS-28 |
| AS-42 | aiur | `dashboard-adopts-aiur-style-foundation` | 3 | AS-02, AS-11, AS-12, AS-13 |
| AS-43 | aiur | `dashboard-adopts-aiur-style-shell` | 4 | AS-42, AS-26 |
| AS-45 | khala | `khala-app-shell-adopts-aiur-style` | 4 | AS-44, AS-35 |
| AS-50 | aiur | `aiur-style-dedupe-aiur` | 2 | AS-40, AS-41, AS-43 |
| AS-51 | khala | `aiur-style-dedupe-khala` | 2 | AS-44, AS-45 |
| AS-52 | archon | `aiur-style-dedupe-archon` | 2 | AS-46 |

**Why AS-05 lands before the package:** it is the operator's visible bug and a 20-line fix in `website/src/flowField.ts` + `main.ts`. AS-24 and AS-30 then carry the same test into the package, and AS-40 re-runs it against the package-backed page.

**Critical path:**

AS-10 → AS-11 → AS-13 → AS-26 → AS-27 → AS-35 → AS-44 → AS-45 → AS-51

That is 9 PRs. With the four baseline tickets, AS-05, AS-12, AS-14, AS-23 and AS-25 in parallel, a single-lane executor finishes in about 31 PRs. With 3–4 parallel agents it takes about 10–11 waves.

---

## 13. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **Screenshot flake** (canvas anti-aliasing, font hinting, GPU) blocks every PR | High | Pinned Playwright container; reduced-motion static field; local fonts; `maxDiffPixelRatio 0.002`; element-level shots; baselines captured in CI's container, never on a dev laptop |
| Dashboard CSS cascade collisions: `dashboard.css` (10k lines) has generic class names (`.topbar`, `.btn`) that could beat or lose to package rules | High | Package rules live in `@layer aiur`, and unlayered dashboard rules win by default. The package uses only `aiur-*` classes. AS-42 adds nothing visual; AS-43 swaps shell classes in one file (`dashboard_shell.ex`) plus the `dashboard.css` line ranges it deletes |
| Dashboard font change (Space Grotesk and JetBrains Mono actually loading) reflows tables and truncation | Medium | DR-10 is its own commit in AS-42 with full-page diffs. The existing `shell-content-width` and `build-order-responsive` specs must stay green |
| archon CSP: moving to self-hosted fonts and external CSS/JS without updating `edge-host.mjs` breaks the landing page silently | Medium | AS-46 updates `edge-host.mjs` and `netlify/test/edge-host.test.mjs` together, and adds a Playwright check with the production headers applied (no `securitypolicyviolation`) |
| khala CSP regression via an inline `<script>` from the package or Vite | Medium | The package never emits inline script (package test greps `dist/**/*.html` and the `markup/` fixtures). The khala visual config serves the production CSP header |
| npm publishing needs operator setup (trusted publisher for `aiur-style`) | Certain | AS-14 proves the workflow with `--dry-run`. AS-35 is `complexity:1` but **blocked on the operator** creating the npm package, or granting the org the OIDC trusted publisher (Q1) |
| `file:` dependency differences between bun (Netlify) and `npm ci` (CI) | Medium | AS-40 runs both in CI (`bun install --frozen-lockfile` then `npm ci`) and commits both lockfiles, as today |
| `dist/` committed → merge conflicts across parallel component PRs | High | `dist/` is fully generated. The conflict rule is to take either side and run `npm run build`, and `check-dist` catches mistakes. The component tickets are ordered so at most ~3 run in parallel |
| Legacy storage keys: visitors who dismissed a banner see it again | Low | `data-legacy-keys` migration, with a test per consumer |
| Scope creep into dashboard feature components (cards, tables, build-order grid) | Medium | Out of scope (§14); the package takes only what two or more consumers share |
| Khala #163 ("channel" rename) conflicting with the splash migration | Medium | AS-04 is blocked by khala#163, so baselines include the new copy. Any Khala copy a ticket touches uses "channel", never "chat" or "room" |
| Operator-visible drift fixes (DR-1, DR-2, DR-4, DR-5, DR-12) disliked after landing | Medium | Each is a separate commit with diff images; open questions Q3 and Q4 settle them before the migration tickets start |

---

## 14. Out of scope

- **archon `templates/base`** (document renderer, npm `aiur-archon` payload). It has a separate palette (`--ink`, `--surface`, `#FF0420` accent), is inlined into every generated doc, is guarded by `templates/check-dist`, and claims "no runtime dependencies". A later, separate proposal could let it read `aiur-style/tokens` at *build* time. Not now.
- The dashboard's feature components (units table, build-order grid, Stream Deck emulator, conversation drawer, analytics) and its status banners. Only the shell, page frame, buttons, focus ring, tokens, fonts and theme move.
- The aiur.team terminal simulation (`src/dashboard.ts`, `--term-*` tokens, text golden).
- `ProductSwitcher.vue`: single consumer (docs). It stays in the docs and switches to `--aiur-*` tokens in AS-41.
- archon's sign-in bar and account menu: archon-only. They stay in `site/` and `welcome/`.
- Khala product feature screens (`features/**`). AS-45 changes only the shell they sit in.

---

## 15. Open questions for the operator

1. **Q1: package name and npm ownership.** Recommendation: **`aiur-style`** (unscoped, free today, matches `aiur-cli` and `aiur-archon`). Alternative: `@aiur/style`, but the `@aiur` npm scope's ownership is unverified. Who creates the npm package and configures the GitHub OIDC trusted publisher for `aiur-team/aiur` → `aiur-style`?
2. **Q2: default theme.** aiur.team, the docs and the dashboard force dark when nothing is stored; archon and khala follow the system. Keep the per-site defaults (the plan's default), or make every site follow the system?
3. **Q3: Docs button on aiur.team.** It is a mono text link today and a filled pill on archon/khala. The plan makes it the filled pill everywhere (DR-4). OK?
4. **Q4: dashboard dark-theme button fill.** The dashboard uses `#0070f0` in dark. The plan unifies on `#1f57c4` (white text 6.5:1 vs 4.59:1). OK to change the dashboard's primary buttons?
5. **Q5: "built with Aiur" on aiur.team itself.** The plan omits it there (aiur.team keeps its brand footer) and uses it on every product site. OK?
6. **Q6: dashboard muted text colour** (`#969aa4` → `#8c8d93` dark, `#635a48` → `#5f5645` light, DR-6). Accept the small shift, or keep the dashboard's values as the canonical ones?
7. **Q7: the aiur.team banner.** It announces Archon today. Should aiur.team show a banner at all long-term, and which campaign id should it use?
