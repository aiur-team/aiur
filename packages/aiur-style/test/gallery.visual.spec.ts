import { registerContentTests } from './content.spec';
import './footer.spec';
import { test, expect } from '@playwright/test';
import { writeFileSync } from 'node:fs';
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

    // Keep the token baseline scoped to its original gallery content.
    await page.locator('#footer').evaluate(element => element.remove());

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

    // Keep the token baseline scoped to its original gallery content.
    await page.locator('#footer').evaluate(element => element.remove());

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

test('offline type specimens load every bundled weight', async ({ page }) => {
  const fonts: string[] = [];
  page.on('response', response => {
    if (response.url().endsWith('.woff2') && response.status() === 200) fonts.push(response.url());
  });
  await page.route('**/*', route => route.request().url().startsWith('http://127.0.0.1:3000/')
    ? route.continue() : route.abort());
  const stylesheet = page.waitForResponse(response => response.url().endsWith('/dist/fonts.css'));
  await page.goto('http://127.0.0.1:3000/gallery/?specimens');
  expect((await stylesheet).status()).toBe(200);
  const loaded = await page.evaluate(async () => {
    const results: boolean[] = [];
    for (const [family, weights] of [
      ['Bungee', [400]], ['Space Grotesk', [300, 400, 500, 600, 700]],
      ['JetBrains Mono', [100, 200, 300, 400, 500, 600, 700, 800]],
    ] as [string, number[]][]) {
      for (const weight of weights) {
        const faces = await document.fonts.load(`${weight} 16px "${family}"`);
        results.push(faces.length === 1 && faces[0].status === 'loaded'
          && document.fonts.check(`${weight} 16px "${family}"`));
      }
    }
    await document.fonts.ready;
    return results;
  });
  expect(loaded).toEqual(Array(14).fill(true));
  expect(new Set(fonts).size).toBe(3);
  await expect(page.locator('#type-specimens')).toHaveScreenshot('type-specimens.png');
});

for (const background of ['#ffffff', '#1a1b1e']) {
test(`optimized logos on ${background}; nearest neighbor fails`, async ({ page }, testInfo) => {
  await page.goto('./');
  const errors = await page.evaluate(async (background) => {
    const load = async (name: string) => {
      const image = new Image();
      image.src = `../dist/assets/${name}`;
      await image.decode();
      return image;
    };
    const original = await load('aiur-logo.png');
    const png = await load('aiur-logo-512.png');
    const webp = await load('aiur-logo-512.webp');
    const canvas = document.createElement('canvas');
    canvas.width = png.width; canvas.height = png.height;
    const context = canvas.getContext('2d')!;
    context.imageSmoothingEnabled = false;
    context.drawImage(original, 0, 0, canvas.width, canvas.height);
    const bad = new Image(); bad.src = canvas.toDataURL(); await bad.decode();
    const lab = (r: number, g: number, b: number) => {
      const linear = (v: number) => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
      [r, g, b] = [r, g, b].map(v => linear(v / 255));
      const f = (v: number) => v > 216 / 24389 ? Math.cbrt(v) : (24389 / 27 * v + 16) / 116;
      const x = f((r * .4124564 + g * .3575761 + b * .1804375) / .95047);
      const y = f(r * .2126729 + g * .7151522 + b * .072175);
      const z = f((r * .0193339 + g * .119192 + b * .9503041) / 1.08883);
      return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
    };
    const render = (image: HTMLImageElement, height: number) => {
      const c = document.createElement('canvas');
      c.height = height; c.width = Math.round(original.width / original.height * height);
      const ctx = c.getContext('2d')!;
      ctx.fillStyle = background; ctx.fillRect(0, 0, c.width, c.height);
      ctx.imageSmoothingQuality = 'high';
      ctx.drawImage(image, 0, 0, c.width, c.height);
      return ctx.getImageData(0, 0, c.width, c.height).data;
    };
    const compare = (image: HTMLImageElement, height: number) => {
      const a = render(original, height), b = render(image, height);
      let max = 0, sum = 0, over2 = 0;
      for (let i = 0; i < a.length; i += 4) {
        const x = lab(a[i], a[i + 1], a[i + 2]), y = lab(b[i], b[i + 1], b[i + 2]);
        const delta = Math.hypot(...x.map((v, j) => v - y[j]));
        max = Math.max(max, delta); sum += delta; if (delta > 2) over2++;
      }
      const diff = document.createElement('canvas');
      diff.height = height; diff.width = a.length / 4 / height;
      const ctx = diff.getContext('2d')!;
      const pixels = ctx.createImageData(diff.width, diff.height);
      for (let i = 0; i < a.length; i += 4) {
        const changed = a.slice(i, i + 3).some((value, j) => value !== b[i + j]);
        pixels.data.set(changed ? [255, 0, 128, 255] : [255, 255, 255, 255], i);
      }
      ctx.putImageData(pixels, 0, 0);
      return { max, mean: sum / (a.length / 4), over2: over2 / (a.length / 4), diff: diff.toDataURL() };

    };
    const panels = [224, 28].map(height => {
      const c = document.createElement('canvas');
      const width = Math.round(original.width / original.height * height);
      c.width = width * 3; c.height = height;
      const ctx = c.getContext('2d')!;
      ctx.fillStyle = background; ctx.fillRect(0, 0, c.width, c.height);
      ctx.imageSmoothingQuality = 'high';
      [original, png, bad].forEach((image, index) => ctx.drawImage(image, index * width, 0, width, height));
      return c.toDataURL();
    });
    return { badSource: bad.src, panels, png: [compare(png, 224), compare(png, 28)],
      webp: [compare(webp, 224), compare(webp, 28)], bad: compare(bad, 224) };
  }, background);
  writeFileSync(testInfo.outputPath('nearest-neighbor-512.png'), Buffer.from(errors.badSource.split(',')[1], 'base64'));
  for (const [index, panel] of errors.panels.entries()) {
    writeFileSync(testInfo.outputPath(`logo-review-${[224, 28][index]}.png`), Buffer.from(panel.split(',')[1], 'base64'));
    await testInfo.attach(`logo-original-lanczos-nearest-${[224, 28][index]}.png`, {
      body: Buffer.from(panel.split(',')[1], 'base64'), contentType: 'image/png',
    });
  }
  for (const [format, comparisons] of [['png', errors.png], ['webp', errors.webp], ['nearest', [errors.bad]]] as const) {
    for (const [index, comparison] of comparisons.entries()) {
      writeFileSync(testInfo.outputPath(`logo-${format}-${[224, 28][index]}-diff.png`), Buffer.from(comparison.diff.split(',')[1], 'base64'));
      await testInfo.attach(`logo-${format}-${[224, 28][index]}-diff.png`, {
        body: Buffer.from(comparison.diff.split(',')[1], 'base64'), contentType: 'image/png',
      });
    }
  }
  const metrics = { png: errors.png.map(({ diff, ...metric }) => metric),
    webp: errors.webp.map(({ diff, ...metric }) => metric), bad: (({ diff, ...metric }) => metric)(errors.bad) };
  console.log('Logo ΔE76 metrics:', metrics);
  await testInfo.attach('logo-metrics', { body: JSON.stringify(metrics, null, 2), contentType: 'application/json' });
  const withinBudget = (metric: { mean: number; max: number; over2: number }, index: number) =>
    metric.mean < [0.43, 2][index] && metric.max < 34 && metric.over2 <= [0.05, 0.27][index];
  for (const comparisons of [errors.png, errors.webp]) {
    for (const [index, comparison] of comparisons.entries()) expect.soft(withinBudget(comparison, index), `optimized logo at ${[224, 28][index]}px`).toBe(true);
  }
  expect.soft(withinBudget(errors.bad, 0), 'nearest-neighbor must fail at 224px').toBe(false);
});
}
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
