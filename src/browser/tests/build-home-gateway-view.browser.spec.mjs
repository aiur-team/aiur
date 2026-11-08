import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

const summary = (id, workload, running, max) => ({
  gateway_id: id, observed_at: '2026-11-07T00:00:00Z', age_ms: 0, connectivity: 'online', workload,
  capacity: { running, max }, projects: [{ repo: `${id.toLowerCase()}/repo`, running }]
})
// Credentialed fetches need the exact origin echoed, as a listed server.dashboard_origins entry does.
const cors = route => ({
  'access-control-allow-origin': route.request().headers().origin, 'access-control-allow-credentials': 'true',
  'access-control-allow-methods': 'GET, POST', 'access-control-allow-headers': 'content-type, x-aiur-request'
})
const json = (route, status, body) => route.fulfill({ status, contentType: 'application/json', headers: cors(route), body: JSON.stringify(body) })
const reply = (route, status, body) => route.request().method() === 'OPTIONS' ? route.fulfill({ status: 204, headers: cors(route) }) : json(route, status, body)

async function open(page, { nook = route => json(route, 200, summary('NOOK', 'idle', 0, 2)), lab, url = '/gateways', seed } = {}) {
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.route('https://nook.test/api/v1/gateway/summary', nook)
  await page.route('https://lab.test/api/v1/gateway/summary', lab ?? (route => json(route, 200, summary('LAB', 'active', 1, 4))))
  if (seed) await page.addInitScript(seed)
  await page.goto(url)
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
}

const card = (page, name) => page.locator(`[data-gateway-card="${name}"]`)

test('an online idle gateway shows connectivity and workload as two separate fields', async ({ page }) => {
  await open(page)
  const nook = card(page, 'nook')
  await expect(nook.locator('[data-field="connectivity"]')).toHaveText('online')
  await expect(nook.locator('[data-field="workload"]')).toHaveText('idle')
  await expect(nook.locator('[data-field="capacity"]')).toHaveText('0 of 2 agents')
  await expect(card(page, 'local').locator('[data-field="connectivity"]')).toHaveText('online')
})

test('an unreachable gateway is never shown as idle', async ({ page }) => {
  const cached = JSON.stringify({ observed_at_ms: Date.now() - 300000, summary: summary('NOOK', 'active', 1, 2) })
  await open(page, { nook: route => route.abort(), seed: `localStorage.setItem('aiur.projectsHome.v1.NOOK', ${JSON.stringify(cached)})` })
  const nook = card(page, 'nook')
  await expect(nook.locator('[data-field="connectivity"]')).toHaveText('unreachable · last seen 5m ago')
  await expect(nook.locator('[data-field="workload"]')).toHaveText('last known active (5m ago)')
  await expect(nook).not.toContainText('idle')
  expect(await page.evaluate(() => performance.getEntriesByType('navigation')[0].loadEventEnd)).toBeLessThan(3000)
})

test('pause all with Nook offline reports Nook will pause on reconnect', async ({ page }) => {
  let nookPause = 0
  await open(page, { nook: route => route.abort() })
  await page.route('https://lab.test/api/v1/gateway/pause', route => reply(route, 200, { ok: true, globally_paused: true }))
  await page.route('https://nook.test/api/v1/gateway/pause', route => { nookPause += 1; return route.abort() })
  await page.route('**/api/v1/gateway/pause', route => route.request().url().startsWith('https://') ? route.fallback() : route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true,"globally_paused":true}' }))
  await page.route('**/api/v1/fleet/pause', route => route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true,"intent_written":true,"globally_paused":true}' }))
  page.on('dialog', dialog => dialog.accept())
  await page.locator('[data-action="pause-all"]').click()
  await expect(page.locator('[data-report] h3')).toHaveText('Pause all — 3 gateways')
  await expect(page.locator('[data-report-line="lab"]')).toContainText('paused ✓')
  await expect(page.locator('[data-report-line="nook"]')).toContainText('will pause on reconnect')
  expect(nookPause).toBe(1)
})

test('an unknown gateway name says so', async ({ page }) => {
  await open(page, { url: '/gateways?gateway=nope' })
  await expect(page.getByText('unknown gateway')).toBeVisible()
  await expect(page.getByRole('link', { name: /All gateways/ })).toHaveAttribute('href', '/gateways')
})
