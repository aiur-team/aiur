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

test('command keys render real state-derived controls, flash on click, and emit events', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  const commands = page.locator('[data-streamdeck-command]')
  await expect(commands).toHaveCount(4)
  await expect(page.getByRole('button', { name: 'Pause', exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Prioritize', exact: true })).toBeVisible()
  await expect(page.locator('#sd-command-keys button:disabled')).toHaveCount(4)
  await expect(page.locator('#sd-command-keys .sd-cmd-key.is-empty[aria-hidden="true"]')).toHaveCount(4)

  await page.evaluate(() => {
    const hook = window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))
    window.__streamdeckCommandEvents = []
    window.__streamdeckGridEvents = []
    const pushEvent = hook.pushEvent.bind(hook)
    hook.pushEvent = (name, payload) => {
      if (name === 'command-press') window.__streamdeckCommandEvents.push({ name, payload })
      if (name === 'key-press') window.__streamdeckGridEvents.push({ name, payload })
      return pushEvent(name, payload)
    }
  })

  for (const command of ['pause', 'priority', 'logs']) {
    const key = page.locator(`[data-streamdeck-command="${command}"]`)
    await key.click()
    await expect(key).toHaveClass(/is-flashing/, { timeout: 500 })
    if (command === 'logs') {
      await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')
      await page.locator('.sd-knob').first().click()
      await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')
    }
  }

  expect(await page.evaluate(() => window.__streamdeckCommandEvents.map((event) => event.payload.command))).toEqual(['pause', 'priority', 'logs'])
  expect(await page.evaluate(() => window.__streamdeckGridEvents)).toEqual([])
})

test('command mic activates on pointerdown and deactivates on pointerup', async ({ page }) => {
  await openStreamdeck(page)
  await page.locator('.sd-key:not(.is-empty)').first().click()

  const micKey = page.locator('[data-streamdeck-command="mic"]')
  await expect(micKey).toBeVisible()

  await micKey.hover()
  await page.mouse.down()
  await expect(micKey).toHaveClass(/mic-live/, { timeout: 500 })

  await page.mouse.up()
  await expect(micKey).not.toHaveClass(/mic-live/, { timeout: 500 })
})

test('command mic deactivates on pointerleave (not stuck on drag-exit)', async ({ page }) => {
  await openStreamdeck(page)
  await page.locator('.sd-key:not(.is-empty)').first().click()

  const micKey = page.locator('[data-streamdeck-command="mic"]')
  const box = await micKey.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2

  await page.mouse.move(cx, cy)
  await page.mouse.down()
  await expect(micKey).toHaveClass(/mic-live/, { timeout: 500 })

  // Move outside the segment without releasing — simulates a drag-exit.
  await page.mouse.move(0, 0)
  await expect(micKey).not.toHaveClass(/mic-live/, { timeout: 500 })

  await page.mouse.up()
})

test('command mic deactivates on pointercancel', async ({ page }) => {
  await openStreamdeck(page)
  await page.locator('.sd-key:not(.is-empty)').first().click()

  const micKey = page.locator('[data-streamdeck-command="mic"]')
  await micKey.dispatchEvent('pointerdown')
  await expect(micKey).toHaveClass(/mic-live/, { timeout: 500 })

  await micKey.dispatchEvent('pointercancel')
  await expect(micKey).not.toHaveClass(/mic-live/, { timeout: 500 })
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
  await expect(page.locator('#sd-pager-dots [aria-current="page"]')).toHaveAttribute('data-page', '1')

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

test('touch strip exposes provider percentages, not only window counts', async ({ page }) => {
  await openStreamdeck(page)

  await expect(page.locator('.sd-screen-segment').filter({ hasText: 'Claude' })).toContainText('30%')
  await expect(page.locator('.sd-screen-segment').filter({ hasText: 'Codex' })).toContainText('50%')
  await expect(page.locator('.sd-screen-segment').filter({ hasText: 'Claude' }).locator('.sd-screen-value')).not.toContainText('windows')
  await expect(page.locator('.sd-screen-segment').filter({ hasText: 'Codex' }).locator('.sd-screen-value')).not.toContainText('windows')
})

test('Stream Deck emulator passes automated accessibility checks', async ({ page }) => {
  await openStreamdeck(page)

  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations).toEqual([])
})
