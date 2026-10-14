import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { anchor, dragDialThroughAngles, openStreamdeck } from './support/streamdeck-emulator.mjs'

test('dial drag rotates the knob and updates aria-valuenow', async ({ page }) => {
  await openStreamdeck(page)

  const knob = page.locator('.sd-knob').first()
  await expect(knob).toBeVisible()

  // Start at a mid-range value so we have room to increase.
  const initialValue = parseInt(await knob.getAttribute('aria-valuenow'), 10)

  // Sweep 54° clockwise: 54 / 2.7 = exactly 20 value units. The movement is
  // also safely above the 8° press threshold, so this pins both interaction
  // constants through the real browser gesture path.
  await dragDialThroughAngles(page, knob, [-90, -36])

  const newValue = parseInt(await knob.getAttribute('aria-valuenow'), 10)
  expect(newValue - initialValue).toBe(20)
})

test('installation modal renders its steps and closes by backdrop or Escape at mobile size', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 375, height: 760 } })
  const page = await context.newPage()

  try {
    await openStreamdeck(page)

    const packageUrl = 'https://github.com/aiur-team/aiur/releases/download/streamdeck-nightly/aiur-streamdeck-nightly-linux-x64.tar.gz'
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
    // The rolling asset carries no commit hash; nothing per-commit leaks into the dialog.
    await expect(dialog).not.toContainText(/streamdeck-[0-9a-f]{40}/)

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
    document.querySelector('section.dashboard-shell').appendChild(spacer)
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
  // the five command keys instead (pause, logs, mic, settings, commands), so
  // the grid is no longer empty here; that PR owns the grid, this one owns the
  // strip below.
  await expect(page.locator('#sd-keys[data-mode-view="cmd"]')).toBeVisible()
  await expect(page.locator('#sd-keys [data-streamdeck-command]')).toHaveCount(5)
  await expect(page.locator('#sd-keys .sd-key:not(.is-empty)')).toHaveCount(5)
  await expect(page.locator('#sd-keys')).not.toHaveAttribute('data-grid-total', /./)
  await expect(page.locator('[data-streamdeck-command]')).toHaveCount(5)
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
  expect(geometry.barHeight).toBe('8px')
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
  await expect(commands).toHaveCount(5)
  await expect(page.getByRole('button', { name: 'Pause', exact: true })).toBeVisible()
  await expect(page.locator('#sd-keys').getByRole('button', { name: 'Settings', exact: true })).toBeVisible()
  await expect(page.locator('#sd-keys button:disabled')).toHaveCount(3)
  await expect(page.locator('#sd-keys .sd-cmd-key.is-empty[aria-hidden="true"]')).toHaveCount(3)

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

test('cmd mode renders the design\'s five command keys with Mic excluded from the click path', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()

  const buttons = page.locator('.sd-cmd-key .sd-key-face[data-streamdeck-command]')
  await expect(buttons).toHaveCount(5)
  await expect(buttons.locator('.sd-cmd-label')).toHaveText(['Pause', 'Logs', 'Mic', 'Settings', 'Commands'])
  await expect(buttons.locator('.sd-cmd-sub')).toHaveText(['HOLD', 'SCROLL', 'HOLD', 'OPEN', 'OPEN'])

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
