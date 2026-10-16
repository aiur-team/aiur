import { test, expect } from '@playwright/test';

const brandOf = (page: import('@playwright/test').Page) => page.locator('.aiur-brand');

test('brand is tucked while the hero is visible and revealed once it passes under the bar', async ({ page }) => {
  await page.goto('topbar.html');
  const brand = brandOf(page);
  await expect(brand).toHaveAttribute('aria-hidden', 'true');
  await expect(brand).toHaveAttribute('tabindex', '-1');
  await page.evaluate(() => scrollTo(0, 900));
  await expect(brand).not.toHaveAttribute('aria-hidden', /.*/);
  await expect(brand).not.toHaveAttribute('tabindex', /.*/);
  await page.evaluate(() => scrollTo(0, 0));
  await expect(brand).toHaveAttribute('aria-hidden', 'true');
});

test('focus is never stranded on a tucked brand', async ({ page }) => {
  await page.goto('topbar.html');
  await page.evaluate(() => scrollTo(0, 900));
  const brand = brandOf(page);
  await expect(brand).not.toHaveAttribute('aria-hidden', /.*/);
  await brand.focus();
  expect(await brand.evaluate(el => document.activeElement === el)).toBe(true);
  await page.evaluate(() => scrollTo(0, 0));
  await expect(brand).toHaveAttribute('aria-hidden', 'true');
  expect(await brand.evaluate(el => document.activeElement === el)).toBe(false);
});

test('brand stays visible without IntersectionObserver', async ({ page }) => {
  await page.addInitScript(() => { delete (window as any).IntersectionObserver; });
  await page.goto('topbar.html');
  await expect(brandOf(page)).not.toHaveAttribute('aria-hidden', /.*/);
});

test('theme toggle aria-pressed tracks explicit and system theme', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'light' });
  await page.goto('topbar.html');
  const toggle = page.locator('.aiur-theme-toggle');
  await expect(toggle).toHaveAttribute('aria-label', 'Dark mode');
  // the page defaults to dark, so the first click lands on light
  await expect(toggle).toHaveAttribute('aria-pressed', 'true');
  await toggle.click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  await page.evaluate(() => document.documentElement.removeAttribute('data-theme'));
  await page.emulateMedia({ colorScheme: 'light' });
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  await page.emulateMedia({ colorScheme: 'dark' });
  await expect(toggle).toHaveAttribute('aria-pressed', 'true');
});

test('pin hands the bar to fixed once the banner has scrolled away', async ({ page }) => {
  await page.goto('topbar.html');
  await page.evaluate(() => {
    const bar = document.querySelector<HTMLElement>('.aiur-topbar')!;
    const strip = document.createElement('div');
    strip.id = 'strip'; strip.style.cssText = 'height:100px;position:absolute;top:0;width:1px';
    document.body.append(strip);
    // re-run auto-init for a bar that now names a banner
    bar.dataset.aiurPinBanner = '#strip';
    return import('../dist/js/brand-reveal.js').then(m => m.initTopbarPin(bar, { banner: '#strip' }));
  });
  const bar = page.locator('.aiur-topbar');
  await expect(bar).not.toHaveClass(/is-pinned/);
  await page.evaluate(() => scrollTo(0, 300));
  await expect(bar).toHaveClass(/is-pinned/);
  await expect(bar).toHaveCSS('position', 'fixed');
});

for (const theme of ['light', 'dark']) {
  test(`topbar screenshots ${theme}`, async ({ page }) => {
    await page.goto('topbar.html');
    const toggle = page.locator('.aiur-theme-toggle');
    // the page defaults to dark; reach light through the real toggle
    if (theme === 'light') await toggle.click();
    await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
    await expect(toggle).toHaveAttribute('aria-pressed', String(theme === 'dark'));
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(() => scrollTo(0, 900));
    const bar = page.locator('.aiur-topbar');
    await expect(brandOf(page)).not.toHaveAttribute('aria-hidden', /.*/);
    await expect(bar).toHaveScreenshot(`topbar-brand-${theme}.png`);
    await bar.evaluate(el => { el.classList.add('is-pinned'); el.classList.remove('aiur-topbar--sticky'); });
    await expect(bar).toHaveScreenshot(`topbar-pinned-${theme}.png`);
    await bar.evaluate(el => { el.classList.add('aiur-topbar--end'); el.querySelector('.aiur-brand')!.remove(); });
    await expect(bar).toHaveScreenshot(`topbar-end-${theme}.png`);
    // pressed state and page theme always move together, as a user sees them
    await expect(toggle).toHaveScreenshot(`theme-toggle-${theme === 'dark'}-${theme}.png`);
  });
}
