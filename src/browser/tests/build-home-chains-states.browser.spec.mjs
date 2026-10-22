import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { open, reveal, tree, lock, card } from './support/build-home-chains.mjs'
import { installFitObserver } from './support/build-home-chains-parity.mjs'
import { settleAnimations } from './support/browser-helpers.mjs'

// Product-only states absent from the mock design; initial pixels await DESIGN-E8 S-34 sign-off.
const states = [
  { name: 'cycle', id: '3', productOnly: true },
  { name: 'unloaded', id: '9012', productOnly: true },
  { name: 'unknown', id: '9021', productOnly: true },
]
test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', colorScheme: 'light' })
for (const width of [1440, 390]) for (const state of states) test(`product-only ${state.name} ${width}`, async ({ page }) => {
  test.info().annotations.push({ type: 'pending-sign-off', description: 'DESIGN-E8 S-34: productOnly=' + state.productOnly })
  await page.setViewportSize({ width, height: width === 390 ? 844 : 900 })
  await open(page)
  await page.locator('html').evaluate(el => Object.assign(el.dataset, { theme: 'light', palette: 'gruvbox' }))
  await reveal(page, state.id)
  // This suite freezes presentation; the interaction suite tests mouse/touch lock initiation.
  await page.evaluate(id => st.fx.lockTree(id), state.id)
  await page.locator('[data-lt="tree"]').click()
  await settleAnimations(page, '#bd-tree')
  // The phone shell can scroll the document past its fixed nav at the board end.
  await page.evaluate(() => window.scrollTo(0, 0))
  await expect(tree(page)).toHaveScreenshot(`${state.name}-${width}.png`)
})

test('Fit waits for deferred columns before resolving its positioned lock', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await open(page, { dataset: 'live' })
  await page.locator('[data-span="30"]').click()
  await expect(page.locator('#bd-sec-hist .bd-sech')).toContainText('all 248 from ')
  await page.locator('[data-span="1"]').click()
  await lock(page, '597')
  await installFitObserver(page)
  await page.evaluate(() => {
    const later = st.ctx.life.later.bind(st.ctx.life)
    window.releaseColumns = null
    st.ctx.life.later = (key, delay, callback) => {
      if (key !== 'cols') return later(key, delay, callback)
      window.releaseColumns = () => { st.ctx.life.later = later; callback() }
    }
  })
  await page.locator('[data-lt="fit"]').click()
  await expect.poll(() => page.evaluate(() => typeof window.releaseColumns)).toBe('function')
  await page.evaluate(() => { window.fitResolved = false; window.chainParityFit.then(() => { window.fitResolved = true }) })
  await expect.poll(() => page.evaluate(() => st.ctx.snapping || st.ctx.isScrolling())).toBe(false)
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  const pending = await page.evaluate(() => ({ done: window.fitResolved, actual: st.ctx.cols, expected: st.fx.visibleCols() }))
  expect(pending.actual).not.toEqual(pending.expected)
  expect(pending.done).toBe(false)
  await page.evaluate(async () => { window.releaseColumns(); await window.chainParityFit })
  const final = await page.evaluate(() => {
    const el = [...st.ctx.R.values()].find(el => el.dataset.id === '597')
    const root = el.getBoundingClientRect(), content = st.ctx.content.getBoundingClientRect(), tab = st.ctx.content.querySelector('.bd-lt')
    return { actual: st.ctx.cols, expected: st.fx.visibleCols(), lock: st.ctx.lockId,
      x: parseFloat(tab.style.left), right: root.right - content.left - 1 }
  })
  expect(final.actual).toEqual(final.expected)
  expect(final.lock).toBe('597')
  expect(final.x).toBeCloseTo(final.right, 1)
})

// Fixture positioning must supersede a native animator left by initial band snapping.
test('reveal cancels a pending smooth scroll before positioning a card', async ({ page }) => {
  await open(page)
  await page.evaluate(() => st.fx.scrollVP(0, true))
  await reveal(page, '3')
  await expect.poll(() => page.evaluate(() => st.ctx.snapping || st.ctx.isScrolling())).toBe(false)
  await expect(card(page, '3')).toBeVisible()
})
