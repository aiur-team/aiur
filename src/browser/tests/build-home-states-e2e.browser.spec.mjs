import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles' })
const open = async (page, name) => {
  await page.goto('/build-fixture/' + name)
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-mounted', '')
}
const scroll = (page, sec) => page.evaluate(async sec => {
  const { ctx, fx } = await import('/build-home/state.js')
  ctx.vp.scrollTop = ctx.secs[sec].el.offsetTop; fx.update()
}, sec)
test('degraded fixture renders aged failure markers and survives a LiveView patch', async ({ page }) => {
  await open(page, 'degraded'); await expect(page.locator('#bd-content')).toHaveCount(1)
  await scroll(page, 'hist')
  await expect(page.locator('#bd-sec-hist .bd-mk.empty')).toContainText('History unavailable')
  await expect(page.locator('#bd-sec-hist .bd-mk.empty')).toContainText('read 12 min ago (14:08)')
  await scroll(page, 'plan')
  await expect(page.locator('#bd-sec-plan .bd-mk.empty')).toHaveText('Build queue disabledbuild queue is off in .aiur/config.')
  await expect(page.locator('#bd-sec-nq .bd-sech')).toContainText('stale, read 3 h ago (11:20)')
  const status = 'history:unavailable index:stale queue:disabled'
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-states', status)
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'); await ctx.push('build:url', { view: 'graph', span: 2 })
  })
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-states', status)
})
test('age tick relayouts marker text through the live renderer', async ({ page }) => {
  await page.clock.install(); await open(page, 'degraded')
  await expect(page.locator('#bd-content')).toHaveCount(1); await scroll(page, 'hist')
  await expect(page.locator('#bd-sec-hist .bd-mk.empty')).toContainText('read 12 min ago')
  await page.locator('#bd-sec-hist .bd-mk.empty').evaluate(el => { window.originalMarker = el })
  await page.clock.runFor(65000)
  await expect(page.locator('#bd-sec-hist .bd-mk.empty')).toContainText('read 13 min ago')
  expect(await page.locator('#bd-sec-hist .bd-mk.empty').evaluate(el => el === window.originalMarker)).toBe(true)
})
test('sources-only diff keeps rows and changes freshness without moving the anchor', async ({ page }) => {
  await open(page, 'live'); await expect(page.locator('#bd-content')).toHaveCount(1); await scroll(page, 'plan')
  const before = await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'); window.oldCard = ctx.secs.plan.layer.querySelector('.bd-card')
    return oldCard.getBoundingClientRect().top
  })
  expect((await page.request.get('/build-control/diff?name=queue-unavailable')).ok()).toBe(true)
  await expect(page.locator('#bd-sec-plan .bd-sech')).toContainText('unavailable, showing the read')
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-states', 'queue:unavailable')
  const after = await page.evaluate(() => ({ same: oldCard.isConnected, top: oldCard.getBoundingClientRect().top }))
  expect(after.same).toBe(true); expect(after.top).toBeCloseTo(before, 0)
  expect((await page.request.get('/build-control/diff?name=sources-ok')).ok()).toBe(true)
  await expect(page.locator('#bd-sec-plan .bd-sech')).not.toContainText('unavailable')
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-states', '')
})
test('disconnect and reconnect preserve the cached board without skeletons', async ({ page }) => {
  await open(page, 'live'); await expect(page.locator('#bd-content')).toHaveCount(1)
  await page.evaluate(() => { window.cachedBoard = document.querySelector('#bd-content'); window.liveSocket.disconnect() })
  await expect(page.locator('#build-root')).toHaveClass(/stale/)
  await expect(page.locator('#bd-offline')).toContainText('Daemon unreachable')
  expect(await page.evaluate(() => cachedBoard === document.querySelector('#bd-content'))).toBe(true)
  await expect(page.locator('.bd-skel')).toHaveCount(0)
  await page.locator('#bd-retry').click()
  await expect(page.locator('#build-root')).not.toHaveClass(/stale/)
  await expect(page.locator('.bd-offline')).toHaveCount(0)
})
test('initial unavailable response stops the loading spinner', async ({ page }) => {
  await open(page, 'unavailable')
  await expect(page.locator('.bd-loading')).toHaveText('Build timeline unavailable · source unavailable')
  await expect(page.locator('.bd-spin')).toHaveCount(0)
  expect(await page.locator('.bd-skel i').evaluateAll(els => els.length === 16 && els.every(el => getComputedStyle(el).animationName === 'none'))).toBe(true)
})

test('snapshot history window reaches the layout instead of claiming no history', async ({ page }) => {
  await open(page, 'live'); await expect(page.locator('#bd-content')).toHaveCount(1)
  await page.evaluate(async () => {
    const { ctx, S, fx } = await import('/build-home/state.js'), { receive } = await import('/build-home/hook.js')
    S.ready = false
    receive({ ...ctx.snap, generation: ctx.snap.generation + 1, sections: { ...ctx.snap.sections, hist: [] },
      history: { ...ctx.snap.history, more: true, total: 10 } })
    ctx.vp.scrollTop = 0; fx.update()
  })
  await expect(page.locator('#bd-sec-hist .bd-mk.empty')).toHaveText('No history in the loaded daysScroll up to load earlier days.')
})
