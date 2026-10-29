import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 }, timezoneId: 'America/Los_Angeles' })
test.beforeEach(async ({ page }) => {
  page.on('pageerror', error => { throw error })
  await page.goto('/build-fixture/live')
  await expect.poll(() => page.evaluate(async () => !!(await import('/build-home/state.js')).ctx.D?.now.length)).toBe(true)
})

// Opens a running ticket against a stubbed server: `send` answers from `opts.replies`
// in order (a `hold` reply waits for window.releaseSend()); every pushed event is recorded in window.calls.
async function open(page, opts = {}) {
  await page.evaluate(async opts => {
    const { ctx } = await import('/build-home/state.js'), { openModal } = await import('/build-home/modal/frame.js')
    ctx.snap.writable = opts.writable ?? true
    ctx.offline.isLive = () => ctx.socket === 'up'
    window.calls = []; window.replies = opts.replies || []
    let request = 7
    ctx.push = async (event, payload) => {
      window.calls.push({ event, payload })
      if (event === 'conversation-page') return { v: 1, kind: 'conversation', id: payload.id, reset: false, state: 'live', reason: null, live: true, observed_at: null, entries: [], before: null, more: false, note: null, evicted: 0, composer: opts.composer === undefined ? 'ready' : opts.composer }
      if (event === 'voice-availability') return opts.voice || { state: 'unconfigured', reason: 'Dictation is unavailable in this fixture.' }
      if (event !== 'send') return { v: 1, kind: 'ok' }
      const reply = window.replies.shift() || { ok: true }
      if (reply.hang) return new Promise(() => {})
      if (reply.hold) await new Promise(resolve => { window.releaseSend = resolve })
      const text = payload.text.trim()
      return reply.ok ? { v: 1, kind: 'send', ok: true, id: payload.id, request_id: request, entry_id: 'message:r' + request++, text, at: 1791408000000, reason: null, unknown: false, message: null }
        : { v: 1, kind: 'send', ok: false, id: payload.id, request_id: null, entry_id: null, text: null, at: null, reason: reply.reason, unknown: !!reply.unknown, message: reply.message }
    }
    const t = ctx.D.now.find(t => t.agent && t.start != null)
    window.ticketId = t.id
    openModal({ ...t, ...(opts.ticket || {}), agent: { ...t.agent, ...(opts.agent || {}) } })
  }, opts)
}

test('closing the Build modal releases a microphone granted after dismissal', async ({ page }) => {
  await page.evaluate(() => {
    window.lateMicStops = 0
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        enumerateDevices: async () => [],
        getUserMedia: () => new Promise(resolve => { window.grantLateMic = resolve })
      }
    })
  })
  await open(page, { voice: { state: 'available' } })
  await page.locator('#cv-mic').click()
  await expect.poll(() => page.evaluate(() => typeof window.grantLateMic)).toBe('function')
  await page.locator('#bd-tk-close').click()
  await expect(page.locator('#tk-modal')).not.toBeVisible()
  await page.evaluate(() => window.grantLateMic({
    getTracks: () => [{ stop: () => { window.lateMicStops += 1 } }]
  }))
  await expect.poll(() => page.evaluate(() => window.lateMicStops)).toBe(1)
})

test('Build modal dictation sends the typed target and keeps transcription editable until Send', async ({ page }) => {
  await page.evaluate(() => {
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: {
      enumerateDevices: async () => [],
      getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] })
    } })
    window.AudioContext = class {
      constructor() { this.destination = {}; this.audioWorklet = { addModule: async () => {} } }
      createMediaStreamSource() { return { connect: target => target, disconnect() {} } }
      createGain() { return { gain: { value: 1 }, connect: target => target, disconnect() {} } }
      async resume() {}
      close() {}
    }
    window.AudioWorkletNode = class {
      constructor() { this.port = {}; window.voiceSamples = this }
      connect(target) { return target }
      disconnect() {}
    }
    window.AiurVoiceSocket = class {
      connect() {}
      disconnect() {}
      channel(topic, payload) {
        window.voiceTopic = topic; window.voiceJoin = payload
        const handlers = {}
        const ok = { receive(status, fn) { if (status === 'ok') queueMicrotask(() => fn({})); return this } }
        return {
          on(event, fn) { handlers[event] = fn }, onError() {}, onClose() {}, leave() {},
          join() { return ok },
          push(event) {
            if (event === 'audio') queueMicrotask(() => handlers.transcript({ kind: 'partial', text: 'hello' }))
            if (event === 'stop') queueMicrotask(() => {
              handlers.transcript({ kind: 'final', text: 'hello modal' })
              handlers.stopped({})
            })
            return ok
          }
        }
      }
    }
  })
  await open(page, { voice: { state: 'available' } })
  const mic = page.locator('#cv-mic')
  await mic.click()
  await expect(mic).toHaveAttribute('aria-pressed', 'true')
  await expect.poll(() => page.evaluate(() => window.voiceJoin?.target)).toEqual({
    kind: 'worker', ticket: await page.evaluate(() => String(window.ticketId))
  })
  expect(await page.evaluate(() => [window.voiceTopic, window.voiceJoin.surface, window.voiceJoin.mode])).toEqual([
    'voice:dictate', 'agent_composer', 'dictate'
  ])
  await page.evaluate(() => window.voiceSamples.port.onmessage({
    data: { samples: new Float32Array(800).fill(0.5), sampleRate: 16000 }
  }))
  const input = page.locator('#cv-in textarea')
  await expect(input).toHaveValue('hello')
  await mic.click()
  await expect(input).toHaveValue('hello modal')
  await expect(input).toBeEditable()
  expect(await page.evaluate(() => window.calls.filter(call => call.event === 'send'))).toEqual([])
  await input.fill('reviewed message')
  await page.locator('#cv-in').getByRole('button', { name: 'Send', exact: true }).click()
  await expect.poll(() => page.evaluate(() => window.calls.filter(call => call.event === 'send').map(call => call.payload.text))).toEqual(['reviewed message'])
})
