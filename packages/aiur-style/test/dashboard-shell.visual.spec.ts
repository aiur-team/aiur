import { expect, test } from '@playwright/test';

// The dashboard also supports hosts importing the consolidated package entry point.
for (const bundled of [false, true]) {
  test(`dashboard rail keeps its current geometry with ${bundled ? 'bundled' : 'individual'} CSS`, async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto('shell.html');
    const styles = bundled ? ['aiur-style.css'] : ['tokens.css', 'css/dashboard-shell.css'];
    await page.setContent(`<!doctype html><html data-theme="dark"><head>
      ${styles.map(file => `<link rel="stylesheet" href="/dist/${file}">`).join('')}
      <style>body { margin: 0; font: 16px/1.5 system-ui; }</style></head><body>
      <div class="aiur-shell aiur-shell--dashboard">
        <header class="aiur-shell__topbar"><div class="aiur-shell__brand">aiur</div></header>
        <div class="aiur-shell__body">
          <aside class="aiur-shell__sidebar"><nav class="aiur-shell__nav">
            <a class="aiur-shell__item" href="#units" aria-current="page">Units</a>
          </nav></aside><section class="aiur-page">Page</section>
        </div>
      </div></body></html>`);
    const body = page.locator('.aiur-shell__body');
    const brand = page.locator('.aiur-shell__brand');
    const item = page.locator('.aiur-shell__item');
    await expect(brand).toHaveCSS('width', '188px');
    expect((await body.evaluate(node => getComputedStyle(node).gridTemplateColumns)).split(' ')[0]).toBe('188px');
    await expect(item).toHaveCSS('min-height', '0px');
    await expect(item).toHaveCSS('line-height', '21.6px');
    await page.locator('html').evaluate(node => node.classList.add('nav-collapsed'));
    await expect(brand).toHaveCSS('width', '60px');
    expect((await body.evaluate(node => getComputedStyle(node).gridTemplateColumns)).split(' ')[0]).toBe('60px');
    await page.setViewportSize({ width: 960, height: 900 });
    await expect(page.locator('.aiur-shell__sidebar')).toHaveCSS('position', 'fixed');
    await expect(item).toHaveCSS('border-top-left-radius', '10px');
  });
}
