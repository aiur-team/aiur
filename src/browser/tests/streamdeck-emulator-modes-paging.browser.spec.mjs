import { expect, test } from '@playwright/test'
import { anchor, openStreamdeck, openUnits } from './support/streamdeck-emulator.mjs'

test('mode transitions: grid → cmd (key click) → logs (cycle-window) → back → back', async ({ page }) => {
  await openStreamdeck(page)

  const device = page.locator('.sd-device')
  const keysView = page.locator('#sd-keys[data-mode-view="grid"]')
  const cmdView = page.locator('#sd-keys[data-mode-view="cmd"]')
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
  await anchor(dial3)
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
  await anchor(dial0)
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
  await anchor(dial0)
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
  await expect(page.locator('#sd-keys')).toHaveCount(0)
})

// Read-only command keys are covered by 'read-only mode disables the
// fleet-control command keys and a mic hold does not arm it' above, which
// asserts the same gating plus the `is-disabled` face and the inert hold.

test('CONTROLLING relabel rides the cmd page and the pager dots return on back', async ({ page }) => {
  await openStreamdeck(page)

  const pager = page.locator('[data-segment="pager"]')
  const pageCount = parseInt(await page.locator('#sd-keys').getAttribute('data-grid-page-count'), 10)

  await expect(pager).toContainText('MORE AGENTS')
  await expect(pager.locator('.sd-pager-dot')).toHaveCount(pageCount)
  expect(await pager.locator('.sd-seg-dlabel').evaluate((heading) => getComputedStyle(heading).fontFamily)).toContain('JetBrains Mono')

  const identifier = await page.locator('.sd-key:not(.is-empty)').first().getAttribute('data-streamdeck-identifier')
  await page.locator('.sd-key:not(.is-empty)').first().click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')

  // The page indicator must not survive into cmd mode: there is no page set on
  // screen to indicate. The dots go, and the CONTROLLING relabel rides the cmd
  // page. The dial-D column itself stays — #1607 identifies the controlled
  // agent there, and `streamdeck-operator-flow.browser.spec.mjs` asserts that
  // `.sd-pager-label` reads `#<id>` at this exact point in the flow.
  await expect(pager.locator('.sd-pager-dot')).toHaveCount(0)
  await expect(pager.locator('.sd-seg-dlabel')).toHaveText('CONTROLLING')
  await expect(pager.locator('.sd-pager-label')).toHaveText(`#${identifier}`)
  await expect(page.locator('.sd-strip-cmd-pager')).toHaveText(`CONTROLLING #${identifier}`)

  // The cmd page takes every column left of dial D rather than sharing the
  // strip with the info segments: it starts at the strip's content edge and
  // stops where the pager column begins.
  const cmdBox = await page.locator('.sd-strip-cmd').boundingBox()
  const pagerBox = await pager.boundingBox()
  const stripBox = await page.locator('#sd-screen').boundingBox()
  expect(cmdBox.x + cmdBox.width).toBeLessThanOrEqual(pagerBox.x + 1)
  expect(cmdBox.width).toBeGreaterThan(stripBox.width * 0.6)
  await expect(page.locator('.sd-seg-info')).toHaveCount(0)

  const dialD = page.locator('.sd-knob').nth(3)
  await dialD.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')
  await expect(page.locator('.sd-strip-logs')).toBeVisible()
  await expect(pager.locator('.sd-pager-dot')).toHaveCount(0)
  await expect(pager.locator('.sd-pager-label')).toHaveText(`#${identifier}`)
  await expect(page.locator('.sd-seg-info')).toHaveCount(0)

  // Dial A is the back press: logs -> cmd -> grid.
  const dialA = page.locator('.sd-knob').first()
  await dialA.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')
  await expect(page.locator('.sd-strip-cmd-pager')).toHaveText(`CONTROLLING #${identifier}`)
  await dialA.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'grid')

  await expect(pager).toContainText('MORE AGENTS')
  await expect(pager.locator('.sd-pager-dot')).toHaveCount(pageCount)
  await expect(page.locator('.sd-strip-cmd-pager')).toHaveCount(0)
})

test('dial drag + mode transition both work in the same session', async ({ page }) => {
  await openStreamdeck(page)

  // First rotate dial 0 to change its value.
  const knob = page.locator('.sd-knob').first()
  await anchor(knob)
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
  // The navigation separator handles keyboard toggles.
  const navToggle = page.locator('#ax-drag')
  await navToggle.press('Enter')
  await navToggle.press('Enter')

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
  await anchor(dialD)
  const box = await dialD.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2

  await page.mouse.move(cx, cy - 30)
  await page.mouse.down()
  await page.mouse.move(cx + 20, cy - 20)

  const navToggle = page.locator('#ax-drag')
  const navWasCollapsed = await navToggle.getAttribute('data-nav-collapsed') === 'true'
  await navToggle.dispatchEvent('keydown', { key: 'Enter' })
  await expect(navToggle).toHaveAttribute('data-nav-collapsed', String(!navWasCollapsed))

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

  await anchor(dialD)
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

  await anchor(dialD)
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
  await anchor(dialD)
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

  await anchor(dialD)
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
  // Apply the "Select all preceding filters" selection at mount instead of
  // clicking the button. The click is a phx-click LiveView drops silently when
  // the socket is still settling under CI load (the handler returns without
  // pushing when the view is momentarily disconnected), which left the view on
  // the default `:live` scope. Removing a unit against that stale scope
  // collapses `#units-rows` to the single remaining live unit and the sync
  // assertions below fail even though the emulator never desynced. Loading the
  // selection from the URL keeps the scope deterministic.
  const allConditions = encodeURIComponent('active,alert,paused,queued,finished')
  await openUnits(units, `/units?v=1&scope=unfinished&conditions=${allConditions}`)

  const rows = units.locator('#units-rows tr.units-row')
  // The fixture exposes 7 units, of which 6 are unfinished. Confirming the
  // rendered scope before mutating makes the assumption this test asserts on
  // explicit, so a stale selection fails loudly here instead of as a one-row
  // table later.
  await expect(units.locator('.units-header p').nth(1)).toContainText('7 observed · 6 in selected scope')
  const before = Number.parseInt(await units.locator('.units-header p').nth(1).textContent(), 10)
  await rows.first().locator('td.ut-id-cell').click()
  await units.locator('#remove-selected-unit').evaluate((button) => button.click())

  await expect(units.locator('.units-header p').nth(1)).toContainText(`${before - 1} observed`)

  // The header count and the row list are separate patches from the same
  // LiveView diff, so the header settling does not mean the tbody has. Wait on
  // the rows themselves before snapshotting them: `evaluateAll` is a one-shot
  // read with no retry, and reading mid-patch returned 1 row of 5 in CI.
  await expect(rows).toHaveCount(5)

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
