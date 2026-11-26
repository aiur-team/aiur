import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })

async function settle(page) { for (let i = 0; i < 64; i++) await page.clock.runFor(16) }

// #5614: the order header casts a shadow over the board unless Live is docked right under it.
test('order header drops its shadow only while Live is docked at the top', async ({ page }) => {
  page.on('pageerror', error => { throw error })
  await page.clock.install({ time: 1791407999000 }); await page.clock.pauseAt(1791408000000)
  await page.goto('/build-fixture/live')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/, { timeout: 10000 })
  await page.evaluate(async () => { window.m = await import('/build-home/state.js'); await import('/build-home/band.js') })
  await settle(page)
  const vp = page.locator('#bd-vp'), lanes = page.locator('#bd-lanes')

  await page.evaluate(() => m.fx.jumpNow(true)); await settle(page)
  await expect(vp).toHaveClass(/live-top/)
  await expect(lanes).toHaveCSS('box-shadow', 'none')

  await page.evaluate(() => m.fx.scrollVP(m.ctx.secs.hist.el.offsetTop + m.ctx.L.secs.hist.h + m.ctx.L.band.h - m.ctx.vp.clientHeight, false))
  await settle(page)
  expect(await page.evaluate(() => Math.abs(m.ctx.bandEl.getBoundingClientRect().bottom - m.ctx.vp.getBoundingClientRect().bottom))).toBeLessThanOrEqual(1)
  await expect(vp).not.toHaveClass(/live-top/)
  await expect(lanes).toHaveCSS('box-shadow', /rgba\(0, 0, 0, 0\.55\)/)

  // A band floating 100px below the header is not docked either.
  await page.evaluate(() => { m.ctx.vp.scrollTop = m.ctx.secs.hist.el.offsetTop + m.ctx.L.secs.hist.h - 146; m.fx.update() })
  await expect(vp).not.toHaveClass(/live-top/)
})
