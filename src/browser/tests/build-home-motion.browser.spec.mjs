import { test, expect } from '@playwright/test'
import { openProduct, parityContextOptions } from '../support/design-parity.mjs'

const cell = { viewport: { width: 1440, height: 900 }, theme: 'dark', palette: 'gruvbox', dataset: 'live' }

test('product reduced-motion preference disables animated effects', async ({ browser }) => {
  const context = await browser.newContext({
    ...parityContextOptions(cell),
    reducedMotion: 'reduce',
    baseURL: test.info().project.use.baseURL,
    httpCredentials: { username: 'aiur', password: 'test' }
  })
  try {
    const page = await context.newPage()
    await openProduct(page, { ...cell, reducedMotion: 'reduce' }, { query: '?trees=1' })
    await expect(page.locator('#bd-content')).toBeVisible()
    expect(await page.evaluate(() => matchMedia('(prefers-reduced-motion: reduce)').matches)).toBe(true)
    const running = await page.locator('#build-root').evaluate(root =>
      [...root.querySelectorAll('*')].flatMap(el => el.getAnimations()).filter(animation => animation.playState === 'running').length
    )
    expect(running).toBe(0)
  } finally {
    await context.close()
  }
})
