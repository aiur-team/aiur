import { test, expect } from '@playwright/test';

export function registerContentTests() {
  test.describe('Content sections', () => {
    test.beforeEach(async ({ page }) => {
      await page.emulateMedia({ reducedMotion: 'reduce' });
    });

    for (const theme of ['light', 'dark']) {
      for (const [width, columns] of [[1024, 3], [700, 2], [400, 1]]) {
        test(`content ${theme} at ${width}px`, async ({ page }) => {
          await page.setViewportSize({ width, height: 1000 });
          await page.goto(`content.html?theme=${theme}`);
          await page.evaluate(() => document.fonts.ready);
          expect(await page.locator('.aiur-lockup__logo').evaluate(el => (el as HTMLImageElement).naturalWidth)).toBeGreaterThan(0);
          expect(await page.locator('.aiur-features').evaluate(el => getComputedStyle(el).gridTemplateColumns.split(' ').length)).toBe(columns);
          expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
          await expect(page.locator('.aiur-wordmark')).toMatchAriaSnapshot('- heading "AIUR" [level=1]');
          for (const section of ['features', 'prose', 'lockup']) {
            await expect(page.locator(`#${section}`)).toHaveScreenshot(`${section}-${theme}-${width}.png`, { maxDiffPixelRatio: 0.002, style: ".aiur-scrollcue { visibility: hidden; }" });
          }
          await page.evaluate(() => window.scrollTo(0, 0));
          await expect(page.locator('.aiur-scrollcue')).toHaveScreenshot(`scrollcue-${theme}-${width}.png`, { style: "body > :not(.aiur-scrollcue) { visibility: hidden; }" });
        });
      }
    }

    test('scroll cue light text has at least 4.5:1 contrast on the page', async ({ page }) => {
      await page.goto('content.html?theme=light');
      const colors = await page.locator('.aiur-scrollcue').evaluate(el => ({
        foreground: getComputedStyle(el).color, background: getComputedStyle(document.body).backgroundColor,
      }));
      const luminance = (rgb: string) => rgb.match(/\d+/g)!.slice(0, 3).map(Number).map(channel => {
        const s = channel / 255;
        return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
      }).reduce((sum, channel, index) => sum + channel * [0.2126, 0.7152, 0.0722][index], 0);
      const a = luminance(colors.foreground), b = luminance(colors.background);
      expect((Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)).toBeGreaterThanOrEqual(4.5);
    });

    test('auto scroll cue hides past 60px and returns at the threshold', async ({ page }) => {
      await page.goto('content.html');
      const cue = page.locator('.aiur-scrollcue');
      await expect(cue).not.toHaveClass(/is-gone/);
      await page.evaluate(() => window.scrollTo(0, 61));
      await expect(cue).toHaveClass(/is-gone/);
      await page.evaluate(() => window.scrollTo(0, 60));
      await expect(cue).not.toHaveClass(/is-gone/);
    });

    test('scroll cue custom condition, initial state, idempotence and cleanup', async ({ page }) => {
      await page.goto('content.html');
      const result = await page.evaluate(async () => {
        const { initScrollCue } = await import('../dist/js/scrollcue.js');
        const el = document.createElement('div');
        document.body.append(el);
        let hidden = true;
        const first = initScrollCue(el, { hideAfter: 100, hideWhen: () => hidden });
        const initiallyHidden = el.classList.contains('is-gone');
        const same = first === initScrollCue(el);
        hidden = false;
        window.dispatchEvent(new Event('scroll'));
        const shown = !el.classList.contains('is-gone');
        first.destroy();
        hidden = true;
        window.dispatchEvent(new Event('scroll'));
        const stayedShown = !el.classList.contains('is-gone');
        const second = initScrollCue(el, { hideWhen: () => hidden });
        first.destroy();
        const oldCleanupSafe = initScrollCue(el) === second;
        return { initiallyHidden, same, shown, stayedShown, oldCleanupSafe, reinitialized: second !== first && el.classList.contains('is-gone') };
      });
      expect(result).toEqual({ initiallyHidden: true, same: true, shown: true, stayedShown: true, oldCleanupSafe: true, reinitialized: true });
    });

    test('content animations are removed for reduced motion', async ({ page }) => {
      await page.goto('content.html');
      for (const selector of ['.aiur-wordmark span', '.aiur-scrollcue', '.aiur-scrollcue__chev']) {
        await expect(page.locator(selector).first()).toHaveCSS('animation-name', 'none');
        await expect(page.locator(selector).first()).toHaveCSS('opacity', '1');
      }
    });
  });
}
