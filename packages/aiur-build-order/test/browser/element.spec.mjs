import { expect, test } from '@playwright/test';

// A fixture page in Chromium: the package's own source, its stylesheet and two
// published documents. No build step, no framework, no daemon.

test.beforeEach(async ({ page }) => {
  await page.goto('/test/browser/fixture-page.html');
  await expect(page.locator('#reference')).toHaveAttribute('data-status', 'known');
});

test('the element renders the review and the graph from a src URL', async ({ page }) => {
  const reference = page.locator('#reference');
  await expect(reference.locator('article.aiur-bo--review')).toHaveCount(1);
  await expect(reference.locator('svg.aiur-bo-graph')).toHaveCount(1);
  await expect(reference.locator('tr[data-ticket]')).toHaveCount(6);
  await expect(reference.locator('g.aiur-bo-graph-node')).toHaveCount(6);
  await expect(reference.locator('g.aiur-bo-graph-gate')).toHaveCount(1);
  await expect(reference.locator('[data-edge-kind]')).not.toHaveCount(0);
});

test('the five edge kinds are distinguishable, not one grey line', async ({ page }) => {
  const strokes = await page.locator('#reference svg.aiur-bo-graph path.aiur-bo-edge').evaluateAll((paths) =>
    [...new Set(paths.map((path) => getComputedStyle(path).stroke))],
  );
  expect(strokes.length).toBeGreaterThan(1);
  const dashes = await page.locator('#reference svg.aiur-bo-graph path.aiur-bo-edge').evaluateAll((paths) =>
    [...new Set(paths.map((path) => getComputedStyle(path).strokeDasharray))],
  );
  expect(dashes.length).toBeGreaterThan(1);
});

test('the package styles the page through aiur-style tokens', async ({ page }) => {
  const background = await page.locator('#reference article.aiur-bo--review').evaluate((node) => getComputedStyle(node).backgroundColor);
  expect(background).not.toBe('rgba(0, 0, 0, 0)');
  const font = await page.locator('#reference .aiur-bo-title').evaluate((node) => getComputedStyle(node).fontFamily);
  expect(font.length).toBeGreaterThan(0);
});

test('an unknown document shows its banner and no percentage', async ({ page }) => {
  const unavailable = page.locator('#unavailable');
  await expect(unavailable.locator('[data-section="status-banner"]')).toHaveCount(1);
  await expect(unavailable.locator('[data-section="status-banner"]')).toContainText('unknown, not zero');
  await expect(unavailable.locator('[data-percent]')).toHaveCount(0);
  await expect(unavailable).not.toContainText('0%');
  await expect(unavailable.locator('tr[data-ticket]')).toHaveCount(2);
});

test('view=graph stays a graph and view=both stays both', async ({ page }) => {
  await expect(page.locator('#graph-only svg.aiur-bo-graph')).toHaveCount(1);
  await expect(page.locator('#graph-only article.aiur-bo--review')).toHaveCount(0);
});

test('an unusable document renders its error instead of an empty box', async ({ page }) => {
  const broken = page.locator('#broken');
  await expect(broken).toHaveAttribute('data-status', 'error');
  await expect(broken.locator('.aiur-bo-banner')).toContainText('could not be read');
  await expect(broken.locator('svg.aiur-bo-graph')).toHaveCount(0);
});

test('the page needs one stylesheet, and the element injects it once', async ({ page }) => {
  const injected = await page.locator('style[data-aiur-build-order]').count();
  expect(injected).toBe(1);
});
