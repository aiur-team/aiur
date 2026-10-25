# aiur-style

Consolidated design system and component library for the Aiur family of sites: aiur.team, Aiur dashboard, archon.aiur.team, and khala.aiur.team.

## Status

This package is currently in development. It provides:
- Design tokens and CSS component styles
- Plain ES-module behaviors that progressively enhance server-rendered markup
- A pre-paint theme initialization script
- Self-hosted fonts and brand assets
- A thin React wrapper subpath (for Khala app)
- A VitePress adapter stylesheet (for docs)

Components and consumer migrations are tracked in the aiur-style umbrella issue: [aiur-team/aiur#2792](https://github.com/aiur-team/aiur/issues/2792).

## Installation

```bash
npm install aiur-style
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
