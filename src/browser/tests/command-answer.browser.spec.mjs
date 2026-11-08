import { expect, test } from '@playwright/test'
import { fileURLToPath } from 'node:url'
import { openFixture } from './support/browser-helpers.mjs'

test('the Commands action stays disabled during LiveView join, then records its answer', async ({ page }) => {
  await openFixture(page, 'writable')
  const configure = await page.goto('/command-answer-control/answerable')
  const configureBody = await configure.text()
  expect(configure?.status(), configureBody).toBe(200)
  await expect(page).toHaveURL(/\/commands\/dec_.+/)

  const form = page.locator('form.decision-answer-form')
  await expect(form).toBeVisible()
  await expect(form.locator('input[name="decision_id"]')).toHaveValue(/.+/)
  const decision = form.getByRole('button', { name: 'Decision' })
  await expect.poll(async () => {
    const response = await page.request.get('/command-answer-join-state')
    return (await response.json()).state
  }).toBe('joining')
  await expect(decision).toBeDisabled()
  await expect(page.getByRole('status').filter({ hasText: 'Connecting to the live dashboard' })).toBeVisible()

  await expect.poll(async () => {
    const response = await page.request.get('/command-answer-join-state')
    return (await response.json()).state
  }, { timeout: 10_000 }).toBe('joined')
  await expect(decision).toBeEnabled()
  await decision.click()

  await expect.poll(async () => {
    const response = await page.request.get('/command-answer-state')
    expect(response.ok()).toBe(true)
    return response.json()
  }).toMatchObject({
    decision_status: 'decided',
    selected_option_id: 'approve',
    actor: { kind: 'operator' }
  })
})

test('native questions validate as a group and submit all choices at 390px', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await openFixture(page, 'writable')
  await page.goto('/command-answer-control/answerable?native=true')
  const form = page.locator('form.decision-answer-form')
  const first = form.getByRole('group', { name: 'Which release strategy?' })
  const second = form.getByRole('group', { name: 'Which targets?' })
  await first.getByLabel('Safe rollout', { exact: true }).check()
  await expect(form.getByRole('button', { name: 'Submit answers' })).toBeEnabled()
  await form.getByRole('button', { name: 'Submit answers' }).click()
  await expect.poll(async () => (await (await page.request.get('/command-answer-state')).json()).decision_status).toBe('open')
  await expect(second.locator('input').first()).toHaveJSProperty('validationMessage', 'Answer this question.')
  await second.getByLabel('Alpha', { exact: true }).check()
  await second.getByLabel('Beta', { exact: true }).check()
  await second.getByLabel('Other', { exact: true }).check()
  await expect(second.getByLabel('Other response', { exact: true })).toBeVisible()
  await second.getByLabel('Other response', { exact: true }).fill('Canary')
  const dimensions = await page.evaluate(() => ({ width: innerWidth, scroll: document.documentElement.scrollWidth }))
  expect(dimensions.scroll).toBeLessThanOrEqual(dimensions.width)
  await form.getByRole('button', { name: 'Submit answers' }).click()
  await expect.poll(async () => (await (await page.request.get('/command-answer-state')).json()).question_answers).toEqual({
    q1: ['Safe rollout'], q2: ['Alpha', 'Beta', 'Canary']
  })
  await expect(page.locator('.decision-answer-summary')).toContainText('Which targets?: Alpha, Beta, Canary')
})

async function openCommand(page) {
  // Load the checkout's assets so an isolated mutation worktree exercises its
  // own production source even when reusing the same synthetic HTTP fixture.
  await page.route(/\/(conversation-voice-controller|voice-input-hook)\.js$/, (route) => {
    const file = new URL(route.request().url()).pathname.split('/').pop()
    return route.fulfill({ path: fileURLToPath(new URL(`../../priv/static/${file}`, import.meta.url)), contentType: 'application/javascript' })
  })
  await page.addInitScript(() => {
    window.__micRequests = []
    window.__voicePushes = []
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: {
      enumerateDevices: async () => [],
      getUserMedia: async () => {
        const form = document.querySelector('.decision-answer-form')
        window.__micRequests.push({ field: Boolean(form.querySelector('[data-voice-input]')), custom: form.querySelector('[value=custom]').checked })
        return { getTracks: () => [{ stop() {} }] }
      }
    } })
    window.AudioContext = class {
      constructor() { this.destination = {}; this.audioWorklet = { addModule: async () => {} } }
      createMediaStreamSource() { return { connect: (target) => target, disconnect() {} } }
      createGain() { return { gain: { value: 1 }, connect: (target) => target, disconnect() {} } }
      async resume() {}
      close() {}
    }
    window.AudioWorkletNode = class {
      constructor() { this.port = {} }
      connect(target) { return target }
      disconnect() {}
    }
  })
  await openFixture(page, 'writable')
  await page.goto('/voice-input-fixture?command=true')
  await expect(page.locator('#standalone-voice')).toBeVisible()
  await page.goto('/command-answer-control/answerable')
  const decisionId = new URL(page.url()).pathname.split('/').pop()
  const form = page.locator(`#decision-answer-form-${decisionId}`)
  await expect(form.getByRole('button', { name: 'Decision', exact: true })).toBeEnabled()
  await expect(form.locator('[data-voice-root]')).toHaveAttribute('data-voice-state', 'idle')
  await expect(form.locator('[data-voice-status]')).toHaveText('Choose Dictate to speak a custom response. Review the text, then record your answer.')
  await page.evaluate(() => {
    const open = window.AiurVoiceTransport.open
    window.AiurVoiceTransport.open = (opts) => {
      window.__voiceHandlers = opts.handlers
      window.__voiceJoin = opts.joinPayload
      const transport = open(opts)
      const push = transport.channel.push.bind(transport.channel)
      transport.channel.push = (event, payload) => { window.__voicePushes.push(event); return push(event, payload) }
      return transport
    }
  })
  return form
}

async function start(form) {
  await form.getByRole('button', { name: 'Choose voice input' }).click()
  await form.getByRole('menuitem', { name: 'Dictate message' }).click()
  await expect(form.locator('[data-voice-status]')).toContainText('Listening')
}

for (const surface of ['detail', 'card']) {
  test(`Command ${surface} selects Custom response before capture and records reviewed text`, async ({ page }) => {
    const form = await openCommand(page)
    const decisionId = new URL(page.url()).pathname.split('/').pop()
    if (surface === 'card') {
      await page.getByRole('link', { name: 'Collapse details' }).click()
    }
    expect(await page.evaluate(() => window.__micRequests)).toEqual([])
    await expect(form.locator('[data-voice-input]')).toHaveCount(0)
    await start(form)
    expect(await page.evaluate(() => window.__micRequests)).toEqual([{ field: true, custom: true }])
    expect(await page.evaluate(() => window.__voiceJoin)).toMatchObject({
      surface: 'command_response', target: { kind: 'command', expected_version: 1 }
    })
    await page.evaluate(() => window.__voiceHandlers.transcript({ kind: 'final', text: 'Use the safer path' }))
    await form.getByRole('button', { name: 'Stop dictation' }).click()
    await expect(form.locator('[data-voice-send]')).toBeEnabled()
    await expect(form.locator('[data-voice-input]')).toHaveValue(/Use the safer path/)
    await expect(form.locator('[data-voice-status]')).toHaveText('Dictation ready. Review the text, then record your answer.')
    await form.locator('[data-voice-input]').fill('Use the safer path after review')
    await expect(form.locator('[data-voice-root]')).toHaveAttribute('data-voice-state', 'idle')
    await expect(form.locator('[data-voice-status]')).toHaveText('Choose Dictate to speak a custom response. Review the text, then record your answer.')
    expect((await (await page.request.get('/command-answer-state')).json()).decision_status).toBe('open')
    await form.locator('[data-voice-send]').click()
    await expect.poll(async () => (await (await page.request.get('/command-answer-state')).json()).decision_status).toBe('decided')
    const recorded = surface === 'card' ? page.locator(`#history-${decisionId} .history-decision`) : page.locator(`#decision-detail-${decisionId} .decision-answer-summary`)
    await expect(recorded).toContainText('Use the safer path')
  })
}

test('Command dictation appends and stops at maxlength without truncating the transcript', async ({ page }) => {
  const form = await openCommand(page)
  await form.locator('[value=custom]').check()
  await form.locator('[data-voice-input]').fill('Existing response')
  await start(form)
  await page.evaluate(() => window.__voiceHandlers.transcript({ kind: 'final', text: 'x'.repeat(4100) }))
  await expect(form.locator('[data-voice-status]')).toContainText('Response limit reached')
  await expect.poll(() => page.evaluate(() => window.__voicePushes.filter((event) => event === 'stop').length)).toBe(1)
  await expect(form.locator('[data-voice-input]')).toHaveValue(/^Existing response x{4100}/)
  await expect(form.locator('[data-voice-input]')).toBeEditable()
  expect((await (await page.request.get('/command-answer-state')).json()).decision_status).toBe('open')
})

test('a missing Custom response patch times out without requesting the microphone', async ({ page }) => {
  const form = await openCommand(page)
  // Simulate an unavailable LiveView connection: no server patch can create the field.
  await page.evaluate(() => window.liveSocket.disconnect())
  await form.getByRole('button', { name: 'Choose voice input' }).click()
  await form.getByRole('menuitem', { name: 'Dictate message' }).click()
  await expect(form.locator('[data-voice-status]')).toHaveText('The response field did not open.')
  expect(await page.evaluate(() => window.__micRequests)).toEqual([])
})

test('Command Cancel restores the existing response without deciding the Command', async ({ page }) => {
  const form = await openCommand(page)
  await form.locator('[value=custom]').check()
  const input = form.locator('[data-voice-input]')
  await input.fill('Existing response')
  await start(form)
  await page.evaluate(() => window.__voiceHandlers.transcript({ kind: 'final', text: 'discard these words' }))
  await expect(input).toHaveValue('Existing response discard these words')
  await form.getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(input).toHaveValue('Existing response')
  await expect(input).toBeEditable()
  expect(await page.evaluate(() => window.__voicePushes)).toContain('cancel')
  expect(await page.evaluate(() => window.__voicePushes)).not.toContain('stop')
  expect((await (await page.request.get('/command-answer-state')).json()).decision_status).toBe('open')
})

test('revision dictation auto-selects Custom response and submits the reviewed correction', async ({ page }) => {
  const answer = await openCommand(page)
  await answer.getByRole('button', { name: 'Decision', exact: true }).click()
  const form = page.locator('[id^="decision-revision-form-"]')
  await expect(form).toBeVisible()
  await expect(form.locator('[data-voice-input]')).toHaveCount(0)
  await start(form)
  await expect(form.getByRole('button', { name: 'Send correction', exact: true })).toBeDisabled()
  expect(await page.evaluate(() => window.__micRequests)).toEqual([{ field: true, custom: true }])
  expect(await page.evaluate(() => window.__voiceJoin)).toMatchObject({
    surface: 'command_revision', target: { kind: 'command', decision_id: new URL(page.url()).pathname.split('/').pop() }
  })
  await page.evaluate(() => window.__voiceHandlers.transcript({ kind: 'final', text: 'Hold the rollout' }))
  await form.getByRole('button', { name: 'Stop dictation' }).click()
  await expect(form.locator('[data-voice-input]')).toHaveValue(/Hold the rollout/)
  await expect(form.locator('[data-voice-status]')).toHaveText('Dictation ready. Review the text, then send your correction.')
  await expect(page.locator('.decision-revision-list')).toHaveCount(0)
  await form.locator('[data-voice-input]').fill('Hold the rollout after review')
  await expect(page.locator('[data-voice-input]')).toHaveValue('Hold the rollout after review')
  await form.locator('[name="revision[reason]"]').fill('New evidence')
  await form.getByRole('button', { name: 'Send correction', exact: true }).click()
  await expect(page.locator('.decision-revision-list')).toContainText('Hold the rollout after review')
  await expect(page.locator('.decision-revision-list')).toContainText('New evidence')
})

test('override timeline and form fit desktop and mobile after an answer', async ({ page }, testInfo) => {
  await openFixture(page, 'writable')
  await page.goto('/command-answer-control/answerable')
  const commandUrl = page.url()
  // The fixture retains earlier repeats; measure the real pending rows first.
  await page.goto('/voice-input-fixture?command=true')
  await page.goto('/')
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
  await expect(page.locator('summary[title="Override status unavailable"]')).toHaveCount(0)
  const pendingBefore = await page.locator('.fleet-override-badge').count()
  await page.goto(commandUrl)
  await page.getByRole('button', { name: 'Decision', exact: true }).click()
  const form = page.locator('form[phx-submit="revise-decision"]')
  await expect(form).toBeVisible()
  await form.locator('input[value="custom"]').check()
  await form.locator('textarea[name="revision[custom_response]"]').fill('Hold the rollout until the regression is fixed.')
  await form.locator('textarea[name="revision[reason]"]').fill('New regression discovered after the answer.')
  await form.getByRole('button', { name: 'Send correction', exact: true }).click()
  const timeline = page.getByRole('region', { name: 'Overrides', exact: true })
  await expect(timeline.locator('ol > li')).toHaveCount(1)
  // This fixture has no tracker/worker: retained corrective creation fails.
  // The browser verifies the actual failure, never a fabricated delivery.
  await expect(timeline.locator('.chip')).toHaveText('Override failed')
  await expect(timeline.getByRole('link', { name: 'Original Command' })).toBeVisible()
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 900 })
    await expect(timeline).toBeVisible()
    const bounds = await timeline.boundingBox()
    expect(bounds.x + bounds.width).toBeLessThanOrEqual(width)
    for (const link of await timeline.getByRole('link').all()) {
      const rect = await link.boundingBox()
      expect(rect.x + rect.width).toBeLessThanOrEqual(width)
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await page.screenshot({ path: testInfo.outputPath(`override-${width}.png`), fullPage: true })
  }
  // Reuse the harness's existing control to share this retained store with Build.
  await page.goto('/voice-input-fixture?command=true')
  await page.goto('/')
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
  await expect(page.getByRole('region', { name: 'Fleet overrides' })).toContainText('Override failed')
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 900 })
    const geometry = await page.evaluate(() => {
      const board = document.querySelector('#build-root'), summary = document.querySelector('#fleet-overrides')
      const shown = board.getBoundingClientRect().toJSON(), badge = summary.getBoundingClientRect().toJSON()
      summary.hidden = true
      const hidden = board.getBoundingClientRect().toJSON()
      summary.hidden = false
      const overlaps = badge.left < shown.right && badge.right > shown.left && badge.top < shown.bottom && badge.bottom > shown.top
      return { shown, hidden, overlaps }
    })
    expect(geometry.shown, 'override summary must not shift or resize the Build board').toEqual(geometry.hidden)
    expect(geometry.overlaps, `override badge must not cover the Build board at ${width}px`).toBe(false)
  }
  const disclosure = page.locator('#fleet-overrides details')
  const toggle = disclosure.locator('summary')
  const panel = disclosure.locator('.fleet-overrides-panel')
  await expect(page.locator('.fleet-override-badge')).toHaveCount(pendingBefore + 1)
  await expect(toggle).toHaveText(`Overrides: ${pendingBefore + 1}`)
  await expect(panel).toBeHidden()
  await expect(page.locator('.aiur-shell__topbar #fleet-overrides')).toBeVisible()
  await page.screenshot({ path: testInfo.outputPath('override-fleet-390.png'), fullPage: true })
  await toggle.focus()
  await page.keyboard.press('Enter')
  await expect(panel).toBeVisible()
  await page.keyboard.press('Escape')
  await expect(panel).toBeHidden()
  await toggle.click()
  await expect(panel).toBeVisible()
  await page.locator('#route-title').click()
  await expect(panel).toBeHidden()
  await toggle.click()
  const badge = page.locator(`.fleet-override-badge[href="${new URL(commandUrl).pathname}"]`)
  await expect(badge).toHaveAttribute('href', /\/commands\/dec_/)
  await expect(badge).toBeVisible()
  // A CSS-only reflow probe; routing and implementation evidence are tested separately.
  const text = await badge.textContent()
  await badge.evaluate(el => { el.textContent = 'Ticket #6913 · Implemented in PR #12345 (awaiting merge)' })
  const bounds = await badge.boundingBox()
  expect(bounds.x + bounds.width).toBeLessThanOrEqual(390)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  await badge.evaluate((el, value) => { el.textContent = value }, text)
})

// The card list is reached by patching from the seeded Command's detail URL:
// only that URL mounts the real dashboard on the shared fixture server.
async function openCommandCard(page, theme = 'dark') {
  await openFixture(page, 'writable')
  await page.evaluate((value) => localStorage.setItem('aiur-theme', value), theme)
  await page.addInitScript(() => {
    document.addEventListener('DOMContentLoaded', () => {
      document.documentElement.dataset.theme = localStorage.getItem('aiur-theme') ?? 'dark'
    }, { once: true })
  })
  // Earlier specs configure voice; configure it here too so the card's dictation copy is the same in any order.
  await page.goto('/voice-input-fixture?command=true')
  await expect(page.locator('#standalone-voice')).toBeVisible()
  await page.goto('/command-answer-control/answerable')
  const decisionId = new URL(page.url()).pathname.split('/').pop()
  await expect.poll(async () => (await (await page.request.get('/command-answer-join-state')).json()).state, { timeout: 10_000 }).toBe('joined')
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  await page.getByRole('link', { name: 'Collapse details' }).click()
  const card = page.locator(`#decision-${decisionId}`)
  await expect(card.locator('.decision-answer-form')).toBeVisible()
  return { card, decisionId }
}

test('a compact Command card shows the question once, two pills, one option style, and answers', async ({ page }) => {
  const { card, decisionId } = await openCommandCard(page)
  await expect(card.getByText('Should the browser fixture record this operator decision?', { exact: true })).toHaveCount(1)
  await expect(card.locator('.decision-card-head .chip')).toHaveText(['Blocking', /^asked /])
  await expect(card.locator('.decision-option-preview')).toHaveCount(0)
  await expect(card.locator('.decision-more')).not.toHaveAttribute('open', '')
  const labels = await page.locator('.filter-row .filter-chip').evaluateAll((chips) => chips.map((chip) => chip.dataset.countLabel))
  expect(new Set(labels).size).toBe(labels.length)
  expect(labels.length).toBeLessThanOrEqual(5)

  await card.getByRole('button', { name: 'Decision', exact: true }).click()
  await expect.poll(async () => (await (await page.request.get('/command-answer-state')).json()).decision_status).toBe('decided')
  await expect(page.locator(`#history-${decisionId}`)).toBeVisible()
})

for (const theme of ['light', 'dark']) {
  for (const width of [1440, 390]) {
    test(`Commands card baseline ${theme} ${width}`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 })
      const { card } = await openCommandCard(page, theme)
      await expect(page.locator('html')).toHaveAttribute('data-theme', theme)
      await page.evaluate(() => document.fonts.ready)
      // Sticky chrome and Commands left open by earlier specs (their shadows) would make the image order-dependent.
      const others = `.decision-card:not(#${await card.getAttribute('id')})`
      await page.addStyleTag({ content: `.ax-top, #ax-title, .sidenav { visibility: hidden !important; } ${others} { display: none !important; } * { overflow-anchor: none !important; }` })
      // Content above the list (daemon banner, fleet error) varies by run and leaves the card on a sub-pixel offset,
      // which shifts the crop by a row; reset every scroller and snap the card to a whole pixel until it holds.
      await expect.poll(() => card.evaluate((el) => {
        el.style.top = ''
        for (let n = el.parentElement; n; n = n.parentElement) n.scrollTop = 0
        window.scrollTo(0, 0)
        const top = el.getBoundingClientRect().top
        el.style.position = 'relative'
        el.style.top = `${Math.floor(top) - top}px`
        const snapped = el.getBoundingClientRect().top
        return snapped >= 0 && snapped === Math.round(snapped)
      })).toBe(true)
      // A pointer left over an option by an earlier spec renders its hover state.
      await page.mouse.move(0, 0)
      // The age is masked, but its width still moves the Blocking pill beside it.
      await card.locator('.decision-card-head .decision-age').evaluate((el) => { el.textContent = 'asked just now' })
      await expect(card).toHaveScreenshot(`commands-card-${theme}-${width}.png`, { mask: [card.locator('.decision-age')] })
    })
  }
}
