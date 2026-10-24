import { readFile } from 'node:fs/promises'
import { test, expect } from '@playwright/test'
import { openParityPair, waitParityReady, expectDesignParity, PARITY_VIEWPORTS, FIXTURE_META } from '../support/design-parity.mjs'
import { alignBoard, primeBoardPaint } from '../support/build-home-band-canvas.mjs'
import { nowPatch } from '../scripts/build-home-now-patch.mjs'

test.use({ trace: 'off' })
test.setTimeout(120000)
const source = await readFile(new URL('../../test/fixtures/build_home/design-source/assets/build.js', import.meta.url), 'utf8')
async function freeze(pair, dataset, initial = false) {
  const assets = test.info().project.metadata.bandAssetRoot
  if (assets) await pair.product.route('**/build-home/*.js', async route => route.fulfill({ contentType: 'text/javascript', body: await readFile(assets + '/' + new URL(route.request().url()).pathname.split('/').at(-1), 'utf8') }))
  if (initial) await pair.product.route('**/build-home/hook.js', async route => {
    const hook = await readFile(assets ? assets + '/hook.js' : new URL('../../priv/static/build-home/hook.js', import.meta.url), 'utf8')
    expect(hook.split('S.ready = true;')).toHaveLength(2)
    await route.fulfill({ contentType: 'text/javascript', body: hook.replace('S.ready = true;', 'S.ready = false;') })
  })
  if (assets || initial) {
    await pair.product.reload(); await waitParityReady(pair.product, 'board', 'product', true)
  }
  const anchor = '  window.AiurBuild = {'
  const probe = nowPatch(source, dataset).replace(anchor, `window.__bandProbe = { stop() { S.ready = false; snapping = true; }, scroll(st) { vp.scrollTop = st; update(); } };\n${anchor}`)
  await pair.design.route('**/assets/build.js*', route => route.fulfill({ contentType: 'text/javascript', body: probe }))
  await pair.design.reload(); await waitParityReady(pair.design, 'board', 'design', true)
  await pair.design.evaluate(() => window.__bandProbe.stop())
  await pair.product.evaluate(async () => {
    const { S, ctx } = await import('/build-home/state.js'); S.ready = false; ctx.snapping = true
  })
  await alignBoard(pair)
  await Promise.all([pair.design, pair.product].map(page => page.clock.setSystemTime(FIXTURE_META.now)))
}
// The ETA copy is the sole pending C7-T03 exception; no header/card masks are added.
for (const dataset of ['live', 'dense', 'newrepo', 'noqueue', 'offline', 'now0', 'now24']) for (const viewport of PARITY_VIEWPORTS) for (const theme of ['dark', 'light']) for (const palette of ['gruvbox', 'aiur']) {
  test(`band pixels and card geometry: ${dataset} ${viewport.viewport.width} ${theme} ${palette}`, async ({ browser }) => {
    const cell = { ...viewport, theme, palette, dataset: ['now0', 'now24'].includes(dataset) ? 'live' : dataset }
    const pair = await openParityPair(browser, cell, { motion: true })
    try {
      if (['now0', 'now24'].includes(dataset)) {
        await pair.product.goto('/build-fixture/' + dataset)
        await waitParityReady(pair.product, 'board', 'product', true)
      }
      await freeze(pair, dataset)
      const geometry = page => page.evaluate(() => ({
        h: document.querySelector('#bd-now').style.height,
        cards: Array.from(document.querySelectorAll('#bd-now .bd-card'), el => ({ id: el.dataset.id.replace('AIUR-', ''), ...Object.fromEntries(['top', 'left', 'width', 'height'].map(k => [k, parseFloat(el.style[k])])) }))
      }))
      const [d, p] = await Promise.all([geometry(pair.design), geometry(pair.product)])
      expect(p.h).toBe(d.h); expect(p.cards.map(c => c.id)).toEqual(d.cards.map(c => c.id))
      for (let i = 0; i < d.cards.length; i++) for (const key of ['top', 'left', 'width', 'height']) expect(Math.abs(p.cards[i][key] - d.cards[i][key])).toBeLessThanOrEqual(1)
      // Tall bands extend beyond the scrollport. Compare the whole visible
      // composition there; a bounding-box clip would include off-page pixels.
      const region = await pair.design.locator('#bd-vp').evaluate((vp, h) => parseFloat(h) > vp.clientHeight ? '#bd-vp' : '#bd-now', d.h)
      for (const position of ['top', 'bottom']) {
        const st = await pair.design.evaluate(position => {
          const vp = document.querySelector('#bd-vp'), band = document.querySelector('#bd-now'), hist = document.querySelector('#bd-sec-hist')
          return Math.max(0, hist.offsetTop + hist.offsetHeight - (position === 'top' ? 46 : vp.clientHeight - band.offsetHeight))
        }, position)
        await pair.design.evaluate(st => window.__bandProbe.scroll(st), st)
        await pair.product.evaluate(async st => { const { ctx, fx } = await import('/build-home/state.js'); ctx.vp.scrollTop = st; fx.update() }, st)
        await primeBoardPaint(pair)
        await expectDesignParity(pair, { name: `band-${dataset}-${viewport.viewport.width}-${theme}-${palette}-${position}`, region, preserveAnimations: true })
      }
      await Promise.all([pair.design, pair.product].map(page => page.locator('[data-min]').evaluate(el => el.click())))
      await primeBoardPaint(pair)
      await expectDesignParity(pair, { name: `band-${dataset}-${viewport.viewport.width}-${theme}-${palette}-min`, region: '#bd-now', preserveAnimations: true })
      for (const ast of await pair.design.locator('.bd-now-st [data-ast]').evaluateAll(els => els.map(el => el.dataset.ast))) {
        await Promise.all([pair.design, pair.product].map(page => page.locator('.bd-now-h [data-ast="' + ast + '"]').first().evaluate(el => el.click())))
        await primeBoardPaint(pair)
        // Filter dimming behind the blurred band belongs to C10-T02.
        await expectDesignParity(pair, { name: `band-${dataset}-${viewport.viewport.width}-${theme}-${palette}-${ast}`, region: '.bd-now-st', preserveAnimations: true })
      }
    } finally { await pair.close() }
  })
}
// #3141 acceptance: same global scrollTop, rendered mobile cards and headers, no masks.
for (const theme of ['dark', 'light']) for (const palette of ['gruvbox', 'aiur']) for (const dataset of ['live', 'dense', 'newrepo', 'noqueue', 'offline']) test(`mobile composed headers without masks: ${dataset} ${theme} ${palette}`, async ({ browser }) => {
  const pair = await openParityPair(browser, { ...PARITY_VIEWPORTS[2], theme, palette, dataset }, { motion: true })
  try {
    // Freeze readiness before the product's first scroll event can page history;
    // freeze() reloads the reference, so both sides keep their initial payload.
    await freeze(pair, dataset, true)
    pair.allowlist = pair.allowlist.filter(entry => entry.kind !== 'pixel-mask')
    await Promise.all([pair.design, pair.product].map(page => page.locator('[data-min]').evaluate(el => el.click())))
    for (const sec of ['hist', 'plan', 'nq']) {
      const st = await pair.design.locator('#bd-sec-' + sec).evaluate(el => el.offsetTop - 160)
      await pair.design.evaluate(st => window.__bandProbe.scroll(st), st)
      await pair.product.evaluate(async st => { const { ctx, fx } = await import('/build-home/state.js'); ctx.vp.scrollTop = st; fx.update() }, st)
      const [dy, py] = await Promise.all([pair.design, pair.product].map(page => page.locator(`#bd-sec-${sec} .bd-sech`).evaluate(el => el.getBoundingClientRect().top)))
      expect(Math.abs(py - dy)).toBeLessThanOrEqual(1)
      const scroll = page => page.evaluate(() => ({ top: document.querySelector('#bd-vp').scrollTop, x: scrollX, y: scrollY }))
      const before = await Promise.all([pair.design, pair.product].map(scroll))
      expect(before[1].top).toBe(before[0].top)
      await primeBoardPaint(pair)
      await expectDesignParity(pair, { name: `mobile-composed-${dataset}-${theme}-${palette}-${sec}`, region: `#bd-sec-${sec} .bd-sech` })
      await expectDesignParity(pair, { name: `mobile-composed-cards-${dataset}-${theme}-${palette}-${sec}`, region: '#bd-vp' })
      expect(await Promise.all([pair.design, pair.product].map(scroll))).toEqual(before)
      const cards = page => page.locator('.bd-sec .bd-card').evaluateAll(els => els.map(el => ({ id: el.dataset.id.replace('AIUR-', ''), top: el.getBoundingClientRect().top })).sort((a, b) => a.id.localeCompare(b.id)))
      const [d, p] = await Promise.all([cards(pair.design), cards(pair.product)])
      expect(p.map(c => c.id)).toEqual(d.map(c => c.id))
      for (let i = 0; i < d.length; i++) expect(Math.abs(p[i].top - d[i].top)).toBeLessThanOrEqual(1)
    }
  } finally { await pair.close() }
})
