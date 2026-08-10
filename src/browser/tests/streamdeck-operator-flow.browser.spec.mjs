import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

// SP-401: the per-mode Stream Deck specs each verify their own slice. This file
// verifies that the slices compose into a surface an operator can drive end to
// end — page the grid, take a real agent control, read its logs, and back out
// to where they started. It fails when any single step of that flow regresses,
// not merely when the page fails to render.

const CONTROLLED = '1352'
// docs/design/streamdeck/README.md, "cmd": the eight key slots become four
// commands and four blanks — Pause, Prioritize, Logs, Mic. Slot 1 "toggles to
// Play, when `control === "Paused"`", so the word it carries is the agent's live
// state and the operator reads the action the key will actually take. This spec
// asserts the designed command set, not whichever placeholder renders today.
const cmdCommands = (slotOne) => [slotOne, 'Prioritize', 'Logs', 'Mic']

async function openStreamdeck(page) {
  await page.goto('/auth/read_only')
  await page.goto('/')
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

// The design puts the commands on the key slots, so SP-202 moves them out of
// `#sd-cmd-view` and onto `#sd-keys`. Both carry `data-mode-view="cmd"` and label
// each command with `.sd-cmd-label`, which is the part the operator reads.
function commandLabels(page) {
  return page.locator('[data-mode-view="cmd"] .sd-cmd-label').allInnerTexts()
}

// Everything cmd mode owes the operator, asserted through the parts the design
// names rather than the markup that happens to carry them today.
//
// The identity check is the design's, from README "Touch strip": in `cmd` "the
// pager segment relabels to `CONTROLLING` with the agent's number". Both halves
// are asserted — the relabel and the number — so this stays a proof that the
// operator can read who they are controlling. SP-302 moves that relabel onto the
// full-width cmd panel, which is still inside `#sd-screen`, so the strip is the
// stable place to read it from.
//
// The grid check is also the design's, from README "cmd": "the eight key slots
// become four commands and four blanks". The keys therefore survive cmd mode —
// what must be gone is the *agent* grid, and `data-grid-page` is the attribute
// that only the agent grid carries.
async function expectControllingCmd(page, device, slotOne) {
  await expect(device).toHaveAttribute('data-mode', 'cmd')
  await expect(device).toHaveAttribute('data-controlling', CONTROLLED)

  const screen = page.locator('#sd-screen')
  await expect(screen).toContainText('CONTROLLING')
  await expect(screen).toContainText(`#${CONTROLLED}`)

  await expect(page.locator('#sd-keys[data-grid-page]')).toHaveCount(0)
  expect(await commandLabels(page)).toEqual(cmdCommands(slotOne))
}

// The scroll state the operator drives lives in the LiveView's `@logs` assigns.
// Which element renders it is per-mode-ticket territory — the design moves the
// event window onto the keys and the transcript onto the strip — so read it from
// the device root, the one element every mode keeps.
async function logOffset(device, name) {
  return Number.parseInt(await device.getAttribute(`data-log-${name}`), 10)
}

// Free dial turns move the column offset without landing on a window boundary,
// so return to the opening window by pressing dial D — which snaps to a whole
// window — until the operator is looking at the keys they started on. One full
// lap of `windows` presses is always enough because a press wraps.
async function cycleToOpeningWindow(page, keys, openingPage) {
  const windows = Number.parseInt(await keys.getAttribute('data-grid-page-count'), 10)

  for (let attempt = 0; attempt <= windows; attempt += 1) {
    const current = await visibleIdentifiers(page)
    if (current.join() === openingPage.join()) return

    // Wait for the press to land before reading the grid again: an unsettled
    // read would compare the previous window and overshoot the target.
    const before = Number.parseInt(await keys.getAttribute('data-grid-page'), 10)
    await dial(page, 3).click()
    await expect(keys).toHaveAttribute('data-grid-page', String((before + 1) % windows))
  }

  expect(await visibleIdentifiers(page)).toEqual(openingPage)
}

test('operator drives grid → paged grid → cmd with a real pause/resume → logs → back to the grid it started on', async ({ page }) => {
  await openStreamdeck(page)

  const device = page.locator('.sd-device')
  const keys = page.locator('#sd-keys')
  const pager = page.locator('[data-segment="pager"]')
  const dialA = dial(page, 0)
  const dialD = dial(page, 3)
  const controlled = page.locator(`#sd-keys [data-streamdeck-identifier="${CONTROLLED}"]`)

  // ---------------------------------------------------------------- step 2 --
  // The grid opens on real, bucketed fleet state: the alert agent leads the
  // canonical bucket order, and the running agent offers a pause.
  await expect(device).toHaveAttribute('data-mode', 'grid')
  await expect(keys).toHaveAttribute('data-grid-page', '0')

  const windows = Number.parseInt(await keys.getAttribute('data-grid-page-count'), 10)
  expect(windows).toBeGreaterThan(1)
  await expect(pager.locator('.sd-pager-dot')).toHaveCount(windows)
  await expect(pager.locator('[aria-current="page"]')).toHaveAttribute('data-pager-page', '0')

  const openingPage = await visibleIdentifiers(page)
  // The first window holds the head of the canonical bucket order, so every
  // non-queued bucket is represented by the agent the fixture fleet gave it.
  await expect(page.locator('#sd-keys [data-streamdeck-identifier="1331"]')).toHaveClass(/st-alert/)
  await expect(page.locator('#sd-keys [data-streamdeck-identifier="1338"]')).toHaveClass(/st-stuck/)
  await expect(page.locator('#sd-keys [data-streamdeck-identifier="1345"]')).toHaveClass(/st-paused/)
  await expect(controlled).toHaveClass(/st-running/)
  await expect(controlled).toHaveAttribute('data-control-action', 'pause')

  // ---------------------------------------------------------------- step 3 --
  // Page with dial D by drag, then wheel and keyboard, then press to cycle.
  await dragDial(page, dialD, [-90, 0, 90, 126])
  await expect(keys).toHaveAttribute('data-grid-page', '1')
  await expect(pager.locator('[aria-current="page"]')).toHaveAttribute('data-pager-page', '1')
  expect(await visibleIdentifiers(page)).not.toEqual(openingPage)

  // The knob writes its own `aria-valuenow` client-side before it notifies the
  // server, so that attribute alone would stay green with the grid-page round
  // trip deleted. `data-grid-dial-value` is the server's echo of the value the
  // dial pushed, so assert the wheel and the keyboard each reach the fleet.
  const afterDrag = await dialValue(dialD)
  const echoAfterDrag = await gridDialEcho(keys)
  await dialD.hover()
  await page.mouse.wheel(0, 100)
  await expect.poll(() => dialValue(dialD)).toBeLessThan(afterDrag)
  await expect(keys).toHaveAttribute('data-grid-dial-value', String(await dialValue(dialD)))
  expect(await gridDialEcho(keys)).toBeLessThan(echoAfterDrag)

  const afterWheel = await dialValue(dialD)
  const echoAfterWheel = await gridDialEcho(keys)
  // Arrow keys are the accessible route into paging, so prove that leg reaches
  // the server too rather than only redrawing the knob.
  await dialD.focus()
  await page.keyboard.press('ArrowDown')
  await expect.poll(() => dialValue(dialD)).toBeLessThan(afterWheel)
  await expect(keys).toHaveAttribute('data-grid-dial-value', String(await dialValue(dialD)))
  expect(await gridDialEcho(keys)).toBeLessThan(echoAfterWheel)

  // A press is not a turn: it cycles the window and leaves the mode alone.
  const pageBeforePress = Number.parseInt(await keys.getAttribute('data-grid-page'), 10)
  await dialD.click()
  await expect(device).toHaveAttribute('data-mode', 'grid')
  await expect(keys).toHaveAttribute('data-grid-page', String((pageBeforePress + 1) % windows))
  await expect(pager.locator('[aria-current="page"]')).toHaveAttribute(
    'data-pager-page',
    String((pageBeforePress + 1) % windows)
  )

  await cycleToOpeningWindow(page, keys, openingPage)

  // ---------------------------------------------------------------- step 4 --
  // Press the running agent's key: it enters cmd mode and pauses the agent.
  await controlled.click()
  // The press pauses the agent on its way into cmd, so slot 1 must already offer
  // Play: the operator is looking at the state their own press just produced.
  await expectControllingCmd(page, device, 'Play')

  // Back out and confirm the fleet itself moved — the agent is now bucketed as
  // paused and its key offers resume. Feedback text alone would not prove this.
  await dialA.click()
  await expect(device).toHaveAttribute('data-mode', 'grid')
  await expect(controlled).toHaveClass(/st-paused/)
  await expect(controlled).toHaveAttribute('data-control-action', 'resume')

  // Resume from the same key. The press both resumes the agent and re-enters
  // cmd, so the operator continues into logs from here rather than pressing the
  // key a third time — another press would toggle the control straight back.
  await controlled.click()
  // ...and this press resumed it, so the same slot has swung back to Pause.
  await expectControllingCmd(page, device, 'Pause')

  // ---------------------------------------------------------------- step 5 --
  // Descend from cmd into the focused agent's logs.
  await dialD.click()
  await expect(device).toHaveAttribute('data-mode', 'logs')
  await expect(device).toHaveAttribute('data-controlling', CONTROLLED)

  // Both windows start at their real top bound.
  await expect(device).toHaveAttribute('data-log-events-offset', '0')
  await expect(device).toHaveAttribute('data-log-transcript-offset', '0')
  await expect(page.locator('#sd-transcript-hint-up')).toHaveAttribute('aria-hidden', 'true')

  // Dial D scrolls the event window; dial A scrolls the transcript. They are
  // separate windows, so moving one must leave the other where it was.
  await dialD.hover()
  await page.mouse.wheel(0, -100)
  await expect(device).toHaveAttribute('data-log-events-offset', '1')
  await expect(device).toHaveAttribute('data-log-transcript-offset', '0')

  // Each wheel notch is one discrete step, so overshoot the window deliberately:
  // the offset clamps to the real bound rather than running past it.
  const eventsMax = await logOffset(device, 'events-max-offset')
  expect(eventsMax).toBeGreaterThan(0)
  for (let step = 0; step < eventsMax + 3; step += 1) {
    await page.mouse.wheel(0, -100)
  }
  await expect(device).toHaveAttribute('data-log-events-offset', String(eventsMax))

  await dialA.hover()
  await page.mouse.wheel(0, -100)
  await expect(device).toHaveAttribute('data-log-transcript-offset', '1')
  // The hint arrow is state, not decoration (README, "Touch strip"): off the top
  // bound it has somewhere to point, and at the bottom bound it does not.
  await expect(page.locator('#sd-transcript-hint-up')).toHaveAttribute('aria-hidden', 'false')

  // The transcript clamps at its own, different bound.
  const transcriptMax = await logOffset(device, 'transcript-max-offset')
  expect(transcriptMax).toBeGreaterThan(0)
  for (let step = 0; step < transcriptMax + 3; step += 1) {
    await page.mouse.wheel(0, -100)
  }
  await expect(device).toHaveAttribute('data-log-transcript-offset', String(transcriptMax))
  await expect(page.locator('#sd-transcript-hint-down')).toHaveAttribute('aria-hidden', 'true')

  // ---------------------------------------------------------------- step 6 --
  // Dial A backs out to cmd, then to the grid the operator started on.
  await dialA.click()
  await expect(device).toHaveAttribute('data-mode', 'cmd')
  await dialA.click()
  await expect(device).toHaveAttribute('data-mode', 'grid')

  await expect(keys).toHaveAttribute('data-grid-page', '0')
  await expect(pager.locator('[aria-current="page"]')).toHaveAttribute('data-pager-page', '0')
  await expect(pager.locator('.sd-pager-dot')).toHaveCount(windows)
  // The resume actually took: the agent is running again and the fleet has
  // re-sorted back into the exact window the operator started on.
  await expect(controlled).toHaveClass(/st-running/)
  await expect(controlled).toHaveAttribute('data-control-action', 'pause')
  expect(await visibleIdentifiers(page)).toEqual(openingPage)
})
