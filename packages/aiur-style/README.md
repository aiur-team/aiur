# aiur-style

Consolidated design system and component library for the Aiur family of sites: aiur.team, Aiur dashboard, archon.aiur.team, and khala.aiur.team.

## Status

Version 0.1.0 provides:
- Design tokens and CSS component styles
- Plain ES-module behaviors that progressively enhance server-rendered markup
- A pre-paint theme initialization script
- Self-hosted fonts and brand assets
- A thin React wrapper subpath (for Khala app)
- A VitePress adapter stylesheet (for docs)

Components and consumer migrations are tracked in the aiur-style umbrella issue: [aiur-team/aiur#2792](https://github.com/aiur-team/aiur/issues/2792).

## Installation

```bash
npm install --save-exact aiur-style@0.1.0
```

## Usage

### CSS

Import the main CSS file in your document:

```html
<link rel="stylesheet" href="node_modules/aiur-style/dist/aiur-style.css">
```

Or in JavaScript/TypeScript:

```javascript
import 'aiur-style/aiur-style.css';
```

`tokens.css` exposes `--aiur-color-fg-dark` and `--aiur-color-accent-dark` for fixed-dark device surfaces. Both are generated from the dark palette and stay constant when the page theme changes.

### JavaScript

Theme and banner behaviors are exported from the package root.

```javascript
import { getTheme, setTheme, onThemeChange, initThemeToggle } from 'aiur-style';
```

## Theme

The package supports light and dark themes via the `data-theme` attribute on `<html>`:

```html
<html data-theme="dark">
  <!-- content -->
</html>
```

When the attribute is absent, the theme follows the system preference via `prefers-color-scheme`.

Load the external classic initializer as the first child of `<head>`, before
stylesheets. Copy it from `aiur-style/theme-init.js` into your public assets;
do not use `type="module"`, `async`, `defer`, or inline script code.

```html
<script src="/aiur-style/theme-init.js" data-default="dark"
  data-legacy-keys="khala.theme" data-banner="aiur-launch"></script>
```

Stored `light`/`dark` wins over `data-default` (`system` by default). System mode
leaves the attribute absent. `data-storage-key` overrides `aiur-theme` for both
initialization and runtime persistence. Space-separated `data-legacy-keys`
migrate the first valid theme and the first banner dismissal (`dismissed` or
`1`), without overwriting an existing choice. A migrated key is removed only
after the new value is written. `data-banner` selects `aiur-banner:<id>`;
`dismissed` sets `html[data-aiur-banner="dismissed"]` before paint.
`data-vitepress="true"` synchronizes `vitepress-theme-appearance` (including
`auto` for system mode) and `html.dark` during initialization only. Runtime
`setTheme()` does not synchronize VitePress. Storage failures never prevent rendering.

`getTheme()` resolves the attribute or system preference. `setTheme(theme,
{persist: false})` changes only the current page; persistence defaults to true.
Each attribute change dispatches `aiur:themechange` on `document` with
`detail: {theme}`. `onThemeChange(callback)` observes explicit choices and system
changes while the attribute is absent, and returns an unsubscribe function.

`initThemeToggle(button)` reveals a hidden button, synchronizes `aria-pressed`
(true means dark), and toggles relative to the resolved theme. Repeated calls
bind once; the first call's `{destroy}` removes the listeners and permits
initialization again. Supply `type="button"`, an accessible label, and
`aria-hidden="true"` on decorative icons in your markup.

## Announcement banner

Use `markup/banner.html` as the server-rendered pattern and load the shared CSS.
Match its `data-aiur-banner` campaign id to the initializer's `data-banner`.
Initialize it from an external module:

```javascript
import { initBanner } from 'aiur-style/banner';
const banner = initBanner(document.querySelector('[data-aiur="banner"]'));
// When the element is removed:
banner.destroy();
```

Alternatively, load `dist/js/auto.js` as an external module to initialize
`data-aiur="banner"` elements. Closing saves `aiur-banner:<id>=dismissed`,
hides the banner, moves focus to the next control (or `main`/`body`), and
emits a bubbling `aiur:bannerdismiss` event. Storage failures still allow
closing for the current page. Choose a new campaign id to show a new message.

## Tokens

`src/tokens/tokens.json` is the source for `dist/tokens.css`, `dist/tokens.js`,
`dist/tokens.d.ts`, and the token layer in `dist/aiur-style.css`. CSS names use
`--aiur-{group}-{role}`; JavaScript keys use `group.role`.

```javascript
import { tokens, breakpoints, contrastPairs } from 'aiur-style/tokens';
import 'aiur-style/tokens.css'; // Or load the complete aiur-style.css instead.
```

Colors have `light` and `dark` values; other tokens have `value` (theme-specific
shadow values use a light/dark object). Every entry records its description and
source. Aliases such as `{color.muted}` resolve to CSS `var()` references and
concrete values in the JavaScript maps.

The brand palette stays fixed. For readable text, use these substitution tokens
on the named background; their per-theme aliases and explanations live together
in `tokens.json`:

| Text token | Background | Substitution |
|---|---|---|
| `--aiur-color-faint-on-bg` | `--aiur-color-bg` | Light: muted; dark: faint |
| `--aiur-color-faint-on-bg-2` | `--aiur-color-bg-2` | Light: muted; dark: faint |
| `--aiur-color-faint-on-bg-app` | `--aiur-color-bg-app` | Light: muted; dark: faint |
| `--aiur-color-accent-on-bg-2` | `--aiur-color-bg-2` | Light: accent-ink; dark: accent |
| `--aiur-color-accent-on-surface-2` | `--aiur-color-surface-2` | Light: accent; dark: accent-ink |

Raw light faint is below 4.5:1 on page backgrounds; raw light accent on bg-2 and
raw dark accent on surface-2 also fail. `contrastPairs` describes readable text
combinations (4.5:1) and focus indicators (3:1), including these substitutions.
White text belongs on `fill`, `fill-hover`, or `fill-pressed`, never dark `accent`.
`breakpoints` exports `{shell: 960, features2: 720, features1: 440}` in pixels.

The [gallery](gallery/index.html) shows every color, its resolved value, and a
sample in either theme. `?theme=system` previews the system preference.

## Development

See the aiur-style plan: [docs/aiur-style/plan.md](../../docs/aiur-style/plan.md).

`dist/` is generated and is not committed. The `prepare` lifecycle builds it
when the package is installed from this repository and when npm packs it for
publication. To build locally:

```bash
npm run build        # Compile TypeScript and concatenate CSS
npm run check-dist   # Verify dist/ matches the build
npm test             # Run node tests
npm run test:visual:docker # Run visual tests in the pinned CI container
```

## Releases

`.github/workflows/aiur-style-release.yml` runs read-only PR dry-runs and a
separate OIDC publish job on `aiur-style-v*` tags. The publish job uses Node 24,
verifies the tag/version and changelog, checks freshly built `dist/`, tests the
installed tarball exports, then publishes with `--provenance --access public`.
Only that job has `id-token: write`; no npm token secret is needed.
The packed manifest identifies `aiur-team/aiur`, directory `packages/aiur-style`.

Before the first tag, the operator must bootstrap ownership of `aiur-style`
(for example by publishing the pre-release-preparation `0.0.0` from main), then
configure its npm trusted publisher: organization **aiur-team**, repository
**aiur**, workflow **aiur-style-release.yml**, no environment. Allow direct
`npm publish`. See [npm trusted publishing](https://docs.npmjs.com/trusted-publishers/).
Do not tag until that setup is complete.

Prepare stable semver in `package.json` and its lockfile, add the matching
`## [<version>]` changelog heading, and rebuild generated `dist/`. Verify without
publishing from the repository root:

```bash
node packages/aiur-style/scripts/verify-release.mjs --self-test
node packages/aiur-style/scripts/verify-release.mjs aiur-style-v0.1.0
node --test packages/aiur-style/test/pack.test.mjs
```

After review and merge, the release operator pushes `aiur-style-v0.1.0` on the
merge commit. Check the Actions publish job, `npm view aiur-style@0.1.0 dist.tarball`,
and the npm provenance record, then install the registry version in a clean project.

## Consumer recipes

- **aiur.team:** use `file:../packages/aiur-style`, import the main CSS and root
  controllers, and import `createFlowField` from `aiur-style/field`. Copy the
  initializer, fonts and assets to public files during prebuild/predev.
- **VitePress docs:** use `file:../../packages/aiur-style`; import `tokens.css`,
  `fonts.css` and `vitepress.css`. Add the external initializer to `head` with
  `data-vitepress="true"`; VitePress owns runtime theme controls.
- **Dashboard:** run `scripts/sync-aiur-style` to copy generated assets into
  `src/priv/static/aiur-style/`; serve CSS, module behaviors and the classic
  initializer from that directory.
- **Archon:** pin `aiur-style` to `0.1.0`. Copy `node_modules/aiur-style/dist`
  into the served `/aiur-style/` directory, link the CSS, load `js/auto.js` as
  an external module, and load `init/theme-init.js` before paint. Serve fonts
  from the same origin with `font-src 'self'`.
- **Khala splash:** pin `0.1.0`, import the main CSS and controllers with Vite,
  and copy the initializer into landing public assets. Use external scripts
  for the CSP. Set `data-legacy-keys="khala.theme khala.aiur-banner.dismissed"`.
- **Khala app:** use the same dependency, import `css/shell.css`, `css/page.css`
  and `css/button.css`, and use the React wrappers below for channel navigation.

The initializer's exported subpath is `aiur-style/theme-init.js`; its physical
file for asset copying is `node_modules/aiur-style/dist/init/theme-init.js`.
Theme controllers come from `aiur-style` (there is no `/theme` export).

## License

MIT

## React

React 18+ is an optional peer. Vanilla imports do not load React. Import CSS
explicitly; these components render the same markup contracts as the vanilla gallery.

```tsx
import { AiurShell, PageFrame, ThemeToggle, Button } from 'aiur-style/react';
import 'aiur-style/aiur-style.css';

<AiurShell navItems={[{ href: '/channels', label: 'Channels', current: true }]}
  brand="Aiur" controls={<ThemeToggle />}>
  <PageFrame title="Channels" description="Choose a channel">
    <Button as="a" href="/channels/new">New channel</Button>
  </PageFrame>
</AiurShell>
```

`collapsed` and `onCollapsedChange` provide controlled navigation; omit `collapsed`
for stored state with an optional `defaultCollapsed`. `mode="hosted-content"`
renders only `.aiur-shell-content-root`, with `data-theme` from the host's
`theme` port or the vanilla theme controller. Khala's `navigation`, `actions`,
`headerContent`, `sidebar`, `brandHref`, and PageFrame `model` props are accepted.
`mobileControls` overrides the controls shown in the mobile pill.

`Button` accepts `variant="primary|ghost|danger|tool"`, `size="sm|md|lg"`,
`shape="pill|rounded|icon"`, native element props, and `as` (default `button`).
`ThemeToggle` initializes and destroys the vanilla controller on mount/unmount.
The package build bundles `gallery/react.tsx` with esbuild into the ignored
`gallery/dist/`; `test/react.visual.spec.ts` compares it directly with the vanilla
shell in both themes, at desktop/tablet/mobile sizes, with a 0.001 pixel ratio limit.
