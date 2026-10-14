import { registerContentTests } from './content.spec';
import { test, expect } from '@playwright/test';
import { tokens, contrastPairs } from '../dist/tokens.js';

registerContentTests();

test.describe('Gallery Visual Tests', () => {
  test('gallery loads the committed package stylesheet', async ({ page }) => {
    const stylesheet = page.waitForResponse(response =>
      response.url().endsWith('/dist/aiur-style.css'));
    await page.goto('./');
    const response = await stylesheet;
    expect(response.status()).toBe(200);
    expect(await response.text()).toContain('@layer aiur');
    expect(await page.evaluate(() =>
      Array.from(document.styleSheets).some(sheet =>
        sheet.href?.endsWith('/dist/aiur-style.css') && sheet.cssRules.length > 0)
    )).toBe(true);
  });

  test('light theme gallery', async ({ page }) => {
    await page.goto('./?theme=light');

    // Verify theme attribute
    const theme = await page.locator('html').getAttribute('data-theme');
    expect(theme).toBe('light');

    await page.evaluate(() => document.fonts.ready);

    await expect(page.locator('.swatch')).toHaveCount(Object.keys(tokens.light).filter(name => name.startsWith('color.')).length);

    // Capture screenshot
    await expect(page).toHaveScreenshot('gallery-light.png', {
      fullPage: true,
      maxDiffPixelRatio: 0.002,
      animations: 'disabled',
      caret: 'hide',
    });
  });

  test('dark theme gallery', async ({ page }) => {
    await page.goto('./?theme=dark');

    // Verify theme attribute
    const theme = await page.locator('html').getAttribute('data-theme');
    expect(theme).toBe('dark');

    await page.evaluate(() => document.fonts.ready);

    await expect(page.locator('.swatch')).toHaveCount(Object.keys(tokens.light).filter(name => name.startsWith('color.')).length);

    // Capture screenshot
    await expect(page).toHaveScreenshot('gallery-dark.png', {
      fullPage: true,
      maxDiffPixelRatio: 0.002,
      animations: 'disabled',
      caret: 'hide',
    });
  });

  test('theme toggle button works', async ({ page }) => {
    await page.goto('./');

    const button = page.locator('.theme-toggle');
    await button.click();

    // Verify theme changed
    const theme = await page.locator('html').getAttribute('data-theme');
    expect(theme).toBe('light');

    await button.click();
    const newTheme = await page.locator('html').getAttribute('data-theme');
    expect(newTheme).toBe('dark');
  });

  test('theme param is respected', async ({ page }) => {
    // Test light theme param
    await page.goto('./?theme=light');
    let theme = await page.locator('html').getAttribute('data-theme');
    expect(theme).toBe('light');

    // Test dark theme param
    await page.goto('./?theme=dark');
    theme = await page.locator('html').getAttribute('data-theme');
    expect(theme).toBe('dark');
  });
});

for (const preference of ['light', 'dark'] as const) {
  for (const choice of ['system', 'light', 'dark'] as const) {
    test(`token theme ${choice} under ${preference} preference`, async ({ page }) => {
      await page.emulateMedia({ colorScheme: preference });
      await page.goto(`./?theme=${choice}`);
      const theme = choice === 'system' ? preference : choice;
      await expect(page.locator('.swatch')).toHaveCount(Object.keys(tokens[theme]).filter(name => name.startsWith('color.')).length);
      expect(await page.locator('html').getAttribute('data-theme')).toBe(choice === 'system' ? null : choice);
      const computed = await page.evaluate(() => {
        const style = getComputedStyle(document.documentElement);
        return { scheme: style.colorScheme, values: Object.fromEntries(
          Array.from(style).filter(name => name.startsWith('--aiur-')).map(name => [name, style.getPropertyValue(name).trim()])) };
      });
      expect(computed.scheme).toBe(theme);
      for (const [name, value] of Object.entries(tokens[theme])) {
        expect(computed.values[`--aiur-${name.replaceAll('.', '-')}`], name).toBe(value);
      }
      for (const pair of contrastPairs.filter(pair => pair.foreground.includes('-on-'))) {
        const sample = page.locator(`[data-token="${pair.foreground}"] .swatch-sample`);
        const colors = await sample.evaluate(element => ({ color: getComputedStyle(element).color, background: getComputedStyle(element).backgroundColor }));
        const rgb = (hex: string) => `rgb(${hex.slice(1).match(/../g)!.map(channel => parseInt(channel, 16)).join(', ')})`;
        expect(colors).toEqual({ color: rgb(tokens[theme][pair.foreground]), background: rgb(tokens[theme][pair.background]) });
      }
    });
  }
}

test('token swatches remain readable and fit a mobile viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('./?theme=light');
  await expect(page.locator('.swatch')).toHaveCount(Object.keys(tokens.light).filter(name => name.startsWith('color.')).length);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});

test('system theme changes update rendered swatches and labels together', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'light' });
  await page.goto('./?theme=system');
  const swatch = page.locator('[data-token="color.bg"]');
  await expect(swatch.locator('.swatch-value')).toHaveText('#e7d6b2');
  await expect(swatch.locator('.swatch-color')).toHaveCSS('background-color', 'rgb(231, 214, 178)');
  await page.emulateMedia({ colorScheme: 'dark' });
  await expect(swatch.locator('.swatch-value')).toHaveText('#1a1b1e');
  await expect(swatch.locator('.swatch-color')).toHaveCSS('background-color', 'rgb(26, 27, 30)');
  expect(await page.locator('html').getAttribute('data-theme')).toBeNull();
});
