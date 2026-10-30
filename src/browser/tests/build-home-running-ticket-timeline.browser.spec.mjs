import { test, expect } from '@playwright/test'
import { mountConversation, scenario, states } from './support/build-conversation.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 } })
test.beforeEach(async ({ page }, info) => mountConversation(page, info))

test('running ticket modal switches between live conversation and timeline with keyboard tabs', async ({ page }) => {
  await scenario(page, 'kinds')
  const tabs = page.getByRole('tablist', { name: 'Ticket detail' })
  await expect(tabs.getByRole('tab', { name: 'Conversation' })).toHaveAttribute('aria-selected', 'true')
  await expect(page.locator('#cv-log [data-k]')).toHaveCount(states.kinds.entries.length)
  await tabs.getByRole('tab', { name: 'Conversation' }).focus()
  await page.keyboard.press('ArrowRight')
  await expect(tabs.getByRole('tab', { name: 'Timeline' })).toBeFocused()
  await expect(page.locator('#cv-panel-timeline')).toBeVisible()
  const id = await page.evaluate(async () => (await import('/build-home/modal/frame.js')).MS.t.id)
  await page.evaluate(id => window.dispatchEvent(new CustomEvent('phx:build-ticket-doc', { detail: {
    v: 1, kind: 'doc', id, timeline: { status: 'ok', items: [{ id: 1, at: Date.now(), actor: 'Aiur agent', kind: 'note', label: 'Agent is working' }], phases: [], progress: [] },
  } })), id)
  await expect(page.locator('#cv-panel-timeline')).toContainText('Agent is working')
  await page.setViewportSize({ width: 390, height: 844 })
  await expect(page.locator('#cv-panel-timeline')).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
  await tabs.getByRole('tab', { name: 'Conversation' }).click()
  await expect(page.locator('#cv-log [data-k]')).toHaveCount(states.kinds.entries.length)
  await expect(page.locator('#cv-map')).toBeVisible()
  await expect(page.locator('#cv-in')).toBeAttached()
})
