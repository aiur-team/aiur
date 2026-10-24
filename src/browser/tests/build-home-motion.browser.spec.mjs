import { test, expect } from '@playwright/test'
import { openProduct, parityContextOptions } from '../support/design-parity.mjs'

const cell = { viewport: { width: 1440, height: 900 }, theme: 'dark', palette: 'gruvbox', dataset: 'live' }

test('reduced-motion preference disables a running card glow animation', async ({ browser }) => {
  const inspect = async reducedMotion => {
    const options = { ...parityContextOptions(cell), reducedMotion, baseURL: test.info().project.use.baseURL,
      httpCredentials: { username: 'aiur', password: 'test' } }
    const context = await browser.newContext(options)
    try {
      const page = await context.newPage()
      await openProduct(page, { ...cell, reducedMotion })
      await expect(page.locator('#bd-content')).toBeVisible()
      return await page.evaluate(() => {
        const card = document.createElement('div'), glow = document.createElement('i')
        card.className = 'ag-active'; glow.className = 'bd-glow'; card.append(glow)
        document.querySelector('#bd-content').append(card)
        const style = getComputedStyle(glow)
        return { reduce: matchMedia('(prefers-reduced-motion: reduce)').matches,
          name: style.animationName, duration: style.animationDuration,
          running: glow.getAnimations().some(animation => animation.playState === 'running') }
      })
    } finally { await context.close() }
  }
  const normal = await inspect('no-preference'), reduced = await inspect('reduce')
  expect(normal).toEqual({ reduce: false, name: 'bdRot', duration: '9s', running: true })
  expect(reduced).toMatchObject({ reduce: true, name: 'none', running: false })
})
