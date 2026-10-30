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
  await form.getByRole('button', { name: 'Stop dictation' }).click()
  await expect(form.locator('[data-voice-input]')).toHaveValue('hello browser')
  await expect(form.locator('[data-voice-status]')).toHaveText('Dictation ready. Review the text, then send your correction.')
  await expect(page.locator('.decision-revision-list')).toHaveCount(0)
  await form.locator('[data-voice-input]').fill('Hold the rollout after review')
  await expect(page.locator('[data-voice-input]')).toHaveValue('Hold the rollout after review')
  await form.locator('[name="revision[reason]"]').fill('New evidence')
  await form.getByRole('button', { name: 'Send correction', exact: true }).click()
  await expect(page.locator('.decision-revision-list')).toContainText('Hold the rollout after review')
  await expect(page.locator('.decision-revision-list')).toContainText('New evidence')
})
