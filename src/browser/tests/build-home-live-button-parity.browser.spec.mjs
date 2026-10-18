import { readFile } from 'node:fs/promises'
import { test, expect } from '@playwright/test'
import { openParityPair, waitParityReady, expectDesignParity, FIXTURE_META } from '../support/design-parity.mjs'

// The header/usage composition changes the global Y by a fractional pixel.
// Keep the control's own background, opacity, geometry and real `.at` state.
async function compareControl(pair, name) {
  const originals = []
  for (const page of [pair.design, pair.product]) originals.push(await page.locator('#bd-nowbtn').evaluate(el => {
    const box = el.getBoundingClientRect(), style = el.getAttribute('style'), canvas = document.createElement('div')
    canvas.dataset.liveControlCanvas = ''
    Object.assign(canvas.style, { position: 'fixed', left: Math.round(box.x) + 'px', top: '100px', width: box.width + 'px', height: box.height + 'px', background: 'var(--bg)', zIndex: '9998' })
    el.parentElement.appendChild(canvas)
    Object.assign(el.style, { position: 'fixed', left: Math.round(box.x) + 'px', top: '100px', width: box.width + 'px', height: box.height + 'px', boxSizing: 'border-box', margin: '0', zIndex: '9999' })
    const moved = el.getBoundingClientRect(), hit = document.elementFromPoint(moved.x + moved.width / 2, moved.y + moved.height / 2)
    if (hit !== el && !el.contains(hit)) throw new Error('Live control is covered by its fixture canvas')
    return style
  }))
  try { await expectDesignParity(pair, { name, region: '#bd-nowbtn', preserveAnimations: true }) }
  finally {
    for (const [i, page] of [pair.design, pair.product].entries()) await page.locator('#bd-nowbtn').evaluate((el, style) => {
      if (style === null) el.removeAttribute('style'); else el.setAttribute('style', style)
      document.querySelector('[data-live-control-canvas]').remove()
    }, originals[i])
  }
}

const source = await readFile(new URL('../../test/fixtures/build_home/design-source/assets/build.js', import.meta.url), 'utf8')
test.use({ trace: 'off' })
test.setTimeout(60000)
for (const dataset of ['live', 'newrepo']) for (const theme of ['dark', 'light']) for (const palette of ['aiur', 'gruvbox']) test(`Live control pixels and floating state: ${dataset} ${theme} ${palette}`, async ({ browser }) => {
  const pair = await openParityPair(browser, { viewport: { width: 1440, height: 1100 }, deviceScaleFactor: 1, dataset, theme, palette }, { motion: true })
  try {
    const assets = test.info().project.metadata.bandAssetRoot
    if (assets) {
      await pair.product.route('**/build-home/*.js', async route => route.fulfill({ contentType: 'text/javascript', body: await readFile(assets + '/' + new URL(route.request().url()).pathname.split('/').at(-1), 'utf8') }))
      await pair.product.reload(); await waitParityReady(pair.product, 'board', 'product', true)
    }
    const probe = 'window.__liveControl = offset => { S.ready = false; snapping = true; vp.scrollTop = secs.hist.el.offsetTop + L.secs.hist.h - LH - offset; update(); };\n'
    await pair.design.route('**/assets/build.js*', route => route.fulfill({ contentType: 'text/javascript', body: source.replace('  window.AiurBuild = {', probe + '  window.AiurBuild = {') }))
    await pair.design.reload(); await waitParityReady(pair.design, 'board', 'design', true)
    for (const page of [pair.design, pair.product]) await page.clock.setSystemTime(FIXTURE_META.now)
    for (const offset of [100, 0]) {
      await pair.design.evaluate(offset => window.__liveControl(offset), offset)
      await pair.product.evaluate(async offset => {
        const { ctx, S, fx, LH } = await import('/build-home/state.js')
        S.ready = false; ctx.snapping = true
        ctx.vp.scrollTop = ctx.secs.hist.el.offsetTop + ctx.L.secs.hist.h - LH - offset; fx.update()
      }, offset)
      const at = await Promise.all([pair.design, pair.product].map(page => page.locator('#bd-nowbtn').evaluate(el => el.classList.contains('at'))))
      expect(at[1]).toBe(at[0])
      if (dataset === 'live') expect(at[1]).toBe(offset === 100)
      await compareControl(pair, `live-control-${dataset}-${theme}-${palette}-${offset}`)
    }
  } finally { await pair.close() }
})
