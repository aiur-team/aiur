import { test, expect } from '@playwright/test'
import { captureStable, openProduct, parityContextOptions, PARITY_VIEWPORTS, PARITY_THRESHOLD } from '../support/design-parity.mjs'

// Advance only until the production column/scroll schedulers and CSS have
// settled. A paused clock otherwise leaves .scrolling disabling card hit tests.
async function waitForCard(page, target, exposed = false) {
  await expect.poll(async () => {
    await page.clock.runFor(16)
    return target.evaluate(async (el, exposed) => {
      const { ctx, fx } = await import('/build-home/state.js'), box = el.getBoundingClientRect()
      return {
        columns: ctx.cols.join('|') === fx.visibleCols().join('|'),
        scrolling: ctx.isScrolling() || ctx.content.classList.contains('scrolling'),
        transitions: el.getAnimations().filter(a => a.playState === 'running' || a.pending).length,
        opacity: getComputedStyle(el).opacity,
        exposed: !exposed || [0.25, 0.75].every(x => [0.25, 0.75].every(y =>
          el.contains(document.elementFromPoint(box.left + box.width * x, box.top + box.height * y))))
      }
    }, exposed)
  }, { intervals: [16], message: 'card columns, scroll settlement, transitions and exposure' }).toEqual({
    columns: true, scrolling: false, transitions: 0, opacity: '1', exposed: true
  })
}

for (const width of [1440, 390]) for (const theme of ['dark', 'light']) test(`S-5 adopted unknown-value capture: ${width} ${theme}`, async ({ browser }, info) => {
  test.setTimeout(120000)
  const cell = { ...PARITY_VIEWPORTS.find(v => v.viewport.width === width), theme, palette: 'aiur', dataset: 'live' }
  const context = await browser.newContext({ ...parityContextOptions(cell), baseURL: info.project.use.baseURL })
  try {
    const page = await context.newPage(); await openProduct(page, cell, { query: 'view=gantt', motion: true })
    const markers = await page.evaluate(async () => {
      const { ctx, S, fx } = await import('/build-home/state.js'), { receive } = await import('/build-home/hook.js')
      const end = ctx.snap.now
      const hist = { ...ctx.snap.sections.hist[0], id: 's5-start-unknown', start: null, end, title: 'Start unknown' }
      const plan = { ...ctx.snap.sections.plan[0], id: 's5-estimate-unknown', est: null, override: null, wave: 1, title: 'Estimate unknown' }
      S.span = 1; S.ready = false; S.histFrom = end - 86400000
      receive({ ...ctx.snap, kind: 'snapshot', generation: ctx.proto.generation + 1, sections: { hist: [hist], now: [], plan: [plan], nq: [] }, history: { ...ctx.snap.history, from: end - 86400000, more: false, total: 1 } })
      ctx.vp.scrollTop = 0; fx.update()
      return ['s5-start-unknown', 's5-estimate-unknown'].map(id => {
        const el = ctx.R.get((id.includes('start') ? 'hist:' : 'plan:') + id)
        return { id, cls: el.className, title: el.querySelector('.bd-in').title, height: parseFloat(el.style.height) }
      })
    })
    expect(markers[0].cls).toContain('start-unknown'); expect(markers[0].height).toBeCloseTo(29.9, 9)
    expect(markers[1].cls).toContain('est-unknown'); expect(markers[1].cls).toContain('gplan'); expect(markers[1].height).toBe(32.5)
    expect(markers.map(m => m.title.endsWith(m.id.includes('start') ? 'start unknown' : 'estimate unknown'))).toEqual([true, true])
    // Adopted unknown-value designs have no reference-page counterpart. Keep
    // committed regression baselines and attach the unmasked sign-off evidence.
    for (const marker of markers) {
      await page.evaluate(async id => {
        const { ctx, fx } = await import('/build-home/state.js')
        ctx.snapping = true
        const sec = id.includes('start') ? 'hist' : 'plan', it = ctx.L.secs[sec].items.find(it => it.t.id === id)
        fx.scrollVP(Math.max(0, ctx.secs[sec].el.offsetTop + it.y - 100), false); fx.update()
      }, marker.id)
      const target = page.locator(`.bd-card[data-id="${marker.id}"]`)
      await waitForCard(page, target)
      // Scroll the outer document without moving the board or hiding navigation.
      const size = await target.evaluate(el => {
        const box = el.getBoundingClientRect()
        window.scrollBy({ top: Math.round(box.top + box.height / 2 - innerHeight / 2), behavior: 'instant' })
        return { width: box.width, height: box.height }
      })
      await waitForCard(page, target, true)
      const box = await target.boundingBox()
      expect({ width: box.width, height: box.height }).toEqual(size)
      // Full-page capture can relocate fixed navigation after hit-testing. Keep
      // the capture viewport unchanged, and check the measured clip each sample.
      const capture = { screenshot: async opts => {
        await waitForCard(page, target, true)
        const current = await target.boundingBox()
        expect(current, 'card geometry changed during capture').toEqual(box)
        const viewport = page.viewportSize()
        expect(current.x).toBeGreaterThanOrEqual(0); expect(current.y).toBeGreaterThanOrEqual(0)
        expect(current.x + current.width).toBeLessThanOrEqual(viewport.width)
        expect(current.y + current.height).toBeLessThanOrEqual(viewport.height)
        return page.screenshot({ ...opts, fullPage: false, clip: current })
      } }
      const png = await captureStable(capture, { animations: 'disabled', caret: 'hide', scale: 'device' })
      await info.attach(`${marker.id}-${width}-${theme}`, { body: png, contentType: 'image/png' })
      expect(png).toMatchSnapshot(`${marker.id}-${width}-${theme}.png`, { threshold: PARITY_THRESHOLD, maxDiffPixels: 0 })
    }
    await info.attach(`s5-semantics-${width}-${theme}`, { body: Buffer.from(JSON.stringify(markers, null, 2)), contentType: 'application/json' })
  } finally { await context.close() }
})
