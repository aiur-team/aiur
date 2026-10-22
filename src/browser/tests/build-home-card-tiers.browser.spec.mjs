import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles' })

test.beforeEach(async ({ page }, testInfo) => {
  const renderAsset = testInfo.project.metadata.renderAsset
  if (renderAsset) await page.route('**/build-home/render.js', route => route.fulfill({ path: renderAsset, contentType: 'text/javascript' }))
})

for (const width of [1440, 390]) {
  test(`section cards follow layout tiers after URL span changes and history paging at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 })
    await page.goto('/build-fixture/live')
    await expect(page.locator('#bd-content')).toHaveCount(1)
    const details = new Set()
    for (const span of [1, 7, 30, 7]) {
      // Exercise the server URL event used by back/forward navigation, including
      // the subsequent real load-earlier replies; never force a local relayout.
      await page.evaluate(span => window.liveSocket.main.pushLinkPatch(new Event('click'), `/build?span=${span}`, null), span)
      await expect.poll(() => page.evaluate(async span => {
        const { S, ctx } = await import('/build-home/state.js')
        const { H } = await import('/build-home/history.js')
        const { histDays } = await import('/build-home/layout.js')
        return S.span === span && H.state === 'idle' && (!H.more || histDays(ctx.D.hist).length >= span)
      }, span)).toBe(true)
      const result = await page.evaluate(async () => {
        const { ctx } = await import('/build-home/state.js')
        const cards = [...document.querySelectorAll('.bd-sec .bd-card')]
        return {
          detail: ctx.L.det,
          count: cards.length,
          mismatches: cards.filter(card => !card.classList.contains(ctx.L.det)).map(card => ({ id: card.dataset.id, classes: card.className })),
        }
      })
      expect(result.count).toBeGreaterThan(0)
      expect(result.mismatches, `span ${span}, layout tier ${result.detail}`).toEqual([])
      details.add(result.detail)
    }
    expect(details.size).toBeGreaterThan(1)
  })
}

// The live shape: 30 epic lanes in the board order, with history rows spread over `used` of them.
// Floors follow the design: a lane narrower than 62 px flows instead.
for (const used of [30, 12]) test(`history over ${used} of 30 lanes keeps cards readable at 1440px (#4769)`, async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await page.goto('/build-fixture/live')
  await expect(page.locator('#bd-sec-hist .bd-card').first()).toBeAttached()
  const cols = await page.evaluate(async used => {
    const { ctx, fx } = await import('/build-home/state.js')
    const D = ctx.D, base = D.epics[D.order[0]]
    for (let i = 0; i < 30; i++) { D.epics['lane' + i] = { ...base, label: 'Lane ' + i }; D.order.splice(-1, 0, 'lane' + i) }
    D.hist.forEach((t, i) => { t.epic = 'lane' + (i % used) })
    fx.relayout()
    ctx.vp.scrollTop = ctx.secs.hist.el.offsetTop + ctx.L.secs.hist.h - ctx.vp.clientHeight
    fx.update(true)
    return ctx.cols
  }, used)
  expect(cols.filter(k => /^lane\d+$/.test(k) && +k.slice(4) >= used), 'unused lanes get no column').toEqual([])
  await page.waitForTimeout(400)
  const cards = await page.evaluate(() => {
    const vp = document.querySelector('#bd-vp').getBoundingClientRect()
    return [...document.querySelectorAll('#bd-sec-hist .bd-card')].map(el => ({ el, r: el.getBoundingClientRect() }))
      .filter(({ r }) => r.bottom > vp.top && r.top < vp.bottom)
      .map(({ el, r }) => ({ id: el.dataset.id, width: Math.round(r.width), tier: ['full', 'line', 'mini', 'bar'].find(t => el.classList.contains(t)), title: Math.round(el.querySelector('.bd-title')?.getBoundingClientRect().width ?? 0) }))
  })
  expect(cards.length).toBeGreaterThan(0)
  for (const card of cards) {
    expect(card.width, JSON.stringify(card)).toBeGreaterThanOrEqual(60)
    expect(['full', 'line'], JSON.stringify(card)).toContain(card.tier)
    expect(card.title, JSON.stringify(card)).toBeGreaterThanOrEqual(40)
  }
})
