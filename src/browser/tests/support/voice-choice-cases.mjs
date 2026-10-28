import { expect, test } from '@playwright/test'
import { openUnits } from './units-helpers.mjs'

async function openChoice(page, path) {
  await page.addInitScript(() => {
    window.__micRequests = 0
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: {
      enumerateDevices: async () => [],
      getUserMedia: async () => { window.__micRequests++; throw new DOMException('denied', 'NotAllowedError') }
    } })
  })
  await openUnits(page, path)
  await page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()
  return page.getByRole('dialog', { name: 'Responsive Units interface' })
}

test('voice chooser requests no audio on load, open or LiveView patch and Escape returns focus', async ({ page }) => {
  const drawer = await openChoice(page)
  expect(await page.evaluate(() => window.__micRequests)).toBe(0)
  const trigger = drawer.getByRole('button', { name: 'Choose voice input' })
  await trigger.click()
  await expect(drawer.getByRole('menuitem', { name: 'Dictate message' })).toBeFocused()
  await drawer.getByRole('menuitem', { name: 'Dictate message' }).press('ArrowDown')
  await expect(drawer.getByRole('menuitem', { name: 'Converse' })).toBeFocused()
  await drawer.getByLabel('Message agent').fill('editable draft')
  await expect(page.locator('[data-units-fixture]')).toHaveAttribute('data-voice-draft', 'editable draft')
  await expect(drawer.getByRole('menu')).toBeVisible()
  expect(await page.evaluate(() => window.__micRequests)).toBe(0)
  await drawer.getByRole('menuitem', { name: 'Converse' }).press('Escape')
  await expect(trigger).toBeFocused()
  await expect(drawer.getByRole('menu')).toHaveCount(0)
  await expect(drawer).toBeVisible()
})

test('unavailable Converse stays visible with its reason and never requests audio', async ({ page }) => {
  const drawer = await openChoice(page)
  await drawer.getByRole('button', { name: 'Choose voice input' }).click()
  const converse = drawer.getByRole('menuitem', { name: 'Converse' })
  await expect(converse).toHaveAttribute('aria-disabled', 'true')
  await expect(converse).toContainText("Voice input isn't installed in this Aiur. Typed messages work as usual.")
  await converse.evaluate(button => button.click())
  expect(await page.evaluate(() => window.__micRequests)).toBe(0)
})

test('available Converse emits the target hand-off without dictation or microphone capture', async ({ page }) => {
  const drawer = await openChoice(page, '/units-fixture?converse=available')
  await page.evaluate(() => {
    window.__voiceJoins = []
    window.AiurVoiceTransport.open = options => { window.__voiceJoins.push(options.topic); throw new Error('unexpected join') }
  })
  await drawer.getByRole('button', { name: 'Choose voice input' }).click()
  await drawer.getByRole('menuitem', { name: 'Converse' }).click()
  await expect(page.locator('[data-units-fixture]')).toHaveAttribute('data-voice-handoff', JSON.stringify({ surface: 'agent_composer', target: JSON.stringify({ kind: 'worker', ticket: '1110' }) }))
  expect(await page.evaluate(() => window.__voiceJoins)).toEqual([])
  expect(await page.evaluate(() => window.__micRequests)).toBe(0)
})
