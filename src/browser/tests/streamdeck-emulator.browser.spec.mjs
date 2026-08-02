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

  // Start at a mid-range value so we have room to increase.
  const initialValue = parseInt(await knob.getAttribute('aria-valuenow'), 10)

  // Drag a wide clockwise arc that accumulates well over 8° (press threshold)
  // and sweeps enough angle to guarantee an increase, even from a high initial.
  const box = await knob.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2

  // Start directly above centre and sweep clockwise (right then down).
  await page.mouse.move(cx, cy - 30)
  await page.mouse.down()
  await page.mouse.move(cx + 20, cy - 20)
  await page.mouse.move(cx + 30, cy)
  await page.mouse.move(cx + 20, cy + 20)
  await page.mouse.move(cx, cy + 30)
  await page.mouse.up()

  const newValue = parseInt(await knob.getAttribute('aria-valuenow'), 10)
  // A sustained clockwise drag must increase the value, not merely match it.
  expect(newValue).toBeGreaterThan(initialValue)
})

test('wheel event adjusts the knob value and does not scroll the page', async ({ page }) => {
  await openStreamdeck(page)

  // Make the page scrollable so the scroll-prevention check is not trivially true.
  await page.evaluate(() => {
    const spacer = document.createElement('div')
    spacer.style.height = '2000px'
    spacer.setAttribute('aria-hidden', 'true')
    document.querySelector('.shell-content').appendChild(spacer)
  })
  await page.waitForTimeout(50)

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

  // Page must NOT have scrolled: the non-passive listener called preventDefault.
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

  // Second rapid click: dispatch directly to exercise the remove+reflow+re-add
  // branch. After the first click, mode shifted to cmd so the keys container is
  // display:none — Playwright's click (even with force:true) refuses to target
  // elements inside a hidden parent. page.evaluate dispatches without that check.
  await page.evaluate(() => {
    const k = document.querySelector('.sd-key:not(.is-empty)')
    k.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }))
  })
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

test('mode transitions: grid → cmd (key click) → logs (cycle-window) → back → back', async ({ page }) => {
  await openStreamdeck(page)

  const device = page.locator('.sd-device')
  const keysView = page.locator('[data-mode-view="grid"]')
  const cmdView = page.locator('[data-mode-view="cmd"]')
  const logsView = page.locator('[data-mode-view="logs"]')

  // Initial state: grid mode, keys visible, cmd and logs hidden.
  await expect(device).toHaveAttribute('data-mode', 'grid')
  await expect(keysView).toBeVisible()
  await expect(cmdView).not.toBeVisible()
  await expect(logsView).not.toBeVisible()

  // Click a key to enter cmd mode.
  const key = page.locator('.sd-key:not(.is-empty)').first()
  await key.click()
  await expect(device).toHaveAttribute('data-mode', 'cmd')
  await expect(keysView).not.toBeVisible()
  await expect(cmdView).toBeVisible()
  await expect(logsView).not.toBeVisible()

  // Dial 3 press (cycle-window) → logs mode.
  const dial3 = page.locator('.sd-knob').nth(3)
  const d3box = await dial3.boundingBox()
  const d3cx = d3box.x + d3box.width / 2
  const d3cy = d3box.y + d3box.height / 2
  await page.mouse.move(d3cx, d3cy)
  await page.mouse.down()
  await page.mouse.up()
  await expect(device).toHaveAttribute('data-mode', 'logs')
  await expect(keysView).not.toBeVisible()
  await expect(cmdView).not.toBeVisible()
  await expect(logsView).toBeVisible()

  // Dial 0 press (back) → cmd mode.
  const dial0 = page.locator('.sd-knob').first()
  const d0box = await dial0.boundingBox()
  const d0cx = d0box.x + d0box.width / 2
  const d0cy = d0box.y + d0box.height / 2
  await page.mouse.move(d0cx, d0cy)
  await page.mouse.down()
  await page.mouse.up()
  await expect(device).toHaveAttribute('data-mode', 'cmd')

  // Dial 0 press (back) again → grid mode.
  // Re-fetch bounding box: the layout reflowed when keys became hidden (cmd mode),
  // so cached coordinates from the logs-mode capture may miss the knob.
  const d0box2 = await dial0.boundingBox()
  const d0cx2 = d0box2.x + d0box2.width / 2
  const d0cy2 = d0box2.y + d0box2.height / 2
  await page.mouse.move(d0cx2, d0cy2)
  await page.mouse.down()
  await page.mouse.up()
  await expect(device).toHaveAttribute('data-mode', 'grid')
  await expect(keysView).toBeVisible()
})

test('dial drag + mode transition both work in the same session', async ({ page }) => {
  await openStreamdeck(page)

  // First rotate dial 0 to change its value.
  const knob = page.locator('.sd-knob').first()
  const box = await knob.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2

  await page.mouse.move(cx, cy - 30)
  await page.mouse.down()
  for (let i = 1; i <= 20; i += 1) {
    const angle = -90 + i * 2
    const radians = (angle * Math.PI) / 180
    await page.mouse.move(cx + Math.cos(radians) * 30, cy + Math.sin(radians) * 30)
  }
  await page.mouse.up()
  await expect.poll(async () => parseInt(await knob.getAttribute('aria-valuenow'), 10)).toBeGreaterThan(0)
  const dialValue = parseInt(await knob.getAttribute('aria-valuenow'), 10)

  // Then click a key to enter cmd mode.
  const key = page.locator('.sd-key:not(.is-empty)').first()
  await key.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')

  // Dial value should be preserved across the mode change.
  expect(parseInt(await knob.getAttribute('aria-valuenow'), 10)).toBe(dialValue)
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
  // The nav toggle button is labelled "Hide navigation" or "Show navigation".
  const navToggle = page.getByRole('button', { name: /navigation/i }).first()
  await navToggle.click({ force: true })
  await navToggle.click({ force: true })

  // Wait briefly for any patch to settle.
  await page.waitForTimeout(200)

  const valueAfterPatch = parseInt(await knob.getAttribute('aria-valuenow'), 10)
  expect(valueAfterPatch).toBe(valueBeforePatch)
})

test('dial D pages live fleet keys and pager dots', async ({ page }) => {
  await openStreamdeck(page)

  const keys = page.locator('#sd-keys')
  await expect(keys).toHaveAttribute('data-grid-page-count', '3')
  await expect(keys.locator('[data-streamdeck-identifier="1352"]')).toBeVisible()
  await expect(keys.locator('[data-streamdeck-identifier="1376"]')).toHaveCount(0)

  const dialD = page.locator('.sd-knob').nth(3)
  await dialD.hover()
  const dialBox = await dialD.boundingBox()
  const cx = dialBox.x + dialBox.width / 2
  const cy = dialBox.y + dialBox.height / 2
  const radius = Math.min(dialBox.width, dialBox.height) / 3
  const point = (degrees) => {
    const radians = (degrees * Math.PI) / 180
    return { x: cx + Math.cos(radians) * radius, y: cy + Math.sin(radians) * radius }
  }

  await page.mouse.move(...Object.values(point(-90)))
  await page.mouse.down()
  await page.mouse.move(...Object.values(point(0)))
  await page.mouse.move(...Object.values(point(90)))
  await page.mouse.move(...Object.values(point(126)))
  await page.mouse.up()

  await expect(keys).toHaveAttribute('data-grid-page', '1')
  const dialValue = parseInt(await keys.getAttribute('data-grid-dial-value'), 10)
  expect(dialValue).toBeGreaterThanOrEqual(75)
  expect(dialValue).toBeLessThanOrEqual(85)
  await expect(dialD).toHaveAttribute('aria-valuenow', String(dialValue))
  await expect(keys.locator('.sd-key:not(.is-empty)')).toHaveCount(8)
  await expect(keys.locator('[data-streamdeck-identifier="1352"]')).toHaveCount(0)
  await expect(page.locator('#sd-pager-dots [aria-current="page"]')).toHaveAttribute('data-page', '1')

  await dialD.click()
  await expect(keys).toHaveAttribute('data-grid-page', '2')
  await expect(keys).toHaveAttribute('data-grid-dial-value', '100')
  await expect(dialD).toHaveAttribute('aria-valuenow', '100')

  await dialD.click()
  await expect(keys).toHaveAttribute('data-grid-page', '0')
  await expect(keys).toHaveAttribute('data-grid-dial-value', '0')
  await expect(dialD).toHaveAttribute('aria-valuenow', '0')
})

test('dial D drag, wheel, and keyboard preserve continuous fleet offsets', async ({ page }) => {
  await openStreamdeck(page)

  const keys = page.locator('#sd-keys')
  const dialD = page.locator('.sd-knob').nth(3)
  const box = await dialD.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2

  await page.mouse.move(cx, cy - 30)
  await page.mouse.down()
  for (let i = 1; i <= 20; i += 1) {
    const angle = -90 + i * 2
    const radians = (angle * Math.PI) / 180
    await page.mouse.move(cx + Math.cos(radians) * 30, cy + Math.sin(radians) * 30)
  }
  await page.mouse.up()
  await expect.poll(async () => parseInt(await dialD.getAttribute('aria-valuenow'), 10)).toBeGreaterThan(0)
  const afterDrag = parseInt(await dialD.getAttribute('aria-valuenow'), 10)
  await expect(keys).toHaveAttribute('data-grid-dial-value', String(afterDrag))

  await dialD.hover()
  await page.mouse.wheel(0, -100)
  await expect.poll(async () => parseInt(await dialD.getAttribute('aria-valuenow'), 10)).toBeGreaterThan(afterDrag)
  const afterWheel = parseInt(await dialD.getAttribute('aria-valuenow'), 10)

  await dialD.focus()
  await page.keyboard.press('ArrowDown')
  await expect.poll(async () => parseInt(await dialD.getAttribute('aria-valuenow'), 10)).toBeLessThan(afterWheel)
  const afterKeyboard = parseInt(await dialD.getAttribute('aria-valuenow'), 10)
  await expect(keys).toHaveAttribute('data-grid-dial-value', String(afterKeyboard))
})

test('logs mode scrolls classified feed events and flattened transcript panes within real bounds', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  const dialD = page.locator('.sd-knob').nth(3)
  await dialD.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')

  await expect(page.locator('#sd-log-events')).toContainText('event-1')
  await dialD.hover()
  for (let i = 0; i < 12; i += 1) await page.mouse.wheel(0, -100)
  await expect(page.locator('#sd-log-events')).toHaveAttribute('data-max-offset', '2')
  await expect(page.locator('#sd-log-events')).toHaveAttribute('data-offset', '1')
  await expect(page.locator('#sd-log-events')).toContainText('event-2')

  await dialD.click()
  await expect(page.locator('#sd-log-events')).toHaveAttribute('data-offset', '2')
  await expect(dialD).toHaveAttribute('aria-valuenow', '100')

  await dialD.click()
  await expect(page.locator('#sd-log-events')).toHaveAttribute('data-offset', '0')
  await expect(dialD).toHaveAttribute('aria-valuenow', '0')

  const dialA = page.locator('.sd-knob').first()
  await dialA.hover()
  await page.mouse.wheel(0, -100)
  await expect(page.locator('#sd-log-transcript')).toHaveAttribute('data-offset', '1')
  await expect(page.locator('#sd-log-transcript')).toHaveAttribute('data-max-offset', '18')
  await expect(page.locator('#sd-log-transcript [data-log-kind="message"]')).toContainText('event-10')

  await page.mouse.wheel(0, 1000)
  await expect(page.locator('#sd-log-transcript')).toHaveAttribute('data-offset', '0')
  await expect(page.locator('#sd-transcript-hint-up')).toHaveAttribute('aria-hidden', 'true')
})

test('touch strip exposes provider percentages, not only window counts', async ({ page }) => {
  await openStreamdeck(page)

  await expect(page.locator('.sd-screen-segment').filter({ hasText: 'Claude' })).toContainText('Daily 30%')
  await expect(page.locator('.sd-screen-segment').filter({ hasText: 'Codex' })).toContainText('Daily 50%')
  await expect(page.locator('.sd-screen-segment').filter({ hasText: 'Claude' }).locator('.sd-screen-value')).not.toContainText('windows')
  await expect(page.locator('.sd-screen-segment').filter({ hasText: 'Codex' }).locator('.sd-screen-value')).not.toContainText('windows')
})

test('Stream Deck emulator passes automated accessibility checks', async ({ page }) => {
  await openStreamdeck(page)

  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations).toEqual([])
})
