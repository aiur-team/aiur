import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { openFixture } from './support/browser-helpers.mjs'
const fixture = name => JSON.parse(readFileSync(new URL(`../../test/fixtures/build_home/usage/${name}.json`, import.meta.url)))
const NOW = 1791408000000

// #7763: the sidebar copy renders the header cards' projection in compact form.
async function open(page, width, height) {
  await page.setViewportSize({ width, height })
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.clock.install({ time: NOW - 1000 })
  await page.clock.pauseAt(NOW)
  await page.goto('/build-fixture/live')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
  await page.evaluate(async ({ now, block }) => {
    const usage = await import('/build-home/usage.js'), state = await import('/build-home/state.js')
    ;(await import('/build-home/clock.js')).setNow(now)
    state.ctx.snap.usage = block; usage.renderUsage()
  }, { now: NOW, block: fixture('n7') })
}
const values = (page, sel, value) => page.locator(sel).evaluateAll((lines, value) =>
  Object.fromEntries(lines.map(l => [l.dataset.k, value === 'header'
    ? (l.querySelector('.ax-pc').textContent || l.querySelector('.ax-usd')?.textContent || '')
    : l.querySelector('.ax-np').textContent])), value)

test('desktop sidebar shows compact APIS and MODELS with the header values', async ({ page }) => {
  await open(page, 1440, 900)
  const nav = page.locator('#bd-usage-nav')
  await expect(nav).toBeVisible()
  await expect(nav.locator('.ax-nh')).toHaveText(['APIS', 'MODELS'])
  const header = await values(page, '.ax-usage .ax-ln', 'header')
  const side = await values(page, '#bd-usage-nav .ax-nl', 'side')
  expect(Object.keys(header).length).toBeGreaterThan(2)
  expect(Object.values(header).some(v => v.endsWith('% left'))).toBe(true)
  expect(side).toEqual(header)
  // Pinned to the bottom of the rail, below the last nav item.
  const [last, block, rail] = await Promise.all([
    page.locator('#ax-nav .snav').last().boundingBox(), nav.boundingBox(), page.locator('.aiur-shell__rail').boundingBox()])
  expect(block.y).toBeGreaterThanOrEqual(last.y + last.height)
  expect(Math.abs(block.y + block.height - (rail.y + rail.height))).toBeLessThan(12)
  expect(block.width).toBeLessThanOrEqual(190)
})

test('nav items stay fully visible on a short desktop window; the meters scroll', async ({ page }) => {
  await open(page, 1440, 700)
  await expect(page.locator('#bd-usage-nav .ax-nl').first()).toBeAttached()
  const items = await page.locator('#ax-nav .snav').evaluateAll(els => els.map(e => e.getBoundingClientRect().bottom))
  expect(items.length).toBeGreaterThan(0)
  for (const bottom of items) expect(bottom).toBeLessThanOrEqual(700)
  const meters = await page.locator('.aiur-shell__meters').evaluate(m => [m.getBoundingClientRect().bottom, getComputedStyle(m).overflowY])
  expect(meters[0]).toBeLessThanOrEqual(700)
  expect(meters[1]).toBe('auto')
})

// #7774 adds a fixed full-width Executor footer; stand one in until it is on this branch.
for (const height of [900, 700]) test(`meters stay above the Executor footer at 1440x${height}`, async ({ page }) => {
  await open(page, 1440, height)
  await page.evaluate(() => {
    if (document.querySelector('#executor-footer')) return
    const f = document.createElement('div')
    f.id = 'executor-footer'
    f.style.cssText = 'position:fixed;left:0;right:0;bottom:0;height:44px;z-index:55'
    document.body.append(f)
  })
  await expect(page.locator('#bd-usage-nav .ax-nl').first()).toBeAttached()
  const [meters, footer] = await Promise.all([page.locator('.aiur-shell__meters').boundingBox(), page.locator('#executor-footer').boundingBox()])
  expect(meters.y + meters.height).toBeLessThanOrEqual(footer.y)
})

test('phone width does not render the sidebar copy', async ({ page }) => {
  await open(page, 390, 844)
  await expect(page.locator('.ax-usage')).toBeVisible()
  await expect(page.locator('#bd-usage-nav')).toBeHidden()
})
