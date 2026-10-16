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
