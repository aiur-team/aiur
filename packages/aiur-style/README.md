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

## Development

See the aiur-style plan: [docs/aiur-style/plan.md](../../docs/aiur-style/plan.md).

To build locally:

```bash
npm run build        # Compile TypeScript and concatenate CSS
npm run check-dist   # Verify dist/ matches the build
npm test             # Run node tests
npm run test:visual:docker # Run visual tests in the pinned CI container
```

## Releases

Releases use `.github/workflows/aiur-style-release.yml`, independently of the
`aiur-cli` workflow. PRs touching this package run `check-dist`, the release
verifier's node:test suite, `npm pack`, and `npm publish --dry-run`. The pack file
list appears in the Actions summary and the `aiur-style-pack` artifact. PRs never
publish and do not receive OIDC write permission. Both jobs set the packed
manifest's `repository` to `aiur-team/aiur` and directory to `packages/aiur-style`
for npm provenance; the checked-in manifest is unchanged.

One-time operator setup (before the first automated release):

1. Establish ownership of the unscoped npm package `aiur-style`. If it does not
   exist, an authorized maintainer must bootstrap it on npm; that initial publish
   is a separate operator action, not part of this workflow change.
2. In the package's npm settings, add a GitHub Actions trusted publisher:
   organization **aiur-team**, repository **aiur**, workflow filename
   **aiur-style-release.yml**. Leave the environment field empty (the job uses no
   GitHub environment), and allow direct `npm publish` if that option is shown.
   See [npm trusted publishing](https://docs.npmjs.com/trusted-publishers/).
   No npm token secret is required. The job uses Node 24 and npm >= 11.5.1.

For a release, update `package.json` and the lockfile to a stable semver, add a
`## [<version>]` heading to `CHANGELOG.md`, rebuild and commit `dist/`, and merge
those changes. Push the tag `aiur-style-v<version>` on the release commit.
The workflow rejects a tag/version mismatch, a missing changelog heading, or
stale `dist/`, then publishes with provenance and waits up to about two minutes
for that exact version to become visible on npm. Do not push a release tag just
to test the workflow: tags trigger a real publish after validation.

Run the release checks locally from the repository root:

```bash
node packages/aiur-style/scripts/verify-release.mjs --self-test
node packages/aiur-style/scripts/verify-release.mjs aiur-style-v<version>
```

## License

MIT
