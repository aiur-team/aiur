import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })

test('390 px: Executor entry point and not-attached setup fit without scrolling sideways', async ({ page }) => {
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  expect((await page.request.post('/conversation-fixture/reset?empty=true')).ok()).toBe(true)
  await page.goto('/')
  await page.locator('a[href="/executor"]').first().click()
  await expect(page).toHaveURL(/\/executor$/)
  await expect(page.locator('#executor-frame h1')).toHaveText('Executor')
  await expect(page.locator('#executor-frame [data-state="not_opted_in"]')).toBeVisible()
  await expect(page.locator('#executor-frame')).toContainText('aiur executor-attach --harness claude')
  await expect(page.locator('#executor-frame')).not.toContainText('Idle')
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})

test('Executor event jumps retain the frame and history at phone width', async ({ page }) => {
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  expect((await page.request.post('/conversation-fixture/reset')).ok()).toBe(true)
  await page.goto('/executor')
  await expect(page.locator('#executor-frame [data-state="ended"]')).toBeVisible()
  await page.getByRole('link', { name: 'PR #42 merged', exact: true }).click()
  await expect(page).toHaveURL(/\/executor\?pos=1000$/)
  await expect(page.locator('#entry-1000.conversation-highlight')).toBeInViewport()
  await expect(page.locator('#executor-frame h1')).toHaveText('Executor')
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})
