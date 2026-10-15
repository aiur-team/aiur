import { test, expect, type Locator } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixture = '/test/fixtures/vitepress/.vitepress/dist/';

test.beforeAll(() => {
  execFileSync(path.join(root, 'node_modules/.bin/vitepress'), ['build', 'test/fixtures/vitepress'], {
    cwd: root, stdio: 'inherit',
  });
});

function contrast(foreground: string, background: string) {
  const luminance = (hex: string) => {
    const channels = hex.replace('#', '').match(/../g)!.map(channel => {
      const value = parseInt(channel, 16) / 255;
      return value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4;
    });
    return channels[0] * .2126 + channels[1] * .7152 + channels[2] * .0722;
  };
  const [lighter, darker] = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
  return (lighter + .05) / (darker + .05);
}

async function renderedColors(locator: Locator): Promise<[string, string]> {
  return locator.evaluate(element => {
    const hex = (color: string) => '#' + color.match(/\d+/g)!.slice(0, 3)
      .map(channel => Number(channel).toString(16).padStart(2, '0')).join('');
    let parent: Element | null = element;
    let background = 'rgba(0, 0, 0, 0)';
    while (parent && background === 'rgba(0, 0, 0, 0)') {
      background = getComputedStyle(parent).backgroundColor;
      parent = parent.parentElement;
    }
    return [hex(getComputedStyle(element).color), hex(background)];
  });
}

for (const theme of ['light', 'dark']) {
  test.describe(`VitePress ${theme}`, () => {
    test.beforeEach(async ({ page }) => {
      await page.emulateMedia({ colorScheme: 'light' });
      await page.addInitScript(saved => localStorage.setItem('vitepress-theme-appearance', saved), theme);
      await page.goto(fixture);
      await expect(page.locator('html')).toHaveClass(theme === 'dark' ? /dark/ : /^(?!.*dark)/);
    });

    test('brand fill, hover, pressed and keyboard focus use shared tokens', async ({ page }) => {
      await expect(page.locator('body')).toHaveCSS('background-color', theme === 'dark' ? 'rgb(26, 27, 30)' : 'rgb(231, 214, 178)');
      const field = await page.locator('.VPHomeHero').evaluate(element => getComputedStyle(element, '::before').backgroundImage);
      expect(field).toContain('repeating-linear-gradient');
      expect(field).toContain(theme === 'dark' ? 'rgba(221, 226, 235, 0.14)' : 'rgba(42, 37, 26, 0.17)');
      const button = page.locator('.VPButton.brand');
      expect(await page.locator('html').evaluate(element =>
        getComputedStyle(element).getPropertyValue('--vp-button-brand-bg').trim())).toBe('#1f57c4');
      await expect(button).toHaveCSS('background-color', 'rgb(31, 87, 196)');
      await expect(button).toHaveCSS('color', 'rgb(255, 255, 255)');
      await button.hover();
      await expect(button).toHaveCSS('background-color', 'rgb(26, 74, 168)');
      await page.mouse.down();
      await expect(button).toHaveCSS('background-color', 'rgb(22, 62, 140)');
      await page.mouse.move(0, 0);
      await page.mouse.up();
      await button.evaluate(element => element.setAttribute('aria-pressed', 'true'));
      await expect(button).toHaveCSS('background-color', 'rgb(22, 62, 140)');
      await button.evaluate(element => element.removeAttribute('aria-pressed'));
      await button.evaluate(element => element.setAttribute('aria-disabled', 'true'));
      await button.hover();
      await expect(button).toHaveCSS('background-color', 'rgb(31, 87, 196)');
      await expect(button).toHaveCSS('opacity', '0.45');
      await button.evaluate(element => element.removeAttribute('aria-disabled'));
      await page.mouse.move(0, 0);
      await page.keyboard.press('Tab');
      await button.focus();
      await expect(button).toHaveCSS('outline', `${theme === 'dark' ? 'rgb(47, 134, 255)' : 'rgb(31, 87, 196)'} solid 2px`);
      await expect(button).toHaveCSS('outline-offset', '3px');
      const alt = page.locator('.VPButton.alt');
      await expect(alt).toHaveCSS('background-color', 'rgba(0, 0, 0, 0)');
      await expect(alt).toHaveCSS('color', theme === 'dark' ? 'rgb(140, 141, 147)' : 'rgb(95, 86, 69)');
      await alt.hover();
      await expect(alt).toHaveCSS('color', theme === 'dark' ? 'rgb(237, 238, 240)' : 'rgb(42, 37, 32)');
    });

    test('muted text, brand controls and code labels meet docs contrast checks', async ({ page }) => {
      const colors = await page.locator('html').evaluate(element => {
        const style = getComputedStyle(element);
        return ['--aiur-color-muted', '--aiur-color-bg', '--aiur-color-bg-2',
          '--vp-button-brand-text', '--vp-button-brand-bg'].map(name => style.getPropertyValue(name).trim());
      });
      for (const background of colors.slice(1, 3)) expect(contrast(colors[0], background)).toBeGreaterThanOrEqual(4.5);
      expect(contrast(colors[3], colors[4])).toBeGreaterThanOrEqual(4.5);
      await page.getByRole('link', { name: 'Start building' }).click();
      await expect(page.locator('.lang')).toBeVisible();
      await expect(page.locator('.lang')).toHaveCSS('color', theme === 'dark' ? 'rgb(140, 141, 147)' : 'rgb(95, 86, 69)');
      expect(contrast(...await renderedColors(page.locator('.lang')))).toBeGreaterThanOrEqual(4.5);
    });

    test('home and doc screenshots', async ({ page }) => {
      for (const [name, route] of [['home', ''], ['doc', 'guide.html']]) {
        await page.goto(fixture + route);
        await page.evaluate(() => document.fonts.ready);
        await expect(page).toHaveScreenshot(`vitepress-${name}-${theme}.png`, {
          maxDiffPixelRatio: .002, animations: 'disabled', caret: 'hide',
        });
      }
    });
  });
}

test('data-theme dark hook works without the VitePress class', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'light' });
  await page.addInitScript(() => localStorage.setItem('vitepress-theme-appearance', 'light'));
  await page.goto(fixture);
  await page.locator('html').evaluate(element => element.setAttribute('data-theme', 'dark'));
  await expect(page.locator('html')).not.toHaveClass(/dark/);
  await expect(page.locator('body')).toHaveCSS('background-color', 'rgb(26, 27, 30)');
  await expect(page.locator('.VPButton.brand')).toHaveCSS('background-color', 'rgb(31, 87, 196)');
});
