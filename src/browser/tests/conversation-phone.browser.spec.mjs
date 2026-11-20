import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

test('390×844: full conversation event navigation and jumps fit', async ({ page }) => {
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  // Existing layout guard: the seeded Executor history has navigable events.
  expect((await page.request.post('/conversation-fixture/reset')).ok()).toBe(true)
  await page.goto('/conversations/conv_r65bhwvxdvx53cu3twy7a3ubgf')
  const jump = page.getByRole('link', { name: 'PR #42 merged', exact: true })
  await jump.scrollIntoViewIfNeeded()
  await expect(jump).toBeInViewport()
  await jump.click()
  await expect(page.locator('#entry-1000.conversation-highlight')).toBeInViewport()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
  expect(await page.locator('#conversation-scroll').evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true)
})
