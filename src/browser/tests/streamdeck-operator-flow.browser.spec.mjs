import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

// SP-401: the per-mode Stream Deck specs each verify their own slice. This file
// verifies that the slices compose into a surface an operator can drive end to
// end — page the grid, take a real agent control, read its logs, and back out
// to where they started. It fails when any single step of that flow regresses,
// not merely when the page fails to render.

const CONTROLLED = '1352'
// The design's cmd slots are Pause / Logs / Mic / Settings. Pause is the only
// one that relabels from the agent's real state, so asserting both variants is
// what proves the labels track the fleet rather than being a fixed list.
const CMD_COMMANDS_RUNNING = ['Pause', 'Priority up', 'Priority down', 'Commands', 'Open PR', 'Dashboard', 'Mic', 'Settings']
const CMD_COMMANDS_PAUSED = ['Play', 'Priority up', 'Priority down', 'Commands', 'Open PR', 'Dashboard', 'Mic', 'Settings']

async function openStreamdeck(page) {
  await page.goto('/auth/read_only')
  await page.goto('/route-shell')
  await page.context().setHTTPCredentials(dashboardCredentials)
  // Taking a real agent control needs a writable dashboard. This fixture server
  // belongs to this spec alone, so opting in here cannot leak into other specs.
  const control = await page.goto('/streamdeck-control/writable')
  expect(control.status()).toBe(200)
  await page.goto('/streamdeck')
  await expect(page.locator('#streamdeck-page')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
}

function dial(page, index) {
  return page.locator('.sd-knob').nth(index)
}

async function dragDial(page, knob, angles) {
  // `page.mouse` takes viewport coordinates and does no scrolling of its own,
  // unlike `hover()`/`click()`. The deck sits below the route heading, so
  // without this the drag is dispatched off-screen and the dial never moves.
  // The nudge clears the sticky topbar, which the minimal scroll can otherwise
  // leave the dial flush underneath.
  await knob.scrollIntoViewIfNeeded()
  await knob.evaluate((element) => {
    const topbar = document.querySelector('header.ax-top')
    if (!topbar) return

    const overlap = topbar.getBoundingClientRect().bottom - element.getBoundingClientRect().top
    if (overlap > 0) window.scrollBy(0, -overlap - 8)
  })

  const box = await knob.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2
  const radius = Math.min(box.width, box.height) / 3
  const point = (degrees) => {
    const radians = (degrees * Math.PI) / 180
    return { x: cx + Math.cos(radians) * radius, y: cy + Math.sin(radians) * radius }
  }

  await page.mouse.move(...Object.values(point(angles[0])))
  await page.mouse.down()
  for (const degrees of angles.slice(1)) {
    await page.mouse.move(...Object.values(point(degrees)))
  }
  await page.mouse.up()
}

function visibleIdentifiers(page) {
  return page.locator('#sd-keys .sd-key').evaluateAll((keys) =>
    keys.map((key) => (key.classList.contains('is-empty') ? null : key.getAttribute('data-streamdeck-identifier')))
  )
}

async function dialValue(knob) {
  return Number.parseInt(await knob.getAttribute('aria-valuenow'), 10)
}

// The server's echo of the dial value it was last pushed. Unlike the knob's own
// `aria-valuenow`, this only moves when `grid-page` actually reaches the
// LiveView, so it distinguishes a real round trip from a client-side redraw.
async function gridDialEcho(keys) {
  return Number.parseInt(await keys.getAttribute('data-grid-dial-value'), 10)
}

// Cmd mode fills the key grid itself, so the labels live on the command keys
// inside `#sd-keys` rather than in a parallel list beside it.
function commandLabels(page) {
  return page.locator('#sd-keys [data-streamdeck-command]').evaluateAll((nodes) => nodes.map((node) => node.getAttribute('aria-label')))
}

// Ticket mode fills the eight key slots with actions. So
// the key grid survives the mode switch and the agent faces do not: assert the
// slot shape rather than the absence of `#sd-keys`.
async function expectCommandSurface(keys, expectedLabels, page) {
  await expect(keys).toHaveAttribute('data-mode-view', 'cmd')
  await expect(keys.locator('.sd-cmd-key:not(.is-empty)')).toHaveCount(8)
  await expect(keys.locator('.sd-cmd-key.is-empty')).toHaveCount(0)
  // Every painted slot has an action; unavailable actions are disabled.
  await expect(keys.locator('.sd-cmd-key.is-empty[aria-hidden="true"]')).toHaveCount(0)
  await expect(keys.locator('.sd-cmd-key.is-empty[disabled]')).toHaveCount(0)
  // No agent grid is left behind under the commands.
  await expect(keys).not.toHaveAttribute('data-grid-page', /.*/)
  await expect.poll(() => commandLabels(page)).toEqual(expectedLabels)
}

// Return to the opening window with reverse turns. Dial D press cycles views;
// paging turns clamp at the first and last windows instead of wrapping.
async function cycleToOpeningWindow(page, keys, openingPage) {
  const windows = Number.parseInt(await keys.getAttribute('data-grid-page-count'), 10)

  for (let attempt = 0; attempt <= windows; attempt += 1) {
    const current = await visibleIdentifiers(page)
    if (current.join() === openingPage.join()) return

    // Wait for the turn to land before reading the grid again: an unsettled
    // read would compare the previous window and overshoot the target.
    const before = Number.parseInt(await keys.getAttribute('data-grid-page'), 10)
    await dial(page, 3).press('ArrowDown')
    await expect(keys).toHaveAttribute('data-grid-page', String(Math.max(0, before - 1)))
  }

  expect(await visibleIdentifiers(page)).toEqual(openingPage)
}

test('operator drives grid → paged grid → cmd with a real pause/resume → logs → back to the grid it started on', async ({ page }) => {
  await openStreamdeck(page)

  const device = page.locator('.sd-device')
  const keys = page.locator('#sd-keys')
  const pager = page.locator('[data-streamdeck-region="600"]')
  const dialA = dial(page, 0)
  const dialD = dial(page, 3)
  const controlled = page.locator(`#sd-keys [data-streamdeck-identifier="${CONTROLLED}"]`)

  // ---------------------------------------------------------------- step 2 --
  // Ticket attention order leads with the error, followed by the command.
  // Control metadata still lets the running agent offer a pause.
  await expect(device).toHaveAttribute('data-mode', 'grid')
  await expect(keys).toHaveAttribute('data-grid-page', '0')

  const windows = Number.parseInt(await keys.getAttribute('data-grid-page-count'), 10)
  expect(windows).toBeGreaterThan(1)
  await expect(pager).toHaveAttribute('aria-label', 'Queued 15; Not queued 0')
  await expect(pager.locator('circle[data-page="0"]')).toHaveAttribute('fill', '#9fd0ff')
  await expect(keys).toHaveAttribute('data-grid-page', '0')

  const openingPage = await visibleIdentifiers(page)
  await expect(keys.locator('.sd-key:not(.is-empty)').first()).toHaveAttribute('data-streamdeck-identifier', '1338')
  await expect(keys.locator('[data-streamdeck-identifier="1331"]')).toHaveAttribute('aria-label', /Awaiting command/)
  // Build states drive ordering and labels; fleet metadata retains control buckets.
  await expect(page.locator('#sd-keys [data-streamdeck-identifier="1331"]')).toHaveAttribute('data-streamdeck-state', 'alert')
  await expect(page.locator('#sd-keys [data-streamdeck-identifier="1338"]')).toHaveAttribute('data-streamdeck-state', 'stuck')
  await expect(page.locator('#sd-keys [data-streamdeck-identifier="1345"]')).toHaveAttribute('data-streamdeck-state', 'paused')
  await expect(controlled).toHaveAttribute('data-streamdeck-state', 'running')
  await expect(controlled).toHaveAttribute('data-control-action', 'pause')

  // ---------------------------------------------------------------- step 3 --
  // Page with dial D by drag, wheel and keyboard; press is reserved for views.
  await dragDial(page, dialD, [-90, 0, 90, 126])
  await expect(keys).toHaveAttribute('data-grid-page', '1')
  await expect(pager).toHaveAttribute('aria-label', 'Queued 15; Not queued 0')
  await expect(pager.locator('circle[data-page="1"]')).toHaveAttribute('fill', '#9fd0ff')
  expect(await visibleIdentifiers(page)).not.toEqual(openingPage)

  await dialD.hover()
  await page.mouse.wheel(0, 100)
  await expect(keys).toHaveAttribute('data-grid-page', '0')
  await dialD.press('ArrowUp')
  await expect(keys).toHaveAttribute('data-grid-page', '1')
  await dialD.press('ArrowUp')
  await expect(keys).toHaveAttribute('data-grid-page', '2')
  await cycleToOpeningWindow(page, keys, openingPage)

  // ---------------------------------------------------------------- step 4 --
  // Press the running agent's key: it enters cmd mode and pauses the agent.
  await controlled.click()
  await expect(device).toHaveAttribute('data-mode', 'cmd')
  // SD-303 replaces the Command summary and pager with one full-width chat
  // region. This fixture has no available conversation source, so the strip
  // names that state rather than showing an empty panel that looks live.
  const chat = page.locator('[data-mode-view="cmd-strip"] [data-streamdeck-region="0"]')
  await expect(page.locator('[data-mode-view="cmd-strip"] [data-streamdeck-region]')).toHaveCount(1)
  await expect(chat).toHaveCSS('width', '800px')
  await expect(chat).toHaveAttribute('aria-label', 'Conversation unavailable')
  await expect(chat).toContainText('Conversation unavailable')
  // Cmd mode replaces the key faces, it does not merely relabel the strip: the
  // operator is looking at the command set. The press already paused the agent,
  // so the first slot offers the resume rather than a second pause.
  await expectCommandSurface(keys, CMD_COMMANDS_PAUSED, page)

  // Back out and confirm the fleet itself moved — the agent is now bucketed as
  // paused and its key offers resume. Feedback text alone would not prove this.
  await dialA.click()
  await expect(device).toHaveAttribute('data-mode', 'grid')
  await expect(controlled).toHaveAttribute('data-streamdeck-state', 'paused')
  await expect(controlled).toHaveAttribute('data-control-action', 'resume')

  // Resume from the same key. The press both resumes the agent and re-enters
  // cmd, so the operator continues into logs from here rather than pressing the
  // key a third time — another press would toggle the control straight back.
  await controlled.click()
  await expect(device).toHaveAttribute('data-mode', 'cmd')
  // Resuming reopens the same full-width conversation strip.
  await expect(page.locator('[data-mode-view="cmd-strip"] [data-streamdeck-region]')).toHaveCount(1)
  await expect(chat).toHaveCSS('width', '800px')
  await expect(chat).toHaveAttribute('aria-label', 'Conversation unavailable')
  await expect(chat).toContainText('Conversation unavailable')
  // The resume landed before this render, so the same slot has flipped back to
  // Pause — the label is reading real state, not a fixed list.
  await expectCommandSurface(keys, CMD_COMMANDS_RUNNING, page)

  // ---------------------------------------------------------------- step 5 --
  // Descend from cmd into the focused agent's logs.
  await dialD.click()
  await expect(device).toHaveAttribute('data-mode', 'logs')
  await expect(page.locator('#sd-logs-view')).toHaveAttribute('data-focused-identifier', CONTROLLED)

  // Both surfaces open at the *live* end — the right-hand end of a chat — not
  // at the ticket's first line. The event window is the eight keys; the
  // transcript is the touch strip itself.
  const events = page.locator('#sd-log-keys')
  const transcript = page.locator('#sd-screen')
  const eventsMax = Number.parseInt(await events.getAttribute('data-max-offset'), 10)
  const transcriptMax = Number.parseInt(
    await transcript.getAttribute('data-transcript-max-offset'),
    10
  )
  expect(eventsMax).toBeGreaterThan(0)
  expect(transcriptMax).toBeGreaterThan(0)
  await expect(events).toHaveAttribute('data-offset', String(eventsMax))
  await expect(transcript).toHaveAttribute('data-transcript-offset', String(transcriptMax))
  await expect(page.locator('#sd-transcript-hint-down')).toHaveAttribute('aria-hidden', 'true')
  // LIVE is the last key, and it is the active one on arrival.
  await expect(events.locator('.sd-live-key')).toHaveAttribute('aria-label', 'LIVE')
  await expect(events.locator('.sd-live-key')).toHaveAttribute('aria-current', 'true')

  // Selecting a log event: pressing an event key makes it active, moves the
  // strip to that event's own header, and deactivates LIVE. The selection is
  // read from the server-rendered `aria-current`, not a client-local attribute.
  const pressed = events.locator('.sd-log-key:not(.sd-live-key)').last()
  await pressed.click()
  await expect(pressed).toHaveAttribute('aria-current', 'true')
  await expect(events.locator('.sd-live-key')).toHaveAttribute('aria-current', 'false')
  await expect(transcript).not.toHaveAttribute('data-transcript-offset', String(transcriptMax))
  await expect(page.locator('[data-log-kind="evhdr"]').first()).toBeVisible()

  // Returning to LIVE reverses it: back to the newest end, LIVE active again.
  await events.locator('.sd-live-key').click()
  await expect(transcript).toHaveAttribute('data-transcript-offset', String(transcriptMax))
  await expect(events.locator('.sd-live-key')).toHaveAttribute('aria-current', 'true')

  // Dial D scrolls the event window; dial A scrolls the transcript. Both open
  // at their far end, so a notch backwards is the move that has anywhere to go.
  await dialD.hover()
  await page.mouse.wheel(0, 100)
  await expect(events).toHaveAttribute('data-offset', String(eventsMax - 1))
  await expect(transcript).toHaveAttribute('data-transcript-offset', String(transcriptMax))

  // Each wheel notch is one discrete step, so overshoot deliberately: the
  // offset clamps at the real bound rather than running past the origin.
  for (let step = 0; step < eventsMax + 3; step += 1) {
    await page.mouse.wheel(0, 100)
  }
  await expect(events).toHaveAttribute('data-offset', '0')
  // Paged fully left, the origin anchor is the first key — and LIVE stays
  // pinned to the last (bottom-right) key rather than scrolling away.
  await expect(events.locator('[data-log-event-index="0"]')).toHaveCount(1)
  await expect(events.locator('.sd-live-key')).toHaveCount(1)
  await expect(events.locator('.sd-key').last()).toHaveClass(/sd-live-key/)

  await dialA.hover()
  await page.mouse.wheel(0, 100)
  await expect(transcript).toHaveAttribute('data-transcript-offset', String(transcriptMax - 1))
  await expect(page.locator('#sd-transcript-hint-down')).toHaveAttribute('aria-hidden', 'false')

  // The transcript clamps at its own, different bound.
  for (let step = 0; step < transcriptMax + 3; step += 1) {
    await page.mouse.wheel(0, 100)
  }
  await expect(transcript).toHaveAttribute('data-transcript-offset', '0')
  await expect(page.locator('#sd-transcript-hint-up')).toHaveAttribute('aria-hidden', 'true')

  // ---------------------------------------------------------------- step 6 --
  // Dial A backs out to cmd, then to the grid the operator started on.
  await dialA.click()
  await expect(device).toHaveAttribute('data-mode', 'cmd')
  await dialA.click()
  await expect(device).toHaveAttribute('data-mode', 'grid')

  await expect(keys).toHaveAttribute('data-grid-page', '0')
  await expect(keys).toHaveAttribute('data-grid-page', '0')
  await expect(pager).toHaveAttribute('aria-label', 'Queued 15; Not queued 0')
  await expect(pager.locator('circle[data-page="0"]')).toHaveAttribute('fill', '#9fd0ff')
  // The resume actually took: the agent is running again and the fleet has
  // re-sorted back into the exact window the operator started on.
  await expect(controlled).toHaveAttribute('data-streamdeck-state', 'running')
  await expect(controlled).toHaveAttribute('data-control-action', 'pause')
  expect(await visibleIdentifiers(page)).toEqual(openingPage)
})
