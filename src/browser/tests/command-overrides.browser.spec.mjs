import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'

test('override timeline and form fit desktop and mobile after an answer', async ({ page }, testInfo) => {
  await openFixture(page, 'writable')
  await page.goto('/command-answer-control/answerable')
  await page.getByRole('button', { name: 'Decision', exact: true }).click()
  const form = page.locator('form[phx-submit="revise-decision"]')
  await expect(form).toBeVisible()
  await form.locator('input[value="custom"]').check()
  await form.locator('textarea[name="revision[custom_response]"]').fill('Hold the rollout until the regression is fixed.')
  await form.locator('textarea[name="revision[reason]"]').fill('New regression discovered after the answer.')
  await form.getByRole('button', { name: 'Send correction', exact: true }).click()
  const timeline = page.getByRole('region', { name: 'Overrides', exact: true })
  await expect(timeline.locator('ol > li')).toHaveCount(1)
  // This fixture has no tracker/worker: retained corrective creation fails.
  // The browser verifies the actual failure, never a fabricated delivery.
  await expect(timeline.locator('.chip')).toHaveText('Override failed')
  await expect(timeline.getByRole('link', { name: 'Original Command' })).toBeVisible()
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 900 })
    await expect(timeline).toBeVisible()
    const bounds = await timeline.boundingBox()
    expect(bounds.x + bounds.width).toBeLessThanOrEqual(width)
    for (const link of await timeline.getByRole('link').all()) {
      const rect = await link.boundingBox()
      expect(rect.x + rect.width).toBeLessThanOrEqual(width)
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await page.screenshot({ path: testInfo.outputPath(`override-${width}.png`), fullPage: true })
  }
  // Reuse the harness's existing control to share this retained store with Build.
  await page.goto('/voice-input-fixture?command=true')
  await page.goto('/')
  await expect(page.getByRole('region', { name: 'Fleet overrides' })).toContainText('Override failed')
  const badge = page.locator('.fleet-override-badge').first()
  await expect(badge).toHaveAttribute('href', /\/commands\/dec_/)
  await page.screenshot({ path: testInfo.outputPath('override-fleet-390.png'), fullPage: true })
  // A CSS-only reflow probe; routing and implementation evidence are tested separately.
  const text = await badge.textContent()
  await badge.evaluate(el => { el.textContent = 'Ticket #6913 · Implemented in PR #12345 (awaiting merge)' })
  const bounds = await badge.boundingBox()
  expect(bounds.x + bounds.width).toBeLessThanOrEqual(390)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  await badge.evaluate((el, value) => { el.textContent = value }, text)
})
