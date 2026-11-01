import { test, expect } from '@playwright/test'

const root = '#standalone-controls'
const status = `${root} [data-voice-status]`
const input = '#standalone-input'

async function open(page) {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: {
      enumerateDevices: async () => [],
      getUserMedia: () => new Promise((resolve, reject) => {
        window.__grant = () => resolve({ getTracks: () => [{ stop() {} }] })
        window.__deny = name => reject(new DOMException('test', name))
      })
    } })
  })
  await page.goto('/auth/writable')
  await page.goto('/streamdeck-control/writable')
  await page.goto('/voice-input-fixture')
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
  await page.evaluate(() => {
    window.AudioContext = class {}
    window.AudioWorkletNode = class {}
    window.AiurVoiceCapture.Capture = class {
      async start() {}
      stop() { window.__captureStops = (window.__captureStops || 0) + 1 }
    }
    window.AiurVoiceSocket = class {
      connect() {}
      disconnect() {}
      channel() {
        const handlers = {}
        window.__emit = (event, payload) => handlers[event](payload)
        return {
          on(event, callback) { handlers[event] = callback },
          onError(callback) { window.__lose = callback },
          onClose() {}, leave() {}, push() {},
          join() { return { receive(event, callback) {
            if (event === 'ok' && !window.__refusal) queueMicrotask(() => callback({}))
            if (event === 'error' && window.__refusal) queueMicrotask(() => callback({ reason: 'untrusted provider text', reason_code: window.__refusal }))
            return this
          } } }
        }
      }
    }
  })
}
async function choose(page) {
  await page.locator(root).getByRole('button', { name: 'Choose voice input' }).click()
  await page.locator(root).getByRole('menuitem', { name: 'Dictate message' }).click()
}
async function state(page, value, copy) {
  await expect(page.locator(root)).toHaveAttribute('data-voice-state', value)
  await expect(page.locator(status)).toHaveText(copy)
}
async function listen(page) {
  await choose(page)
  await page.evaluate(() => window.__grant())
  await state(page, 'listening', 'Listening… press the microphone again when you are finished.')
}

test('dictation follows permission, listening, finishing and ready without early ready on final text', async ({ page }) => {
  await open(page)
  await state(page, 'idle', 'Press the microphone to dictate. Review the text, then press Send.')
  await choose(page)
  await state(page, 'requesting_permission', 'Requesting microphone permission…')
  await expect(page.locator(input)).not.toBeEditable()
  await page.evaluate(() => window.__grant())
  await state(page, 'listening', 'Listening… press the microphone again when you are finished.')
  await page.evaluate(() => window.__emit('transcript', { kind: 'final', text: 'spoken words' }))
  await state(page, 'listening', 'Listening… press the microphone again when you are finished.')
  await page.locator(root).getByRole('button', { name: 'Stop dictation' }).click()
  await state(page, 'finishing', 'Finishing transcription…')
  await expect(page.locator('#standalone-voice [data-voice-send]')).toBeDisabled()
  await page.evaluate(() => window.__emit('stopped', {}))
  await state(page, 'ready', 'Dictation ready. Review the text, then press Send.')
  await expect(page.locator(input)).toBeEditable()
  await expect(page.locator(input)).toHaveValue('spoken words')
  await page.locator(input).fill('reviewed spoken words')
  await state(page, 'idle', 'Press the microphone to dictate. Review the text, then press Send.')
  await page.locator('#standalone-voice [data-voice-send]').click()
  await expect(page.locator('[data-voice-fixture]')).toHaveAttribute('data-sent', 'reviewed spoken words')
})

for (const [code, copy] of [
  ['target_stale', 'This Command has changed. Reload it before dictating an answer.'],
  ['zzz', 'Microphone dictation could not start.'],
  ['toString', 'Microphone dictation could not start.']
]) test(`join refusal ${code} uses stable copy and retains typed text`, async ({ page }) => {
  await open(page)
  await page.locator(input).fill('keep this draft')
  await page.evaluate(code => { window.__refusal = code }, code)
  await choose(page)
  await page.evaluate(() => window.__grant())
  await state(page, 'error', copy)
  await expect(page.locator(input)).toHaveValue('keep this draft')
  await expect(page.locator(input)).toBeEditable()
})

for (const [name, value, copy] of [
  ['NotAllowedError', 'permission_denied', 'Microphone permission was denied for this origin. Allow it in site settings, then try again.'],
  ['NotFoundError', 'no_device', 'No microphone is available. Connect one or choose a different browser microphone.']
]) test(`${value} allows retry`, async ({ page }) => {
  await open(page)
  await choose(page)
  await page.evaluate(name => window.__deny(name), name)
  await state(page, value, copy)
  await expect(page.locator(input)).toBeEditable()
  await listen(page)
})

test('channel errors and finishing timeout keep captured text', async ({ page }) => {
  await open(page)
  await listen(page)
  await page.evaluate(() => {
    window.__emit('transcript', { kind: 'partial', text: 'keep my words' })
    window.__emit('error', { reason_code: 'provider_quota', reason: 'wrong text', message: 'wrong message', local: true })
  })
  await state(page, 'error', 'ElevenLabs quota exhausted')
  await expect(page.locator(input)).toHaveValue('keep my words')
  await listen(page)
  await page.clock.install()
  await page.locator(root).getByRole('button', { name: 'Stop dictation' }).click()
  await page.clock.fastForward(5100)
  await state(page, 'error', 'Speech-to-text connection was lost. Try dictation again.')
  await expect(page.locator(input)).toHaveValue('keep my words')
})

test('capability patches preserve active capture and disable next activation while typing still sends', async ({ page }) => {
  await open(page)
  await listen(page)
  await page.getByRole('button', { name: 'Disable voice', exact: true }).click()
  await expect(page.locator(root)).toHaveAttribute('data-voice-stt-state', 'unavailable')
  await state(page, 'listening', 'Listening… press the microphone again when you are finished.')
  await page.locator(root).getByRole('button', { name: 'Stop dictation' }).click()
  await page.evaluate(() => window.__emit('stopped', {}))
  await page.locator(root).getByRole('button', { name: 'Choose voice input' }).click()
  await expect(page.locator(root).getByRole('menuitem', { name: 'Dictate message' })).toHaveAttribute('aria-disabled', 'true')
  await expect(page.locator(root).getByRole('link', { name: 'Set up voice input' })).toHaveAttribute('href', 'https://aiur.team/docs/apis/elevenlabs#configure-the-key')
  await page.locator(root).getByRole('button', { name: 'Choose voice input' }).press('Escape')
  await page.locator(input).fill('typed while unavailable')
  await page.locator('#standalone-voice [data-voice-send]').click()
  await expect(page.locator('[data-voice-fixture]')).toHaveAttribute('data-sent', 'typed while unavailable')
  await state(page, 'unavailable', 'Voice input is not configured.')
  await page.getByRole('button', { name: 'Enable voice', exact: true }).click()
  await state(page, 'sent', 'Press the microphone to dictate. Review the text, then press Send.')
  await expect(page.locator('#standalone-voice [data-voice-delivery]')).toHaveText('Delivered to the agent')
})


test('a server stop during listening releases capture and enters ready', async ({ page }) => {
  await open(page)
  await listen(page)
  await page.evaluate(() => window.__emit('stopped', {}))
  await state(page, 'ready', 'Dictation ready. Review the text, then press Send.')
  expect(await page.evaluate(() => window.__captureStops)).toBe(1)
  await expect(page.locator(input)).toBeEditable()
})
