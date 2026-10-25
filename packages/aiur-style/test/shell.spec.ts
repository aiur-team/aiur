import { test, expect } from '@playwright/test';

for (const theme of ['light', 'dark']) {
  test.describe(theme, () => {
    test('collapse, keyboard expand, callback and storage survive reload', async ({ page }) => {
      await page.goto('shell.html?theme=' + theme);
      const shell = page.locator('.aiur-shell');
      const toggle = page.locator('.aiur-shell__toggle');
      await page.evaluate(() => {
        document.querySelector('.aiur-shell')!.addEventListener('shell-toggle', event => {
          document.body.dataset.lastToggle = String((event as CustomEvent).detail);
        });
      });
      await toggle.click();
      await expect(shell).toHaveAttribute('data-nav-collapsed', 'true');
      await expect(toggle).toHaveAttribute('aria-pressed', 'true');
      await expect(toggle).toHaveAccessibleName('Expand navigation');
      await expect(page.locator('.aiur-shell__nav--sidebar')).toBeHidden();
      await expect(page.locator('body')).toHaveAttribute('data-last-toggle', 'true');
      expect(await page.evaluate(() => localStorage.getItem('aiur-nav-collapsed'))).toBe('true');
      await page.reload();
      await expect(shell).toHaveAttribute('data-nav-collapsed', 'true');
      const expand = page.locator('.aiur-shell__toggle');
      await expect(expand).toHaveAttribute('aria-pressed', 'true');
      await expand.focus();
      await page.keyboard.press('Enter');
      await expect(shell).toHaveAttribute('data-nav-collapsed', 'false');
      await expect(expand).toHaveAccessibleName('Collapse navigation');
      await expect(page.locator('.aiur-shell__nav--sidebar')).toBeVisible();
      await page.reload();
      await expect(shell).toHaveAttribute('data-nav-collapsed', 'false');
      await page.getByRole('button', { name: 'Toggle color theme' }).click();
      await expect(page.locator('html')).toHaveAttribute('data-theme', theme === 'light' ? 'dark' : 'light');
    });

    test('aria-current uses the resolved accent fill and ink without an outline', async ({ page }) => {
      await page.goto('shell.html?theme=' + theme);
      const active = page.locator('.aiur-shell__nav--sidebar [aria-current="page"]');
      const colors = await active.evaluate(element => {
        const probe = document.createElement('span');
        probe.style.background = 'var(--aiur-color-accent-soft)';
        probe.style.color = 'var(--aiur-color-accent-ink)';
        element.append(probe);
        const style = getComputedStyle(probe);
        const result = { background: style.backgroundColor, ink: style.color };
        probe.remove();
        return result;
      });
      await expect(active).toHaveCSS('background-color', colors.background);
      await expect(active).toHaveCSS('color', colors.ink);
      await expect(active).toHaveCSS('outline-style', 'none');
      await expect(page.locator('.aiur-shell__nav--sidebar .is-attention')).toHaveText('2');
      await expect(page.locator('.aiur-shell__nav--sidebar [aria-disabled]')).toHaveText('GitHub cacheComing soon');
      expect(await page.locator('.aiur-shell__nav--sidebar .aiur-shell__item').allTextContents())
        .toEqual(await page.locator('.aiur-shell__nav--pill .aiur-shell__item').allTextContents());
      await page.emulateMedia({ colorScheme: theme as 'light' | 'dark' });
      await page.locator('html').evaluate(element => element.removeAttribute('data-theme'));
      await expect(page.locator('.aiur-shell__topbar')).toHaveCSS('border-bottom-color',
        theme === 'light' ? 'rgba(42, 37, 26, 0.1)' : 'rgba(221, 226, 235, 0.08)');
    });

    test('sidebar switches to the pill precisely at 960px', async ({ page }) => {
      await page.setViewportSize({ width: 960, height: 768 });
      await page.goto('shell.html?theme=' + theme);
      await expect(page.locator('.aiur-shell__sidebar')).toBeVisible();
      await expect(page.locator('.aiur-shell__nav--pill')).toBeHidden();
      await page.setViewportSize({ width: 959, height: 768 });
      await expect(page.locator('.aiur-shell__sidebar')).toBeHidden();
      await expect(page.locator('.aiur-shell__nav--pill')).toBeVisible();
    });
  });

  for (const viewport of [{ width: 1440, height: 900 }, { width: 1024, height: 768 }, { width: 390, height: 844 }]) {
    const mobile = viewport.width < 960;
    const size = viewport.width + 'x' + viewport.height;
    test.describe(theme + ' ' + size, () => {
      test.use({ viewport, deviceScaleFactor: mobile ? 3 : 1, isMobile: mobile, hasTouch: mobile });

      test('AS-02 element parity', async ({ page }) => {
        await page.goto('shell.html?as02&theme=' + theme);
        await page.evaluate(() => document.fonts.ready);
        const prefix = theme + '-' + size + '-units-' + (mobile ? 'mobile' : 'expanded');
        for (const [part, selector] of [
          ['header', '.aiur-shell__topbar'],
          ['nav', mobile ? '.aiur-shell__nav--pill' : '.aiur-shell__sidebar'],
          ['context', '.aiur-page__header'],
        ]) {
          await expect(page.locator(selector)).toHaveScreenshot('as02-' + prefix + '-' + part + '.png', { maxDiffPixelRatio: 0.01 });
        }
        if (!mobile) {
          await page.getByRole('button', { name: 'Collapse navigation' }).click();
          await page.mouse.move(700, 500);
          await expect(page.locator('.aiur-shell__toggle')).toHaveScreenshot(
            'as02-' + theme + '-' + size + '-units-collapsed-nav.png', { maxDiffPixelRatio: 0.01 });
        }
      });

      test('gallery shell baseline', async ({ page }) => {
        await page.goto('shell.html?theme=' + theme);
        await page.evaluate(() => document.fonts.ready);
        await expect(page).toHaveScreenshot('gallery-shell-' + theme + '-' + size + '.png', { maxDiffPixelRatio: 0.002 });
        if (!mobile) {
          await page.getByRole('button', { name: 'Collapse navigation' }).click();
          await page.mouse.move(700, 500);
          await expect(page).toHaveScreenshot('gallery-shell-' + theme + '-' + size + '-collapsed.png', { maxDiffPixelRatio: 0.002 });
        }
      });
    });
  }
}

test('custom storage key, blocked storage and listener disposal', async ({ page }) => {
  await page.goto('shell.html');
  const result = await page.evaluate(async () => {
    const { initShellNav } = await import('../dist/js/index.js');
    const shell = document.querySelector<HTMLElement>('.aiur-shell')!.cloneNode(true) as HTMLElement;
    document.body.append(shell);
    localStorage.setItem('private-nav', 'true');
    const toggles: boolean[] = [];
    const dispose = initShellNav(shell, { storageKey: 'private-nav', onToggle: value => toggles.push(value) });
    const toggle = shell.querySelector<HTMLButtonElement>('.aiur-shell__toggle')!;
    const restored = shell.dataset.navCollapsed;
    toggle.click();
    const stored = localStorage.getItem('private-nav');
    dispose();
    toggle.click();
    const disposedState = shell.dataset.navCollapsed;
    Object.defineProperty(window, 'localStorage', { configurable: true, get() { throw new Error('blocked'); } });
    const disposeBlocked = initShellNav(shell);
    toggle.click();
    const blockedState = shell.dataset.navCollapsed;
    disposeBlocked();
    return { restored, stored, toggles, disposedState, blockedState };
  });
  expect(result).toEqual({ restored: 'true', stored: 'false', toggles: [false], disposedState: 'false', blockedState: 'true' });
});
