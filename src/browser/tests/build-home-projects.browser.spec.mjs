import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

const summary = (id, running, max) => ({
  gateway_id: id, observed_at: '2026-11-07T00:00:00Z', age_ms: 0, connectivity: 'online',
  capacity: { running, max }, projects: [{ repo: `${id.toLowerCase()}/repo`, running }]
})
// Credentialed fetches need the exact origin echoed, as a listed server.dashboard_origins entry does.
const cors = route => ({ 'access-control-allow-origin': route.request().headers().origin, 'access-control-allow-credentials': 'true' })
const json = (route, status, body) => route.fulfill({ status, contentType: 'application/json', headers: cors(route), body: JSON.stringify(body) })

async function open(page, { nook, lab = route => json(route, 200, summary('LAB', 2, 4)), seed } = {}) {
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.route('https://nook.test/api/v1/gateway/summary', nook ?? (route => json(route, 200, summary('NOOK', 1, 2))))
  await page.route('https://lab.test/api/v1/gateway/summary', lab)
  if (seed) await page.addInitScript(seed)
  await page.goto('/projects')
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
}

const card = (page, name) => page.locator(`[data-gateway-card="${name}"]`)
const fiveMinutesAgo = `localStorage.setItem('aiur.projectsHome.v1.NOOK', JSON.stringify({observed_at_ms: Date.now() - 300000, summary: ${JSON.stringify(summary('NOOK', 1, 2))}}))`

test('a peer that is down reads unreachable with its last-seen age, and the page does not wait for it', async ({ page }) => {
  await open(page, { nook: route => route.abort(), seed: fiveMinutesAgo })
  await expect(card(page, 'nook').locator('[data-conn-text]')).toHaveText('unreachable · last seen 5m ago')
  // The hook aborts the peer at 3 s, but the document itself must load without waiting for it.
  expect(await page.evaluate(() => performance.getEntriesByType('navigation')[0].loadEventEnd)).toBeLessThan(3000)
  await expect(card(page, 'lab').locator('[data-conn-text]')).toContainText('online')
  await expect(card(page, 'nook')).not.toContainText(/\b0 agents\b|idle/)
  await expect(page.locator('[data-totals]')).toHaveText('Running 2 of 4+ · 2 gateways unknown') // Lab 2 of 4; Nook down and the harness gateway's own count unreadable
})

test('a signed-out peer offers sign in, and a different gateway id is rejected', async ({ page }) => {
  await open(page, { nook: route => route.fulfill({ status: 401, headers: cors(route), body: '' }), lab: route => json(route, 200, summary('OTHER', 9, 9)) })
  await expect(card(page, 'nook').locator('[data-conn-text]')).toHaveText('error: signed out')
  await expect(card(page, 'nook').getByRole('link', { name: 'Sign in' })).toHaveAttribute('href', /return_to=/)
  await expect(card(page, 'lab').locator('[data-conn-text]')).toHaveText('error: gateway id mismatch')
  await expect(card(page, 'lab')).not.toContainText('other/repo')
})

test('peer cards survive a LiveView patch, Build stays reachable, and a phone has no overflow', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 800 })
  await open(page)
  await expect(card(page, 'nook').locator('[data-conn-text]')).toContainText('online')
  await page.waitForTimeout(10500)
  await expect(card(page, 'nook').locator('[data-conn-text]')).toContainText('online')
  await assertNoDocumentOverflow(page)
  await page.locator('[data-gateway-card="local"] a[href="/build"]').first().click()
  await expect(page).toHaveURL(/\/build$/)
})
