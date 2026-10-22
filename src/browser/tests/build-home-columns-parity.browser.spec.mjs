import { normalizeColumnCapture } from '../support/build-home-columns-motion.mjs'
import { readFile } from 'node:fs/promises'
import { test, expect } from '@playwright/test'
import { openParityPair, expectDesignParity, waitParityReady, FIXTURE_META, PARITY_VIEWPORTS } from '../support/design-parity.mjs'

const source = await readFile(new URL('../../test/fixtures/build_home/design-source/assets/build.js', import.meta.url), 'utf8')
const probe = source.replace('  window.AiurBuild = {', `window.__columns = { prepare(mode) {
  S.ready = false; snapping = true;
  if (mode === 'focus' || mode === 'compact') { S.feature = 'khala'; S.fmode = mode }
  if (mode === 'epic') { S.f.epic = ['docs']; D._fwd = null; relayout() }
  if (mode !== 'boot') vp.scrollTop = 0;
  applyCols(visibleCols(), true);
} };\n  window.AiurBuild = {`)
const cells = [
  ...['live', 'newrepo', 'noqueue', 'offline'].flatMap(dataset => [1440, 1024, 390].flatMap(width => ['light', 'dark'].flatMap(theme => ['aiur', 'gruvbox'].map(palette => ({ dataset, width, theme, palette, mode: 'boot' }))))),
  ...['live', 'dense'].flatMap(dataset => [1440, 1024].flatMap(width => ['light', 'dark'].map(theme => ({ dataset, width, theme, palette: 'gruvbox', mode: 'top' })))),
  ...['focus', 'compact', 'epic'].flatMap(mode => ['light', 'dark'].map(theme => ({ dataset: 'live', width: 1440, theme, palette: 'gruvbox', mode }))),
]
for (const cell of cells) test(`column parity ${Object.values(cell).join(' ')}`, async ({ browser }) => {
  test.setTimeout(120_000)
  const pair = await openParityPair(browser, { dataset: cell.dataset, ...PARITY_VIEWPORTS.find(v => v.viewport.width === cell.width), theme: cell.theme, palette: cell.palette }, { motion: true })
  try {
    await pair.design.route('**/assets/build.js*', route => route.fulfill({ contentType: 'text/javascript', body: probe }))
    await pair.design.reload(); await waitParityReady(pair.design, 'board', 'design', true)
    await pair.design.evaluate(mode => __columns.prepare(mode), cell.mode)
    await pair.product.evaluate(async mode => {
      const { ctx, S, fx } = await import('/build-home/state.js'), c = await import('/build-home/columns.js')
      S.ready = false
      if (mode === 'focus' || mode === 'compact') {
        await (await import('/build-home/history.js')).ensureDays(100)
        S.feature = 'khala'; S.fmode = mode
      }
      if (mode === 'epic') { S.f.epic = ['docs']; ctx.D._fwd = null; fx.relayout() }
      if (mode !== 'boot') ctx.vp.scrollTop = 0
      c.applyCols(c.visibleCols(), true)
    }, cell.mode)
    await Promise.all([pair.design, pair.product].map(async page => { await page.clock.runFor(800); await page.evaluate(() => document.getAnimations().forEach(a => Number.isFinite(a.effect?.getComputedTiming().endTime) ? a.finish() : a.cancel())); await page.clock.setSystemTime(FIXTURE_META.now) }))
    const read = page => page.evaluate(() => [...document.querySelectorAll('.bd-lane, .bd-guide')].map(el => ({ cls: el.className, left: el.style.left, width: el.style.width, hue: el.style.getPropertyValue('--h'), title: el.title, count: el.querySelector('em')?.textContent, paint: Object.fromEntries(['backgroundColor', 'borderLeft', 'font', 'color', 'transition'].map(key => [key, getComputedStyle(el)[key]])) })))
    expect(await read(pair.product)).toEqual(await read(pair.design))
    // Guides sit behind separately owned cards and the Now band; their geometry and paint are compared above.
    await Promise.all([pair.design, pair.product].map(normalizeColumnCapture))
    await expectDesignParity(pair, { name: 'columns-' + cell.mode, region: '.bd-lanes', preserveAnimations: true })
  } finally { await pair.close() }
})
