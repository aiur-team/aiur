import { test, expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { minify } from 'terser';

const gallery = readFileSync(new URL('../gallery/index.html', import.meta.url), 'utf8');
const source = readFileSync(new URL('../src/init/theme-init.js', import.meta.url), 'utf8');

// Kept as a deliberately wrong fixture: module execution waits until after parsing.
const deferredFixture = gallery.replace('src="../dist/init/theme-init.js"', 'type="module" src="../dist/init/theme-init.js"');

async function serve(page: Page, attributes = '', deferred = false, csp = false) {
  const html = (deferred ? deferredFixture : gallery).replace('data-default="dark"', attributes || 'data-default="dark"');
  await page.route('**/gallery/fixture.html', route => route.fulfill({
    contentType: 'text/html', body: html,
    headers: csp ? { 'Content-Security-Policy': "script-src 'self'" } : {},
  }));
  if (deferred) await page.route('**/dist/init/theme-init.js', async route => {
    await new Promise(resolve => setTimeout(resolve, 200));
    // Modules lack currentScript; adapt only the lookup so the same logic runs late.
    await route.fulfill({ contentType: 'text/javascript', body: source.replace('document.currentScript', "document.querySelector('script[data-default]')") });
  });
}

async function observeLight(page: Page) {
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.addInitScript(() => {
    localStorage.setItem('aiur-theme', 'light');
    const state = window as typeof window & { wrongThemeObserved: boolean; frames: string[] };
    state.wrongThemeObserved = false;
    state.frames = [];
    new MutationObserver(() => {
      if (document.body && document.documentElement.getAttribute('data-theme') !== 'light') {
        state.wrongThemeObserved = true;
      }
    }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-theme'] });
    function frame() {
      if (document.body) state.frames.push(getComputedStyle(document.documentElement).colorScheme);
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  });
}

async function lightEvidence(page: Page) {
  await page.waitForFunction(() => (window as typeof window & { frames: string[] }).frames.length > 0);
  return page.evaluate(() => {
    const state = window as typeof window & { wrongThemeObserved: boolean; frames: string[] };
    return { wrong: state.wrongThemeObserved, darkFrame: state.frames.includes('dark') };
  });
}

test('stored light overrides default dark before body mutations and every observed frame', async ({ page }) => {
  await observeLight(page);
  await page.goto('./');
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  expect(await lightEvidence(page)).toEqual({ wrong: false, darkFrame: false });
});

test('negative module fixture fails the same pre-paint assertion', async ({ page }) => {
  await observeLight(page);
  await serve(page, '', true);
  await page.goto('./fixture.html');
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  const evidence = await lightEvidence(page);
  expect(() => expect(evidence).toEqual({ wrong: false, darkFrame: false })).toThrow();
  expect(evidence).toEqual({ wrong: true, darkFrame: true });
});

test('system dark leaves the attribute absent and resolves dark tokens', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'dark' });
  await serve(page, 'data-default="system"');
  await page.goto('./fixture.html');
  expect(await page.locator('html').getAttribute('data-theme')).toBeNull();
  expect(await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--aiur-color-bg').trim())).toBe('#1a1b1e');
});

test('migrates the first legacy theme and banner dismissal', async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('khala.theme', 'light');
    localStorage.setItem('archon.theme', 'dark');
    localStorage.setItem('khala.aiur-banner.dismissed', '1');
  });
  await serve(page, 'data-default="dark" data-legacy-keys="khala.theme archon.theme khala.aiur-banner.dismissed" data-banner="aiur-launch"');
  await page.goto('./fixture.html');
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  await expect(page.locator('html')).toHaveAttribute('data-aiur-banner', 'dismissed');
  expect(await page.evaluate(() => ({ ...localStorage }))).toEqual({
    'aiur-theme': 'light', 'archon.theme': 'dark', 'aiur-banner:aiur-launch': 'dismissed',
  });
});

test('existing custom choice and dismissal win over legacy values', async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('custom-theme', 'light');
    localStorage.setItem('khala.theme', 'dark');
    localStorage.setItem('aiur-banner:launch', 'dismissed');
  });
  await serve(page, 'data-default="dark" data-storage-key="custom-theme" data-legacy-keys="khala.theme" data-banner="launch"');
  await page.goto('./fixture.html');
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  await expect(page.locator('html')).toHaveAttribute('data-aiur-banner', 'dismissed');
  expect(await page.evaluate(() => localStorage.getItem('khala.theme'))).toBe('dark');
});

for (const theme of ['light', 'dark', 'system']) {
  test(`VitePress bridge synchronizes ${theme}`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'dark' });
    await serve(page, `data-default="${theme}" data-vitepress="true"`);
    await page.goto('./fixture.html');
    expect(await page.evaluate(() => localStorage.getItem('vitepress-theme-appearance'))).toBe(theme === 'system' ? 'auto' : theme);
    expect(await page.locator('html').evaluate(html => html.classList.contains('dark'))).toBe(theme !== 'light');
  });
}

test('blocked localStorage renders without console or page errors', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  await page.addInitScript(() => Object.defineProperty(window, 'localStorage', { get() { throw new Error('blocked'); } }));
  await serve(page, 'data-default="dark" data-vitepress="true" data-banner="launch" data-legacy-keys="khala.theme"');
  await page.goto('./fixture.html');
  await expect(page.locator('.swatch')).not.toHaveCount(0);
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  expect(errors).toEqual([]);
});

test('gallery runs under script-src self without CSP violations', async ({ page }) => {
  await page.addInitScript(() => {
    const state = window as typeof window & { violations: string[] };
    state.violations = [];
    document.addEventListener('securitypolicyviolation', event => state.violations.push(event.violatedDirective));
  });
  await serve(page, '', false, true);
  await page.goto('./fixture.html');
  await expect(page.locator('.swatch')).not.toHaveCount(0);
  await page.locator('#theme-toggle').click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  expect(await page.evaluate(() => (window as typeof window & { violations: string[] }).violations)).toEqual([]);
});

for (const theme of ['dark', 'system']) {
  test(`screenshot: default ${theme} under system light`, async ({ page }, info) => {
    await page.emulateMedia({ colorScheme: 'light' });
    await serve(page, `data-default="${theme}"`);
    await page.goto('./fixture.html');
    await expect(page.locator('.swatch')).not.toHaveCount(0);
    expect(await page.locator('html').getAttribute('data-theme')).toBe(theme === 'system' ? null : 'dark');
    await info.attach(`gallery-${theme}`, { body: await page.screenshot({ fullPage: true }), contentType: 'image/png' });
  });
}

test('readable ES5 initializer fits the 1024-byte minified budget', async () => {
  const result = await minify(source, { compress: true, mangle: true, ecma: 5 });
  expect(Buffer.byteLength(result.code!)).toBeLessThanOrEqual(1024);
});
