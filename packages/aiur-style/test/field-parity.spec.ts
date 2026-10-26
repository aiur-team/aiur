import { test, expect } from '@playwright/test';
import { transformSync } from 'esbuild';
import { readFileSync } from 'node:fs';
import { PNG } from 'pngjs';
import pixelmatch from 'pixelmatch';

// AS-05 reference: website/src/flowField.ts at 221ba57bb, vendored independently of the new module.
const reference = transformSync(readFileSync(new URL('./fixtures/field-as05.ts', import.meta.url), 'utf8'), { loader: 'ts', format: 'esm' }).code;

for (const theme of ['dark', 'light']) {
  test(`field AS-05 pixel parity ${theme}`, async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto(`field.html?theme=${theme}&no-hug&legacy`);
    await page.evaluate(() => { document.documentElement.dataset.fieldDebug = ''; return document.fonts.ready; });
    await page.addScriptTag({ type: 'module', content: `${reference}\nwindow.reference = createFlowField();` });
    await page.evaluate(() => {
      document.body.style.setProperty('--line', getComputedStyle(document.querySelector('canvas')!).getPropertyValue('--aiur-color-field-line'));
      (window as any).reference.redraw();
    });
    const before = PNG.sync.read(Buffer.from(await page.locator('canvas').evaluate(el => (el as HTMLCanvasElement).toDataURL().split(',')[1]), 'base64'));
    await page.evaluate(async () => {
      const { createFlowField } = await import('../dist/js/field.js');
      (window as any).field = createFlowField(document.querySelector('canvas')!);
      await new Promise(requestAnimationFrame);
    });
    const after = PNG.sync.read(Buffer.from(await page.locator('canvas').evaluate(el => (el as HTMLCanvasElement).toDataURL().split(',')[1]), 'base64'));
    expect([after.width, after.height]).toEqual([before.width, before.height]);
    const changed = pixelmatch(before.data, after.data, null, before.width, before.height, { threshold: 0, includeAA: true });
    expect(changed / (before.width * before.height)).toBeLessThanOrEqual(0.0005);
    expect(before.data.filter((value, i) => i % 4 === 3 && value > 0).length).toBeGreaterThan(1000);
  });
}
