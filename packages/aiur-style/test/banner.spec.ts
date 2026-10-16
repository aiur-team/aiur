import { test, expect } from '@playwright/test';

for (const theme of ['light', 'dark']) {
  test(`banner ${theme}: ghost SVG close and screenshots`, async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.goto(`./?theme=${theme}`);
    const banner = page.locator('.aiur-banner');
    await expect(banner.locator('.aiur-banner__text')).toHaveCSS('font-size', '13px');
    const close = banner.getByRole('button', { name: 'Dismiss announcement' });
    await expect(close).toHaveCSS('width', '26px');
    await expect(close).toHaveCSS('height', '26px');
    await expect(close).toHaveCSS('border-radius', '7px');
    await expect(close).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)');
    await expect(close.locator('svg')).toHaveAttribute('aria-hidden', 'true');
    await expect(close.locator('svg')).toHaveCSS('width', '14px');
    await expect(close.locator('path')).toHaveAttribute('d', 'M6 6l12 12M18 6L6 18');
    await expect(close.locator('svg')).toHaveAttribute('stroke-width', '1.8');
    await expect(close).toHaveText('');
    await page.evaluate(() => document.fonts.ready);
    const options = { maxDiffPixelRatio: 0.002, animations: 'disabled' as const, caret: 'hide' as const };
    await expect(banner).toHaveScreenshot(`banner-${theme}.png`, options);
    await close.hover();
    await expect(close).toHaveCSS('color', theme === 'light' ? 'rgb(42, 37, 32)' : 'rgb(237, 238, 240)');
    expect(await close.evaluate(el => getComputedStyle(el).backgroundColor)).not.toBe('rgba(0, 0, 0, 0)');
    await expect(banner).toHaveScreenshot(`banner-${theme}-hover.png`, options);
    await page.mouse.move(0, 0);
    await banner.getByRole('link').focus();
    await page.keyboard.press('Tab');
    await expect(close).toBeFocused();
    await expect(close).toHaveCSS('outline-style', 'solid');
    await expect(close).toHaveCSS('outline-width', '2px');
    await expect(banner).toHaveScreenshot(`banner-${theme}-focus.png`, options);
    await expect(close).toHaveCSS('transition-duration', '0s');
    await page.emulateMedia({ reducedMotion: 'no-preference' });
    await expect(close).toHaveCSS('transition-duration', '0.2s, 0.2s');
  });
}

test('keyboard dismisses, persists the campaign, emits once and focuses the next control', async ({ page }) => {
  await page.goto('./');
  await page.evaluate(() => {
    document.querySelector('.aiur-banner')!.addEventListener('aiur:bannerdismiss', () => {
      document.body.dataset.dismissed = String(Number(document.body.dataset.dismissed ?? 0) + 1);
    });
  });
  await page.locator('#theme-toggle').focus();
  await page.keyboard.press('Tab');
  await expect(page.locator('.aiur-banner__link')).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.locator('.aiur-banner__close')).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page.locator('.aiur-banner')).toBeHidden();
  await expect(page.locator('#after-banner')).toBeFocused();
  await expect(page.locator('body')).toHaveAttribute('data-dismissed', '1');
  expect(await page.evaluate(() => localStorage.getItem('aiur-banner:gallery'))).toBe('dismissed');
});

test('dismissed banner is hidden on insertion and the first animation frame after reload', async ({ page }) => {
  await page.goto('./');
  await page.locator('.aiur-banner__close').click();
  await page.addInitScript(() => {
    const evidence = { visibleOnInsertion: false, frames: [] as boolean[] };
    Object.assign(window, { bannerEvidence: evidence });
    new MutationObserver(() => {
      const banner = document.querySelector('.aiur-banner');
      if (banner && getComputedStyle(banner).display !== 'none') evidence.visibleOnInsertion = true;
    }).observe(document, { childList: true, subtree: true });
    requestAnimationFrame(() => {
      const banner = document.querySelector('.aiur-banner');
      evidence.frames.push(!!banner && getComputedStyle(banner).display !== 'none');
    });
  });
  await page.reload();
  await page.waitForFunction(() => (window as any).bannerEvidence.frames.length === 1);
  expect(await page.evaluate(() => (window as any).bannerEvidence)).toEqual({ visibleOnInsertion: false, frames: [false] });
  await expect(page.locator('.aiur-banner')).toBeHidden();
});

// Future regression guard for the existing AS-13 campaign-key isolation.
test('a different campaign is shown even after an earlier campaign was dismissed', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('aiur-banner:old-campaign', 'dismissed'));
  await page.goto('./');
  await expect(page.locator('.aiur-banner')).toBeVisible();
});

for (const fallback of ['main', 'body']) {
  test(`blocked storage still dismisses and focuses ${fallback} when no later control exists`, async ({ page }) => {
    await page.addInitScript(() => Object.defineProperty(window, 'localStorage', { get() { throw new Error('blocked'); } }));
    await page.goto('./');
    await page.evaluate(useMain => {
      document.getElementById('after-banner')!.remove();
      document.getElementById('buttons')!.remove();
      if (useMain) document.body.append(document.createElement('main'));
    }, fallback === 'main');
    await page.locator('.aiur-banner__close').click();
    await expect(page.locator('.aiur-banner')).toBeHidden();
    await expect(page.locator(fallback)).toBeFocused();
    await expect(page.locator(fallback)).toHaveAttribute('tabindex', '-1');
    await page.locator('#theme-toggle').focus();
    await expect(page.locator(fallback)).not.toHaveAttribute('tabindex');
  });
}

test('destroy removes the dismissal listener', async ({ page }) => {
  await page.goto('./');
  await page.evaluate(async () => {
    const { initBanner } = await import('../dist/js/banner.js');
    const el = document.querySelector<HTMLElement>('.aiur-banner')!;
    const clone = el.cloneNode(true) as HTMLElement;
    el.replaceWith(clone);
    initBanner(clone).destroy();
  });
  await page.locator('.aiur-banner__close').click();
  await expect(page.locator('.aiur-banner')).toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem('aiur-banner:gallery'))).toBeNull();
});
