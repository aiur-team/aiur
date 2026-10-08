import { test, expect } from '@playwright/test'
import { openDesign, openProduct, parityContextOptions, FIXTURE_META } from '../support/design-parity.mjs'

const cell = { viewport: { width: 1440, height: 900 }, theme: 'dark', palette: 'gruvbox', dataset: 'live' }

test('clock probe: product connects and patches with preinstalled clock', async ({ browser }) => {
  const context = await browser.newContext({ ...parityContextOptions(cell), baseURL: test.info().project.use.baseURL })
  try {
    const page = await context.newPage()
    await page.clock.install({ time: FIXTURE_META.now - 1000 })
    await page.clock.pauseAt(FIXTURE_META.now)
    await openProduct(page, cell, { phase: 'shell', productRoute: '/build-orders' })
    await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
    await page.evaluate(() => window.liveSocket.getSocket().channels[0].push('event', { type: 'click', event: 'restore-nav', value: { collapsed: '1' } }))
    await page.clock.runFor(16)
    await expect(page.locator('.dashboard-shell')).toHaveAttribute('data-nav-collapsed', 'true')
  } finally { await context.close() }
})

test('clock probe: design scroll advances one frame', async ({ browser }) => {
  const context = await browser.newContext(parityContextOptions(cell))
  try {
    const page = await context.newPage()
    await openDesign(page, cell, { phase: 'loading' })
    await page.clock.runFor(640)
    await expect(page.locator('#bd-content')).toHaveCount(1)
    const before = await page.locator('#bd-vp').evaluate(el => el.scrollTop)
    const input = await page.locator('#bd-vp').evaluate(el => new Promise(resolve => {
      el.addEventListener('scroll', () => resolve({ from: el.scrollTop, at: performance.now() }), { once: true })
      el.scrollTop -= 20
    }))
    await page.clock.runFor(200)
    await page.evaluate(() => { window.probeFrames = []; requestAnimationFrame(now => window.probeFrames.push(now)) })
    await page.clock.runFor(16)
    const { after, frames } = await page.evaluate(() => ({ after: document.querySelector('#bd-vp').scrollTop, frames: window.probeFrames }))
    expect(frames).toHaveLength(1)
    const k = (frames[0] - input.at - 200) / 420
    expect(k).toBeGreaterThan(0)
    expect(k).toBeLessThan(1)
    expect(Math.abs(after - (input.from + (before - input.from) * (1 - (1 - k) ** 3)))).toBeLessThanOrEqual(1)
  } finally { await context.close() }
})
