import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { anchor, dragDialThroughAngles, openStreamdeck as openStreamdeckPage } from './support/streamdeck-emulator.mjs'

// Pointer coordinates must stay fixed after anchoring in this gesture spec.
async function openStreamdeck(page, mode) {
  await openStreamdeckPage(page, mode)
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
  await page.evaluate(() => {
    document.documentElement.style.scrollBehavior = 'auto'
    window.scrollTo({ top: window.scrollY, behavior: 'instant' })
  })
}

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
    const close = dialog.getByRole('button', { name: 'Close', exact: true })
    await expect(close).toHaveCSS('display', 'flex')
    await expect(close).toHaveCSS('border-radius', '999px')
    await expect(close).toHaveCSS('min-height', '30.4px')


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

test('wheel events adjust every dial, including C, without scrolling the page', async ({ page }) => {
  await openStreamdeck(page)

  // Keep native page scrolling observable while checking every dial.
  await page.evaluate(() => {
    const spacer = document.createElement('div')
    spacer.style.height = '2000px'
    spacer.setAttribute('aria-hidden', 'true')
    document.querySelector('section.dashboard-shell').appendChild(spacer)
  })

  const settledScroll = () => page.evaluate(() => new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(() => resolve(window.scrollY)))
  }))
  for (const index of [0, 1, 2, 3]) {
    const knob = page.locator('.sd-knob').nth(index)
    await knob.hover()
    const initialValue = parseInt(await knob.getAttribute('aria-valuenow'), 10)
    const scrollBeforeWheel = await page.evaluate(() => window.scrollY)

    await page.mouse.wheel(0, -100)
    await expect.poll(async () => parseInt(await knob.getAttribute('aria-valuenow'), 10)).toBeGreaterThan(initialValue)
    const afterUp = parseInt(await knob.getAttribute('aria-valuenow'), 10)
    expect(await settledScroll()).toBe(scrollBeforeWheel)

    await page.mouse.wheel(0, 100)
    await expect.poll(async () => parseInt(await knob.getAttribute('aria-valuenow'), 10)).toBeLessThan(afterUp)
    expect(await settledScroll()).toBe(scrollBeforeWheel)
  }
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

test('dial taps and long holds send one raw action, including a patch during the hold', async ({ page }) => {
  await openStreamdeck(page)
  const knob = page.locator('.sd-knob').first()
  await page.evaluate(() => {
    const hook = window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))
    window.__dialActions = []
    const push = hook.pushEvent.bind(hook)
    hook.pushEvent = (name, payload) => {
      if (name === 'input') window.__dialActions.push(payload)
      return push(name, payload)
    }
  })
  await knob.click()
  await expect(knob).toHaveClass(/press/, { timeout: 500 })
  expect(await page.evaluate(() => window.__dialActions)).toEqual([{ kind: 'dial', index: 0, action: 'press' }])

  await knob.hover()
  await page.mouse.down()
  const nav = page.locator('#ax-drag')
  const before = await nav.getAttribute('data-nav-collapsed')
  await nav.dispatchEvent('keydown', { key: 'Enter' })
  await expect(nav).not.toHaveAttribute('data-nav-collapsed', before)
  await page.waitForTimeout(550)
  await page.mouse.up()
  expect(await page.evaluate(() => window.__dialActions)).toEqual([
    { kind: 'dial', index: 0, action: 'press' },
    { kind: 'dial', index: 0, action: 'long_press' }
  ])
})

test('grid key press enters command mode and replaces grid keys', async ({ page }) => {
  await openStreamdeck(page)

  const key = page.locator('#sd-keys .sd-key:not(.is-empty)').first()
  await expect(key).toBeVisible()

  await key.click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')
  // #1607 deleted the standalone #sd-cmd-view and fills the cmd-mode grid with
  // the ticket action keys, so
  // the grid is no longer empty here; that PR owns the grid, this one owns the
  // strip below.
  await expect(page.locator('#sd-keys[data-mode-view="cmd"]')).toBeVisible()
  await expect(page.locator('#sd-keys [data-streamdeck-command]')).toHaveCount(8)
  await expect(page.locator('#sd-keys .sd-key:not(.is-empty)')).toHaveCount(8)
  await expect(page.locator('#sd-keys')).not.toHaveAttribute('data-grid-total', /./)
  await expect(page.locator('[data-streamdeck-command]')).toHaveCount(8)
  await expect(page.locator('[data-mode-view="cmd-strip"] [data-streamdeck-region="0"]')).toBeVisible()
  await expect(page.locator('[data-mode-view="cmd-strip"] [data-streamdeck-region]')).toHaveCount(1)
  const panel = page.locator('[data-mode-view="cmd-strip"] [data-streamdeck-region="0"]')
  await expect(panel).toHaveCSS('width', '800px')
  await expect(panel).toContainText('Conversation unavailable')

  await expect(page.locator('.sd-dial-hint').first().locator('span').first()).toHaveCSS('visibility', 'hidden')
})

test('agent key uses one daemon SVG with native geometry and accessible identity', async ({ page }) => {
  await openStreamdeck(page)
  const key = page.locator('#sd-keys [data-streamdeck-identifier="1352"]')
  await expect(key).toHaveAttribute('aria-label', /1352.*Running/)
  await expect(key.locator('svg')).toHaveCount(1)
  await expect(key.locator('svg')).toHaveAttribute('viewBox', '0 0 120 120')
  const box = await key.boundingBox()
  expect(box.width).toBe(120)
  expect(box.height).toBe(120)
  await expect(key.locator('[data-part="progress-fill"]')).toHaveAttribute('fill', '#3fb950')
  await expect(page.locator('[data-streamdeck-identifier="1338"] [data-part="progress-fill"]')).toHaveAttribute('fill', '#74d47f')
  const ids = await page.locator('#sd-keys [id]').evaluateAll((nodes) => nodes.map((node) => node.id))
  expect(new Set(ids).size).toBe(ids.length)
})

// Pressing a fleet-control key needs a writable dashboard: read-only renders
// those keys disabled and the hook never binds them.
test('command keys render real state-derived controls, flash on click, and emit events', async ({ page }) => {
  await openStreamdeck(page, 'writable')

  await page.locator('#sd-keys .sd-key:not(.is-empty)').first().click()
  const commands = page.locator('[data-streamdeck-command]')
  await expect(commands).toHaveCount(8)
  await expect(page.getByRole('button', { name: 'Pause', exact: true })).toBeVisible()
  await expect(page.locator('#sd-keys').getByRole('button', { name: 'Settings', exact: true })).toBeVisible()
  await expect(page.locator('#sd-keys button:disabled')).toHaveCount(3)
  await expect(page.locator('#sd-keys .sd-cmd-key.is-empty[aria-hidden="true"]')).toHaveCount(0)

  await page.evaluate(() => {
    const hook = window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))
    window.__streamdeckCommandEvents = []
    window.__streamdeckGridEvents = []
    window.__streamdeckFlashes = []
    // Observe after the key handler, before an asynchronous pane swap can remove it.
    document.addEventListener('click', (event) => {
      const key = event.target.closest('[data-streamdeck-command]')
      if (key) window.__streamdeckFlashes.push({ command: key.dataset.streamdeckCommand, flashing: key.classList.contains('is-flashing') })
    })
    const pushEvent = hook.pushEvent.bind(hook)
    hook.pushEvent = (name, payload) => {
      if (name === 'command-press') window.__streamdeckCommandEvents.push({ name, payload })
      if (name === 'key-press') window.__streamdeckGridEvents.push({ name, payload })
      return pushEvent(name, payload)
    }
  })

  for (const command of ['pause', 'commands', 'settings']) {
    const key = page.locator(`[data-streamdeck-command="${command}"]`)
    await key.click()
    expect(await page.evaluate(() => window.__streamdeckFlashes.at(-1))).toEqual({ command, flashing: true })
    // Settings shares the physical dial-4 hold to go back; Commands keeps dial A.
    if (command === 'commands' || command === 'settings') {
      await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', command)
      if (command === 'settings') {
        const dial = page.locator('.sd-knob').nth(3)
        await anchor(dial)
        const box = await dial.boundingBox()
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
        await page.mouse.down()
        await page.waitForTimeout(550)
        await page.mouse.up()
      } else {
        await page.locator('.sd-knob').first().click()
      }
      await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')
    }
  }

  expect(await page.evaluate(() => window.__streamdeckCommandEvents.map((event) => event.payload.command))).toEqual(['pause', 'commands', 'settings'])
  expect(await page.evaluate(() => window.__streamdeckGridEvents)).toEqual([])
})

test('the SVG Dashboard key opens its server URL without sending a command action', async ({ page }) => {
  await openStreamdeck(page, 'writable')
  await page.locator('#sd-keys .sd-key:not(.is-empty)').first().click()
  const key = page.getByRole('button', { name: 'Dashboard', exact: true })
  const url = await key.getAttribute('data-streamdeck-url')
  expect(url).toMatch(/^https?:\/\//)
  await page.evaluate(() => {
    window.__openedDeckLinks = []
    window.__deckLinkCommands = []
    window.open = (url, target, features) => { window.__openedDeckLinks.push({ url, target, features }); return null }
    const hook = window.liveSocket.main.getHook(document.querySelector('#streamdeck-page'))
    const push = hook.pushEvent.bind(hook)
    hook.pushEvent = (name, payload) => { if (name === 'command-press') window.__deckLinkCommands.push(payload); return push(name, payload) }
  })
  await key.click()
  expect(await page.evaluate(() => window.__openedDeckLinks)).toEqual([{ url, target: '_blank', features: 'noopener,noreferrer' }])
  expect(await page.evaluate(() => window.__deckLinkCommands)).toEqual([])
})

test('command mic activates on pointerdown and deactivates on pointerup', async ({ page }) => {
  await openStreamdeck(page, 'writable')
  await page.locator('.sd-key:not(.is-empty)').first().click()

  const micKey = page.locator('.sd-mic-key')
  const micFace = micKey.locator('svg rect').first()
  await expect(micKey).toBeVisible()

  await micKey.hover()
  await page.mouse.down()
  await expect(micKey).toHaveClass(/mic-live/, { timeout: 500 })

  // The hold must actually pulse, not merely carry the class: .sd-mic-key
  // .mic-live is only meaningful if the face resolves the design's animation.
  await expect(micFace).toHaveAttribute('stroke', '#ff9a90')

  await page.mouse.up()
  await expect(micKey).not.toHaveClass(/mic-live/, { timeout: 500 })
  await expect(micFace).not.toHaveAttribute('stroke', '#ff9a90')
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

test('cmd mode renders the ticket action keys with Mic excluded from the click path', async ({ page }) => {
  await openStreamdeck(page)

  await page.locator('.sd-key:not(.is-empty)').first().click()

  const buttons = page.locator('.sd-cmd-key[data-streamdeck-command]')
  await expect(buttons).toHaveCount(8)
  expect(await buttons.evaluateAll((nodes) => nodes.map((node) => node.getAttribute('aria-label')))).toEqual(['Pause', 'Priority up', 'Priority down', 'Commands', 'Open PR', 'Dashboard', 'Mic', 'Settings'])
  await expect(buttons.locator('[data-part="caption"]')).toHaveText(['HOLD', 'QUEUE', 'QUEUE', 'OPEN', 'OPEN', 'OPEN', 'HOLD', 'OPEN'])

  // Mic is the only press-and-hold key; the hook drives it from pointer events
  // rather than the click handler it binds to the others.
  const micButton = page.locator('[data-streamdeck-command="mic"]')
  await expect(micButton).toHaveAttribute('data-command-hold', 'true')
  await expect(page.locator('[data-command-hold="true"]')).toHaveCount(1)

  // Commands is the control here: it is navigation rather than fleet control, so it
  // stays enabled even in this read-only fixture. That proves the disabling
  // asserted below is the read-only gate and not every key being inert.
  await expect(page.locator('[data-streamdeck-command="commands"]')).toBeEnabled()
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
    await expect(page.locator(`.sd-cmd-key[data-streamdeck-command="${command}"]`)).toHaveAttribute('aria-disabled', 'true')
  }

  const micKey = page.locator('.sd-mic-key')
  const micButton = micKey

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
  const micButton = micKey
  await micButton.dispatchEvent('pointerdown')
  await expect(micKey).toHaveClass(/mic-live/, { timeout: 500 })

  await micButton.dispatchEvent('pointercancel')
  await expect(micKey).not.toHaveClass(/mic-live/, { timeout: 500 })
})

test('command mic deactivates when a mode transition removes the held key', async ({ page }) => {
  await openStreamdeck(page, 'writable')
  await page.locator('.sd-key:not(.is-empty)').first().click()

  const micKey = page.locator('.sd-mic-key')
  const micButton = micKey
  await micButton.dispatchEvent('pointerdown')
  await expect(micKey).toHaveClass(/mic-live/, { timeout: 500 })

  await page.locator('.sd-knob').first().click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'grid')

  await page.locator('.sd-key:not(.is-empty)').first().click()
  await expect(page.locator('.sd-device')).toHaveAttribute('data-mode', 'cmd')
  await expect(page.locator('.sd-mic-key')).not.toHaveClass(/mic-live/, { timeout: 500 })
})
