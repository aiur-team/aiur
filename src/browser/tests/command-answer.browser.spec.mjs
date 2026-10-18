import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'

test('a real Commands Decision submit records a human-required answer in DecisionStore', async ({ page }) => {
  await openFixture(page, 'writable')
  const configure = await page.goto('/command-answer-control/answerable')
  const configureBody = await configure.text()
  expect(configure?.status(), configureBody).toBe(200)
  await expect(page).toHaveURL(/\/command-answer-fixture\/.+/)
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)

  const form = page.locator('form.decision-answer-form')
  await expect(form).toBeVisible()
  await expect(form.locator('input[name="decision_id"]')).toHaveValue(/.+/)
  await form.getByRole('button', { name: 'Decision' }).click()

  await expect.poll(async () => {
    const response = await page.request.get('/command-answer-state')
    expect(response.ok()).toBe(true)
    return response.json()
  }).toMatchObject({
    decision_status: 'decided',
    selected_option_id: 'approve',
    actor: { kind: 'operator' }
  })
})
