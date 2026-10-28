import { test, expect } from '@playwright/test'

async function openVoice(page, query = '') {
  await page.addInitScript(() => {
    window.__micRequests = 0
    window.__trackStops = 0
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        enumerateDevices: async () => [],
        getUserMedia: async () => {
          window.__micRequests += 1
          return { getTracks: () => [{ stop() { window.__trackStops += 1 } }] }
        }
      }
    })
    window.AudioContext = class {
      constructor() {
        this.destination = {}
        this.audioWorklet = { addModule: async () => {} }
      }
      createMediaStreamSource() { return { connect: (target) => target, disconnect() {} } }
      createGain() { return { gain: { value: 1 }, connect: (target) => target, disconnect() {} } }
      async resume() {}
      close() {}
    }
    window.AudioWorkletNode = class {
      constructor() { this.port = {}; window.__worklet = this }
      connect(target) { return target }
      disconnect() {}
    }
  })
  await page.goto('/auth/writable')
  await page.goto('/streamdeck-control/writable')
  await page.goto(`/voice-input-fixture${query}`)
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
}

async function dictate(page, root = '#standalone-voice') {
  const form = page.locator(root)
  await form.getByRole('button', { name: 'Choose voice input' }).click()
  expect(await page.evaluate(() => window.__micRequests)).toBe(0)
  await form.getByRole('menuitem', { name: 'Dictate message' }).click()
  await expect(form.locator('[data-voice-status]')).toContainText('Listening')
  await expect(form.locator('[data-voice-input]')).toHaveAttribute('data-voice-recording', 'true')
  await page.evaluate(() => window.__worklet.port.onmessage({
    data: { samples: new Float32Array(800).fill(0.5), sampleRate: 16000 }
  }))
  await expect(form.locator('[data-voice-input]')).toHaveValue('hello')
  return form
}

async function patch(page, count) {
  await page.getByRole('button', { name: 'Server patch', exact: true }).click()
  await expect(page.locator('[data-voice-fixture]')).toHaveAttribute('data-patch', String(count))
}

test('VoiceInput dictates into a standalone form and waits for Send', async ({ page }) => {
  await openVoice(page)
  const form = await dictate(page)
  await form.getByRole('button', { name: 'Stop dictation' }).click()
  await expect(form.locator('[data-voice-input]')).toHaveValue('hello browser')
  await expect(form.getByRole('button', { name: 'Send', exact: true })).toBeEnabled()
  await expect(page.locator('[data-voice-fixture]')).toHaveAttribute('data-sent', '')
  await form.getByRole('button', { name: 'Send', exact: true }).click()
  await expect(page.locator('[data-voice-fixture]')).toHaveAttribute('data-sent', 'hello browser')
})

test('VoiceInput never requests the microphone before a click or without a textarea', async ({ page }) => {
  await openVoice(page)
  expect(await page.evaluate(() => window.__micRequests)).toBe(0)
  await patch(page, 1)
  expect(await page.evaluate(() => window.__micRequests)).toBe(0)
  await page.locator('#missing-input').getByRole('button', { name: 'Choose voice input' }).click()
  await page.locator('#missing-input').getByRole('menuitem', { name: 'Dictate message' }).click()
  expect(await page.evaluate(() => window.__micRequests)).toBe(0)
})

test('server patches during recording preserve dictated partials repeatedly', async ({ page }) => {
  await openVoice(page)
  const form = await dictate(page)
  // Blur the textarea: LiveView's focused-input protection must not mask the guard.
  await patch(page, 1)
  await expect(form.locator('[data-voice-input]')).toHaveValue('hello')
  await patch(page, 2)
  await expect(form.locator('[data-voice-input]')).toHaveValue('hello')
  await expect(form.locator('[data-voice-input]')).toHaveAttribute('data-voice-recording', 'true')
  await form.getByRole('button', { name: 'Stop dictation' }).click()
  await expect(form.locator('[data-voice-input]')).toHaveValue('hello browser')
  expect(await page.evaluate(() => window.__micRequests)).toBe(1)
})

test('after stop the server value wins again', async ({ page }) => {
  await openVoice(page)
  const form = await dictate(page)
  await form.getByRole('button', { name: 'Stop dictation' }).click()
  await expect(form.locator('[data-voice-input]')).toHaveValue('hello browser')
  await expect(form.locator('[data-voice-input]')).not.toHaveAttribute('data-voice-recording', 'true')
  await patch(page, 1)
  await expect(form.locator('[data-voice-input]')).toHaveValue('server 1')
})

test('destroying the standalone hook releases capture', async ({ page }) => {
  await openVoice(page)
  await dictate(page)
  await page.getByRole('button', { name: 'Remove form' }).click()
  await expect(page.locator('#standalone-voice')).toHaveCount(0)
  await expect.poll(() => page.evaluate(() => window.__trackStops)).toBe(1)
})

test('the component hook attribute contains the caller-owned composer', async ({ page }) => {
  await openVoice(page)
  const form = await dictate(page, '#component-voice')
  await form.getByRole('button', { name: 'Stop dictation' }).click()
  await expect(form.locator('[data-voice-input]')).toHaveValue('hello browser')
  await expect(page.locator('#standalone-input')).toHaveValue('')
  await expect(page.locator('[data-voice-fixture]')).toHaveAttribute('data-sent', '')
})

test('modal dictation fills the message box and waits for Send', async ({ page }) => {
  await openVoice(page, '?modal=true')
  const form = await dictate(page, '#agent-log-composer-1110')
  await expect(form.getByRole('button', { name: 'Send', exact: true })).toBeDisabled()
  await form.getByRole('button', { name: 'Stop dictation' }).click()
  await expect(form.getByLabel('Message agent', { exact: true })).toHaveValue('hello browser')
  await expect(page.locator('[data-voice-fixture]')).toHaveAttribute('data-sent', '')
  await expect(page.locator('#standalone-input')).toHaveValue('')
  await form.getByRole('button', { name: 'Send', exact: true }).click()
  await expect(page.locator('[data-voice-fixture]')).toHaveAttribute('data-sent', 'hello browser')
})

test('closing the agent log modal releases its recording', async ({ page }) => {
  await openVoice(page, '?modal=true')
  await dictate(page, '#agent-log-composer-1110')
  await page.getByRole('dialog', { name: '1110', exact: true }).getByRole('button', { name: 'Close', exact: true }).click()
  await expect(page.locator('#agent-log-composer-1110')).toHaveCount(0)
  await expect.poll(() => page.evaluate(() => window.__trackStops)).toBe(1)
})
