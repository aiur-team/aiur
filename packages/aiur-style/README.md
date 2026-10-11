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

The package exports an empty barrel for now. Behaviors and components will be added in future updates.

```javascript
import 'aiur-style';
```

## Theme

The package supports light and dark themes via the `data-theme` attribute on `<html>`:

```html
<html data-theme="dark">
  <!-- content -->
</html>
```

When the attribute is absent, the theme follows the system preference via `prefers-color-scheme`.

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

To build locally:

```bash
npm run build        # Compile TypeScript and concatenate CSS
npm run check-dist   # Verify dist/ matches the build
npm test             # Run node tests
npm run test:visual:docker # Run visual tests in the pinned CI container
```

## License

MIT
