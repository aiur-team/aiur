import './support/voice-modules-cases.mjs'
import './support/voice-choice-cases.mjs'
import { expect, test } from '@playwright/test'
import { openVoice, openWritableVoice } from './support/voice-drawer-helpers.mjs'

test('Voice drawer dictation explains microphone permission denial in the standard composer', async ({ page }) => {
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

  await openVoice(page)
  await page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()

  const drawer = page.getByRole('dialog', { name: 'Responsive Units interface' })
  const mic = drawer.getByRole('menuitem', { name: 'Dictate message' })
  await drawer.getByRole('button', { name: 'Choose voice input' }).click()
  await expect(mic).toBeEnabled()
  await mic.click()

  await expect(drawer.locator('[data-voice-status]')).toContainText(
    'Microphone permission was denied for this origin. Allow it in site settings, then try again.'
  )
  await expect(drawer.getByLabel('Message agent')).toHaveValue('')
  await expect(drawer.locator('[data-voice-mic]')).toHaveAttribute('aria-pressed', 'false')
})

test('Voice drawer dictation releases a microphone that arrives after the modal closes', async ({ page }) => {
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

  await openVoice(page)
  await page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()
  const drawer = page.getByRole('dialog', { name: 'Responsive Units interface' })
  await drawer.getByRole('button', { name: 'Choose voice input' }).click()
  await drawer.getByRole('menuitem', { name: 'Dictate message' }).click()
  await drawer.getByRole('button', { name: 'Close' }).click()
  await expect(drawer).toHaveCount(0)

  await page.evaluate(() => {
    window.__resolveVoiceStream({
      getTracks: () => [{ stop: () => { window.__voiceTrackStops += 1 } }]
    })
  })

  await expect.poll(() => page.evaluate(() => window.__voiceTrackStops)).toBe(1)
})

test('Voice drawer dictation streams a waveform into the composer and waits for Send', async ({ page }) => {
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

  await openVoice(page)
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
      channel(topic, payload) {
        window.__voiceJoin = { topic, payload }
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
  const mic = drawer.getByRole('menuitem', { name: 'Dictate message' })
  const waveform = drawer.getByLabel('Microphone waveform')
  const before = await waveform.evaluate((canvas) => canvas.toDataURL())

  await drawer.getByRole('button', { name: 'Choose voice input' }).click()
  await mic.click()
  await expect(drawer.getByRole('button', { name: 'Stop dictation' })).toHaveAttribute('aria-pressed', 'true')
  await expect(drawer.getByLabel('Message agent')).toHaveAttribute('readonly', '')
  await expect(drawer.getByRole('button', { name: 'Send' })).toBeDisabled()
  await expect.poll(() => page.evaluate(() => window.__voiceSocketOptions?.params?._csrf_token)).not.toBeFalsy()
  const join = await page.evaluate(() => window.__voiceJoin)
  expect(join.topic).toBe('voice:dictate')
  expect(join.payload).toMatchObject({ v: 1, mode: 'dictate', surface: 'agent_composer', target: { kind: 'worker', ticket: '1110' } })
  expect(join.payload.client_session_id).toMatch(/^[a-f0-9-]{36}$/)

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
  await expect(page.locator('[data-voice-drawer-fixture]')).toHaveAttribute('data-sent-message', '')

  await drawer.getByRole('button', { name: 'Send' }).click()
  await expect(page.locator('[data-voice-drawer-fixture]')).toHaveAttribute('data-sent-message', 'hello browser')

  await drawer.getByRole('button', { name: 'Choose voice input' }).click()
  await drawer.getByRole('menuitem', { name: 'Dictate message' }).click()
  await expect(drawer.getByRole('button', { name: 'Stop dictation' })).toHaveAttribute('aria-pressed', 'true')
  await page.evaluate(() => window.__voiceChannel.closeHandler())
  await expect(drawer.locator('[data-voice-status]')).toContainText(
    'Speech-to-text connection was lost. Try dictation again.'
  )
  await expect(drawer.locator('[data-voice-mic]')).toHaveAttribute('aria-pressed', 'false')
  await expect.poll(() => page.evaluate(() => window.__voiceTrackStops)).toBe(2)
})

test('Voice drawer dictation crosses the authenticated Phoenix voice socket', async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        enumerateDevices: async () => [],
        getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] })
      }
    })
  })

  await openWritableVoice(page)
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
  await drawer.getByRole('button', { name: 'Choose voice input' }).click()
  await drawer.getByRole('menuitem', { name: 'Dictate message' }).click()
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

test('Voice drawer interactive voice chat sends speech and plays the next agent reply', async ({ page }) => {
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

  await openWritableVoice(page)
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

  await expect(page.locator('[data-voice-drawer-fixture]')).toHaveAttribute('data-sent-message', 'hello browser')
  await expect(drawer.locator('[data-voice-mic]')).toBeDisabled()
  await expect(drawer.getByRole('button', { name: 'Cancel waiting for voice reply' })).toBeEnabled()
  await expect(drawer.locator('.conversation-message-agent[data-message-complete="false"]')).toContainText('Voice reply')
  await expect.poll(() => page.evaluate(() => window.__voicePlaybackStarts)).toBe(0)
  await page.getByRole('button', { name: 'Complete voice reply' }).evaluate((button) => button.click())
  await expect(drawer).toContainText('Voice reply from the agent.')
  await expect.poll(() => page.evaluate(() => window.__voicePlaybackStarts)).toBe(1)
  await expect(drawer.locator('[data-voice-status]')).toContainText(
    'Reply finished. Press the conversation button to speak again.'
  )
})

test('Voice drawer dictation recovers when the voice connection closes while capture starts', async ({ page }) => {
  await page.addInitScript(() => {
    window.__voiceTrackStops = 0
    window.__openAudioContexts = 0
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        enumerateDevices: async () => [],
        getUserMedia: async () => ({ getTracks: () => [{ stop() { window.__voiceTrackStops += 1 } }] })
      }
    })
  })

  await openVoice(page)
  await page.evaluate(() => {
    class FakePush {
      receive(status, callback) {
        if (status === 'ok') queueMicrotask(() => callback({}))
        return this
      }
    }

    window.AiurVoiceSocket = class {
      connect() {}
      disconnect() {}
      channel() {
        window.__voiceChannel = {
          on() {},
          onError() {},
          onClose(callback) { this.closeHandler = callback },
          join: () => new FakePush(),
          leave() {},
          push() { return new FakePush() }
        }
        return window.__voiceChannel
      }
    }

    window.AudioContext = class {
      constructor() {
        window.__openAudioContexts += 1
        this.destination = {}
        this.audioWorklet = {
          addModule: () => new Promise((resolve) => { window.__finishWorkletLoad = resolve })
        }
      }
      createMediaStreamSource() { return { connect: (target) => target, disconnect() {} } }
      createGain() { return { gain: { value: 1 }, connect: (target) => target, disconnect() {} } }
      async resume() {}
      close() { window.__openAudioContexts -= 1 }
    }

    window.AudioWorkletNode = class {
      constructor() { this.port = {} }
      connect(target) { return target }
      disconnect() {}
    }
  })

  await page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()
  const drawer = page.getByRole('dialog', { name: 'Responsive Units interface' })
  await drawer.getByRole('button', { name: 'Choose voice input' }).click()
  await drawer.getByRole('menuitem', { name: 'Dictate message' }).click()
  await expect.poll(() => page.evaluate(() => typeof window.__finishWorkletLoad)).toBe('function')

  await page.evaluate(() => window.__voiceChannel.closeHandler())
  await page.evaluate(() => window.__finishWorkletLoad())

  await expect(drawer.locator('[data-voice-status]')).toContainText(
    'Speech-to-text connection was lost. Try dictation again.'
  )
  await expect(drawer.locator('[data-voice-mic]')).toHaveAttribute('aria-pressed', 'false')
  await expect(drawer.locator('[data-voice-mic]')).toBeEnabled()
  await expect(drawer.getByLabel('Message agent')).not.toHaveAttribute('readonly', '')
  expect(await page.evaluate(() => window.__voiceTrackStops)).toBe(1)
  expect(await page.evaluate(() => window.__openAudioContexts)).toBe(0)
})

test('Mobile conversation drawer avoids focus zoom and follows new rows only while pinned', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await openVoice(page)
  await page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()
  const drawer = page.getByRole('dialog', { name: 'Responsive Units interface' })
  const composer = drawer.getByLabel('Message agent')
  const scroll = drawer.locator('[data-conversation-scroll]')
  const rows = scroll.locator('.conversation-drawer-messages > li')
  const lastMessage = () => rows.last()
  await scroll.evaluate((element) => { element.style.height = '32px'; element.style.minHeight = '0' })

  await expect(composer).toHaveCSS('font-size', '16px')
  const scaleBefore = await page.evaluate(() => visualViewport.scale)
  await composer.focus()
  expect(await page.evaluate(() => visualViewport.scale)).toBe(scaleBefore)

  await composer.fill(`${'A long message that wraps onto several lines. '.repeat(10)}`)
  await expect.poll(() => composer.evaluate((element) => element.getBoundingClientRect().height)).toBeGreaterThan(38)
  await expect.poll(() => composer.evaluate((element) => element.getBoundingClientRect().height)).toBeLessThanOrEqual(140)
  expect(await composer.evaluate((element) => element.scrollHeight)).toBeGreaterThan(await composer.evaluate((element) => element.clientHeight))
  await expect(drawer).toHaveClass(/is-chat-composer-focused/)
  await expect.poll(() => scroll.evaluate((element) => element.scrollHeight - element.clientHeight - element.scrollTop)).toBeLessThanOrEqual(24)

  await page.evaluate(() => {
    const viewport = window.visualViewport
    Object.defineProperty(viewport, 'height', { configurable: true, value: 400 })
    viewport.dispatchEvent(new Event('resize'))
  })
  await expect.poll(() => page.evaluate(() => {
    const viewport = window.visualViewport
    const rect = document.querySelector('[data-conversation-scroll] .conversation-drawer-messages > li:last-child').getBoundingClientRect()
    return rect.top >= viewport.offsetTop && rect.bottom <= viewport.offsetTop + viewport.height
  })).toBe(true)
  expect(await composer.evaluate((element) => element.getBoundingClientRect().bottom)).toBeLessThanOrEqual(400)

  await scroll.evaluate((element) => { element.scrollTop = element.scrollHeight })
  const countBeforePinnedAppend = await rows.count()
  await page.locator('[phx-click="complete-voice-reply"]').evaluate((button) => button.click())
  await expect(lastMessage()).toContainText('Voice reply from the agent.')
  await expect(rows).toHaveCount(countBeforePinnedAppend + 1)
  await expect.poll(() => scroll.evaluate((element) => element.scrollHeight - element.clientHeight - element.scrollTop)).toBeLessThanOrEqual(24)

  await drawer.getByRole('button', { name: 'Close' }).click()
  await page.getByRole('button', { name: 'Open chat for its-everdred/aiur #1110' }).click()
  await expect(drawer).toBeVisible()
  await scroll.evaluate((element) => { element.style.height = '32px'; element.style.minHeight = '0'; element.scrollTop = 0 })
  await expect.poll(() => scroll.evaluate((element) => element.scrollHeight - element.clientHeight)).toBeGreaterThan(24)
  await scroll.evaluate((element) => { element.scrollTop = element.scrollHeight; element.dispatchEvent(new Event('scroll')) })
  await page.evaluate(() => {
    const requestFrame = window.requestAnimationFrame
    window.__queuedViewportFrame = null
    window.requestAnimationFrame = (callback) => { window.__queuedViewportFrame = callback; return 321 }
    window.visualViewport.dispatchEvent(new Event('resize'))
    window.requestAnimationFrame = requestFrame
  })
  await scroll.evaluate((element) => { element.scrollTop = 0; element.dispatchEvent(new Event('scroll')) })
  expect(await page.evaluate(() => typeof window.__queuedViewportFrame)).toBe('function')
  await page.evaluate(() => window.__queuedViewportFrame?.())
  expect(await scroll.evaluate((element) => element.scrollTop)).toBe(0)
  await composer.fill(`${'A long message that wraps onto several lines. '.repeat(10)}`)
  expect(await scroll.evaluate((element) => element.scrollTop)).toBe(0)
  const countBeforeHistoryAppend = await rows.count()
  await page.locator('[phx-click="complete-voice-reply"]').evaluate((button) => button.click())
  await expect(lastMessage()).toContainText('Voice reply from the agent.')
  await expect(rows).toHaveCount(countBeforeHistoryAppend + 1)
  expect(await scroll.evaluate((element) => element.scrollTop)).toBe(0)
  await expect(drawer.getByRole('button', { name: 'Jump to latest' })).toBeVisible()
})
