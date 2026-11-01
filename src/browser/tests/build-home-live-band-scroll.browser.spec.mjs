import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles' })

// #7446: the live band scrolls with the content; the reader can stop with it part-way up the screen.
for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) test(`live band stays where the reader stops at ${viewport.width}`, async ({ page }) => {
  page.on('pageerror', error => { throw error })
  await page.setViewportSize(viewport)
  await page.clock.install({ time: 1791407999000 }); await page.clock.pauseAt(1791408000000)
  await page.goto('/build-fixture/live')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/, { timeout: 10000 })
  await page.evaluate(async () => { window.m = await import('/build-home/state.js'); await import('/build-home/band.js') })
  await page.clock.runFor(2000)
  const bandTop = () => page.evaluate(() => Math.round(m.ctx.bandEl.getBoundingClientRect().top - m.ctx.vp.getBoundingClientRect().top))

  // Native scroll that leaves the band's top a third of the way down the viewport.
  await page.evaluate(() => {
    const vp = m.ctx.vp
    vp.scrollTop = m.ctx.secs.hist.el.offsetTop + m.ctx.L.secs.hist.h - Math.round(vp.clientHeight / 3)
    vp.dispatchEvent(new Event('scroll')) // Run the real handler now; the native event may land a frame later.
  })
  expect(await page.evaluate(() => m.ctx.isScrolling())).toBe(true)
  const stopped = await page.evaluate(() => m.ctx.vp.scrollTop), top = await bandTop()
  expect(top).toBeGreaterThan(46 + 36); expect(top).toBeLessThan(viewport.height / 2)

  await page.clock.runFor(2000)
  expect(await page.evaluate(() => [m.ctx.vp.scrollTop, m.ctx.isScrolling(), m.ctx.snapping])).toEqual([stopped, false, false])
  expect(await bandTop()).toBe(top)

  // A live pass keeps the reader's anchor rather than moving the band.
  await page.evaluate(() => m.fx.requestLivePass()); await page.clock.runFor(500)
  expect(await bandTop()).toBe(top)

  // The explicit jump still docks Live under the header.
  await page.evaluate(() => m.fx.jumpNow(false)); await page.clock.runFor(1000)
  expect(await bandTop()).toBe(46)
  expect(await page.evaluate(() => m.ctx.snapping)).toBe(false)
})
