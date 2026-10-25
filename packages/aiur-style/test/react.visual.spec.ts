import { test, expect, type TestInfo, type Page } from '@playwright/test';
import { PNG } from 'pngjs';
import pixelmatch from 'pixelmatch';

async function capture(page: Page) {
  // Tracing can request a screenshot before Chromium has painted its first frame.
  await page.evaluate(() => new Promise<void>(resolve =>
    requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
  return page.screenshot({ animations: 'disabled' });
}

async function compare(actual: Buffer, expected: Buffer, name: string, info: TestInfo) {
  const a = PNG.sync.read(actual);
  const b = PNG.sync.read(expected);
  expect([a.width, a.height]).toEqual([b.width, b.height]);
  const diff = new PNG({ width: a.width, height: a.height });
  const pixels = pixelmatch(a.data, b.data, diff.data, a.width, a.height, { threshold: 0.2 });
  await info.attach(`${name}-diff.png`, { body: PNG.sync.write(diff), contentType: 'image/png' });
  expect(pixels / (a.width * a.height)).toBeLessThanOrEqual(0.001);
}

for (const theme of ['light', 'dark']) {
  for (const viewport of [{ width: 1440, height: 900 }, { width: 1024, height: 768 }, { width: 390, height: 844 }]) {
    test.describe(`${theme} ${viewport.width}x${viewport.height}`, () => {
      test.use({ viewport });
      test('React shell matches vanilla shell pixels', async ({ page }, testInfo) => {
        await page.goto(`shell.html?theme=${theme}`);
        await page.evaluate(() => document.fonts.ready);
        // Compare against the running vanilla gallery, without creating or updating baselines.
        const expanded = await capture(page);
        let collapsed: Buffer | undefined;
        if (viewport.width >= 960) {
          await page.getByRole('button', { name: 'Collapse navigation' }).click();
          await page.mouse.move(700, 500);
          collapsed = await capture(page);
        }
        await page.evaluate(() => localStorage.clear());
        await page.goto(`react.html?theme=${theme}`);
        await expect(page.locator('.aiur-shell')).toBeVisible();
        await page.evaluate(() => document.fonts.ready);
        await testInfo.attach('vanilla-expanded.png', { body: expanded, contentType: 'image/png' });
        const actual = await capture(page);
        await testInfo.attach('react-expanded.png', { body: actual, contentType: 'image/png' });
        await compare(actual, expanded, 'expanded', testInfo);
        if (collapsed) {
          await page.getByRole('button', { name: 'Collapse navigation' }).click();
          await page.mouse.move(700, 500);
          await compare(await capture(page), collapsed, 'collapsed', testInfo);
        }
      });
    });
  }
}
