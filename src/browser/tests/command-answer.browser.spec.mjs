import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'

test('the Commands action stays disabled during LiveView join, then records its answer', async ({ page }) => {
  await openFixture(page, 'writable')
  const configure = await page.goto('/command-answer-control/answerable')
  const configureBody = await configure.text()
  expect(configure?.status(), configureBody).toBe(200)
  await expect(page).toHaveURL(/\/commands\/dec_.+/)

  const form = page.locator('form.decision-answer-form')
  await expect(form).toBeVisible()
  await expect(form.locator('input[name="decision_id"]')).toHaveValue(/.+/)
  const decision = form.getByRole('button', { name: 'Decision' })
  await expect.poll(async () => {
    const response = await page.request.get('/command-answer-join-state')
    return (await response.json()).state
  }).toBe('joining')
  await expect(decision).toBeDisabled()
  await expect(page.getByRole('status').filter({ hasText: 'Connecting to the live dashboard' })).toBeVisible()

  await expect.poll(async () => {
    const response = await page.request.get('/command-answer-join-state')
    return (await response.json()).state
  }, { timeout: 10_000 }).toBe('joined')
  await expect(decision).toBeEnabled()
  await decision.click()

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

test('native questions validate as a group and submit all choices at 390px', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await openFixture(page, 'writable')
  await page.goto('/command-answer-control/answerable?native=true')
  const form = page.locator('form.decision-answer-form')
  const first = form.getByRole('group', { name: 'Which release strategy?' })
  const second = form.getByRole('group', { name: 'Which targets?' })
  await first.getByLabel('Safe rollout', { exact: true }).check()
  await expect(form.getByRole('button', { name: 'Submit answers' })).toBeEnabled()
  await form.getByRole('button', { name: 'Submit answers' }).click()
  await expect.poll(async () => (await (await page.request.get('/command-answer-state')).json()).decision_status).toBe('open')
  await expect(second.locator('input').first()).toHaveJSProperty('validationMessage', 'Answer this question.')
  await second.getByLabel('Alpha', { exact: true }).check()
  await second.getByLabel('Beta', { exact: true }).check()
  await second.getByLabel('Other', { exact: true }).check()
  await expect(second.getByLabel('Other response', { exact: true })).toBeVisible()
  await second.getByLabel('Other response', { exact: true }).fill('Canary')
  const dimensions = await page.evaluate(() => ({ width: innerWidth, scroll: document.documentElement.scrollWidth }))
  expect(dimensions.scroll).toBeLessThanOrEqual(dimensions.width)
  await form.getByRole('button', { name: 'Submit answers' }).click()
  await expect.poll(async () => (await (await page.request.get('/command-answer-state')).json()).question_answers).toEqual({
    q1: ['Safe rollout'], q2: ['Alpha', 'Beta', 'Canary']
  })
  await expect(page.locator('.decision-answer-summary')).toContainText('Which targets?: Alpha, Beta, Canary')
})
