import { expect, test } from '@playwright/test'
import { anchor, dragDialThroughAngles, openStreamdeck, openUnits } from './support/streamdeck-emulator.mjs'

// Read-only command keys are covered by 'read-only mode disables the
// fleet-control command keys and a mic hold does not arm it' above, which
// asserts the same gating plus the `is-disabled` face and the inert hold.

test('full-width chat replaces the cmd pager and the pager returns on back', async ({ page }) => {
  await openStreamdeck(page)

  const pager = page.locator('[data-streamdeck-region="600"]')

  await expect(pager).toContainText('Queued')
  await expect(pager).toHaveAttribute('aria-label', /Queued \d+; Not queued \d+/)
  await expect(pager.locator('circle[data-page="0"]')).toHaveAttribute('fill', '#9fd0ff')
  expect(await pager.locator('svg > text').first().evaluate((heading) => getComputedStyle(heading).fontFamily)).toContain('JetBrains Mono')

  await page.locator('.sd-key:not(.is-empty)').first().click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')

  // Ticket chat occupies the entire strip. The fleet pager returns only on
  // the grid; this fixture names its unavailable conversation explicitly.
  const chat = page.locator('[data-mode-view="cmd-strip"] [data-streamdeck-region="0"]')
  await expect(page.locator('[data-mode-view="cmd-strip"] [data-streamdeck-region]')).toHaveCount(1)
  await expect(pager).toHaveCount(0)
  await expect(chat).toHaveCSS('left', '0px')
  await expect(chat).toHaveCSS('width', '800px')
  await expect(chat).toHaveAttribute('aria-label', 'Conversation unavailable')
  await expect(chat).toContainText('Conversation unavailable')
  await expect(page.locator('.sd-seg-info')).toHaveCount(0)

  // Dial A returns from the focused ticket to the fleet grid.
  await page.locator('.sd-knob').first().click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'grid')

  await expect(pager).toContainText('Queued')
  await expect(pager).toHaveAttribute('aria-label', /Queued \d+; Not queued \d+/)
  await expect(page.locator('[data-streamdeck-region="600"]')).toContainText('Queued')
  await expect(pager.locator('circle[data-page="0"]')).toHaveAttribute('fill', '#9fd0ff')
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
  const valueBeforeDrag = await keys.getAttribute('data-grid-dial-value')
  await page.evaluate(() => {
    const hook = window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))
    window.__streamdeckGridEvents = []
    const pushEvent = hook.pushEvent.bind(hook)
    hook.pushEvent = (name, payload) => {
      if (name === 'input') window.__streamdeckGridEvents.push({ name, payload })
      return pushEvent(name, payload)
    }
  })
  const eventCountBeforeDrag = await page.evaluate(() => window.__streamdeckGridEvents.length)
  await anchor(dialD)
  const box = await dialD.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2

  await page.mouse.move(cx, cy - 10)
  await page.mouse.down()
  const dragStarted = await page.evaluate(
    () => window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))._knobs[3].isDragging,
  )
  expect(dragStarted).toBe(true)
  await page.mouse.move(cx + 20, cy - 20)

  const navToggle = page.locator('#ax-drag')
  const navWasCollapsed = await navToggle.getAttribute('data-nav-collapsed') === 'true'
  await navToggle.dispatchEvent('keydown', { key: 'Enter' })
  await expect(navToggle).toHaveAttribute('data-nav-collapsed', String(!navWasCollapsed))

  await page.mouse.move(cx + 30, cy)
  await page.mouse.up()

  const finalValue = await dialD.getAttribute('aria-valuenow')
  await expect(keys).toHaveAttribute('data-grid-page', '1')
  await expect.poll(() => keys.getAttribute('data-grid-dial-value')).not.toBe(valueBeforeDrag)
  expect(Number(finalValue)).toBeGreaterThan(0)
  const releaseEvents = await page.evaluate(() => window.__streamdeckGridEvents)
  expect(releaseEvents).toHaveLength(eventCountBeforeDrag + 1)
  expect(releaseEvents.at(-1)).toMatchObject({ name: 'input', payload: { kind: 'dial', index: 3, action: 'turn', delta: 1 } })
})

test('a cancelled dial drag emits no release commit', async ({ page }) => {
  await openStreamdeck(page)

  const dialD = page.locator('.sd-knob').nth(3)
  await page.evaluate(() => {
    const hook = window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))
    window.__streamdeckGridEvents = []
    const pushEvent = hook.pushEvent.bind(hook)
    hook.pushEvent = (name, payload) => {
      if (name === 'input') window.__streamdeckGridEvents.push({ name, payload })
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
      if (name === 'input') window.__streamdeckGridEvents.push({ name, payload })
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

test('dial D press enters Features and cycles back to Tickets without a legacy page event', async ({ page }) => {
  await openStreamdeck(page)
  const dialD = page.locator('.sd-knob').nth(3)
  const keys = page.locator('#sd-keys')
  await page.evaluate(() => {
    const hook = window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))
    window.__deckLegacyEvents = []
    const push = hook.pushEvent.bind(hook)
    hook.pushEvent = (name, payload) => {
      if (name === 'grid-page' || name === 'key-press') window.__deckLegacyEvents.push({ name, payload })
      return push(name, payload)
    }
  })
  await dialD.click()
  await expect(page.locator('[data-streamdeck-region="600"]')).toHaveAttribute('aria-label', /Features · page 1/)
  await expect(keys).toHaveAttribute('data-grid-page', '0')
  // Epic and Fleet remain in the shared four-view cycle.
  for (const view of ['epic', 'fleet', 'ticket']) {
    await dialD.click()
    await expect(keys).toHaveAttribute('data-deck-view', view)
  }
  await expect(keys.locator('[data-streamdeck-identifier="1352"]')).toBeVisible()
  await keys.locator('[data-streamdeck-identifier="1352"]').click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')
  expect(await page.evaluate(() => window.__deckLegacyEvents)).toEqual([])
})

test('dial D pages live fleet keys using raw input from drag, wheel and keyboard', async ({ page }) => {
  await openStreamdeck(page)
  const keys = page.locator('#sd-keys')
  const dialD = page.locator('.sd-knob').nth(3)
  await expect(keys).toHaveAttribute('data-grid-page-count', '3')
  await expect(keys.locator('[data-streamdeck-identifier="1352"]')).toBeVisible()
  await dragDialThroughAngles(page, dialD, [-90, 0, 90])
  await expect(keys).toHaveAttribute('data-grid-page', '1')
  await expect(keys.locator('[data-streamdeck-identifier="1352"]')).toHaveCount(0)
  await expect(page.locator('[data-streamdeck-region="600"] circle[data-page="1"]')).toHaveAttribute('fill', '#9fd0ff')
  const angle = await dialD.evaluate((element) => element.style.getPropertyValue('--a'))
  await dialD.press('ArrowUp')
  await expect(keys).toHaveAttribute('data-grid-page', '2')
  expect(await dialD.evaluate((element) => element.style.getPropertyValue('--a'))).not.toBe(angle)
  await dialD.hover()
  await page.mouse.wheel(0, 100)
  await expect(keys).toHaveAttribute('data-grid-page', '1')
  await dialD.press('ArrowDown')
  await expect(keys).toHaveAttribute('data-grid-page', '0')
  await expect(keys.locator('[data-streamdeck-identifier="1352"]')).toBeVisible()
})

test('an acknowledged grid turn cannot overwrite a later server page patch', async ({ page }) => {
  await openStreamdeck(page)
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)

  const keys = page.locator('#sd-keys')
  const dialD = page.locator('.sd-knob').nth(3)
  await dialD.press('ArrowUp')
  await expect(keys).toHaveAttribute('data-grid-page', '1')
  await expect.poll(() => page.evaluate(() =>
    window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))._pendingPageDialValue
  )).toBe(null)

  await page.evaluate(() => {
    window.liveSocket.main
      .getHook(document.querySelector('#streamdeck-page'))
      .pushEvent('grid-page', { value: 0 })
  })
  await expect(keys).toHaveAttribute('data-grid-page', '0')
  await expect(keys).toHaveAttribute('data-grid-dial-value', '0')
  await expect(dialD).toHaveAttribute('aria-valuenow', '0')
})

test('a patch during dial D drag preserves the full release travel', async ({ page }) => {
  await openStreamdeck(page)

  const dialD = page.locator('.sd-knob').nth(3)
  await page.evaluate(() => {
    const hook = window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))
    window.__streamdeckGridEvents = []
    const pushEvent = hook.pushEvent.bind(hook)
    hook.pushEvent = (...args) => {
      const [name, payload] = args
      if (name === 'input') {
        window.__streamdeckGridEvents.push({ name, payload })
      }
      return pushEvent(...args)
    }
  })

  await anchor(dialD)
  const box = await dialD.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2
  const point = (degrees) => {
    const radians = (degrees * Math.PI) / 180
    return { x: cx + Math.cos(radians) * 30, y: cy + Math.sin(radians) * 30 }
  }

  await page.mouse.move(...Object.values(point(0)))
  await page.mouse.down()
  await page.mouse.move(...Object.values(point(90)))
  const valueBeforePatch = await dialD.getAttribute('aria-valuenow')
  expect(valueBeforePatch).toBe('33')

  await page.evaluate(() => {
    window.liveSocket.main
      .getHook(document.querySelector('#streamdeck-page'))
      .pushEvent('grid-page', { value: 50 })
  })
  await expect.poll(() => page.locator('#sd-keys').getAttribute('data-grid-dial-value')).toBe('50')
  await expect(dialD).toHaveAttribute('aria-valuenow', valueBeforePatch)

  await page.mouse.move(...Object.values(point(45)))
  await page.mouse.up()

  const releaseEvents = await page.evaluate(() => window.__streamdeckGridEvents)
  expect(releaseEvents).toHaveLength(1)
  expect(releaseEvents[0].payload).toMatchObject({ kind: 'dial', index: 3, action: 'turn', delta: 1 })
  await expect.poll(async () => {
    const serverValue = await page.locator('#sd-keys').getAttribute('data-grid-dial-value')
    return await dialD.getAttribute('aria-valuenow') === serverValue
  }).toBe(true)
})

test('emulator and Units stay in sync after a live fleet-size change', async ({ page, context }) => {
  await openStreamdeck(page)

  const units = await context.newPage()
  const originalTotal = await page.locator('#sd-keys').getAttribute('data-grid-total')
  try {
    // Apply the "Select all preceding filters" selection at mount instead of
    // clicking the button. The click is a phx-click LiveView drops silently when
    // the socket is still settling under CI load (the handler returns without
    // pushing when the view is momentarily disconnected), which left the view on
    // the default `:live` scope. Removing a unit against that stale scope
    // collapses `#units-rows` to the single remaining live unit and the sync
    // assertions below fail even though the emulator never desynced. Loading the
    // selection from the URL keeps the scope deterministic.
    const allConditions = encodeURIComponent('active,alert,paused,queued,finished')
    await openUnits(units, `/units-fixture?v=1&scope=unfinished&conditions=${allConditions}`)

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
  } finally {
    try {
      const reset = await page.request.get('/streamdeck-control/read_only')
      expect(reset.status()).toBe(200)
      await expect(page.locator('#sd-keys')).toHaveAttribute('data-grid-total', originalTotal)
    } finally {
      await units.close()
    }
  }
})
