import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

// The fixture dashboard is read-only by default, and the command keys are gated
// on that. Set the mode explicitly rather than relying on the default, so a test
// that opts into `writable` cannot leak into whichever test runs after it.
async function openStreamdeck(page, mode = 'read_only') {
  await page.goto('/auth/read_only')
  await page.goto('/')
  await page.context().setHTTPCredentials(dashboardCredentials)
  const control = await page.goto(`/streamdeck-control/${mode}`)
  expect(control.status()).toBe(200)
  await page.goto('/streamdeck')
  await expect(page.locator('#streamdeck-page')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  await anchor(page.locator('.sd-device'))
}

// `page.mouse` takes viewport coordinates and does no scrolling of its own,
// unlike `hover()`/`click()`. The deck sits below the route heading, so a
// gesture read from an unanchored bounding box lands off-screen. Playwright's
// own scroll is used rather than a raw `scrollIntoView`, because it waits for
// the element to settle first — a box read mid-scroll aims the drag at stale
// coordinates. It scrolls minimally, so clear the sticky topbar afterwards or
// the gesture lands on the topbar instead of the dial.
async function anchor(locator) {
  await locator.scrollIntoViewIfNeeded()
  await locator.evaluate((element) => {
    const topbar = document.querySelector('.topbar')
    if (!topbar) return

    const overlap = topbar.getBoundingClientRect().bottom - element.getBoundingClientRect().top
    if (overlap > 0) window.scrollBy(0, -overlap - 8)
  })
}

async function openUnits(page, path = '/units') {
  await page.goto('/auth/read_only')
  await page.goto(path)
  await expect(page.locator('[data-units-fixture="true"]')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
}

async function dragDialThroughAngles(page, dial, angles) {
  // Re-anchor before every drag: a mode change re-lays the deck out.
  await anchor(dial)

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
  await anchor(knob)
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
    // The Download control is a button that opens the setup modal; it no longer
    // starts a download and there is no separate "Install +" button.
    await expect(page.locator('#streamdeck-download-control')).toHaveCount(1)
    await expect(page.locator('#streamdeck-download-control')).not.toHaveAttribute('href', packageUrl)
    await page.getByRole('button', { name: 'Download' }).click()
    let dialog = page.getByRole('dialog', { name: 'Install on your Stream Deck +' })
    await expect(dialog).toBeVisible()

    // Two steps, and step 1 offers exactly one download — the modal is the only
    // place a package download starts.
    await expect(dialog.getByRole('heading', { name: 'Step 1: Download the package' })).toBeVisible()
    await expect(dialog.getByRole('heading', { name: 'Step 2: Paste this into your agent chat' })).toBeVisible()
    await expect(dialog.locator('a[download]')).toHaveCount(1)
    await expect(dialog.getByRole('link', { name: 'Download the package' })).toHaveAttribute('href', packageUrl)

    await expect(dialog.getByText(/Walk me through installing the Aiur Stream Deck \+ sidecar on Linux/)).toBeVisible()
    await expect(dialog.getByText('packages/streamdeck/README.md')).toBeVisible()
    await expect(dialog).not.toContainText('0098e3ac86a2e49e685e8e6ff67248373de43f1d')

    // The prompt wraps over as many rows as it needs: no sideways scroll, no
    // clipped tail, at the narrowest supported width.
    const prompt = dialog.locator('#streamdeck-install-prompt')
    const promptBox = await prompt.evaluate((el) => {
      const panel = el.closest('.modal-panel')
      const box = el.getBoundingClientRect()
      const panelBox = panel.getBoundingClientRect()

      return {
        clippedHorizontally: el.scrollWidth > el.clientWidth + 1,
        // The panel is the scroll container, so "nothing clipped" means the
        // whole block sits inside the panel's own scrollable extent.
        insidePanel: box.right <= panelBox.right + 1 && box.bottom <= panelBox.top + panel.scrollHeight + 1,
        lines: Math.round(box.height / Number.parseFloat(getComputedStyle(el).lineHeight))
      }
    })
    expect(promptBox.clippedHorizontally, 'prompt never scrolls sideways').toBe(false)
    expect(promptBox.insidePanel, 'the whole prompt is inside the dialog').toBe(true)
    expect(promptBox.lines, 'prompt wraps onto multiple rows at 375px').toBeGreaterThan(1)

    // The copy button puts the prompt on the clipboard.
    await context.grantPermissions(['clipboard-read', 'clipboard-write'])
    await dialog.getByRole('button', { name: 'Copy prompt' }).click()
    await expect(dialog.locator('[data-copy-status]')).toHaveText('Copied')
    expect(await page.evaluate(() => navigator.clipboard.readText())).toContain(
      'Walk me through installing the Aiur Stream Deck + sidecar on Linux'
    )
    await expect(dialog.locator('input[type="password"], [value*="password" i]')).toHaveCount(0)
    await expect(dialog).not.toContainText(dashboardCredentials.username)
    await expect(dialog).not.toContainText(dashboardCredentials.password)

    await page.locator('.sd-install-backdrop').click({ position: { x: 8, y: 8 } })
    await expect(page.getByRole('dialog')).toHaveCount(0)

    await page.getByRole('button', { name: 'Download' }).click()
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
  await anchor(knob)
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

  const key = page.locator('#sd-keys .sd-key:not(.is-empty)').first()
  await expect(key).toBeVisible()

  // The key the operator pressed and the panel it opens must agree about the
  // state's accent — that is the whole point of the shared key-face contract.
  const keyState = await key.evaluate((element) => [...element.classList].find((name) => name.startsWith('st-')))
  const keyAccent = await key.evaluate((element) => getComputedStyle(element).getPropertyValue('--sd-accent').trim())

  await key.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')
  // #1607 deleted the standalone #sd-cmd-view and fills the cmd-mode grid with
  // the four command keys instead, so the grid is no longer empty here; that PR
  // owns the grid, this one owns the strip below.
  await expect(page.locator('#sd-keys[data-mode-view="cmd"]')).toBeVisible()
  await expect(page.locator('#sd-keys [data-streamdeck-command]')).toHaveCount(4)
  await expect(page.locator('#sd-keys .sd-key:not(.is-empty)')).toHaveCount(4)
  await expect(page.locator('#sd-keys')).not.toHaveAttribute('data-grid-total', /./)
  await expect(page.locator('[data-streamdeck-command]')).toHaveCount(4)
  await expect(page.locator('.sd-strip-cmd')).toBeVisible()
  await expect(page.locator('.sd-strip-cmd-pager')).toContainText('CONTROLLING')
  await expect(page.locator('.sd-cmd-provider-logo')).toBeVisible()
  await expect(page.locator('.sd-strip-cmd-progress')).toHaveAttribute('aria-valuenow', /\d+/)

  const panel = page.locator('.sd-strip-cmd')
  await expect(panel).toHaveClass(new RegExp(`\\b${keyState}\\b`))

  const accents = await panel.evaluate((element) => ({
    panel: getComputedStyle(element).getPropertyValue('--sd-accent').trim(),
    icon: getComputedStyle(element.querySelector('.sd-strip-cmd-agent-icon')).color,
    status: getComputedStyle(element.querySelector('.sd-strip-cmd-status')).color
  }))

  const dot = await panel.locator('.sd-strip-cmd-status').evaluate((element) => {
    const marker = getComputedStyle(element, '::before')
    return { background: marker.backgroundColor, width: marker.width, radius: marker.borderTopLeftRadius }
  })

  expect(accents.panel).toBe(keyAccent)
  // The design's leading state dot tracks the status ink via currentColor.
  expect(dot.background).toBe(accents.status)
  expect(parseFloat(dot.width)).toBeGreaterThan(0)
  expect(dot.radius).not.toBe('0px')
  // Both inks resolve from --sd-accent, so neither can be a hardcoded green.
  expect(accents.icon).toBe(accents.status)
  expect(accents.icon).not.toBe('rgb(0, 0, 0)')

  await expect(page.locator('.sd-dial-hint').first().locator('span').first()).toHaveCSS('visibility', 'hidden')
})

test('agent key face matches the design geometry and single-colour progress contract', async ({ page }) => {
  await openStreamdeck(page)

  const key = page.locator('.sd-agent-key:not(.is-empty)').first()
  const geometry = await key.evaluate((element) => {
    const face = element.querySelector('.sd-key-face')
    const icon = element.querySelector('.sd-ag-ic')
    const iconGlyph = icon.querySelector('svg')
    const vendor = element.querySelector('.sd-ag-vendor')
    const bar = element.querySelector('.sd-ag-bar')
    const fill = bar.querySelector('i')
    const top = element.querySelector('.sd-agent-top')
    const css = window.getComputedStyle

    const faceBox = face.getBoundingClientRect()
    const topChildrenFit = Array.from(top.children).every((child) => {
      const box = child.getBoundingClientRect()
      return box.left >= faceBox.left && box.right <= faceBox.right
    })

    return {
      key: element.getBoundingClientRect().toJSON(),
      faceRadius: css(face).borderRadius,
      icon: { width: css(icon).width, height: css(icon).height },
      iconGlyph: { width: css(iconGlyph).width, height: css(iconGlyph).height },
      vendor: { width: css(vendor).width, height: css(vendor).height },
      barHeight: css(bar).height,
      facePadding: {
        top: css(face).paddingTop,
        right: css(face).paddingRight,
        bottom: css(face).paddingBottom,
        left: css(face).paddingLeft
      },
      topGap: css(top).gap,
      topChildrenFit,
      fill: css(fill).backgroundColor
    }
  })

  expect(Math.abs(geometry.key.width - geometry.key.height)).toBeLessThan(1)
  expect(geometry.faceRadius).toBe('12px')
  expect(geometry.icon).toEqual({ width: '30px', height: '30px' })
  // The design centres a fixed 20px glyph in the 30px box (streamdeck.design.css:42-43).
  // Asserting the box alone passed while the glyph rendered at 18px.
  expect(geometry.iconGlyph).toEqual({ width: '20px', height: '20px' })
  expect(geometry.vendor).toEqual({ width: '18px', height: '18px' })
  expect(geometry.barHeight).toBe('6px')
  // .sd-agent is `padding: 0.5rem 0.55rem 0.55rem` with a 0.35rem top-row gap
  // (streamdeck.design.css:38-39). The key box matches the design exactly, so
  // there is no fit reason to narrow either value.
  expect(geometry.facePadding).toEqual({ top: '8px', right: '8.8px', bottom: '8.8px', left: '8.8px' })
  expect(geometry.topGap).toBe('5.6px')
  expect(geometry.topChildrenFit).toBe(true)

  expect(geometry.fill).toBe('rgb(63, 185, 80)')

  // A measured 0% keeps the ordinary green stub; only completion brightens.
  await expect(page.locator('[data-streamdeck-identifier="1352"] .sd-ag-bar i')).toHaveCSS('background-color', 'rgb(63, 185, 80)')
  await expect(page.locator('[data-streamdeck-identifier="1338"] .sd-ag-bar i')).toHaveCSS('background-color', 'rgb(116, 212, 127)')
})

// Pressing a fleet-control key needs a writable dashboard: read-only renders
// those keys disabled and the hook never binds them.
test('command keys render real state-derived controls, flash on click, and emit events', async ({ page }) => {
  await openStreamdeck(page, 'writable')

  await page.locator('#sd-keys .sd-key:not(.is-empty)').first().click()
  const commands = page.locator('[data-streamdeck-command]')
  await expect(commands).toHaveCount(4)
  await expect(page.getByRole('button', { name: 'Pause', exact: true })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Settings', exact: true })).toBeVisible()
  await expect(page.locator('#sd-keys button:disabled')).toHaveCount(4)
  await expect(page.locator('#sd-keys .sd-cmd-key.is-empty[aria-hidden="true"]')).toHaveCount(4)

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

  for (const command of ['pause', 'logs', 'settings']) {
    const key = page.locator(`[data-streamdeck-command="${command}"]`)
    await key.click()
    await expect(key).toHaveClass(/is-flashing/, { timeout: 500 })
    // Logs and Settings are the two navigation keys: each opens its own pane
    // and dial A backs out of it.
    if (command === 'logs' || command === 'settings') {
      await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', command)
      await page.locator('.sd-knob').first().click()
      await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')
    }
  }

  expect(await page.evaluate(() => window.__streamdeckCommandEvents.map((event) => event.payload.command))).toEqual(['pause', 'logs', 'settings'])
  expect(await page.evaluate(() => window.__streamdeckGridEvents)).toEqual([])
})

test('command mic activates on pointerdown and deactivates on pointerup', async ({ page }) => {
  await openStreamdeck(page, 'writable')
  await page.locator('.sd-key:not(.is-empty)').first().click()

  const micKey = page.locator('.sd-mic-key')
  const micFace = micKey.locator('.sd-key-face')
  await expect(micKey).toBeVisible()

  await micKey.hover()
  await page.mouse.down()
  await expect(micKey).toHaveClass(/mic-live/, { timeout: 500 })

  // The hold must actually pulse, not merely carry the class: .sd-mic-key
  // .mic-live is only meaningful if the face resolves the design's animation.
  await expect(micFace).toHaveCSS('animation-name', 'sd-mic-pulse')

  await page.mouse.up()
  await expect(micKey).not.toHaveClass(/mic-live/, { timeout: 500 })
  await expect(micFace).not.toHaveCSS('animation-name', 'sd-mic-pulse')
})

test('command mic deactivates on pointerleave (not stuck on drag-exit)', async ({ page }) => {
  await openStreamdeck(page, 'writable')
  await page.locator('.sd-key:not(.is-empty)').first().click()

  const micKey = page.locator('.sd-mic-key')
  await anchor(micKey)
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

test('cmd mode renders the design\'s four command keys with Mic excluded from the click path', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()

  const buttons = page.locator('.sd-cmd-key .sd-key-face[data-streamdeck-command]')
  await expect(buttons).toHaveCount(4)
  await expect(buttons.locator('.sd-cmd-label')).toHaveText(['Pause', 'Logs', 'Mic', 'Settings'])
  await expect(buttons.locator('.sd-cmd-sub')).toHaveText(['HOLD', 'SCROLL', 'HOLD', 'OPEN'])

  // Mic is the only press-and-hold key; the hook drives it from pointer events
  // rather than the click handler it binds to the others.
  const micButton = page.locator('[data-streamdeck-command="mic"]')
  await expect(micButton).toHaveAttribute('data-command-hold', 'true')
  await expect(page.locator('[data-command-hold="true"]')).toHaveCount(1)

  // Logs is the control here: it is navigation rather than fleet control, so it
  // stays enabled even in this read-only fixture. That proves the disabling
  // asserted below is the read-only gate and not every key being inert.
  await expect(page.locator('[data-streamdeck-command="logs"]')).toBeEnabled()
})

// The browser fixture serves the dashboard read-only, so this is the read-only
// half of the command-key contract: the fleet-control keys are visibly disabled
// and a hold on Mic is inert. The writable paths are covered server-side in
// streamdeck_live_test.exs.
test('read-only mode disables the fleet-control command keys and a mic hold does not arm it', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()

  for (const command of ['pause', 'mic']) {
    await expect(page.locator(`[data-streamdeck-command="${command}"]`)).toBeDisabled()
    await expect(page.locator(`.sd-cmd-key:has([data-streamdeck-command="${command}"])`)).toHaveClass(/is-disabled/)
  }

  const micKey = page.locator('.sd-mic-key')
  const micButton = micKey.locator('[data-streamdeck-command="mic"]')

  // The hook skips disabled keys, so the hold never binds and the key cannot
  // latch live no matter how long the pointer is held down.
  await micButton.dispatchEvent('pointerdown')
  await page.waitForTimeout(250)
  await expect(micKey).not.toHaveClass(/mic-live/)
  await expect(micButton).toHaveAttribute('data-command-state', 'idle')
  await micButton.dispatchEvent('pointerup')
})

// The mic key is fleet control, so it is only armed on a writable dashboard.
test('command mic deactivates on pointercancel', async ({ page }) => {
  await openStreamdeck(page, 'writable')
  await page.locator('.sd-key:not(.is-empty)').first().click()

  const micKey = page.locator('.sd-mic-key')
  const micButton = micKey.locator('[data-streamdeck-command="mic"]')
  await micButton.dispatchEvent('pointerdown')
  await expect(micKey).toHaveClass(/mic-live/, { timeout: 500 })

  await micButton.dispatchEvent('pointercancel')
  await expect(micKey).not.toHaveClass(/mic-live/, { timeout: 500 })
})

test('command mic deactivates when a mode transition removes the held key', async ({ page }) => {
  await openStreamdeck(page, 'writable')
  await page.locator('.sd-key:not(.is-empty)').first().click()

  const micKey = page.locator('.sd-mic-key')
  const micButton = micKey.locator('[data-streamdeck-command="mic"]')
  await micButton.dispatchEvent('pointerdown')
  await expect(micKey).toHaveClass(/mic-live/, { timeout: 500 })

  const dial = page.locator('.sd-knob').nth(3)
  await dial.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')

  await page.locator('.sd-knob').first().click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')
  await expect(page.locator('.sd-mic-key')).not.toHaveClass(/mic-live/, { timeout: 500 })
})

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
  await anchor(dialD)
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

test('clicking a logs event key positions the flattened transcript at that event', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  const dialD = page.locator('.sd-knob').nth(3)
  await anchor(dialD)
  const box = await dialD.boundingBox()
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2)
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')

  const logKeys = page.locator('#sd-log-keys')
  await expect(logKeys.locator('.sd-key')).toHaveCount(8)

  // The surface reads oldest-left to newest-right, so the window opens at the
  // right-hand end: LIVE is the last key, and the origin anchor at index 0 is
  // off-screen behind it.
  const liveIndex = await logKeys.locator('.sd-live-key').getAttribute('data-log-event-index')
  await expect(logKeys.locator('.sd-live-key')).toContainText('LIVE')
  await expect(logKeys.locator('.sd-live-key .sd-live-dot')).toHaveCount(1)
  await expect(logKeys.locator('.sd-live-key .sd-log-dir')).toHaveCount(0)
  await expect(logKeys.locator('.sd-live-key')).toHaveAttribute('aria-current', 'true')

  // The fixture's bus kinds cover four of the five directions on the four
  // newest events — the ones inside the window as it opens — and the origin
  // anchor carries the fifth. Direction comes from the marker kind, not the
  // topic, so this is asserting the kind -> badge mapping end to end.
  const directions = { 7: 'AGENT', 8: 'CONSUME', 9: 'SYSTEM', 10: 'EMIT' }
  const inks = new Set()
  for (const [index, direction] of Object.entries(directions)) {
    const badge = logKeys.locator(`[data-log-event-index="${index}"] .sd-log-dir`)
    await expect(badge).toContainText(direction)
    await expect(badge).toHaveAttribute('data-dir', direction)
    inks.add(await badge.evaluate((el) => getComputedStyle(el).color))
  }
  // EMIT and AGENT share one blue by design; the other two are distinct.
  expect(inks.size).toBe(3)

  // The origin anchor is the far-left key and always exists. Page the window
  // fully left to reach it — that is also the only way an operator sees the
  // beginning of a long ticket.
  const dialDKnob = page.locator('.sd-knob').nth(3)
  for (let i = 0; i < 6; i += 1) await dragDialThroughAngles(page, dialDKnob, [90, 0, -90])
  await expect(logKeys).toHaveAttribute('data-offset', '0')
  const origin = logKeys.locator('[data-log-event-index="0"] .sd-log-dir')
  await expect(origin).toContainText('INFO')
  await expect(logKeys.locator('[data-log-event-index="0"]')).toContainText('Ticket opened')
  inks.add(await origin.evaluate((el) => getComputedStyle(el).color))
  expect(inks.size).toBe(4)
  // LIVE is pinned: even scrolled fully left to the origin, it still occupies
  // the last (bottom-right) key rather than scrolling away.
  await expect(logKeys.locator('.sd-live-key')).toHaveCount(1)
  await expect(logKeys.locator('.sd-key').last()).toHaveClass(/sd-live-key/)

  // Back to where it opened, so the assertions below read the live end.
  for (let i = 0; i < 6; i += 1) await dragDialThroughAngles(page, dialDKnob, [-90, 0, 90])
  await expect(logKeys).toHaveAttribute('data-offset', String(Number(await logKeys.getAttribute('data-max-offset'))))

  const strip = page.locator('#sd-screen')
  const transcript = page.locator('#sd-log-transcript')
  const maxOffset = await transcript.getAttribute('data-max-offset')
  // Requirement: logs opens where the agent is working, not at the ticket's
  // first line.
  await expect(strip).toHaveAttribute('data-transcript-offset', maxOffset)

  // Three entry shapes, not a single flattened line per row.
  await expect(page.locator('.sd-log-entry-message').first()).toBeVisible()

  // Dial A's hint arrows are state: pinned at the newest end there is nothing
  // newer, so the down arrow is hidden and the up one is not.
  await expect(page.locator('#sd-transcript-hint-down')).toHaveAttribute('aria-hidden', 'true')
  await expect(page.locator('#sd-transcript-hint-up')).toHaveAttribute('aria-hidden', 'false')

  // Pressing an event key makes it the active one and LIVE inactive, and moves
  // the strip to that event's own header. Keys 7 and 8 are inside the window
  // as it opens; the far-left ones were reached by paging, above.
  await logKeys.locator('[data-log-event-index="8"]').click()
  await expect(logKeys.locator('[data-log-event-index="8"]')).toHaveAttribute('aria-current', 'true')
  await expect(logKeys.locator('.sd-live-key')).toHaveAttribute('aria-current', 'false')
  await expect(strip).not.toHaveAttribute('data-transcript-offset', maxOffset)
  await expect(page.locator('.sd-log-entry-evhdr').first()).toBeVisible()
  const atEventEight = await transcript.getAttribute('data-offset')

  // A different event key moves it somewhere else again.
  await logKeys.locator('[data-log-event-index="7"]').press('Enter')
  await expect(logKeys.locator('[data-log-event-index="7"]')).toHaveAttribute('aria-current', 'true')
  await expect(transcript).not.toHaveAttribute('data-offset', atEventEight)

  // Returning to LIVE reverses it: back to the newest end, LIVE active again.
  await logKeys.locator('.sd-live-key').click()
  await expect(strip).toHaveAttribute('data-transcript-offset', maxOffset)
  await expect(logKeys.locator('.sd-live-key')).toHaveAttribute('aria-current', 'true')
  await expect(logKeys.locator(`[data-log-event-index="${liveIndex}"]`)).toHaveAttribute('aria-current', 'true')
})

test('dial A pointer direction controls transcript scroll direction in logs mode', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  const dialD = page.locator('.sd-knob').nth(3)
  await dialD.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')

  // The surface opens pinned at the newest end, so the only way to move is
  // back into history first; dragging the other way returns to the end.
  const strip = page.locator('#sd-screen')
  const maxOffset = await page.locator('#sd-log-transcript').getAttribute('data-max-offset')
  await expect(strip).toHaveAttribute('data-transcript-offset', maxOffset)

  const dialA = page.locator('.sd-knob').first()
  await dragDialThroughAngles(page, dialA, [90, 0, -90])
  await expect(strip).toHaveAttribute('data-transcript-offset', String(Number(maxOffset) - 1))

  await dragDialThroughAngles(page, dialA, [-90, 0, 90])
  await expect(strip).toHaveAttribute('data-transcript-offset', maxOffset)
})

test('dial D pointer direction controls event scroll direction in logs mode', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()
  const dialD = page.locator('.sd-knob').nth(3)
  await dialD.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'logs')

  // Same direction contract on the key window, which also opens at its end.
  const logKeys = page.locator('#sd-log-keys')
  const maxOffset = await logKeys.getAttribute('data-max-offset')
  await expect(logKeys).toHaveAttribute('data-offset', maxOffset)

  await dragDialThroughAngles(page, dialD, [90, 0, -90])
  await expect(logKeys).toHaveAttribute('data-offset', String(Number(maxOffset) - 1))

  await dragDialThroughAngles(page, dialD, [-90, 0, 90])
  await expect(logKeys).toHaveAttribute('data-offset', maxOffset)
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

  await expect(providers.filter({ hasText: 'Claude' }).locator('[data-meter="session"]')).toContainText('70% remaining · 22m')
  await expect(providers.filter({ hasText: 'Claude' }).locator('[data-meter="weekly"]')).toContainText('53% remaining · Thu 6PM')
  await expect(providers.filter({ hasText: 'Codex' }).locator('[data-meter="session"]')).toContainText('50% remaining · 1h')
  await expect(providers.filter({ hasText: 'Codex' }).locator('[data-meter="weekly"]')).toContainText('25% remaining · Fri 8PM')

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

  // Both segment headings hold one ink. The design specifies 0.42, which
  // measures under 4.5:1 here and fails the axe check below, so they sit at
  // 0.55 together rather than one heading drifting from the other.
  expect(await providers.first().locator('.sd-info-hd').evaluate((heading) => getComputedStyle(heading).color)).toBe('rgba(255, 255, 255, 0.55)')

  // The pager is the design's dial segment (.sd-seg-d, streamdeck.design.css:153-154):
  // a centred column on the brighter 0.04 ground, labelled by its own text and
  // carrying no logo header.
  const pagerShape = await page.locator('[data-segment="pager"]').evaluate((segment) => {
    const label = segment.querySelector('.sd-seg-dlabel')

    return {
      align: getComputedStyle(segment).alignItems,
      gap: getComputedStyle(segment).gap,
      background: getComputedStyle(segment).backgroundColor,
      labelSize: getComputedStyle(label).fontSize,
      labelWeight: getComputedStyle(label).fontWeight,
      labelColor: getComputedStyle(label).color,
      headings: segment.querySelectorAll('.sd-info-hd').length,
      logos: segment.querySelectorAll('.sd-hd-logo').length
    }
  })

  expect(pagerShape.align).toBe('center')
  expect(pagerShape.gap).toBe('5.12px')
  expect(pagerShape.background).toBe('rgba(255, 255, 255, 0.04)')
  expect(pagerShape.labelSize).toBe('8.64px')
  expect(pagerShape.labelWeight).toBe('700')
  expect(pagerShape.labelColor).toBe('rgba(255, 255, 255, 0.55)')
  expect(pagerShape.headings).toBe(0)
  expect(pagerShape.logos).toBe(0)
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
    const agentKey = keys.querySelector('.sd-agent-key:not(.is-empty)')
    const agentFace = agentKey.querySelector('.sd-key-face')
    const agentFaceStyle = getComputedStyle(agentFace)
    const faceBox = agentFace.getBoundingClientRect()
    const agentIcon = agentKey.querySelector('.sd-ag-ic')
    const agentIconSvg = agentIcon.querySelector('svg')
    const agentTicket = agentKey.querySelector('.sd-ag-id')
    const agentElements = Array.from(agentKey.querySelectorAll('.sd-agent-top > *, .sd-ag-title, .sd-ag-foot'))
    const agentFaceFits = agentElements.every((element) => {
      const box = element.getBoundingClientRect()
      return box.left >= faceBox.left && box.right <= faceBox.right && box.top >= faceBox.top && box.bottom <= faceBox.bottom
    })

    return {
      paddingTop: style.paddingTop,
      borderRadius: style.borderRadius,
      gap: style.gap,
      wellPadding: wellStyle.padding,
      columns: keysStyle.gridTemplateColumns.split(' ').filter(Boolean).length,
      columnGap: keysStyle.columnGap,
      rowGap: keysStyle.rowGap,
      keyRatio: keyBox.width / keyBox.height,
      agentIcon: { width: getComputedStyle(agentIcon).width, height: getComputedStyle(agentIcon).height },
      agentIconSvg: { width: getComputedStyle(agentIconSvg).width, height: getComputedStyle(agentIconSvg).height },
      agentTicketSize: getComputedStyle(agentTicket).fontSize,
      agentPadding: {
        top: agentFaceStyle.paddingTop,
        right: agentFaceStyle.paddingRight,
        bottom: agentFaceStyle.paddingBottom
      },
      agentFaceFits
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
  expect(mobileGeometry.agentIcon).toEqual({ width: '26px', height: '26px' })
  expect(mobileGeometry.agentIconSvg).toEqual({ width: '17px', height: '17px' })
  expect(mobileGeometry.agentTicketSize).toBe('16px')
  // The design's mobile block (streamdeck.design.css:198-208) scales the icon and
  // ticket number only; .sd-agent keeps its desktop padding at both breakpoints.
  expect(mobileGeometry.agentPadding).toEqual({ top: '8px', right: '8.8px', bottom: '8.8px' })
  expect(mobileGeometry.agentFaceFits).toBe(true)
  await device.screenshot({ path: testInfo.outputPath('streamdeck-mobile.png') })
  await page.locator('html').evaluate((html) => html.setAttribute('data-theme', 'light'))
  await device.screenshot({ path: testInfo.outputPath('streamdeck-mobile-light.png') })
})

test('Stream Deck emulator passes automated accessibility checks', async ({ page }) => {
  await openStreamdeck(page)

  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations).toEqual([])

  // The install dialog is a whole second surface — its own heading order, list
  // semantics, contrast and control names — and none of it is reachable by the
  // scan above while the modal is closed.
  await page.getByRole('button', { name: 'Download' }).click()
  await expect(page.locator('#streamdeck-install-modal')).toBeVisible()

  const dialogAccessibility = await new AxeBuilder({ page }).analyze()
  expect(dialogAccessibility.violations).toEqual([])
})
