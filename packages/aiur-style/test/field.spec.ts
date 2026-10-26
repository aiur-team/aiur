import { test, expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { transformSync } from 'esbuild';

async function open(page: Page, query = '') {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto(`field.html${query}`);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForFunction(() => (window as any).field?.debug().obstacles.length > 0);
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

async function tabPixelsMatch(page: Page, switchTab = true) {
  return page.evaluate(async (switchTab) => {
    const canvas = document.querySelector('canvas')!;
    if (switchTab) (document.querySelector('#prompt-tab') as HTMLElement).click();
    await new Promise(requestAnimationFrame);
    const actual = canvas.toDataURL();
    const comparison = canvas.cloneNode() as HTMLCanvasElement;
    canvas.parentElement!.append(comparison);
    const { createFlowField } = await import('../dist/js/field.js');
    const field = createFlowField(comparison);
    await new Promise(requestAnimationFrame);
    const matches = actual === comparison.toDataURL();
    field.destroy();
    comparison.remove();
    return matches;
  }, switchTab);
}

test('field R-TAB-1: command obstacle follows tab rect inside one frame', async ({ page }) => {
  await open(page);
  const result = await page.evaluate(async () => {
    const box = document.querySelector('#command')!;
    const old = box.getBoundingClientRect();
    (document.querySelector('#prompt-tab') as HTMLElement).click();
    await new Promise(requestAnimationFrame);
    const rect = box.getBoundingClientRect();
    const canvas = document.querySelector('canvas')!.getBoundingClientRect();
    const obstacles = (window as any).field.debug().obstacles;
    return { grew: rect.height > old.height, error: Math.min(...obstacles.map((ob: any) =>
      Math.max(Math.abs(ob.cx - (rect.left - canvas.left + rect.width / 2)),
        Math.abs(ob.cy - (rect.top - canvas.top + rect.height / 2)),
        Math.abs(ob.hx - rect.width / 2 - 9), Math.abs(ob.hy - rect.height / 2 - 6)))) };
  });
  expect(result.grew).toBe(true);
  expect(result.error).toBeLessThanOrEqual(1);
});

test('field R-TAB-1 canvas equals rebuilt geometry inside one frame', async ({ page }) => {
  await open(page, '?no-hug');
  expect(await tabPixelsMatch(page, false)).toBe(true);
  expect(await tabPixelsMatch(page)).toBe(true);
});

test('field R-TAB-1 negative: vendored pre-AS-05 fails the same pixel assertion', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('field.html?legacy&no-hug');
  await page.evaluate(() => document.fonts.ready);
  const source = transformSync(readFileSync(new URL('./fixtures/field-pre-as05.ts', import.meta.url), 'utf8'), { loader: 'ts', format: 'esm' }).code;
  await page.evaluate(() => document.body.style.setProperty('--line', getComputedStyle(document.querySelector('canvas')!).getPropertyValue('--aiur-color-field-line')));
  await page.addScriptTag({ type: 'module', content: `${source}\nwindow.legacy = createFlowField();` });
  await page.evaluate(() => new Promise(requestAnimationFrame));
  expect(await tabPixelsMatch(page, false)).toBe(true);
  const matches = await tabPixelsMatch(page);
  test.fail(true, 'Pre-AS-05 rebuilds only on window resize; the command keepout stays stale.');
  expect(matches).toBe(true);
});

test('field observes added, removed and reclassified keepouts within one frame', async ({ page }) => {
  await open(page);
  const counts = await page.evaluate(async () => {
    const field = (window as any).field;
    const counts = [field.debug().obstacles.length];
    const el = document.createElement('div');
    el.textContent = 'New keepout'; el.className = 'aiur-keepout';
    document.querySelector('main')!.append(el);
    // Read after all callbacks in the next frame, including the observer-scheduled update.
    await new Promise(resolve => requestAnimationFrame(() => setTimeout(resolve, 0)));
    counts.push(field.debug().obstacles.length);
    el.className = '';
    await new Promise(resolve => requestAnimationFrame(() => setTimeout(resolve, 0)));
    counts.push(field.debug().obstacles.length);
    el.className = 'keepout';
    await new Promise(resolve => requestAnimationFrame(() => setTimeout(resolve, 0)));
    counts.push(field.debug().obstacles.length);
    el.remove();
    await new Promise(resolve => requestAnimationFrame(() => setTimeout(resolve, 0)));
    counts.push(field.debug().obstacles.length);
    return counts;
  });
  expect(counts).toEqual([counts[0], counts[0] + 1, counts[0], counts[0] + 1, counts[0]]);
});

test('field ResizeObserver tracks each keepout without layout events', async ({ page }) => {
  await open(page);
  const widths = await page.evaluate(async () => {
    const el = document.querySelector('#command') as HTMLElement;
    const before = (window as any).field.debug().obstacles.map((ob: any) => ob.hx);
    await new Promise(resolve => {
      const observer = new ResizeObserver(() => { observer.disconnect(); requestAnimationFrame(resolve); });
      observer.observe(el);
      el.style.width = '290px';
    });
    return { before, after: (window as any).field.debug().obstacles.map((ob: any) => ob.hx) };
  });
  expect(widths.after).not.toEqual(widths.before);
  expect(widths.after).toContain(154);
});

test('field hug obstacles merge inline fragments per line with snug padding', async ({ page }) => {
  await open(page);
  const result = await page.evaluate(() => {
    const el = document.querySelector('.hug')!;
    const range = document.createRange(); range.selectNodeContents(el);
    const rects = Array.from(range.getClientRects()).filter(rect => rect.width);
    const tops = [...new Set(rects.map(rect => Math.round(rect.top)))];
    const canvas = document.querySelector('canvas')!.getBoundingClientRect();
    const obs = (window as any).field.debug().obstacles.slice(4);
    return { tops, obs, canvasTop: canvas.top, boundsWidth: el.getBoundingClientRect().width,
      ranges: tops.map(top => { const line = rects.filter(rect => Math.round(rect.top) === top);
        return { left: Math.min(...line.map(r => r.left)), right: Math.max(...line.map(r => r.right)) }; }) };
  });
  expect(result.tops.length).toBeGreaterThan(1);
  expect(result.obs).toHaveLength(result.tops.length);
  for (let i = 0; i < result.obs.length; i++) {
    expect(result.obs[i].hx).toBeCloseTo((result.ranges[i].right - result.ranges[i].left) / 2 + 9, 4);
    expect(result.obs[i].r).toBeCloseTo(Math.min(result.obs[i].hx, result.obs[i].hy) * .55, 4);
  }
  expect(Math.min(...result.obs.map((ob: any) => ob.hx * 2 - 18))).toBeLessThan(result.boundsWidth);
});

test('field coalesces theme redraw, stops idle frames and destroys observers/listeners', async ({ page }) => {
  await open(page);
  const result = await page.evaluate(async () => {
    const canvas = document.querySelector('canvas')!;
    const ctx = canvas.getContext('2d')!;
    let draws = 0;
    const clear = ctx.clearRect.bind(ctx);
    ctx.clearRect = (...args) => { draws++; clear(...args); };
    const before = canvas.toDataURL();
    document.documentElement.dataset.theme = 'light';
    for (let i = 0; i < 3; i++) document.dispatchEvent(new CustomEvent('aiur:themechange'));
    await new Promise(requestAnimationFrame);
    const themed = canvas.toDataURL();
    const themedDraws = draws;
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    const idleDraws = draws;
    document.dispatchEvent(new CustomEvent('aiur:layoutchange'));
    (window as any).field.destroy();
    const destroyedDraws = draws;
    const empty = !ctx.getImageData(0, 0, canvas.width, canvas.height).data.some(value => value !== 0);
    document.querySelector('#command')!.classList.remove('keepout');
    document.querySelector('.hero')!.append(document.createElement('div'));
    document.dispatchEvent(new CustomEvent('aiur:themechange'));
    window.dispatchEvent(new Event('resize'));
    (window as any).field.rebuild(); (window as any).field.redraw();
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    return { changed: before !== themed, themedDraws, idleDraws, destroyedDraws, finalDraws: draws, empty,
      debug: (window as any).field.debug(), aria: canvas.getAttribute('aria-hidden') };
  });
  expect(result).toEqual({ changed: true, themedDraws: 1, idleDraws: 1, destroyedDraws: 2,
    finalDraws: 2, empty: true, debug: { obstacles: [] }, aria: 'true' });
});

for (const theme of ['dark', 'light']) {
  for (const size of [{ width: 1280, height: 800 }, { width: 390, height: 844 }]) {
    test(`field screenshot ${theme} ${size.width}x${size.height}`, async ({ page }) => {
      await page.setViewportSize(size);
      await open(page, `?theme=${theme}`);
      await expect(page).toHaveScreenshot(`field-${theme}-${size.width}x${size.height}.png`, { maxDiffPixelRatio: 0.0005, threshold: 0 });
    });
  }
}
