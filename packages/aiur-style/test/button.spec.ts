import { test, expect } from '@playwright/test';

for (const theme of ['light', 'dark']) {
  test.describe(`buttons ${theme}`, () => {
    test.beforeEach(async ({ page }) => {
      await page.emulateMedia({ reducedMotion: 'reduce' });
      await page.goto(`./?theme=${theme}`);
      await expect(page.locator('#button-matrix button')).toHaveCount(84);
    });

    test('filled real hover and pressed use the exact shared palette', async ({ page }) => {
      const button = page.locator('[data-variant="filled"][data-size="default"][data-state="rest"]');
      await expect(button).toHaveCSS('background-color', 'rgb(31, 87, 196)');
      await expect(button).toHaveCSS('color', 'rgb(255, 255, 255)');
      await button.hover();
      await expect(button).toHaveCSS('background-color', 'rgb(26, 74, 168)');
      await page.mouse.down();
      await expect(button).toHaveCSS('background-color', 'rgb(22, 62, 140)');
      await page.mouse.up();
      await button.evaluate(element => element.setAttribute('aria-pressed', 'true'));
      await page.mouse.move(0, 0);
      await expect(button).toHaveCSS('background-color', 'rgb(22, 62, 140)');
      await button.hover();
      await expect(button).toHaveCSS('background-color', 'rgb(22, 62, 140)');
    });

    test('forced states match real states for every variant', async ({ page }) => {
      for (const variant of ['filled', 'ghost', 'danger', 'tool']) {
        const row = `[data-variant="${variant}"][data-size="default"]`;
        const button = page.locator(`${row}[data-state="rest"]`);
        await button.hover();
        await button.evaluate(element => Promise.all(element.getAnimations().map(animation => animation.finished)));
        const colors = await button.evaluate(element => {
          const style = getComputedStyle(element);
          return { bg: style.backgroundColor, fg: style.color };
        });
        await expect(page.locator(`${row}[data-state="hover"]`)).toHaveCSS('background-color', colors.bg);
        await expect(page.locator(`${row}[data-state="hover"]`)).toHaveCSS('color', colors.fg);
        await page.mouse.down();
        await button.evaluate(element => Promise.all(element.getAnimations().map(animation => animation.finished)));
        const pressed = await button.evaluate(element => getComputedStyle(element).backgroundColor);
        await expect(page.locator(`${row}[data-state="active"]`)).toHaveCSS('background-color', pressed);
        await expect(page.locator(`${row}[data-state="pressed"]`)).toHaveCSS('background-color', pressed);
        await page.mouse.up();
      }
      const ghost = page.locator('[data-variant="ghost"][data-size="default"][data-state="rest"]');
      await page.mouse.move(0, 0);
      await expect(ghost).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)');
      await expect(ghost).toHaveCSS('color', theme === 'light' ? 'rgb(95, 86, 69)' : 'rgb(140, 141, 147)');
      await ghost.hover();
      await expect(ghost).toHaveCSS('color', theme === 'light' ? 'rgb(42, 37, 32)' : 'rgb(237, 238, 240)');
      const wash = await ghost.evaluate(element => {
        const probe = document.createElement('span');
        probe.style.color = 'color-mix(in srgb, var(--aiur-color-fg) 8%, transparent)';
        element.append(probe);
        const expected = getComputedStyle(probe).color;
        probe.remove();
        return expected;
      });
      await expect(ghost).toHaveCSS('background-color', wash);
      const danger = page.locator('[data-variant="danger"][data-size="default"][data-state="rest"]');
      await expect(danger).toHaveCSS('background-color', theme === 'light' ? 'rgb(210, 59, 50)' : 'rgb(255, 123, 114)');
      await expect(danger).toHaveCSS('color', theme === 'light' ? 'rgb(255, 255, 255)' : 'rgb(42, 9, 6)');
      const tool = page.locator('[data-variant="tool"][data-size="default"][data-state="rest"]');
      await expect(tool).toHaveCSS('min-height', '30.4px');
      await expect(tool).toHaveCSS('font-size', '11.2px');
      await expect(tool).toHaveCSS('font-family', '"JetBrains Mono", ui-monospace, SFMono-Regular, Consolas, monospace');
    });

    test('disabled and aria-disabled retain their rest styles during interaction', async ({ page }) => {
      for (const variant of ['filled', 'ghost', 'danger', 'tool']) {
        for (const state of ['disabled', 'aria-disabled']) {
          const button = page.locator(`[data-variant="${variant}"][data-size="default"][data-state="${state}"]`);
          const rest = await button.evaluate(element => getComputedStyle(element).backgroundColor);
          await expect(button).toHaveCSS('cursor', 'not-allowed');
          await expect(button).toHaveCSS('opacity', '0.45');
          await button.hover();
          await expect(button).toHaveCSS('background-color', rest);
          await page.mouse.down();
          await expect(button).toHaveCSS('background-color', rest);
          await button.evaluate(element => {
            element.classList.add('is-hover', 'is-active');
            element.setAttribute('aria-pressed', 'true');
          });
          await expect(button).toHaveCSS('background-color', rest);
          await page.mouse.up();
        }
      }
    });

    test('keyboard focus rings cover buttons, anchors and tabindex elements', async ({ page }) => {
      const ring = theme === 'light' ? 'rgb(31, 87, 196)' : 'rgb(47, 134, 255)';
      const button = page.locator('[data-variant="filled"][data-size="sm"][data-state="rest"]');
      await button.click();
      expect(await button.evaluate(element => element.matches(':focus-visible'))).toBe(false);
      await expect(button).toHaveCSS('outline-style', 'none');
      await page.keyboard.press('Shift+Tab');
      await page.keyboard.press('Tab');
      expect(await button.evaluate(element => element.matches(':focus-visible'))).toBe(true);
      await expect(button).toHaveCSS('outline', `${ring} solid 2px`);
      await expect(button).toHaveCSS('outline-offset', '3px');
      await page.locator('#button-cta').focus();
      for (const id of ['focus-link', 'focus-tabindex']) {
        await page.keyboard.press('Tab');
        const element = page.locator(`#${id}`);
        await expect(element).toBeFocused();
        await expect(element).toHaveCSS('outline', `${ring} solid 2px`);
        await expect(element).toHaveCSS('outline-offset', '3px');
      }
    });

    test('sizes and shapes use the shared dimensions', async ({ page }) => {
      for (const [size, padding, font] of [['sm', '8.8px 16px', '15.2px'], ['default', '9.6px 17.6px', '15px'], ['lg', '13px 22px', '15px']]) {
        const button = page.locator(`[data-variant="filled"][data-size="${size}"][data-state="rest"]`);
        await expect(button).toHaveCSS('padding', padding);
        await expect(button).toHaveCSS('font-size', font);
        await expect(button).toHaveCSS('border-radius', '999px');
      }
      await expect(page.locator('.aiur-button--rounded')).toHaveCSS('border-radius', '10px');
      const icon = await page.locator('.aiur-button--icon').boundingBox();
      expect(icon!.width).toBeCloseTo(icon!.height, 1);
    });

    test('large CTA nudges its arrow only when motion is allowed', async ({ page }) => {
      const button = page.locator('#button-cta');
      const arrow = button.locator('.aiur-button__icon');
      await page.emulateMedia({ reducedMotion: 'no-preference' });
      await button.hover();
      await expect(arrow).toHaveCSS('transform', 'matrix(1, 0, 0, 1, 3, 0)');
      await page.emulateMedia({ reducedMotion: 'reduce' });
      await expect(arrow).toHaveCSS('transform', 'none');
      await expect(arrow).toHaveCSS('transition-duration', '0s');
      await expect(button).toHaveCSS('transition-duration', '0s');
    });

    test('button matrix screenshot', async ({ page }) => {
      await page.evaluate(() => document.fonts.ready);
      await expect(page.locator('#buttons')).toHaveScreenshot(`button-matrix-${theme}.png`, {
        maxDiffPixelRatio: 0.002, animations: 'disabled', caret: 'hide',
      });
    });
  });
}
