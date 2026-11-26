import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles' })

async function settle(page) { for (let i = 0; i < 64; i++) await page.clock.runFor(16) }
async function open(page, width, query) {
  page.on('pageerror', error => { throw error })
  await page.setViewportSize({ width, height: width < 600 ? 844 : 900 })
  await page.clock.install({ time: 1791407999000 }); await page.clock.pauseAt(1791408000000)
  await page.goto('/build-fixture/live' + query)
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/, { timeout: 10000 })
  await page.evaluate(async () => { window.m = await import('/build-home/state.js') })
  await settle(page)
}
const TIERS = ['full', 'line', 'mini', 'bar']
const measure = (el, tiers) => { const r = el.getBoundingClientRect(); return { w: Math.round(r.width), h: Math.round(r.height), tier: tiers.filter(c => el.classList.contains(c)) } }

// #7687: LIVE cards follow the zoom and layout controls, so they size like a planned card.
for (const width of [390, 1440]) for (const span of [1, 30]) {
  test(`LIVE card matches a planned card at ${width}px, zoom span ${span}`, async ({ page }) => {
    await open(page, width, span > 1 ? '?span=' + span : '')
    const live = await page.locator('#bd-now .bd-card').first().evaluate(measure, TIERS)
    await page.evaluate(() => { m.ctx.vp.scrollTop = m.ctx.secs.plan.el.offsetTop; m.fx.update() }); await settle(page)
    const plan = await page.evaluate(([tiers]) => {
      let el = null; m.ctx.R.forEach(e => { if (!el && e._it?.sec === 'plan') el = e })
      const r = el?.getBoundingClientRect()
      return el ? { w: Math.round(r.width), h: Math.round(r.height), tier: tiers.filter(c => el.classList.contains(c)) } : null
    }, [TIERS])
    expect(plan).not.toBeNull()
    expect(live).toEqual(plan)
  })
}
test('guard: smallest size at 390px fits at least 4 LIVE tickets on screen', async ({ page }) => {
  await open(page, 390, '?span=30')
  const fits = await page.locator('#bd-now .bd-card').evaluateAll(els => els.filter(el => {
    const r = el.getBoundingClientRect()
    return r.top >= 0 && r.bottom <= innerHeight && r.left >= 0 && r.right <= innerWidth
  }).length)
  expect(fits).toBeGreaterThanOrEqual(4)
})
