import { expect, test } from '@playwright/test'
import { openUnits, openWritableUnits } from './support/units-helpers.mjs'

test('Units dictation explains microphone permission denial in the standard composer', async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        enumerateDevices: async () => [],
        getUserMedia: async () => {
          throw new DOMException('permission denied by browser test', 'NotAllowedError')
        }
      }
    })
  })

  await openUnits(page)
  await page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()

  const drawer = page.getByRole('dialog', { name: 'Responsive Units interface' })
  const mic = drawer.getByRole('button', { name: 'Dictate message' })
  await expect(mic).toBeEnabled()
  await mic.click()

  await expect(drawer.locator('[data-voice-status]')).toContainText(
    'Microphone permission was denied for this origin. Allow it in site settings, then try again.'
  )
  await expect(drawer.getByLabel('Message agent')).toHaveValue('')
  await expect(mic).toHaveAttribute('aria-pressed', 'false')
})

test('Units dictation releases a microphone that arrives after the modal closes', async ({ page }) => {
  await page.addInitScript(() => {
    window.__voiceTrackStops = 0
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        enumerateDevices: async () => [],
        getUserMedia: () => new Promise((resolve) => { window.__resolveVoiceStream = resolve })
      }
    })
  })

  await openUnits(page)
  await page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()
  const drawer = page.getByRole('dialog', { name: 'Responsive Units interface' })
  await drawer.getByRole('button', { name: 'Dictate message' }).click()
  await drawer.getByRole('button', { name: 'Close' }).click()
  await expect(drawer).toHaveCount(0)

  await page.evaluate(() => {
    window.__resolveVoiceStream({
      getTracks: () => [{ stop: () => { window.__voiceTrackStops += 1 } }]
    })
  })

  await expect.poll(() => page.evaluate(() => window.__voiceTrackStops)).toBe(1)
})

test('Units dictation streams a waveform into the composer and waits for Send', async ({ page }) => {
  await page.addInitScript(() => {
    window.__voiceTrackStops = 0
    const track = { stop() { window.__voiceTrackStops += 1 } }
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        enumerateDevices: async () => [{ kind: 'audioinput', deviceId: 'browser-mic-1', label: 'Desk microphone' }],
        getUserMedia: async () => ({ getTracks: () => [track] })
      }
    })
  })

  await openUnits(page)
  await page.evaluate(() => {
    class FakePush {
      receive(status, callback) {
        if (status === 'ok') queueMicrotask(() => callback({}))
        return this
      }
    }

    class FakeChannel {
      constructor() { this.handlers = {} }
      on(event, callback) { this.handlers[event] = callback }
      onError(callback) { this.errorHandler = callback }
      onClose(callback) { this.closeHandler = callback }
      join() { return new FakePush() }
      leave() {}
      push(event) {
        window.__voicePushes = [...(window.__voicePushes || []), event]
        if (event === 'audio') {
          queueMicrotask(() => this.handlers.transcript?.({ kind: 'partial', text: 'hello' }))
        } else if (event === 'stop') {
          queueMicrotask(() => this.handlers.transcript?.({ kind: 'final', text: 'hello browser' }))
          queueMicrotask(() => this.handlers.stopped?.({}))
        }
        return new FakePush()
      }
    }

    window.AiurVoiceSocket = class {
      constructor(_path, options) { window.__voiceSocketOptions = options }
      connect() {}
      disconnect() {}
      channel() {
        window.__voiceChannel = new FakeChannel()
        return window.__voiceChannel
      }
    }

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
      constructor() {
        this.port = {}
        window.__voiceWorklet = this
      }
      connect(target) { return target }
      disconnect() {}
    }
  })

  await page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()
  const drawer = page.getByRole('dialog', { name: 'Responsive Units interface' })
  const mic = drawer.getByRole('button', { name: 'Dictate message' })
  const waveform = drawer.getByLabel('Microphone waveform')
  const before = await waveform.evaluate((canvas) => canvas.toDataURL())

  await mic.click()
  await expect(drawer.getByRole('button', { name: 'Stop dictation' })).toHaveAttribute('aria-pressed', 'true')
  await expect(drawer.getByLabel('Message agent')).toHaveAttribute('readonly', '')
  await expect(drawer.getByRole('button', { name: 'Send' })).toBeDisabled()
  await expect.poll(() => page.evaluate(() => window.__voiceSocketOptions?.params?._csrf_token)).not.toBeFalsy()

  await page.evaluate(() => {
    const samples = new Float32Array(800)
    for (let index = 0; index < samples.length; index += 1) samples[index] = index % 2 === 0 ? 0.75 : -0.5
    window.__voiceWorklet.port.onmessage({ data: { samples, sampleRate: 16000 } })
  })

  await expect.poll(() => waveform.evaluate((canvas) => canvas.toDataURL())).not.toBe(before)
  await expect(drawer.getByLabel('Message agent')).toHaveValue('hello')
  await expect(drawer.getByRole('button', { name: 'Stop dictation' })).toHaveAttribute('aria-pressed', 'true')
  await drawer.getByRole('button', { name: 'Stop dictation' }).click()
  await expect(drawer.getByLabel('Message agent')).toHaveValue('hello browser')
  await expect(drawer.getByLabel('Message agent')).not.toHaveAttribute('readonly', '')
  await expect(drawer.getByRole('button', { name: 'Send' })).toBeEnabled()
  await expect(page.locator('[data-units-fixture]')).toHaveAttribute('data-sent-message', '')

  await drawer.getByRole('button', { name: 'Send' }).click()
  await expect(page.locator('[data-units-fixture]')).toHaveAttribute('data-sent-message', 'hello browser')

  await drawer.getByRole('button', { name: 'Dictate message' }).click()
  await expect(drawer.getByRole('button', { name: 'Stop dictation' })).toHaveAttribute('aria-pressed', 'true')
  await page.evaluate(() => window.__voiceChannel.closeHandler())
  await expect(drawer.locator('[data-voice-status]')).toContainText(
    'Speech-to-text connection closed. Try dictation again.'
  )
  await expect(drawer.getByRole('button', { name: 'Dictate message' })).toHaveAttribute('aria-pressed', 'false')
  await expect.poll(() => page.evaluate(() => window.__voiceTrackStops)).toBe(2)
})

test('Units dictation crosses the authenticated Phoenix voice socket', async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        enumerateDevices: async () => [],
        getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] })
      }
    })
  })

  await openWritableUnits(page)
  await page.evaluate(() => {
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
      constructor() {
        this.port = {}
        window.__realVoiceWorklet = this
      }
      connect(target) { return target }
      disconnect() {}
    }
  })

  await page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()
  const drawer = page.getByRole('dialog', { name: 'Responsive Units interface' })
  await drawer.getByRole('button', { name: 'Dictate message' }).click()
  await expect(drawer.getByRole('button', { name: 'Stop dictation' })).toHaveAttribute('aria-pressed', 'true')

  await page.evaluate(() => {
    window.__realVoiceWorklet.port.onmessage({
      data: { samples: new Float32Array(800).fill(0.5), sampleRate: 16000 }
    })
  })

  await expect(drawer.getByLabel('Message agent')).toHaveValue('hello')
  await drawer.getByRole('button', { name: 'Stop dictation' }).click()
  await expect(drawer.getByLabel('Message agent')).toHaveValue('hello browser')
  await expect(drawer.getByRole('button', { name: 'Send' })).toBeEnabled()
})

test('Units interactive voice chat sends speech and plays the next agent reply', async ({ page }) => {
  await page.addInitScript(() => {
    window.__voicePlaybackStarts = 0
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        enumerateDevices: async () => [],
        getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] })
      }
    })

    window.AudioContext = class {
      constructor() {
        this.currentTime = 0
        this.destination = {}
        this.audioWorklet = { addModule: async () => {} }
      }
      createMediaStreamSource() { return { connect: (target) => target, disconnect() {} } }
      createGain() { return { gain: { value: 1 }, connect: (target) => target, disconnect() {} } }
      createBuffer(_channels, length, sampleRate) {
        if (!this.resumed) throw new Error('reply AudioContext was not unlocked by the conversation click')
        return {
          duration: length / sampleRate,
          getChannelData: () => new Float32Array(length)
        }
      }
      createBufferSource() {
        return {
          connect() {},
          start() { window.__voicePlaybackStarts += 1 },
          stop() {},
          disconnect() {}
        }
      }
      async resume() { this.resumed = true }
      close() {}
    }

    window.AudioWorkletNode = class {
      constructor() {
        this.port = {}
        window.__conversationVoiceWorklet = this
      }
      connect(target) { return target }
      disconnect() {}
    }
  })

  await openWritableUnits(page)
  await page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()

  const drawer = page.getByRole('dialog', { name: 'Responsive Units interface' })
  const conversation = drawer.getByRole('button', { name: 'Start interactive voice chat' })
  await conversation.click()
  await expect(drawer.getByRole('button', { name: 'Stop interactive voice chat' })).toHaveAttribute('aria-pressed', 'true')

  await page.evaluate(() => {
    window.__conversationVoiceWorklet.port.onmessage({
      data: { samples: new Float32Array(800).fill(0.5), sampleRate: 16000 }
    })
  })

  await expect(drawer.getByLabel('Message agent')).toHaveValue('hello')
  await drawer.getByRole('button', { name: 'Stop interactive voice chat' }).click()

  await expect(page.locator('[data-units-fixture]')).toHaveAttribute('data-sent-message', 'hello browser')
  await expect(drawer.getByRole('button', { name: 'Dictate message' })).toBeDisabled()
  await expect(drawer.getByRole('button', { name: 'Cancel waiting for voice reply' })).toBeEnabled()
  await expect(drawer.locator('.conversation-message-agent[data-message-complete="false"]')).toContainText('Voice reply')
  await expect.poll(() => page.evaluate(() => window.__voicePlaybackStarts)).toBe(0)
  await expect(drawer).toContainText('Voice reply from the agent.')
  await expect.poll(() => page.evaluate(() => window.__voicePlaybackStarts)).toBe(1)
  await expect(drawer.locator('[data-voice-status]')).toContainText(
    'Reply finished. Press the conversation button to speak again.'
  )
})

test('Units interactive voice chat can cancel an indefinitely queued reply', async ({ page }) => {
  await openUnits(page)

  const state = await page.evaluate(() => {
    const root = document.createElement('div')
    root.innerHTML = `
      <form><textarea data-voice-input>queued turn</textarea><button data-voice-send type="submit">Send</button></form>
      <button data-voice-mic></button><button data-voice-conversation></button>
      <p data-voice-status></p><canvas data-voice-waveform></canvas>
    `
    document.body.append(root)

    const controller = new window.AiurConversationVoiceController({ el: root })
    controller.bindElements()
    controller.awaitingReply = true
    controller.conversationActive = true
    controller.channel = { leave() { window.__cancelChannelLeft = true } }
    controller.socket = { disconnect() { window.__cancelSocketDisconnected = true } }
    controller.syncElements()
    root.querySelector('[data-voice-conversation]').click()

    return {
      status: root.querySelector('[data-voice-status]').textContent,
      inputReadOnly: root.querySelector('[data-voice-input]').readOnly,
      conversationLabel: root.querySelector('[data-voice-conversation]').getAttribute('aria-label'),
      channelLeft: window.__cancelChannelLeft,
      socketDisconnected: window.__cancelSocketDisconnected
    }
  })

  expect(state.status).toContain('Voice reply cancelled')
  expect(state.inputReadOnly).toBe(false)
  expect(state.conversationLabel).toBe('Start interactive voice chat')
  expect(state.channelLeft).toBe(true)
  expect(state.socketDisconnected).toBe(true)
})

test('Units interactive voice chat recovers after a silent turn', async ({ page }) => {
  await openUnits(page)

  const state = await page.evaluate(() => {
    const root = document.createElement('div')
    root.innerHTML = `
      <form><textarea data-voice-input></textarea><button data-voice-send type="submit">Send</button></form>
      <button data-voice-mic></button><button data-voice-conversation></button>
      <p data-voice-status></p><canvas data-voice-waveform></canvas>
    `
    document.body.append(root)

    const controller = new window.AiurConversationVoiceController({ el: root })
    controller.bindElements()
    controller.conversationActive = true
    controller.channel = { leave() { window.__silentChannelLeft = true } }
    controller.socket = { disconnect() { window.__silentSocketDisconnected = true } }
    controller.submitConversationTurn()

    return {
      status: root.querySelector('[data-voice-status]').textContent,
      conversationActive: controller.conversationActive,
      channelLeft: window.__silentChannelLeft,
      socketDisconnected: window.__silentSocketDisconnected
    }
  })

  expect(state.status).toContain('I did not hear a message')
  expect(state.conversationActive).toBe(false)
  expect(state.channelLeft).toBe(true)
  expect(state.socketDisconnected).toBe(true)
})

