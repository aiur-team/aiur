// MP-E8-C12-T04 W1, run by hand (npm run test:home-phone:webkit; not in npm test or CI):
// the phone structure checks in Playwright WebKit, to catch engine differences in sticky
// positioning, nested scrollers and container queries before a device does. Linux WebKit is
// not iOS WKWebView; the device check stays the real proof.
import { existsSync } from 'node:fs'
import { expect, test, webkit } from '@playwright/test'
import { PHONE_CELLS, geom, openPhoneProduct, phoneCell } from '../support/build-home-phone.mjs'

test.setTimeout(180_000)
test.skip(!existsSync(webkit.executablePath()), 'WebKit not installed: run npx playwright install webkit')

let browser
test.beforeAll(async () => { browser = await webkit.launch() })
test.afterAll(async () => { await browser?.close() })

test('webkit phone guard: page width, gutter and nav clearance at p390', async () => {
  const { page, close } = await openPhoneProduct(browser, phoneCell('p390'))
  try {
    const g = await geom(page)
    expect(g.docScrollW).toBeLessThanOrEqual(PHONE_CELLS.p390.width)
    expect(g.histLefts[0]).toBe(46)
    await page.evaluate(() => scrollTo(0, document.documentElement.scrollHeight))
    await expect.poll(() => page.evaluate(() =>
      document.querySelector('#bd-status').getBoundingClientRect().bottom <= document.querySelector('.sidenav').getBoundingClientRect().top)).toBe(true)
  } finally { await close() }
})

test('webkit phone guard: tap opens the modal at phone width', async () => {
  const { page, close } = await openPhoneProduct(browser, phoneCell('p390'))
  try {
    await page.locator('#bd-now .bd-layer > .bd-card').first().tap()
    await expect(page.locator('#tk-backdrop')).toHaveClass(/\bshow\b/)
    const modal = await page.evaluate(() => ({
      width: document.querySelector('#tk-modal').getBoundingClientRect().width,
      agentNameHidden: [...document.querySelectorAll('.bm-agent > span:not(.sr-only)')].every(el => getComputedStyle(el).display === 'none'),
    }))
    expect(modal.width).toBeCloseTo(390 - 2 * 19.2, 0)
    expect(modal.agentNameHidden).toBe(true)
  } finally { await close() }
})
