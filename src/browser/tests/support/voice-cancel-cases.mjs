import { fileURLToPath } from 'node:url'
import { test, expect } from '@playwright/test'

async function open(page) {
  await page.route(/\/(conversation-voice-controller|voice-mode-choice)\.js$/, route => {
    const file = new URL(route.request().url()).pathname.split('/').pop()
    return route.fulfill({ path: fileURLToPath(new URL(`../../../priv/static/${file}`, import.meta.url)), contentType: 'application/javascript' })
  })
  await page.addInitScript(() => {
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: {
      enumerateDevices: async () => [],
      getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] })
    } })
  })
  await page.goto('/auth/writable')
  await page.goto('/streamdeck-control/writable')
  await page.goto('/voice-input-fixture')
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
  await page.evaluate(() => {
    window.__pushes = []
    window.__captureStops = 0
    window.AudioContext = class {}
    window.AudioWorkletNode = class {}
    window.AiurVoiceCapture.Capture = class {
      async start() {}
      stop() { window.__captureStops++ }
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
          onClose() {}, leave() {},
          push(event) { window.__pushes.push(event) },
          join() { return { receive(event, callback) {
            if (event === 'ok') queueMicrotask(() => callback({}))
            return this
          } } }
        }
      }
    }
  })
  return page.locator('#standalone-voice')
}

async function listen(form) {
  await form.getByRole('button', { name: 'Choose voice input' }).click()
  await form.getByRole('menuitem', { name: 'Dictate message' }).click()
  await expect(form.locator('[data-voice-status]')).toContainText('Listening')
}

for (const finishing of [false, true]) {
  test(`Cancel restores exact pre-recording text while ${finishing ? 'finishing' : 'listening'} and ignores late events`, async ({ page }) => {
    const form = await open(page)
    const input = form.locator('[data-voice-input]')
    const draft = '  draft\nwith spacing  '
    await input.fill(draft)
    await expect(form.getByRole('button', { name: 'Cancel', exact: true })).toBeHidden()
    await listen(form)
    await page.evaluate(() => {
      window.__emit('transcript', { kind: 'final', text: 'hello' })
      window.__emit('transcript', { kind: 'partial', text: 'unfinished' })
    })
    await expect(input).toHaveValue('draft\nwith spacing hello unfinished')
    if (finishing) {
      await form.getByRole('button', { name: 'Stop dictation' }).click()
      await expect(form.locator('[data-voice-status]')).toHaveText('Finishing transcription…')
    }
    await form.getByRole('button', { name: 'Cancel', exact: true }).click()
    await expect(input).toHaveValue(draft)
    await expect(input).toBeEditable()
    await expect(form.locator('[data-voice-root]')).toHaveAttribute('data-voice-state', 'idle')
    expect(await page.evaluate(() => window.__pushes)).toEqual(finishing ? ['stop', 'cancel'] : ['cancel'])
    expect(await page.evaluate(() => window.__captureStops)).toBe(1)
    await page.evaluate(() => {
      window.__emit('transcript', { kind: 'final', text: 'late transcript' })
      window.__emit('stopped', {})
      window.__lose()
    })
    await expect(input).toHaveValue(draft)
    await form.getByRole('button', { name: 'Send', exact: true }).click()
    await expect(page.locator('[data-voice-fixture]')).toHaveAttribute('data-sent', draft)
  })
}
