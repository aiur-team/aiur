import { fileURLToPath } from 'node:url'
import { test, expect } from '@playwright/test'

async function open(page, drawer = false) {
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
  await page.goto(drawer ? '/units-fixture' : '/voice-input-fixture')
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
  if (drawer) await page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()
  return drawer ? page.getByRole('dialog', { name: 'Responsive Units interface' }) : page.locator('#standalone-voice')
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

for (const target of ['input', 'control']) {
  test(`Escape from ${target} cancels without closing the drawer; idle Escape closes it`, async ({ page }) => {
    const drawer = await open(page, true)
    const input = drawer.locator('[data-voice-input]')
    await input.fill('original draft')
    await listen(drawer)
    await page.evaluate(() => window.__emit('transcript', { kind: 'final', text: 'hello' }))
    await expect(input).toHaveValue('original draft hello')
    // The transcript dispatches phx-change. Let that patch settle before
    // focusing Cancel: its server-rendered hidden attribute can drop focus.
    await expect(page.locator('[data-units-fixture]')).toHaveAttribute('data-voice-draft', 'original draft hello')
    const focus = target === 'input' ? input : drawer.getByRole('button', { name: 'Cancel', exact: true })
    await focus.press('Escape')
    await expect(drawer).toBeVisible()
    await expect(input).toHaveValue('original draft')
    await expect(page.locator('[data-units-fixture]')).toHaveAttribute('data-voice-draft', 'original draft')
    expect(await page.evaluate(() => window.__pushes)).toEqual(['cancel'])
    await input.press('Escape')
    await expect(drawer).toHaveCount(0)
  })
}
