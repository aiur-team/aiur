---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Aiur-Style Visual Baselines (AS-02) - Plan

**Problem Frame**

Aiur's dashboard shell (nav, page frame, buttons) is about to undergo visual styling changes as part of the aiur-style initiative. To safely iterate on CSS changes without accidentally breaking layout, visual hierarchy, or spacing, we need snapshot baselines of the current shell before any styling touches occur. These baselines will be used by the visual regression suite to catch unintended visual drift during development.

**Target**

Add Playwright screenshot baselines for the dashboard shell, left nav, page frame, and button elements, with infrastructure to support consistent, masked screenshot testing across light/dark themes and multiple viewport sizes.

---

## Requirements

- Commit screenshot baselines for the dashboard shell before any aiur-style change touches `dashboard.css`
- Baselines must cover: light and dark themes, three viewport sizes (desktop, tablet, mobile)
- Baselines must include: full-page shell, nav (expanded/collapsed on desktop, bottom-pill on mobile), page elements (header, buttons)
- Existing 23 browser specs must pass unchanged
- Visual regression proof: demonstrate that test fails when CSS changes are applied to the shell

---

## Key Technical Decisions

1. **Reuse existing infrastructure:** Leverage `src/test/browser/fixture_server.exs` and browser helpers rather than building a new test harness. The fixture server is already deployed and serves the dashboard with real Aiur state.

2. **Theme seeding via localStorage:** Seed theme and nav-collapse state using `localStorage['aiur-theme']` and `localStorage['aiur-nav-collapsed']`, then trigger the `restore-nav` event (already handled by LiveViews). This mirrors how the real app loads persisted user preferences.

3. **Explicit masking for time-based elements:** Use Playwright's `mask:` option with explicit CSS locators to hide timestamps, durations, and live meter values. Create a `support/visual.mjs` module that exports the mask configuration for reuse across test suites.

4. **Pinned Playwright version in package.json:** The exact `@playwright/test` version used in CI must match the version run locally so baseline resolution and diff output remain consistent.

5. **Single test file, matrix-based parametrization:** Use Playwright's `test.describe` and `test.describe.each()` to parametrize across theme, viewport, and route combinations. This keeps test maintenance centralized and output readable.

---

## Implementation Units

### U1. Configure Playwright snapshot paths and masking defaults

**Goal**

Set up Playwright's `toHaveScreenshot()` defaults so snapshot filenames, storage paths, and mask configuration are consistent across all visual tests.

**Requirements**

R: Commit screenshot baselines before style changes

**Dependencies**

None

**Files**

- `src/browser/playwright.config.mjs` (modify)

**Approach**

Playwright's `expect` configuration accepts:
- `snapshotPathTemplate`: Determines where snapshots are stored relative to the test file. Pattern: `{dir}/{testFileDir}/{testFileName}-snapshots/{arg}{platform}{ext}`
- `toHaveScreenshot` defaults: `maxDiffPixels`, `threshold`, `animations`, and `mask` arrays

The goal is to store all snapshots in a parallel `*-snapshots/` directory alongside the test file. Set animation handling to `"disabled"` to prevent flaky timing-dependent renders. Do not pre-set a global `mask` array here — masks are test-specific and will be composed per-test; instead, export a factory function from `support/visual.mjs` that the test imports.

**Patterns to follow**

Check Playwright docs for `snapshotPathTemplate` string formatting. The snapshot dir layout should mirror the test-file structure for discoverability.

**Test scenarios**

- Configuration is loaded: verify `expect.toHaveScreenshot` is available in test files with the correct defaults
- Snapshot path resolution: run a dummy test with `expect(page).toHaveScreenshot()` and confirm the snapshot lands in the expected `*-snapshots/` directory

**Verification**

- `npm run test:visual` finds the config and emits no warnings about missing snapshot configuration
- Snapshots created by this unit land in `src/browser/tests/visual-shell.browser.spec.mjs-snapshots/`

---

### U2. Create visual masking module with time-based element masks

**Goal**

Centralize masking configuration for time-based elements (relative timestamps, durations, usage meter) so it can be imported and composed by any visual test.

**Requirements**

R: Commit screenshot baselines before style changes

**Dependencies**

None

**Files**

- `src/browser/support/visual.mjs` (new)

**Approach**

Create a module that exports a function `getMaskConfig()` which returns an array of mask objects. Each object specifies a CSS selector and optional description:

```js
export const getMaskConfig = () => [
  {
    selector: '[data-test-id="relative-time"]',
    reason: 'Relative timestamp varies by screenshot time'
  },
  {
    selector: '.duration-badge',
    reason: 'Live duration updates'
  },
  {
    selector: '.usage-meter-value',
    reason: 'Real-time usage number'
  },
  // ... other time-based elements
]
```

The function returns an array that the test can pass directly to `toHaveScreenshot({ mask: getMaskConfig() })`. This keeps mask maintenance in one place and makes it easy to add new masks without touching the test file.

**Patterns to follow**

Export the function so tests can import it: `import { getMaskConfig } from '../support/visual.mjs'`. Keep the module in `src/browser/support/` alongside other shared test utilities.

**Test scenarios**

- Module exports `getMaskConfig()` as a function
- Function returns an array of objects, each with `selector` and optional `reason`
- Test can import and call the function without errors
- Masked selectors actually exist on the dashboard shell page (checked by the visual test itself)

**Verification**

- `import { getMaskConfig }` succeeds in test files
- `getMaskConfig()` returns a non-empty array
- Array structure matches Playwright's mask format (selector strings)

---

### U3. Create visual test file with matrix parametrization

**Goal**

Implement a comprehensive Playwright test suite that captures baselines for the dashboard shell across light/dark themes, three viewport sizes, multiple routes, and nav states.

**Requirements**

R: Commit screenshot baselines before style changes
R: Baselines must cover light and dark themes, three viewport sizes
R: Routes: `/`, `/build-orders`, `/analytics`
R: Nav states: expanded, collapsed (desktop), bottom-pill (≤959px)
R: Element shots: header, nav, buttons, keyboard focus

**Dependencies**

U1 (Playwright config), U2 (mask module)

**Files**

- `src/browser/tests/visual-shell.browser.spec.mjs` (new)
- `src/browser/tests/visual-shell.browser.spec.mjs-snapshots/**` (new, generated by Playwright)

**Approach**

Use `test.describe.each()` to parametrize across themes and viewports:

```js
const THEMES = ['light', 'dark'];
const VIEWPORTS = [
  { name: '1440×900', width: 1440, height: 900 },
  { name: '1024×768', width: 1024, height: 768 },
  { name: '390×844', width: 390, height: 844 }
];
const ROUTES = ['/', '/build-orders', '/analytics'];

test.describe.each(THEMES)(
  'Visual baseline: %s theme',
  (theme) => {
    test.describe.each(VIEWPORTS)(
      '%s viewport',
      ({ name, width, height }) => {
        // Nested parametrization for routes and nav states
      }
    );
  }
);
```

For each combination:
1. Set viewport size
2. Seed `localStorage['aiur-theme']` to the theme name
3. Navigate to the route
4. Wait for LiveView to render
5. Trigger `restore-nav` event or directly set `localStorage['aiur-nav-collapsed']` based on viewport
6. Capture full-page screenshot with masks applied
7. Capture element-specific shots: `header.topbar`, `aside.shell-sidebar`, `.shell-nav-mobile`, `.route-context`, one `.btn`, one `.btn.ghost`, one `.tool-btn`
8. On small viewports (≤959px), capture bottom-pill nav state

For keyboard focus baseline:
- Navigate to a route
- Tab to the first `.shell-nav-item`
- Screenshot to capture the focus ring

**Patterns to follow**

- Use the fixture server at `http://localhost:4000` (or the configured test URL)
- Follow existing browser test patterns in `src/browser/tests/` for setup and teardown
- Use `page.addStyleTag` with specific selectors in the proof test (U4) to add CSS and verify masking catches the regression

**Test scenarios**

- **Happy path / full baseline:** For each theme × viewport × route combination:
  - Theme is set correctly (localStorage reflects the theme)
  - Full-page screenshot is captured without errors
  - All time-based elements are masked (verified later by proof test)
  - Nav state matches expectation (expanded on desktop, bottom-pill on mobile)

- **Element shots:** Each required element shoots without timeout:
  - `header.topbar` is visible and captures cleanly
  - `aside.shell-sidebar` (on desktop) or `.shell-nav-mobile` (on mobile)
  - `.route-context` (main content area)
  - Button elements (`.btn`, `.btn.ghost`, `.tool-btn`)

- **Keyboard focus:** Tab navigation and focus ring baseline:
  - First `.shell-nav-item` receives focus after Tab
  - Focus ring is visible in screenshot (proof test validates this cannot be masked accidentally)

- **Edge cases:**
  - Mobile viewport (≤959px) triggers bottom-pill nav, not sidebar
  - Dark theme localStorage value is read correctly and persists through navigation
  - Masking does not over-mask legitimate content (proof test validates this)

**Verification**

- All baseline snapshots are captured and saved to `visual-shell.browser.spec.mjs-snapshots/`
- `npm run test:visual` runs locally and passes (all screenshots match baselines)
- Snapshots include light and dark variants
- Snapshots cover all three viewport sizes
- Element-specific shots are captured and distinct from full-page shots
- Keyboard focus baseline includes focus-ring visibility

---

### U4. Implement proof test for visual regression detection

**Goal**

Verify that the visual regression suite actually catches unintended CSS changes. This proof test demonstrates that baselines are load-bearing and that masking is working correctly.

**Requirements**

R: Visual regression proof: demonstrate test fails when CSS changes applied
R: Test that adds `.shell-nav-item{padding-left:calc(0.72rem + 2px)}` via `page.addStyleTag` and asserts sidebar screenshot fails

**Dependencies**

U1, U2, U3 (baselines must exist)

**Files**

- `src/browser/tests/visual-shell.browser.spec.mjs` (add test case)

**Approach**

Add a test case within the same file that:
1. Navigates to `/` (or `/build-orders`) with light theme
2. Sets viewport to 1440×900 (desktop)
3. Takes a baseline screenshot (reference)
4. Dynamically injects CSS via `page.addStyleTag` that modifies `.shell-nav-item` padding
5. Takes a second screenshot (with the injected CSS)
6. Asserts that the two screenshots do NOT match — i.e., the test framework detects the visual difference
7. Cleans up (the tag is removed when the page unloads)

This proof demonstrates:
- The baseline is actually consulted by the comparison engine
- A real visual change (padding) is caught
- Masking doesn't accidentally hide the changed region

**Patterns to follow**

Use Playwright's `page.addStyleTag()` API to inject the CSS dynamically. Keep the injected CSS minimal and focused on one visual change.

**Test scenarios**

- **Positive case (regression detected):** After injecting CSS that changes nav padding, screenshot comparison fails (test asserts `toBeDefined()` on the expected error, or uses `toThrow()` when calling `expect().toHaveScreenshot()`)
- **Proof of masking:** If masking is applied to the changed region, comparison should still detect it (the mask should NOT hide user-visible CSS changes — only time-based dynamic content)

**Verification**

- Proof test runs and confirms screenshot comparison fails with injected CSS
- When CSS is removed, comparison passes again
- Masking is NOT suppressing the detected change (i.e., the test failure is not masked away)

---

### U5. Update package.json with visual test script and pinned Playwright version

**Goal**

Add the `test:visual` npm script and ensure the exact `@playwright/test` version is pinned in both local development and CI.

**Requirements**

R: `npm run test:visual` passes twice in a row in CI with no baseline change

**Dependencies**

U1, U2, U3, U4

**Files**

- `src/browser/package.json` (modify)

**Approach**

1. Add a `test:visual` script:
   ```json
   "test:visual": "playwright test --grep @visual"
   ```
   Or configure it to run only the visual test file:
   ```json
   "test:visual": "playwright test visual-shell.browser.spec.mjs"
   ```

2. Ensure `@playwright/test` is pinned to an exact version (not a range like `^` or `~`). Check the current pinned version in the repo and use that same version. If no pin exists, determine the latest stable version and pin it.

3. Update any lock file generated by the package manager (`npm-shrinkwrap.json`, `package-lock.json`, or `pnpm-lock.yaml` depending on the project's package manager).

**Patterns to follow**

Match the pinning style used for other critical test dependencies in `src/browser/package.json`. The CI workflow will reference this pinned version.

**Test scenarios**

- `npm run test:visual` resolves to the correct Playwright executable
- The script runs without syntax errors
- Script output shows which test file was executed

**Verification**

- `npm run test:visual` in CI runs the visual test suite
- Tests pass locally when run twice in a row with identical baselines
- No snapshot changes are logged after the second run

---

### U6. Add visual test step to CI workflow

**Goal**

Integrate the visual test into the CI pipeline so baselines are validated on every PR.

**Requirements**

R: `npm run test:visual` passes twice in a row in CI with no baseline change
R: The existing 23 browser specs are untouched and pass

**Dependencies**

U1, U2, U3, U4, U5

**Files**

- `.github/workflows/ci.yml` (modify)

**Approach**

Locate the existing `browser` job in the CI workflow. Add a step that:
1. Runs `npm run test:visual` in the `src/browser` directory
2. Verifies the exit code is 0 (tests pass)
3. Optionally runs it a second time to confirm no snapshot changes occur
4. Uses the same pinned Docker container (`node:<version>` or specified CI image) as the existing browser tests (AS-01)

The step should run after the existing 23 browser specs have passed, or as part of the same job. Ensure the working directory is `src/browser`.

**Patterns to follow**

Follow the existing CI job structure for browser tests. Use the same container image and Node version to guarantee reproducibility.

**Test scenarios**

- CI workflow loads without syntax errors
- Visual test step is executed as part of the browser job
- Baselines are committed to the repo, so CI has them available for comparison
- Test pass/fail is reported in the workflow summary

**Verification**

- CI workflow runs without errors on a PR that does not modify `dashboard.css`
- On a PR that modifies `dashboard.css`, the visual test fails (as expected) with a diff showing the baseline vs. new screenshot
- After PR is merged, subsequent PR runs pass without baseline updates

---

## High-Level Technical Design

```
Test Execution Flow:
┌─────────────────────────────────────────────────────┐
│ Test Setup                                          │
│ ├─ Set viewport (1440×900 / 1024×768 / 390×844)  │
│ ├─ Seed localStorage[aiur-theme] = 'light'/'dark' │
│ ├─ Navigate to route (/ / /build-orders / ...) │
│ └─ Wait for LiveView render                        │
└────────────────┬────────────────────────────────────┘
                 │
┌────────────────▼────────────────────────────────────┐
│ Seeding Nav State                                   │
│ ├─ Trigger 'restore-nav' event (LiveView handles)  │
│ └─ For mobile: set nav to bottom-pill mode        │
└────────────────┬────────────────────────────────────┘
                 │
┌────────────────▼────────────────────────────────────┐
│ Apply Masking                                       │
│ ├─ Get mask config from support/visual.mjs         │
│ ├─ Masks: [timestamps, durations, usage meter]     │
│ └─ Pass to toHaveScreenshot({ mask: [...] })      │
└────────────────┬────────────────────────────────────┘
                 │
┌────────────────▼────────────────────────────────────┐
│ Capture Screenshots                                 │
│ ├─ Full-page shell                                  │
│ ├─ Element shots: nav, header, buttons             │
│ └─ Save to visual-shell.browser.spec.mjs-snapshots/│
└────────────────┬────────────────────────────────────┘
                 │
┌────────────────▼────────────────────────────────────┐
│ Comparison (subsequent runs)                        │
│ ├─ Playwright loads baseline                        │
│ ├─ Compares current screenshot to baseline         │
│ ├─ Reports pass/fail + diff (if changed)           │
│ └─ Masks are applied during comparison too         │
└─────────────────────────────────────────────────────┘
```

**Mask Application Strategy:**

Masking happens at the Playwright level — regions matched by the selector are replaced with a solid color in both the baseline and the comparison screenshot before they are diffed. This ensures:
- Time-based content (timestamps, meters) doesn't cause spurious failures
- Real CSS changes (padding, borders) are still detected
- The mask is not captured in the baseline itself — instead, when comparison time arrives, the mask is applied to both images before diffing

**Theme Seeding Sequence:**

For the app to respect the theme during screenshot capture:
1. Set `localStorage['aiur-theme']` before navigation or after, but before the screenshot
2. The LiveView's `client/js/theme-loader.js` reads this on load OR responds to a `restore-nav` event
3. Wait for any CSS-in-JS or class application to complete (short wait for theme to render)
4. Take screenshot with theme-aware styling applied

---

## Dependencies & Prerequisites

- Fixture server (`src/test/browser/fixture_server.exs`) already running or available for spawning in test setup
- Playwright version exactly as pinned in `src/browser/package.json`
- Docker/CI container matches the same Node version to ensure consistent rendering
- Browser snapshot directories are committed to Git (the `*-snapshots/` folder with `.png` files)

---

## Scope Boundaries

### In Scope for This Ticket
- Screenshot baselines for dashboard shell, nav (all states), page frame, buttons
- Light/dark theme variants
- Three viewport sizes (1440×900, 1024×768, 390×844)
- Three routes (`/`, `/build-orders`, `/analytics`)
- Masking configuration for time-based elements
- Proof test validating regression detection
- CI integration

### Out of Scope / Deferred to Follow-Up Work
- Baseline captures for dashboard pages beyond the shell (detailed page components, modals, dialogs)
- Animated transitions or interactions (beyond keyboard focus)
- Performance snapshots or time-to-interactive baselines
- Automated baseline updates triggered by CSS refactors (snapshot drift validation is manual review during aiur-style PRs)
- Visual regression CI failure reporting integrations (Slack notifications, etc. — baseline comparison failure is reported in the CI log)

---

## Verification Contract

Each implementation unit is complete when:

| Unit | Verification Criteria |
|------|---|
| U1 | Playwright config loads; `expect.toHaveScreenshot` is available in tests; snapshot dir is `*-snapshots/` |
| U2 | `getMaskConfig()` exports and returns an array; masking module imports without errors |
| U3 | All parametrized test combinations run; full-page and element screenshots are captured; keyboard focus baseline is captured; `npm run test:visual` passes |
| U4 | Proof test runs; injected CSS causes screenshot comparison to fail; baseline is required for test to pass |
| U5 | `npm run test:visual` script is defined; Playwright version is pinned; `npm install` resolves dependencies |
| U6 | CI workflow includes visual test step; step runs and passes in the browser job; CI artifact includes snapshots |

---

## Acceptance Examples

**AE1. Baselines capture correctly for light/dark themes and all viewport sizes**
- Given: Dashboard shell is ready
- When: `npm run test:visual` runs with Playwright config and test file in place
- Then: Snapshots are created in `visual-shell.browser.spec.mjs-snapshots/` for all 6 combinations (2 themes × 3 viewports) plus element shots
- And: Screenshots show correct theme colors, nav layout for each viewport, and all nav states

**AE2. Masking hides time-based content but not structural changes**
- Given: Baselines are committed
- When: CSS is injected that changes `.shell-nav-item` padding
- Then: Visual regression test fails (baselines no longer match)
- And: When CSS is removed, test passes (baselines match again)
- Proof: Masking does not suppress this structural change — only time-based elements are masked

**AE3. CI validation passes twice in a row with no baseline changes**
- Given: PR does not modify `dashboard.css`
- When: CI runs the visual test
- Then: First run: all screenshots pass (match committed baselines)
- And: Second run: all screenshots pass again (no snapshot drift)
- And: CI log shows 0 snapshot updates

---

## Definition of Done

- [ ] All unit acceptance criteria are met
- [ ] All unit test scenarios pass
- [ ] Verification contract gates are satisfied
- [ ] `npm run test:visual` runs successfully locally and in CI
- [ ] Existing 23 browser specs pass unchanged
- [ ] Visual baseline snapshots are committed to `src/browser/tests/visual-shell.browser.spec.mjs-snapshots/`
- [ ] Proof test validates that CSS changes are caught by the regression suite
- [ ] PR description includes evidence of proof test failure with injected CSS
- [ ] No changes to `src/lib/**` or `src/priv/static/**` (only test infrastructure added)
- [ ] CI job completes without errors; baseline validation passes twice

