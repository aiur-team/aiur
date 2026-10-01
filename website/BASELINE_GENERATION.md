# Visual Baseline Generation

This document describes how to generate and commit visual test baselines for aiur.team and docs.

## Prerequisites

- Docker installed and running
- Node.js dependencies installed (`npm ci`)
- Playwright version pinned to 1.54.1

## Local Baseline Generation

The most reliable way to generate baselines matching CI environment:

```bash
cd website
npm run test:visual:docker
```

This command:
1. Runs the visual test suite in the exact Docker container used by CI
2. Generates baseline `.png` files under `tests/visual.spec.ts-snapshots/`
3. Ensures reproducibility and CI parity

### Alternative: Local Generation

If Docker is unavailable, you can generate baselines locally:

```bash
npm run test:visual:update
```

**Warning:** Local generation may produce different baselines due to OS-level rendering differences. The Docker approach is strongly preferred.

## Expected Output

- ~140 total baseline files (~90 full-page + ~50 element shots)
- Directory structure: `tests/visual.spec.ts-snapshots/{platform}/{testFileName}-{arg}.png`
- Platforms: `linux` (from Docker), or local OS if not using Docker

Example output paths:
```
tests/visual.spec.ts-snapshots/linux/visual.spec.ts-landing-top-light-desktop.png
tests/visual.spec.ts-snapshots/linux/visual.spec.ts-landing-tab-npm-dark-mobile.png
tests/visual.spec.ts-snapshots/linux/visual.selftest.spec.ts-detects-color-change.png
```

## Committing Baselines

Once baselines are generated:

```bash
git add tests/visual.spec.ts-snapshots/
git commit -m "test(visual): add baseline screenshots for aiur.team and docs

- 90+ full-page baselines across 2 themes × 3 viewports × 7 states
- 50+ element snapshots for key UI sections
- Generated in mcr.microsoft.com/playwright:v1.54.1-noble Docker container
- Captures current visual state before aiur-style (#2792) redesign"
```

## Determinism Verification

After committing, verify determinism by running CI twice:

1. Trigger GitHub Actions workflow on your PR/branch
2. Wait for the visual test job to complete and pass
3. Re-run the workflow (Re-run all jobs)
4. Verify it passes again without baseline changes

If the second run shows "snapshot mismatch" errors, the rendering is non-deterministic. Possible causes:

- Browser antialiasing differences
- Subpixel rendering variance
- Font loading timing
- Animation frame timing

**Resolution:** Increase tolerance threshold in playwright.config.ts `expect.toHaveScreenshot` settings and regenerate baselines.

## Font Fixtures

Baselines assume font fixtures are available at `tests/fixtures/fonts/`. Font files should be vendored from Google Fonts:

- Bungee (weights: 400)
- Space Grotesk (weights: 400, 500, 600, 700)
- JetBrains Mono (weights: 400, 500)

If fonts are missing, the test routing in `support/visual.ts` will fall back to CDN requests, but this may introduce network-dependent flake.

## Refresh After Design Changes

When the aiur-style redesign (#2792) lands:

1. Update baselines for the new design state:
   ```bash
   npm run test:visual:docker
   git add tests/visual.spec.ts-snapshots/
   git commit -m "test(visual): update baselines for aiur-style redesign (#2792)"
   ```

2. Verify new baselines with determinism check (run CI twice)

This ensures the visual regression suite continues to catch unintended changes on top of the intentional redesign.
