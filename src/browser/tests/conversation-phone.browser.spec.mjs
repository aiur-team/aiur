import { expect, test } from '@playwright/test'
import { openUnits } from './support/units-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

test('390×844: units and drawer links reach the full view; event navigation and jumps fit', async ({ page }) => {
  await openUnits(page)
  const row = page.locator('#units-rows tr').first()
  const full = row.getByRole('link', { name: 'Full conversation for its-everdred/aiur #1110', exact: true })
  const href = await full.getAttribute('href')
  expect(href).toMatch(/^\/conversations\/conv_[a-z2-7]{26}$/)
  await row.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()
  const drawer = page.getByRole('dialog', { name: 'Responsive Units interface' })
  await expect(drawer.getByRole('link', { name: 'Full conversation', exact: true })).toHaveAttribute('href', href)
  await page.context().setHTTPCredentials(dashboardCredentials)
  await drawer.getByRole('link', { name: 'Full conversation', exact: true }).click()
  await expect(page).toHaveURL(new RegExp(`${href}$`))
  await expect(page.getByText('No messages yet', { exact: true })).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
  await openUnits(page)
  await page.getByRole('link', { name: 'Full conversation for its-everdred/aiur #1110', exact: true }).click()
  await expect(page).toHaveURL(new RegExp(`${href}$`))

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
