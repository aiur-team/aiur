import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { createHash } from 'node:crypto'

// Executor conversation id is SHA-256 base32("executor"), first 26 characters.
test.describe.configure({ mode: 'serial' })

const alphabet = 'abcdefghijklmnopqrstuvwxyz234567'
let bits = ''
for (const byte of createHash('sha256').update('executor').digest()) bits += byte.toString(2).padStart(8, '0')
const id = 'conv_' + bits.match(/.{5}/g).slice(0, 26).map(chunk => alphabet[parseInt(chunk, 2)]).join('')

test.beforeEach(async ({ page }) => {
  await openFixture(page)
  const response = await page.request.post('/conversation-fixture/reset')
  expect(response.ok()).toBe(true)
})

async function open (page) {
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.goto(`/conversations/${id}`)
  await expect(page.locator('#entry-2000')).toBeInViewport()
}

test('tail, older anchor, start and bounded DOM use the durable journal at desktop and phone widths', async ({ page }) => {
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 900 })
    await open(page)
    await expect(page.locator('[data-pos]')).toHaveCount(50)
    await expect(page.locator('[data-pos]').first()).toHaveAttribute('data-pos', '1951')
    const scroll = page.locator('#conversation-scroll')
    await scroll.evaluate(el => { el.scrollTop = 100 })
    const anchor = page.locator('#entry-1952')
    const before = await anchor.evaluate(el => el.getBoundingClientRect().top)
    await page.getByRole('button', { name: 'Load older', exact: true }).click()
    await expect(page.locator('#entry-1901')).toBeAttached()
    await expect.poll(async () => Math.abs(await anchor.evaluate(el => el.getBoundingClientRect().top) - before)).toBeLessThan(2)
    for (let n = 0; n < 10; n++) {
      await page.getByRole('button', { name: 'Load older', exact: true }).click()
      await expect(page.locator('[data-pos]').first()).toHaveAttribute('data-pos', String(1851 - n * 50))
    }
    await expect(page.locator('[data-pos]')).toHaveCount(500)
    await page.getByRole('button', { name: 'Jump to start' }).click()
    await expect(page.locator('[data-pos]').first()).toHaveAttribute('data-pos', '1')
    await expect(page.locator('#entry-1')).toBeInViewport()
    await scroll.evaluate(el => { el.scrollTop = 200 })
    await page.getByRole('button', { name: 'Jump to start' }).click()
    await expect.poll(() => scroll.evaluate(el => el.scrollTop)).toBe(0)
    await page.getByRole('button', { name: 'Load newer', exact: true }).click()
    await expect(page.locator('#entry-100')).toBeAttached()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await page.getByRole('button', { name: 'Latest entries' }).click()
    await expect(page.locator('#entry-2000')).toBeInViewport()
  }
})

test('live entries follow at bottom and preserve the scrolled-up viewport with a counter', async ({ page }) => {
  await open(page)
  const scroll = page.locator('#conversation-scroll')
  await page.request.get('/conversation-fixture/append')
  await expect(page.locator('#entry-2003')).toBeInViewport()
  await expect(page.locator('.conversation-divider', { hasText: 'Session 2' })).toBeAttached()
  await scroll.evaluate(el => { el.scrollTop = 100; el.dispatchEvent(new Event('scroll')) })
  // A subsequent LiveView event roundtrip follows the hook's at_bottom report.
  await page.getByRole('button', { name: 'Load older', exact: true }).click()
  await expect(page.locator('#entry-1950')).toBeAttached()
  const top = await scroll.evaluate(el => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve(el.scrollTop)))))
  await page.request.get('/conversation-fixture/append')
  await expect(page.locator('#conversation-new')).toHaveText('3 new entries below')
  await expect.poll(() => scroll.evaluate(el => el.scrollTop)).toBe(top)
  await page.locator('#conversation-new').click()
  await expect(page.locator('#entry-2006')).toBeInViewport()
})
