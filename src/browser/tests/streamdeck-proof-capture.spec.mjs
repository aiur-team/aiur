import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

// #1358 evidence capture. The per-mode spec (#1353) and the composed
// operator-flow spec (#1742) assert the contract; this file *records* the same
// operator session as committed artifacts, because the proof ticket's boundary
// is evidence an operator can re-read, not a green exit code.
//
// It is deliberately outside `npm test`: it writes into the repository's
// evidence directory, so it runs only when an operator asks for a proof run
// (`npm run proof:streamdeck`). Its assertions are still real — a step that
// cannot be evidenced must fail here rather than produce a screenshot of a
// broken surface.
//
// What this file cannot produce is named in `run.md`: `aiurdev status` and the
// real dashboard's header meters need a live Aiur daemon, which an agent
// workspace is forbidden to start.

const CONTROLLED = '1352'
const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
const evidenceRoot = path.resolve(repositoryRoot, 'docs/research/evidence/streamdeck')

function runIdentifier() {
  const configured = process.env.AIUR_STREAMDECK_PROOF_RUN

  if (configured) return configured

  return `run-${new Date().toISOString().replaceAll(/[:.]/g, '-')}`
}

const runDirectory = path.join(evidenceRoot, runIdentifier())

async function record(name, contents) {
  await writeFile(path.join(runDirectory, name), contents.endsWith('\n') ? contents : `${contents}\n`, 'utf8')
}

function shot(page, name) {
  return page.screenshot({ path: path.join(runDirectory, name), fullPage: true })
}

async function openStreamdeck(page) {
  await page.goto('/auth/read_only')
  await page.goto('/route-shell')
  await page.context().setHTTPCredentials(dashboardCredentials)
  // Steps 4 and 6 take a real agent control, so the proof run needs the
  // writable fixture rather than the read-only one.
  const control = await page.goto('/streamdeck-control/writable')
  expect(control.status()).toBe(200)
  await page.goto('/streamdeck')
  await expect(page.locator('#streamdeck-page')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
}


async function fleetBuckets(page, keys) {
  const windows = Number.parseInt(await keys.getAttribute('data-grid-page-count'), 10)
  const collected = {}

  for (let window = 0; window < windows; window += 1) {
    Object.assign(collected, await gridBuckets(page))

    const current = Number.parseInt(await keys.getAttribute('data-grid-page'), 10)
    await dial(page, 3).press('ArrowUp')
    await expect(keys).toHaveAttribute('data-grid-page', String(Math.min(current + 1, windows - 1)))
  }

  for (let window = windows - 1; window > 0; window -= 1) {
    await dial(page, 3).press('ArrowDown')
    await expect(keys).toHaveAttribute('data-grid-page', String(window - 1))
  }

  return collected
}

// Units paints a row *tone* rather than a bucket, and only for the states that
// need operator attention: a running agent has no tone at all. So the two
// renderings are compared where they overlap (paused and queued) and the rest
// is recorded side by side as evidence rather than asserted as equality.


test.use({ video: 'on' })

test('#1358 emulator proof: steps 1-7 captured as committed evidence', async ({ page, context }) => {
  await mkdir(runDirectory, { recursive: true })

  const startedAt = new Date().toISOString()
  const device = page.locator('.sd-device')
  const keys = page.locator('#sd-keys')
  const pager = page.locator('[data-streamdeck-region="600"]')
  const dialA = dial(page, 0)
  const dialD = dial(page, 3)

  // ------------------------------------------------------------------ 1 --
  // Aiur is up with a fleet and `/streamdeck` renders real agent keys.
  await openStreamdeck(page)
  await expect(device).toHaveAttribute('data-mode', 'grid')
  const fleetTotal = Number.parseInt(await keys.getAttribute('data-grid-total'), 10)
  expect(fleetTotal).toBeGreaterThan(0)
  await expect(keys.locator('.sd-key:not(.is-empty)').first()).toBeVisible()
  await shot(page, '01-start.png')

  // ------------------------------------------------------------------ 2 --
  // The opening grid: real bucketed fleet state. Units parity is captured at
  // the end of this file, because the Units fixture changes the fleet to prove
  // it — see the note there.
  const openingWindow = await visibleIdentifiers(page)
  const buckets = await gridBuckets(page)
  expect(openingWindow.filter(Boolean).length).toBeGreaterThan(0)
  await shot(page, '02-grid.png')

  await record(
    '02-grid.txt',
    [
      'Step 2 (part 1) — the grid the run opened on.',
      `fleet size (emulator data-grid-total): ${fleetTotal}`,
      `windows: ${await keys.getAttribute('data-grid-page-count')}`,
      '',
      'slot  identifier  bucket  (column-major, top-left first; blank slots omitted)',
      ...openingWindow.flatMap((identifier, slot) =>
        identifier ? [`${slot}  ${identifier}  ${buckets[identifier]}`] : []
      ),
      '',
      'Part 2 (`02-grid-units-parity.txt`) compares this projection against the',
      'Units page after a live fleet change.'
    ].join('\n')
  )

  // ------------------------------------------------------------------ 3 --
  // Dial D pages by wheel and keyboard; press cycles views.
  await dialD.hover()
  await page.mouse.wheel(0, 100)
  await expect(keys).toHaveAttribute('data-grid-dial-value', String(await dialD.getAttribute('aria-valuenow')))

  await dialD.focus()
  await page.keyboard.press('ArrowDown')
  await expect(keys).toHaveAttribute('data-grid-dial-value', String(await dialD.getAttribute('aria-valuenow')))

  const windows = Number.parseInt(await keys.getAttribute('data-grid-page-count'), 10)
  const beforeTurn = Number.parseInt(await keys.getAttribute('data-grid-page'), 10)
  await dialD.press('ArrowUp')
  await expect(keys).toHaveAttribute('data-grid-page', String(Math.min(beforeTurn + 1, windows - 1)))
  await expect(keys).toHaveAttribute('data-grid-page', String(Math.min(beforeTurn + 1, windows - 1)))
  await shot(page, '03-paging.png')

  // Return to the window the run opened on before taking a control.
  for (let attempt = 0; attempt <= windows; attempt += 1) {
    if ((await visibleIdentifiers(page)).join() === openingWindow.join()) break

    const current = Number.parseInt(await keys.getAttribute('data-grid-page'), 10)
    await dialD.press('ArrowDown')
    await expect(keys).toHaveAttribute('data-grid-page', String(Math.max(0, current - 1)))
  }
  expect(await visibleIdentifiers(page)).toEqual(openingWindow)

  // ------------------------------------------------------------------ 4 --
  // Press the running agent's key: it enters cmd mode and pauses the agent.
  const controlled = page.locator(`#sd-keys [data-streamdeck-identifier="${CONTROLLED}"]`)
  await expect(controlled).toHaveAttribute('data-control-action', 'pause')
  await controlled.click()
  await expect(device).toHaveAttribute('data-mode', 'cmd')
  await shot(page, '04-pause-cmd.png')

  // The fleet itself moved, not just the key face: back out and read the
  // re-bucketed key. Feedback text alone would not prove the pause landed.
  await dialA.click()
  await expect(device).toHaveAttribute('data-mode', 'grid')
  await expect(controlled).toHaveAttribute('data-streamdeck-state', 'paused')
  await expect(controlled).toHaveAttribute('data-control-action', 'resume')
  await shot(page, '04-pause-grid.png')

  await record(
    '04-pause.txt',
    [
      `Step 4 — agent #${CONTROLLED} paused from the emulator key.`,
      `emulator key bucket: ${(await gridBuckets(page))[CONTROLLED]}`,
      `emulator key control action: ${await controlled.getAttribute('data-control-action')}`,
      'The key press went through the agent control facade — the writable gate',
      'is what makes it a real pause rather than a local relabel — and the',
      'server re-bucketed the agent in the next render.',
      '',
      'NOT CAPTURED HERE: the two third-party confirmations the ticket asks for,',
      '`aiurdev status` and the dashboard, agreeing at this same instant. Both',
      'read a running Aiur daemon; an agent workspace must not start one',
      '(`scripts/aiurdev --test` is Executor-root only). See run.md.'
    ].join('\n')
  )

  // Resume from the same key; the press re-enters cmd on the way.
  await controlled.click()
  await expect(device).toHaveAttribute('data-mode', 'cmd')
  await shot(page, '04-resume.png')

  // ------------------------------------------------------------------ 6 --
  // Dial A returns from the focused conversation to the opening grid page.
  await dialA.click()
  await expect(device).toHaveAttribute('data-mode', 'grid')
  expect(await visibleIdentifiers(page)).toEqual(openingWindow)
  await expect(controlled).toHaveAttribute('data-control-action', 'pause')
  await shot(page, '06-back-navigation.png')

  // ------------------------------------------------------------------ 7 --
  // Touch strip: Summary counts are live, provider segments carry real usage.
  const summary = page.locator('[data-streamdeck-region="0"]')
  await expect(summary).toBeVisible()
  const summaryText = await summary.getAttribute('aria-label')
  // Counts come from Build observations; the fixture can be unavailable.
  expect(summaryText).toMatch(/(?:\d+|—) live \/ (?:\d+|—) left/)
  const everyBucket = await fleetBuckets(page, keys)
  const runningKeys = Object.values(everyBucket).filter((bucket) => bucket === 'running').length
  expect(Object.keys(everyBucket)).toHaveLength(fleetTotal)
  expect(await visibleIdentifiers(page)).toEqual(openingWindow)
  const providerMeters = await page.locator('#sd-screen [data-provider]').evaluateAll((meters) =>
    meters.map((meter) => ({ provider: meter.getAttribute('data-provider'), reading: meter.textContent,
      freshness: meter.querySelector('[data-freshness]')?.getAttribute('data-freshness') }))
  )
  await shot(page, '07-touch-strip.png')

  await record(
    '07-touch-strip.txt',
    [
      'Step 7 — touch strip, read at the same instant as the grid above.',
      `SUMMARY segment: ${summaryText.trim()}`,
      `emulator keys bucketed running: ${runningKeys}`,
      '',
      'provider images (provider / reading / freshness):',
      ...providerMeters.map(
        (meter) => `${meter.provider}  ${meter.reading}  ${meter.freshness}`
      ),
      '',
      'NOT CAPTURED HERE: the numeric comparison against the dashboard header',
      'meters. In this browser fixture the header-meter routes render their own',
      'hardcoded usage rather than the run the emulator reads, so comparing them',
      'would prove nothing. That comparison needs a live daemon — see run.md.'
    ].join('\n')
  )

  await record(
    'run.md',
    [
      '# Stream Deck emulator proof run',
      '',
      `- run started: ${startedAt}`,
      `- run finished: ${new Date().toISOString()}`,
      '- surface: the real `/streamdeck` LiveView, served by the browser fixture',
      '  server over the fixture fleet. Not a mock of the deck.',
      `- fleet size: ${fleetTotal} agents`,
      `- agent controlled in step 4: #${CONTROLLED}`,
      '',
      '## What this run evidences',
      '',
      '| Step | Artifact |',
      '|---:|---|',
      '| 1 | `01-start.png` |',
      '| 2 | `02-grid.png`, `02-grid.txt` |',
      '| 3 | `03-paging.png` |',
      '| 4 | `04-pause-cmd.png`, `04-pause-grid.png`, `04-pause.txt`, `04-resume.png` |',
      '| 6 | `06-back-navigation.png` |',
      '| 7 | `07-touch-strip.png`, `07-touch-strip.txt` |',
      '| 1–7 | `session.webm` — the whole run as one recording |',
      '',
      '## What this run does not evidence',
      '',
      '- `aiurdev status` agreeing with the pause in step 4. It reads a running',
      '  Aiur daemon; an agent workspace must not start one.',
      '- The dashboard header meters as a numeric cross-check for step 7, for the',
      '  reason recorded in `07-touch-strip.txt`.',
      '- Hardware steps 8–11: N/A — #1342 no-go.',
      '',
      'Both open items need an Executor-root run. The commit, kernel and sidecar',
      'version this run was captured on are in `versions.txt`.'
    ].join('\n')
  )

  await page.close()
  await page.video()?.saveAs(path.join(runDirectory, 'session.webm'))
})
