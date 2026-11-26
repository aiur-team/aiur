import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.describe.configure({ mode: 'serial' })

test.beforeEach(async ({ page }) => {
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  expect((await page.request.post('/conversation-fixture/reset')).ok()).toBe(true)
  await page.goto('/conversations/conv_r65bhwvxdvx53cu3twy7a3ubgf')
})

test('merged PR click loads and highlights the entry at desktop and phone widths', async ({ page }) => {
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 900 })
    await page.getByRole('link', { name: 'PR #42 merged', exact: true }).click()
    await expect(page).toHaveURL(/\?pos=1000$/)
    await expect(page.locator('#entry-1000.conversation-highlight')).toBeInViewport()
    await expect(page.locator('[data-pos]')).toHaveCount(50)
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await page.goBack()
  }
})

test('deep links highlight requests and filter choices survive reload', async ({ page }) => {
  const request = page.locator('#event-2-command_requested')
  await expect(request.getByRole('link', { name: 'Open Command' })).toHaveAttribute('href', '/commands/fixture-command')
  await request.getByRole('link', { name: 'Command requested', exact: true }).click()
  await expect(page.locator('#entry-1100.conversation-highlight')).toBeInViewport()
  await page.reload()
  await expect(page.locator('#entry-1100.conversation-highlight')).toBeInViewport()
  await page.locator('[data-filter-kind=pr_merged]').click()
  await expect(page.locator('#event-1-pr_merged')).toHaveCount(0)
  await page.reload()
  await expect(page.locator('[data-filter-kind=pr_merged]')).toHaveAttribute('aria-pressed', 'false')
  await expect(page.locator('#event-1-pr_merged')).toHaveCount(0)
})

test('Open in conversation from a Command lands on its request', async ({ page }) => {
  await page.goto('/command-answer-control/answerable?native=true')
  const commandUrl = page.url()
  const decisionId = new URL(commandUrl).pathname.split('/').at(-1)
  expect((await page.request.get(`/conversation-fixture/append?command_id=${encodeURIComponent(decisionId)}`)).ok()).toBe(true)
  await page.reload()
  await page.getByRole('link', { name: 'Open in conversation', exact: true }).click()
  await expect(page).toHaveURL(/\?pos=1100$/)
  await expect(page.locator('#entry-1100.conversation-highlight')).toBeInViewport()
})
