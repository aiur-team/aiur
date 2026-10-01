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
import 'aiur-style/css';
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

## Development

See the aiur-style plan: [docs/aiur-style/plan.md](../../docs/aiur-style/plan.md).

To build locally:

```bash
npm run build        # Compile TypeScript and concatenate CSS
npm run check-dist   # Verify dist/ matches the build
npm test             # Run node tests
npm run test:visual  # Run Playwright visual tests (requires display)
```

## License

MIT
