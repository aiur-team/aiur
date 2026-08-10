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

async function openUnits(page) {
  await page.goto('/auth/read_only')
  await page.goto('/units')
  await expect(page.locator('[data-units-fixture="true"]')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
}

async function dragDialThroughAngles(page, dial, angles) {
  const box = await dial.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2
  const point = (degrees) => {
    const radians = (degrees * Math.PI) / 180
    return { x: cx + Math.cos(radians) * 30, y: cy + Math.sin(radians) * 30 }
  }

  await page.mouse.move(...Object.values(point(angles[0])))
  await page.mouse.down()
  for (const degrees of angles.slice(1)) {
    await page.mouse.move(...Object.values(point(degrees)))
  }
  await page.mouse.up()
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

test('installation modal renders its steps and closes by backdrop or Escape at mobile size', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 375, height: 760 } })
  const page = await context.newPage()

  try {
    await openStreamdeck(page)

    const packageUrl = 'https://github.com/aiur-team/aiur/releases/download/streamdeck-0098e3ac86a2e49e685e8e6ff67248373de43f1d/aiur-streamdeck-0.0.0-dev.0098e3ac86a2-linux-x64-c6d1f373b30d8f038538becd746acb43ea2d4364501dc7ced4e65819e9bc76c3.tar.gz'
    await expect(page.locator('#streamdeck-download-control')).toHaveAttribute('href', packageUrl)
    await page.getByRole('button', { name: 'Install +' }).click()
    let dialog = page.getByRole('dialog', { name: 'Install on your Stream Deck +' })
    await expect(dialog).toBeVisible()
    await expect(dialog.getByText('Linux with udev')).toBeVisible()
    await expect(dialog.getByText('Pair it with your daemon')).toBeVisible()
    await expect(dialog.getByText('Download the Stream Deck + package')).toBeVisible()
    await expect(dialog.getByText('Create the sidecar directory')).toBeVisible()
    await expect(dialog.getByText('--strip-components=1')).toBeVisible()
    await expect(dialog.getByText('Create the pairing directory')).toBeVisible()
    await expect(dialog.getByText('Create the pairing file')).toBeVisible()
    await expect(dialog.getByText('Restrict the pairing file')).toBeVisible()
    await expect(dialog.getByText('AIUR_PHOENIX_URL')).toBeVisible()
    await expect(dialog.getByText('Install the udev rule')).toBeVisible()
    await expect(dialog.getByText('Install the user unit')).toBeVisible()
    await expect(dialog.getByText('Reload user systemd')).toBeVisible()
    await expect(dialog.getByText('Enable the sidecar')).toBeVisible()
    await expect(dialog.getByText('Plug in the deck')).toBeVisible()
    await expect(dialog.getByText('What success looks like')).toBeVisible()
    await expect(dialog.getByText('0.0.0-dev.0098e3ac86a2')).toBeVisible()
    await expect(dialog.getByText('0098e3ac86a2e49e685e8e6ff67248373de43f1d')).toBeVisible()
    await expect(dialog.getByRole('link', { name: /Download the Stream Deck \+ package/ })).toHaveAttribute('href', packageUrl)
    await expect(dialog.getByRole('link', { name: 'Download package 0.0.0-dev.0098e3ac86a2' })).toHaveAttribute('href', packageUrl)
    await expect(dialog.locator('input[type="password"], [value*="password" i]')).toHaveCount(0)
    await expect(dialog).not.toContainText(dashboardCredentials.username)
    await expect(dialog).not.toContainText(dashboardCredentials.password)

    await page.locator('.sd-install-backdrop').click({ position: { x: 8, y: 8 } })
    await expect(page.getByRole('dialog')).toHaveCount(0)

    await page.getByRole('button', { name: 'Install +' }).click()
    dialog = page.getByRole('dialog', { name: 'Install on your Stream Deck +' })
    await expect(dialog).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(page.getByRole('dialog')).toHaveCount(0)
  } finally {
    await context.close()
  }
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
  const scrollBeforeWheel = await page.evaluate(() => window.scrollY)
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
  expect(scrollY).toBe(scrollBeforeWheel)
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

test('grid key press enters command mode and replaces grid keys', async ({ page }) => {
  await openStreamdeck(page)

  const key = page.locator('.sd-key:not(.is-empty)').first()
  await expect(key).toBeVisible()

  await key.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')
  await expect(page.locator('#sd-cmd-view')).toBeVisible()
  await expect(page.locator('.sd-key:not(.is-empty)')).toHaveCount(0)
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

test('cmd mode renders the design\'s four command keys with Mic excluded from the click path', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  await expect(page.locator('#sd-cmd-view')).toBeVisible()

  const buttons = page.locator('.sd-cmd-button')
  await expect(buttons).toHaveCount(4)
  await expect(buttons.locator('.sd-cmd-label')).toHaveText(['Pause', 'Prioritize', 'Logs', 'Mic'])
  await expect(buttons.locator('.sd-cmd-sub')).toHaveText(['HOLD', 'RAISE', 'SCROLL', 'HOLD'])

  // Mic is press-and-hold, so it carries no click binding at all. The other
  // three keep theirs. A Mic that fired on click would be a different control.
  const micButton = page.locator('button[data-streamdeck-command="mic"]')
  await expect(micButton).toHaveAttribute('data-command-hold', 'true')
  expect(await micButton.getAttribute('phx-click')).toBeNull()

  // Logs is the control here: it is enabled in this read-only fixture and keeps
  // its click binding, so Mic's missing one is the design's exclusion rather
  // than a side effect of read-only disabling.
  const logsButton = page.locator('button[data-streamdeck-command="logs"]')
  await expect(logsButton).toBeEnabled()
  await expect(logsButton).toHaveAttribute('phx-click', 'command-press')
  await expect(page.locator('.sd-cmd-button[data-command-hold="true"]')).toHaveCount(1)
})

// The browser fixture serves the dashboard read-only, so this is the read-only
// half of the Mic contract: the key is visibly disabled and a hold on it is
// inert. The writable hold/release path is covered server-side in
// streamdeck_live_test.exs, and the shared pointer machinery it drives
// (`pointerdown` / `pointerup` / `pointerleave` / `pointercancel`) is exercised
// in a real browser by the `.sd-mic` segment tests above.
test('the read-only mic command key renders disabled and a hold does not arm it', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()

  const micItem = page.locator('.sd-cmd-item.sd-mic-key')
  const micButton = micItem.locator('button[data-streamdeck-command="mic"]')
  await expect(micItem).toHaveClass(/is-disabled/)
  await expect(micButton).toBeDisabled()

  const box = await micItem.boundingBox()
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await page.mouse.down()
  await page.waitForTimeout(250)
  await expect(micItem).not.toHaveClass(/is-live/)
  await expect(micButton).toHaveAttribute('data-command-state', 'idle')
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

test('Logs command transitions from cmd to logs mode', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')

  await page.locator('[data-streamdeck-command="logs"]').click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')
  await expect(page.locator('#sd-logs-view')).toBeVisible()
  await expect(page.locator('#sd-cmd-view')).toHaveCount(0)
})

// The browser fixture serves the dashboard read-only, so the fleet command
// keys must look disabled rather than silently swallowing a control call.
test('read-only command keys render disabled while Logs stays available', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')

  const control = page.locator('[data-streamdeck-command="pause"], [data-streamdeck-command="resume"]')
  await expect(control).toBeDisabled()
  await expect(control).toHaveAttribute('aria-disabled', 'true')

  const priority = page.locator('[data-streamdeck-command="prioritize"], [data-streamdeck-command="deprioritize"]')
  await expect(priority).toBeDisabled()

  await expect(page.locator('[data-streamdeck-command="logs"]')).toBeEnabled()
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
  await page.mouse.move(cx + 30, cy)
  await page.mouse.move(cx, cy + 30)
  await page.mouse.up()
  const dialValue = parseInt(await knob.getAttribute('aria-valuenow'), 10)
  expect(dialValue).toBeGreaterThan(0)

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

test('an active dial drag commits its final value after a LiveView patch', async ({ page }) => {
  await openStreamdeck(page)

  const dialD = page.locator('.sd-knob').nth(3)
  const keys = page.locator('#sd-keys')
  await page.evaluate(() => {
    const hook = window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))
    window.__streamdeckGridEvents = []
    const pushEvent = hook.pushEvent.bind(hook)
    hook.pushEvent = (name, payload) => {
      if (name === 'grid-page') window.__streamdeckGridEvents.push({ name, payload })
      return pushEvent(name, payload)
    }
  })
  const eventCountBeforeDrag = await page.evaluate(() => window.__streamdeckGridEvents.length)
  const box = await dialD.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2

  await page.mouse.move(cx, cy - 30)
  await page.mouse.down()
  await page.mouse.move(cx + 20, cy - 20)

  const navToggle = page.getByRole('button', { name: /navigation/i }).first()
  const navWasCollapsed = await navToggle.getAttribute('aria-pressed') === 'true'
  await navToggle.dispatchEvent('click')
  await expect(navToggle).toHaveAttribute('aria-pressed', String(!navWasCollapsed))

  await page.mouse.move(cx + 30, cy)
  await page.mouse.up()

  const finalValue = await dialD.getAttribute('aria-valuenow')
  await expect(keys).toHaveAttribute('data-grid-dial-value', finalValue, { timeout: 1000 })
  const releaseEvents = await page.evaluate(() => window.__streamdeckGridEvents)
  expect(releaseEvents).toHaveLength(eventCountBeforeDrag + 1)
  expect(releaseEvents.at(-1)).toMatchObject({ name: 'grid-page', payload: { value: Number(finalValue) } })
})

test('a cancelled dial drag emits no release commit', async ({ page }) => {
  await openStreamdeck(page)

  const dialD = page.locator('.sd-knob').nth(3)
  await page.evaluate(() => {
    const hook = window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))
    window.__streamdeckGridEvents = []
    const pushEvent = hook.pushEvent.bind(hook)
    hook.pushEvent = (name, payload) => {
      if (name === 'grid-page') window.__streamdeckGridEvents.push({ name, payload })
      return pushEvent(name, payload)
    }
  })

  const box = await dialD.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2
  await page.mouse.move(cx, cy - 30)
  await page.mouse.down()
  await page.mouse.move(cx + 30, cy)

  const pointerId = await page.evaluate(
    () => window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))._knobs[3]._activePid,
  )
  await page.evaluate((id) => {
    document.dispatchEvent(new PointerEvent('pointercancel', { bubbles: true, pointerId: id }))
  }, pointerId)
  await page.mouse.up()

  expect(await page.evaluate(() => window.__streamdeckGridEvents)).toHaveLength(0)
  await expect.poll(async () => page.evaluate(() => window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))._knobs[3].isDragging)).toBe(false)
})

test('destroying a dial without drag preservation emits no release commit', async ({ page }) => {
  await openStreamdeck(page)

  const dialD = page.locator('.sd-knob').nth(3)
  await page.evaluate(() => {
    const hook = window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))
    window.__streamdeckGridEvents = []
    const pushEvent = hook.pushEvent.bind(hook)
    hook.pushEvent = (name, payload) => {
      if (name === 'grid-page') window.__streamdeckGridEvents.push({ name, payload })
      return pushEvent(name, payload)
    }
  })

  const box = await dialD.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2
  await page.mouse.move(cx, cy - 30)
  await page.mouse.down()
  await page.mouse.move(cx + 30, cy)
  await page.evaluate(() => {
    window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))._destroyKnobs(false)
  })
  await page.mouse.up()

  expect(await page.evaluate(() => window.__streamdeckGridEvents)).toHaveLength(0)
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
  await expect(page.locator('[data-segment="pager"] [aria-current="page"]')).toHaveAttribute('data-pager-page', '1')

  const angleBeforeCycle = await dialD.evaluate((element) => element.style.getPropertyValue('--a'))
  await dialD.click()
  await expect(keys).toHaveAttribute('data-grid-page', '2')
  await expect(keys).toHaveAttribute('data-grid-dial-value', '100')
  await expect(dialD).toHaveAttribute('aria-valuenow', '100')
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'grid')
  expect(await dialD.evaluate((element) => element.style.getPropertyValue('--a'))).toBe(angleBeforeCycle)

  await dialD.hover()
  await page.mouse.wheel(0, 100)
  await expect(dialD).toHaveAttribute('aria-valuenow', '96')
  const angleAfterWheel = parseFloat(await dialD.evaluate((element) => element.style.getPropertyValue('--a')))
  expect(angleAfterWheel).toBeLessThan(parseFloat(angleBeforeCycle))

  await dialD.focus()
  await page.keyboard.press('ArrowDown')
  await expect(dialD).toHaveAttribute('aria-valuenow', '92')
  const angleAfterKey = parseFloat(await dialD.evaluate((element) => element.style.getPropertyValue('--a')))
  expect(angleAfterKey).toBeLessThan(angleAfterWheel)

  const dragBox = await dialD.boundingBox()
  const dragCx = dragBox.x + dragBox.width / 2
  const dragCy = dragBox.y + dragBox.height / 2
  const dragRadius = Math.min(dragBox.width, dragBox.height) / 3
  const dragPoint = (degrees) => {
    const radians = (degrees * Math.PI) / 180
    return { x: dragCx + Math.cos(radians) * dragRadius, y: dragCy + Math.sin(radians) * dragRadius }
  }
  await page.mouse.move(...Object.values(dragPoint(0)))
  await page.mouse.down()
  await page.mouse.move(...Object.values(dragPoint(-30)))
  await page.mouse.up()
  await expect.poll(async () => parseInt(await dialD.getAttribute('aria-valuenow'), 10)).toBeLessThan(92)
  const angleAfterDrag = parseFloat(await dialD.evaluate((element) => element.style.getPropertyValue('--a')))
  expect(angleAfterDrag).toBeLessThan(angleAfterKey)

})

test('an acknowledged grid cycle cannot overwrite a later server page patch', async ({ page }) => {
  await openStreamdeck(page)

  const keys = page.locator('#sd-keys')
  const dialD = page.locator('.sd-knob').nth(3)
  await dialD.click()
  await expect(keys).toHaveAttribute('data-grid-page', '1')
  await expect.poll(() => page.evaluate(() =>
    window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))._pendingPageDialValue
  )).toBe(null)

  await page.evaluate(() => {
    window.liveSocket.main
      .getHook(document.querySelector('#streamdeck-page'))
      .pushEvent('grid-page', { value: 0 })
  })
  await expect(keys).toHaveAttribute('data-grid-dial-value', '0')
  await expect(dialD).toHaveAttribute('aria-valuenow', '0')
})

test('emulator and Units stay in sync after a live fleet-size change', async ({ page, context }) => {
  await openStreamdeck(page)

  const units = await context.newPage()
  await openUnits(units)
  await units.getByRole('button', { name: 'Select all preceding filters' }).click()

  const rows = units.locator('#units-rows tr.units-row')
  const before = Number.parseInt(await units.locator('.units-header p').nth(1).textContent(), 10)
  await rows.first().locator('td.ut-id-cell').click()
  await units.locator('#remove-selected-unit').evaluate((button) => button.click())

  await expect(units.locator('.units-header p').nth(1)).toContainText(`${before - 1} observed`)

  const unitIdentifiers = await rows.evaluateAll((elements) =>
    elements.map((row) => row.querySelector('.ut-id-num').textContent.trim())
  )
  expect(unitIdentifiers).toHaveLength(5)
  await expect(page.locator('#sd-keys')).toHaveAttribute('data-grid-total', String(unitIdentifiers.length))

  const streamdeckSlots = await page.locator('#sd-keys .sd-key').evaluateAll((keys) =>
    keys.map((key) => key.classList.contains('is-empty') ? null : key.getAttribute('data-streamdeck-identifier'))
  )
  const expectedSlots = Array.from({ length: 8 }, (_, slot) => {
    const index = (slot % 4) * 2 + Math.floor(slot / 4)
    return unitIdentifiers[index] ?? null
  })

  expect(streamdeckSlots).toEqual(expectedSlots)
  await units.close()
})

test('logs mode scrolls classified feed events and flattened transcript panes within real bounds', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  const dialD = page.locator('.sd-knob').nth(3)
  const box = await dialD.boundingBox()
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2)
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')

  await expect(page.locator('#sd-log-events')).toContainText('event-1')
  await dialD.hover()
  await page.mouse.wheel(0, -100)
  await expect(page.locator('#sd-log-events')).toHaveAttribute('data-offset', '1')
  await expect(page.locator('#sd-log-events')).toContainText('event-2')

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

test('dial A pointer direction controls transcript scroll direction in logs mode', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  const dialD = page.locator('.sd-knob').nth(3)
  await dialD.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')

  const dialA = page.locator('.sd-knob').first()
  await dragDialThroughAngles(page, dialA, [-90, 0, 90])
  await expect(page.locator('#sd-log-transcript')).toHaveAttribute('data-offset', '1')

  await dragDialThroughAngles(page, dialA, [90, 0, -90])
  await expect(page.locator('#sd-log-transcript')).toHaveAttribute('data-offset', '0')
})

test('dial D pointer direction controls event scroll direction in logs mode', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  const dialD = page.locator('.sd-knob').nth(3)
  await dialD.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')

  await dragDialThroughAngles(page, dialD, [-90, 0, 90])
  await expect(page.locator('#sd-log-events')).toHaveAttribute('data-offset', '1')

  await dragDialThroughAngles(page, dialD, [90, 0, -90])
  await expect(page.locator('#sd-log-events')).toHaveAttribute('data-offset', '0')
})

test('touch strip renders two provider meters and design segment geometry', async ({ page }) => {
  await openStreamdeck(page)

  const providers = page.locator('[data-segment="provider"]')
  const providerCount = await providers.count()
  expect(providerCount).toBeGreaterThan(0)

  for (let index = 0; index < providerCount; index += 1) {
    const provider = providers.nth(index)
    await expect(provider.locator('[data-meter="session"]')).toHaveCount(1)
    await expect(provider.locator('[data-meter="weekly"]')).toHaveCount(1)
    await expect(provider.locator('.sd-mini')).toHaveCount(2)
  }

  await expect(providers.filter({ hasText: 'Claude' }).locator('[data-meter="session"]')).toContainText('30% · 22m')
  await expect(providers.filter({ hasText: 'Claude' }).locator('[data-meter="weekly"]')).toContainText('47% · Thu 6PM')
  await expect(providers.filter({ hasText: 'Codex' }).locator('[data-meter="session"]')).toContainText('50% · 1h')
  await expect(providers.filter({ hasText: 'Codex' }).locator('[data-meter="weekly"]')).toContainText('75% · Fri 8PM')

  const pagerDots = page.locator('[data-segment="pager"] .sd-pager-dot')
  const pageCount = parseInt(await page.locator('#sd-keys').getAttribute('data-grid-page-count'), 10)
  await expect(pagerDots).toHaveCount(pageCount)

  const segmentRows = await page.locator('#sd-screen > [data-segment]').evaluateAll((segments) => segments.map((segment) => Math.round(segment.getBoundingClientRect().top)))
  expect(new Set(segmentRows)).toEqual(new Set([segmentRows[0]]))

  const geometry = await providers.first().evaluate((segment) => {
    const heading = segment.querySelector('.sd-info-hd')
    const mini = segment.querySelector('.sd-mini')

    return {
      direction: getComputedStyle(segment).flexDirection,
      padding: getComputedStyle(segment).padding,
      headingFont: getComputedStyle(heading).fontFamily,
      barHeight: getComputedStyle(mini.querySelector('.sd-mini-bar')).height
    }
  })

  expect(geometry.direction).toBe('column')
  expect(geometry.padding).toBe('5.12px 8px')
  expect(geometry.headingFont).toContain('JetBrains Mono')
  expect(geometry.barHeight).toBe('3px')
})

test('Stream Deck design geometry holds at desktop and mobile widths in both themes', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 1280, height: 900 })
  await openStreamdeck(page)

  const device = page.locator('.sd-device')
  const keys = page.locator('.sd-keys')
  const desktopGeometry = await page.evaluate(() => {
    const device = document.querySelector('.sd-device')
    const keys = document.querySelector('.sd-keys')
    const key = keys.querySelector('.sd-key')
    const deviceStyle = getComputedStyle(device)
    const keysStyle = getComputedStyle(keys)
    const keyBox = key.getBoundingClientRect()

    return {
      device: {
        width: device.getBoundingClientRect().width,
        maxWidth: deviceStyle.maxWidth,
        borderRadius: deviceStyle.borderRadius,
        backgroundImage: deviceStyle.backgroundImage,
        borderColor: deviceStyle.borderColor,
        boxShadow: deviceStyle.boxShadow
      },
      columns: keysStyle.gridTemplateColumns.split(' ').filter(Boolean).length,
      columnGap: keysStyle.columnGap,
      rowGap: keysStyle.rowGap,
      keyRatio: keyBox.width / keyBox.height,
      states: Object.fromEntries(['running', 'paused', 'stuck', 'alert', 'queued'].map((state) => {
        const key = document.createElement('div')
        const face = document.createElement('div')
        key.className = `sd-key st-${state}`
        face.className = 'sd-key-face'
        key.appendChild(face)
        document.body.appendChild(key)
        const styles = [getComputedStyle(key).backgroundImage, getComputedStyle(face).backgroundImage]
        key.remove()
        return [state, styles]
      })),
      pressShadow: (() => {
        const knob = document.querySelector('.sd-knob')
        knob.classList.add('press')
        const boxShadow = getComputedStyle(knob).boxShadow
        knob.classList.remove('press')
        return boxShadow
      })()
    }
  })

  expect(desktopGeometry.device.width).toBeCloseTo(620, 0)
  expect(desktopGeometry.device.maxWidth).toBe('620px')
  expect(desktopGeometry.device.borderRadius).toBe('34px')
  expect(desktopGeometry.device.borderColor).toBe('rgba(255, 255, 255, 0.06)')
  expect(desktopGeometry.device.backgroundImage).toContain('rgb(42, 43, 46)')
  expect(desktopGeometry.device.backgroundImage).toContain('0%')
  expect(desktopGeometry.device.backgroundImage).toContain('rgb(32, 31, 34) 55%')
  expect(desktopGeometry.device.backgroundImage).toContain('rgb(22, 21, 23)')
  expect(desktopGeometry.device.boxShadow).toContain('rgba(0, 0, 0, 0.5) 0px 30px 70px 0px')
  expect(desktopGeometry.device.boxShadow).toContain('rgba(255, 255, 255, 0.06) 0px 1px 0px 0px inset')
  expect(desktopGeometry.columns).toBe(4)
  expect(desktopGeometry.columnGap).toBe('30.4px')
  expect(desktopGeometry.rowGap).toBe('16px')
  expect(desktopGeometry.keyRatio).toBeCloseTo(1, 2)
  expect(desktopGeometry.states.running[0]).toContain('rgb(63, 139, 255)')
  expect(desktopGeometry.states.running[1]).toContain('rgb(24, 33, 45)')
  expect(desktopGeometry.states.paused[0]).toContain('rgb(74, 77, 85)')
  expect(desktopGeometry.states.paused[1]).toContain('rgb(30, 32, 37)')
  expect(desktopGeometry.states.stuck[0]).toContain('rgb(255, 106, 94)')
  expect(desktopGeometry.states.stuck[1]).toContain('rgb(39, 19, 23)')
  expect(desktopGeometry.states.alert[0]).toContain('rgb(255, 192, 97)')
  expect(desktopGeometry.states.alert[1]).toContain('rgb(36, 29, 14)')
  expect(desktopGeometry.states.queued[0]).toContain('rgb(58, 63, 71)')
  expect(desktopGeometry.states.queued[1]).toContain('rgb(25, 27, 33)')
  expect(desktopGeometry.pressShadow).toContain('rgba(0, 0, 0, 0.6) 0px 3px 7px 0px')
  expect(desktopGeometry.pressShadow).toContain('rgba(255, 255, 255, 0.5) 0px 0px 0px 2px inset')
  await device.screenshot({ path: testInfo.outputPath('streamdeck-desktop.png') })

  const darkSurface = await page.evaluate(() => ['.sd-device', '.sd-key.st-running', '.sd-key.st-running .sd-key-face', '.sd-screen', '.sd-well', '.sd-knob'].map((selector) => {
    const style = getComputedStyle(document.querySelector(selector))
    return [selector, style.backgroundImage, style.borderColor, style.boxShadow]
  }))
  await page.locator('html').evaluate((html) => html.setAttribute('data-theme', 'light'))
  const lightSurface = await page.evaluate(() => ['.sd-device', '.sd-key.st-running', '.sd-key.st-running .sd-key-face', '.sd-screen', '.sd-well', '.sd-knob'].map((selector) => {
    const style = getComputedStyle(document.querySelector(selector))
    return [selector, style.backgroundImage, style.borderColor, style.boxShadow]
  }))
  expect(lightSurface).toEqual(darkSurface)
  await device.screenshot({ path: testInfo.outputPath('streamdeck-desktop-light.png') })

  await page.locator('html').evaluate((html) => html.removeAttribute('data-theme'))
  await page.setViewportSize({ width: 540, height: 900 })
  const mobileGeometry = await page.evaluate(() => {
    const device = document.querySelector('.sd-device')
    const keys = document.querySelector('.sd-keys')
    const key = keys.querySelector('.sd-key')
    const style = getComputedStyle(device)
    const keysStyle = getComputedStyle(keys)
    const keyBox = key.getBoundingClientRect()
    const wellStyle = getComputedStyle(document.querySelector('.sd-well'))

    return {
      paddingTop: style.paddingTop,
      borderRadius: style.borderRadius,
      gap: style.gap,
      wellPadding: wellStyle.padding,
      columns: keysStyle.gridTemplateColumns.split(' ').filter(Boolean).length,
      columnGap: keysStyle.columnGap,
      rowGap: keysStyle.rowGap,
      keyRatio: keyBox.width / keyBox.height
    }
  })

  expect(mobileGeometry.paddingTop).toBe('17.6px')
  expect(mobileGeometry.borderRadius).toBe('24px')
  expect(mobileGeometry.gap).toBe('16px')
  expect(mobileGeometry.wellPadding).toBe('14.4px 12.8px')
  expect(mobileGeometry.columns).toBe(4)
  expect(mobileGeometry.columnGap).toBe('8.8px')
  expect(mobileGeometry.rowGap).toBe('8.8px')
  expect(mobileGeometry.keyRatio).toBeCloseTo(1, 2)
  await device.screenshot({ path: testInfo.outputPath('streamdeck-mobile.png') })
  await page.locator('html').evaluate((html) => html.setAttribute('data-theme', 'light'))
  await device.screenshot({ path: testInfo.outputPath('streamdeck-mobile-light.png') })
})

test('Stream Deck emulator passes automated accessibility checks', async ({ page }) => {
  await openStreamdeck(page)

  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations).toEqual([])
})
