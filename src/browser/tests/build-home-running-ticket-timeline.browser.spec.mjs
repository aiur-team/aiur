import { test, expect } from '@playwright/test'
import { mountConversation, scenario, states } from './support/build-conversation.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 } })
test.beforeEach(async ({ page }, info) => mountConversation(page, info))

test('running ticket modal switches between live conversation and timeline with keyboard tabs', async ({ page }) => {
  const entries = Array.from({ length: 201 }, (_, index) => ({
    ...states.kinds.entries[index % states.kinds.entries.length],
    id: 'older:' + index,
    at: Date.now() - (201 - index) * 1000,
  }))
  await page.evaluate(async () => { (await import('/build-home/state.js')).ctx.snap.writable = true })
  await scenario(page, 'kinds', { entries, reply: { composer: 'ready' } })
  const tabs = page.getByRole('tablist', { name: 'Ticket detail' })
  await expect(tabs.getByRole('tab', { name: 'Conversation' })).toHaveAttribute('aria-selected', 'true')
  await expect(page.locator('#cv-log [data-k]')).toHaveCount(100)
  expect(await page.evaluate(() => window.conversationCalls.filter(c => c.event === 'ticket-doc'))).toEqual([])
  await page.locator('#cv-log').evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')) })
  await expect(page.locator('#cv-log [data-k]')).toHaveCount(200)
  await page.locator('#cv-log').evaluate(el => { el.scrollTop = Math.floor(el.scrollHeight / 2); el.dispatchEvent(new Event('scroll')) })
  await page.evaluate(async () => {
    const { MS } = await import('/build-home/modal/frame.js')
    const { receiveConversation } = await import('/build-home/modal/conversation.js')
    receiveConversation({ v: 1, kind: 'conversation-append', id: MS.t.id, entries: [{ id: 'live:new', k: 'say', text: 'New live message', at: Date.now() }] })
  })
  await expect(page.locator('#cv-log [data-k]')).toHaveCount(201)
  const scrollBefore = await page.locator('#cv-log').evaluate(el => el.scrollTop)
  await tabs.getByRole('tab', { name: 'Conversation' }).focus()
  await page.keyboard.press('ArrowRight')
  await expect(tabs.getByRole('tab', { name: 'Timeline' })).toBeFocused()
  await expect(page.locator('#cv-panel-timeline')).toBeVisible()
  await expect(page.locator('#cv-panel-conversation')).toBeHidden()
  await expect.poll(() => page.evaluate(() => window.conversationCalls.filter(c => c.event === 'ticket-doc').length)).toBe(1)
  const id = await page.evaluate(async () => (await import('/build-home/modal/frame.js')).MS.t.id)
  await page.evaluate(id => window.dispatchEvent(new CustomEvent('phx:build-ticket-doc', { detail: {
    v: 1, kind: 'doc', id, timeline: { status: 'ok', items: [{ id: 1, at: Date.now(), actor: 'Aiur agent', kind: 'note', label: 'Agent is working' }], phases: [], progress: [] },
  } })), id)
  await expect(page.locator('#cv-panel-timeline')).toContainText('Agent is working')
  await page.setViewportSize({ width: 390, height: 844 })
  await expect(page.locator('#cv-panel-timeline')).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
  await page.setViewportSize({ width: 1440, height: 900 })
  await expect.poll(() => page.evaluate(async () => !!(await import('/build-home/state.js')).ctx.D?.now.length)).toBe(true)
  await tabs.getByRole('tab', { name: 'Conversation' }).click()
  await expect(page.locator('#cv-panel-conversation')).toBeVisible()
  await expect(page.locator('#cv-log [data-k]')).toHaveCount(201)
  expect(await page.locator('#cv-log').evaluate(el => el.scrollTop)).toBeCloseTo(scrollBefore, -1)
  await expect(page.locator('#cv-map')).toBeVisible()
  await expect(page.locator('#cv-in')).toBeAttached()
})
