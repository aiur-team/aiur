import { test, expect } from '@playwright/test';

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

    // Capture screenshot
    await expect(page).toHaveScreenshot('gallery-light.png', {
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

    // Capture screenshot
    await expect(page).toHaveScreenshot('gallery-dark.png', {
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
