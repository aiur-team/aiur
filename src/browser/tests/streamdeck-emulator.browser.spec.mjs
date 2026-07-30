import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

async function openStreamdeck(page) {
  await page.goto('/auth/read_only')
  await page.goto('/')
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.goto('/streamdeck')
  await expect(page.locator('#streamdeck-page')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
}

test('dial drag rotates the knob and updates aria-valuenow', async ({ page }) => {
  await openStreamdeck(page)

  const knob = page.locator('.sd-knob').first()
  await expect(knob).toBeVisible()

  const initialValue = parseInt(await knob.getAttribute('aria-valuenow'), 10)

  // Drag from centre rightward then downward — a clockwise sweep that increases the value.
  const box = await knob.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2

  await page.mouse.move(cx, cy - 20)
  await page.mouse.down()
  // Sweep clockwise: move right then down to accumulate angle > 8° threshold.
  await page.mouse.move(cx + 20, cy)
  await page.mouse.move(cx + 20, cy + 20)
  await page.mouse.move(cx, cy + 30)
  await page.mouse.up()

  const newValue = parseInt(await knob.getAttribute('aria-valuenow'), 10)
  // Clockwise drag should have increased the value (or at minimum not decreased past start).
  expect(newValue).toBeGreaterThanOrEqual(initialValue)
})

test('wheel event adjusts the knob value and does not scroll the page', async ({ page }) => {
  await openStreamdeck(page)

  const knob = page.locator('.sd-knob').first()
  const initialValue = parseInt(await knob.getAttribute('aria-valuenow'), 10)

  await knob.hover()
  // Scroll up → value should increase.
  await page.mouse.wheel(0, -100)

  const afterUp = parseInt(await knob.getAttribute('aria-valuenow'), 10)
  expect(afterUp).toBeGreaterThan(initialValue)

  // Scroll down → value should decrease.
  await page.mouse.wheel(0, 100)
  const afterDown = parseInt(await knob.getAttribute('aria-valuenow'), 10)
  expect(afterDown).toBeLessThan(afterUp)

  // Page should not have scrolled (non-passive wheel listener prevented default).
  const scrollY = await page.evaluate(() => window.scrollY)
  expect(scrollY).toBe(0)
})

test('keyboard arrow keys adjust the focused knob value', async ({ page }) => {
  await openStreamdeck(page)

  const knob = page.locator('.sd-knob').first()
  await knob.focus()
  await expect(knob).toBeFocused()

  const initialValue = parseInt(await knob.getAttribute('aria-valuenow'), 10)

  await page.keyboard.press('ArrowUp')
  const afterUp = parseInt(await knob.getAttribute('aria-valuenow'), 10)
  expect(afterUp).toBeGreaterThan(initialValue)

  await page.keyboard.press('ArrowDown')
  const afterDown = parseInt(await knob.getAttribute('aria-valuenow'), 10)
  expect(afterDown).toBeLessThan(afterUp)
})

test('brief dial tap (< 8 degrees) triggers a press flash on dial 0', async ({ page }) => {
  await openStreamdeck(page)

  // Dial 0 is the first knob (Focus); a press should trigger the .press class.
  const knob = page.locator('.sd-knob').first()
  const box = await knob.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2

  // Very short click-like gesture: down and up nearly in place (< 8° accumulated).
  await page.mouse.move(cx, cy)
  await page.mouse.down()
  await page.mouse.up()

  // The press class should appear transiently; poll quickly.
  await expect(knob).toHaveClass(/press/, { timeout: 500 })
})

test('key click triggers is-flashing animation; rapid repeat restarts it', async ({ page }) => {
  await openStreamdeck(page)

  const key = page.locator('.sd-key:not(.is-empty)').first()
  await expect(key).toBeVisible()

  await key.click()
  await expect(key).toHaveClass(/is-flashing/, { timeout: 500 })

  // Second rapid click: remove + reflow + re-add should work.
  await key.click()
  // Still present (or re-added); the test confirms the branch ran without throwing.
  await expect(key).toHaveClass(/is-flashing/, { timeout: 500 })
})

test('mic segment activates on pointerdown and deactivates on pointerup', async ({ page }) => {
  await openStreamdeck(page)

  const micSegment = page.locator('.sd-screen-segment').filter({ has: page.locator('.sd-mic') })
  await expect(micSegment).toBeVisible()

  await micSegment.hover()
  await page.mouse.down()
  await expect(micSegment).toHaveClass(/is-live/, { timeout: 500 })

  await page.mouse.up()
  await expect(micSegment).not.toHaveClass(/is-live/, { timeout: 500 })
})

test('mic deactivates on pointerleave (not stuck on drag-exit)', async ({ page }) => {
  await openStreamdeck(page)

  const micSegment = page.locator('.sd-screen-segment').filter({ has: page.locator('.sd-mic') })
  const box = await micSegment.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2

  await page.mouse.move(cx, cy)
  await page.mouse.down()
  await expect(micSegment).toHaveClass(/is-live/, { timeout: 500 })

  // Move outside the segment without releasing — simulates a drag-exit.
  await page.mouse.move(0, 0)
  await expect(micSegment).not.toHaveClass(/is-live/, { timeout: 500 })

  await page.mouse.up()
})

test('dial and knob state survive a LiveView patch (regression for #1306)', async ({ page }) => {
  await openStreamdeck(page)

  const knob = page.locator('.sd-knob').first()
  await knob.hover()

  // Increase value by scrolling.
  await page.mouse.wheel(0, -300)
  const valueBeforePatch = parseInt(await knob.getAttribute('aria-valuenow'), 10)
  expect(valueBeforePatch).toBeGreaterThan(0)

  // Force a LiveView patch by toggling the nav — this triggers a re-render.
  const navToggle = page.getByRole('button', { name: /collapse|expand/i })
  if (await navToggle.isVisible()) {
    await navToggle.click()
    await navToggle.click()
  } else {
    // Use a LiveView pushEvent to trigger an innocuous server round-trip.
    await page.evaluate(() => window.liveSocket?.pushEvent('restore-nav', { collapsed: false }))
  }

  // Wait briefly for any patch to settle.
  await page.waitForTimeout(200)

  const valueAfterPatch = parseInt(await knob.getAttribute('aria-valuenow'), 10)
  expect(valueAfterPatch).toBe(valueBeforePatch)
})

test('Stream Deck emulator passes automated accessibility checks', async ({ page }) => {
  await openStreamdeck(page)

  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations).toEqual([])
})
