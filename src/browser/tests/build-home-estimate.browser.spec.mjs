import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dashboardCredentials } from './support/layout-worker.mjs'
const live = JSON.parse(readFileSync(new URL('../../test/fixtures/build_home/live.json', import.meta.url)))
const total = live.sections.plan.reduce((sum, t) => sum + (t.override ? t.override.hours : t.est), 0)
const count = live.sections.plan.length + live.sections.now.length

test.use({ httpCredentials: dashboardCredentials })
test('L1 capacity diffs repaint the live ETA without navigation', async ({ page }) => {
  await page.goto('/build-fixture/live')
  await expect(page.locator('.bd-now-eta')).toHaveText(`${count} to go · ETA ${Math.max(1, Math.round(total / 4))}h`)
  await expect(page.locator('.bd-now-eta')).toHaveAttribute('title', 'at 4 agents')
  await page.evaluate(() => { window.estimateNavigationMarker = 'same document' })
  expect((await page.request.get('/build-control/diff?name=capacity-eight')).ok()).toBe(true)
  await expect(page.locator('.bd-now-eta')).toHaveText(`${count} to go · ETA ${Math.max(1, Math.round(total / 8))}h`)
  await expect(page.locator('.bd-now-eta')).toHaveAttribute('title', 'at 8 agents')
  expect(await page.evaluate(() => window.estimateNavigationMarker)).toBe('same document')
})
test('hostile override reasons stay escaped in cards and modal', async ({ page }) => {
  await page.goto('/build-fixture/hostile')
  const cue = page.locator('.bd-q.ovr[title*=onmouseover]').first()
  await expect(cue).toHaveAttribute('title', /onmouseover/)
  const card = cue.locator('xpath=ancestor::*[contains(@class,"bd-card")][1]')
  await expect(card.locator('.bd-status')).toContainText('≈1h')
  await card.click()
  await expect(page.locator('.bm-facts')).toContainText('Estimate≈1h')
  await expect(page.locator('.bm-cue').filter({ hasText: /onmouseover/ }).last()).toBeVisible()
  expect(await page.evaluate(() => window.__xss)).toBeUndefined()
  expect(await page.locator('[onmouseover]').count()).toBe(0)
})
