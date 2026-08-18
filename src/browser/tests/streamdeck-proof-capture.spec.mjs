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
  await page.goto('/')
  await page.context().setHTTPCredentials(dashboardCredentials)
  // Steps 4 and 6 take a real agent control, so the proof run needs the
  // writable fixture rather than the read-only one.
  const control = await page.goto('/streamdeck-control/writable')
  expect(control.status()).toBe(200)
  await page.goto('/streamdeck')
  await expect(page.locator('#streamdeck-page')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
}

async function openUnits(page) {
  await page.goto('/auth/read_only')
  // Show every condition so the Units rows are the whole fleet the emulator
  // grid pages through, not the default live-only scope.
  const conditions = encodeURIComponent('active,alert,paused,queued,finished')
  await page.goto(`/units?v=1&scope=unfinished&conditions=${conditions}`)
  await expect(page.locator('[data-units-fixture="true"]')).toBeVisible()
}

function dial(page, index) {
  return page.locator('.sd-knob').nth(index)
}

function visibleIdentifiers(page) {
  return page.locator('#sd-keys .sd-key').evaluateAll((keys) =>
    keys.map((key) => (key.classList.contains('is-empty') ? null : key.getAttribute('data-streamdeck-identifier')))
  )
}

// The bucket the emulator paints on each key.
function gridBuckets(page) {
  return page.locator('#sd-keys .sd-key:not(.is-empty)').evaluateAll((keys) =>
    Object.fromEntries(
      keys.map((key) => [
        key.getAttribute('data-streamdeck-identifier'),
        [...key.classList].find((name) => name.startsWith('st-')) ?? 'st-unknown'
      ])
    )
  )
}

// Every agent's bucket, not just the visible window's: the touch strip counts
// the whole fleet, so a window-sized sample would compare two different
// populations and call the difference a failure. Pressing dial D once per
// window wraps back to the window it started on.
async function fleetBuckets(page, keys) {
  const windows = Number.parseInt(await keys.getAttribute('data-grid-page-count'), 10)
  const collected = {}

  for (let window = 0; window < windows; window += 1) {
    Object.assign(collected, await gridBuckets(page))

    const current = Number.parseInt(await keys.getAttribute('data-grid-page'), 10)
    await dial(page, 3).click()
    await expect(keys).toHaveAttribute('data-grid-page', String((current + 1) % windows))
  }

  return collected
}

// Units paints a row *tone* rather than a bucket, and only for the states that
// need operator attention: a running agent has no tone at all. So the two
// renderings are compared where they overlap (paused and queued) and the rest
// is recorded side by side as evidence rather than asserted as equality.
function unitTones(page) {
  // Only the tone classes the table actually assigns, so an unrelated state
  // class (a selection, say) cannot be read as a fleet state.
  const tones = ['is-paused', 'is-queued', 'is-blocked', 'has-alert']

  return page.locator('#units-rows tr.units-row').evaluateAll(
    (rows, names) =>
      Object.fromEntries(
        rows.map((row) => [
          row.querySelector('.ut-id-num')?.textContent.trim(),
          [...row.classList].find((name) => names.includes(name)) ?? 'none'
        ])
      ),
    tones
  )
}

test.use({ video: 'on' })

test('#1358 emulator proof: steps 1-7 captured as committed evidence', async ({ page, context }) => {
  await mkdir(runDirectory, { recursive: true })

  const startedAt = new Date().toISOString()
  const device = page.locator('.sd-device')
  const keys = page.locator('#sd-keys')
  const pager = page.locator('[data-segment="pager"]')
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
  // Dial D pages: wheel and keyboard both reach the server, press cycles.
  await dialD.hover()
  await page.mouse.wheel(0, 100)
  await expect(keys).toHaveAttribute('data-grid-dial-value', String(await dialD.getAttribute('aria-valuenow')))

  await dialD.focus()
  await page.keyboard.press('ArrowDown')
  await expect(keys).toHaveAttribute('data-grid-dial-value', String(await dialD.getAttribute('aria-valuenow')))

  const windows = Number.parseInt(await keys.getAttribute('data-grid-page-count'), 10)
  const beforePress = Number.parseInt(await keys.getAttribute('data-grid-page'), 10)
  await dialD.click()
  await expect(keys).toHaveAttribute('data-grid-page', String((beforePress + 1) % windows))
  await expect(pager.locator('[aria-current="page"]')).toHaveAttribute(
    'data-pager-page',
    String((beforePress + 1) % windows)
  )
  await expect(pager.locator('.sd-pager-dot')).toHaveCount(windows)
  await shot(page, '03-paging.png')

  // Return to the window the run opened on before taking a control.
  for (let attempt = 0; attempt <= windows; attempt += 1) {
    if ((await visibleIdentifiers(page)).join() === openingWindow.join()) break

    const current = Number.parseInt(await keys.getAttribute('data-grid-page'), 10)
    await dialD.click()
    await expect(keys).toHaveAttribute('data-grid-page', String((current + 1) % windows))
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
  await expect(controlled).toHaveClass(/st-paused/)
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

  // ------------------------------------------------------------------ 5 --
  // Logs mode: dial D scrolls events, dial A the transcript, hints track the
  // real bounds.
  await dialD.click()
  await expect(device).toHaveAttribute('data-mode', 'logs')
  await expect(page.locator('#sd-logs-view')).toHaveAttribute('data-focused-identifier', CONTROLLED)

  const events = page.locator('#sd-log-keys')
  const transcript = page.locator('#sd-screen')
  const eventsMax = Number.parseInt(await events.getAttribute('data-max-offset'), 10)
  const transcriptMax = Number.parseInt(await transcript.getAttribute('data-transcript-max-offset'), 10)
  expect(eventsMax).toBeGreaterThan(0)
  expect(transcriptMax).toBeGreaterThan(0)

  // Both surfaces open at the live end, so the hint that has nowhere to go is
  // hidden and the one that does is shown.
  await expect(events).toHaveAttribute('data-offset', String(eventsMax))
  await expect(page.locator('#sd-transcript-hint-down')).toHaveAttribute('aria-hidden', 'true')
  await shot(page, '05-logs-live-end.png')

  // Overshoot each dial past its own clamp: the offsets stop at the real
  // bounds and the hints flip there, not at a shared guess.
  await dialD.hover()
  for (let step = 0; step < eventsMax + 3; step += 1) await page.mouse.wheel(0, 100)
  await expect(events).toHaveAttribute('data-offset', '0')

  await dialA.hover()
  for (let step = 0; step < transcriptMax + 3; step += 1) await page.mouse.wheel(0, 100)
  await expect(transcript).toHaveAttribute('data-transcript-offset', '0')
  await expect(page.locator('#sd-transcript-hint-up')).toHaveAttribute('aria-hidden', 'true')
  await expect(page.locator('#sd-transcript-hint-down')).toHaveAttribute('aria-hidden', 'false')
  await shot(page, '05-logs-bounds.png')

  await record(
    '05-logs-bounds.txt',
    [
      `Step 5 — focused agent #${CONTROLLED}.`,
      `event window max offset: ${eventsMax} (scrolled to 0, clamped)`,
      `transcript max offset: ${transcriptMax} (scrolled to 0, clamped)`,
      'up hint hidden at the origin, down hint shown — both read from the server render.'
    ].join('\n')
  )

  // ------------------------------------------------------------------ 6 --
  // Dial A backs out logs → cmd → grid, onto the window the run started on.
  await dialA.click()
  await expect(device).toHaveAttribute('data-mode', 'cmd')
  await dialA.click()
  await expect(device).toHaveAttribute('data-mode', 'grid')
  expect(await visibleIdentifiers(page)).toEqual(openingWindow)
  await expect(controlled).toHaveAttribute('data-control-action', 'pause')
  await shot(page, '06-back-navigation.png')

  // ------------------------------------------------------------------ 7 --
  // Touch strip: Summary counts are live, provider segments carry real usage.
  const summary = page.locator('[data-segment="summary"]')
  await expect(summary).toBeVisible()
  const summaryText = (await summary.locator('.sd-info-live').innerText()).replaceAll('\n', ' ')
  const liveCount = Number.parseInt(summaryText, 10)

  // The Summary count is the whole fleet's running agents, so it must equal
  // the keys the grid itself paints as running across every window — a
  // screenshot of a stale number would otherwise pass for evidence.
  const everyBucket = await fleetBuckets(page, keys)
  const runningKeys = Object.values(everyBucket).filter((bucket) => bucket === 'st-running').length
  expect(Object.keys(everyBucket)).toHaveLength(fleetTotal)
  expect(liveCount).toBe(runningKeys)
  // The wrap left the operator on the window they were reading.
  expect(await visibleIdentifiers(page)).toEqual(openingWindow)

  const providerMeters = await page.locator('[data-segment="provider"] .sd-mini').evaluateAll((meters) =>
    meters.map((meter) => ({
      provider: meter.getAttribute('data-provider'),
      meter: meter.getAttribute('data-meter'),
      percent: meter.getAttribute('data-percent'),
      observed: meter.getAttribute('data-observed'),
      freshness: meter.getAttribute('data-freshness')
    }))
  )
  await shot(page, '07-touch-strip.png')

  await record(
    '07-touch-strip.txt',
    [
      'Step 7 — touch strip, read at the same instant as the grid above.',
      `SUMMARY segment: ${summaryText.trim()}`,
      `emulator keys bucketed st-running: ${runningKeys}`,
      '',
      'provider segments (provider / meter / percent / observed / freshness):',
      ...providerMeters.map(
        (meter) => `${meter.provider}  ${meter.meter}  ${meter.percent}  ${meter.observed}  ${meter.freshness}`
      ),
      '',
      'NOT CAPTURED HERE: the numeric comparison against the dashboard header',
      'meters. In this browser fixture the header-meter routes render their own',
      'hardcoded usage rather than the run the emulator reads, so comparing them',
      'would prove nothing. That comparison needs a live daemon — see run.md.'
    ].join('\n')
  )

  // ------------------------------------------------------- 2, part two --
  // Units parity. The Units fixture pushes its own projected fleet into the
  // Stream Deck snapshot when a unit is removed, so the two surfaces are only
  // reading one fleet *after* that push — before it, the emulator runs its own
  // default fixture fleet and a comparison would be a harness artifact rather
  // than a product disagreement. This is also the runbook's "repeat after a
  // fleet update", so it doubles as the live-change half of step 2. It runs
  // last because it changes the fleet the earlier steps were captured on.
  const units = await context.newPage()
  await openUnits(units)

  const rows = units.locator('#units-rows tr.units-row')
  await expect(units.locator('.units-header p').nth(1)).toContainText('7 observed · 6 in selected scope')
  const observedBefore = Number.parseInt(await units.locator('.units-header p').nth(1).textContent(), 10)

  await rows.first().locator('td.ut-id-cell').click()
  await units.locator('#remove-selected-unit').evaluate((button) => button.click())
  await expect(units.locator('.units-header p').nth(1)).toContainText(`${observedBefore - 1} observed`)
  // The header count and the tbody are separate patches from one diff, so wait
  // on the rows before snapshotting them.
  await expect(rows).toHaveCount(5)

  const tones = await unitTones(units)
  const unitIdentifiers = Object.keys(tones)
  await expect(keys).toHaveAttribute('data-grid-total', String(unitIdentifiers.length))

  const syncedWindow = await visibleIdentifiers(page)
  const syncedBuckets = await gridBuckets(page)
  await shot(page, '02-grid-after-change.png')
  await shot(units, '02-units.png')

  // Membership, and the column-major slot order the design specifies.
  expect([...new Set(syncedWindow.filter(Boolean))].sort()).toEqual([...unitIdentifiers].sort())
  expect(syncedWindow).toEqual(
    Array.from({ length: 8 }, (_, slot) => unitIdentifiers[(slot % 4) * 2 + Math.floor(slot / 4)] ?? null)
  )

  // Deliberately NOT asserted: that the two surfaces agree about each agent's
  // *state*. `set_streamdeck_snapshot_identities/1` hands the deck the Units
  // page's identifiers and nothing else, so each surface keeps its own seeded
  // states and an equality check here would be measuring the fixture. The two
  // renderings are recorded side by side instead, and state parity with Units
  // stays part of the live proof.

  await record(
    '02-grid-units-parity.txt',
    [
      'Step 2 (part 2) — emulator grid vs Units after a live fleet change.',
      `Units removed one unit: ${observedBefore} observed -> ${observedBefore - 1} observed.`,
      `fleet size (emulator data-grid-total): ${await keys.getAttribute('data-grid-total')}`,
      `fleet size (Units rows): ${unitIdentifiers.length}`,
      '',
      'slot  identifier  emulator-bucket  units-row-tone  (column-major)',
      ...syncedWindow.flatMap((identifier, slot) =>
        identifier
          ? [`${slot}  ${identifier}  ${syncedBuckets[identifier]}  ${tones[identifier]}`]
          : [`${slot}  (empty)`]
      ),
      '',
      'ASSERTED: membership and column-major slot order are identical.',
      '',
      'NOT ASSERTED: that the two surfaces agree per-agent about state. The',
      'fixture hands the deck the Units identifiers and nothing else, so each',
      'surface keeps its own seeded states — comparing the two columns below',
      'would measure the harness. (Units also paints a row tone only for states',
      'needing attention, so a running agent reads `none` there.) State parity',
      'with Units is part of the live proof, not this run.'
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
      '| 2 | `02-grid.png`, `02-grid.txt`, then after the live fleet change `02-grid-after-change.png`, `02-units.png`, `02-grid-units-parity.txt` |',
      '| 3 | `03-paging.png` |',
      '| 4 | `04-pause-cmd.png`, `04-pause-grid.png`, `04-pause.txt`, `04-resume.png` |',
      '| 5 | `05-logs-live-end.png`, `05-logs-bounds.png`, `05-logs-bounds.txt` |',
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

  await units.close()
  await page.close()
  await page.video()?.saveAs(path.join(runDirectory, 'session.webm'))
})
