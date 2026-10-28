import { expect, test } from '@playwright/test'
import { openUnits } from './units-helpers.mjs'

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


// The voice socket decodes PCM16 little-endian: a byte-order slip would turn
// every dictation into noise without any error on either side.
test('voice capture module encodes 16 kHz PCM16 little-endian base64', async ({ page }) => {
  await openUnits(page)

  const encoded = await page.evaluate(() => {
    const capture = window.AiurVoiceCapture
    return capture.encodePcm16Base64(capture.downsample(new Float32Array([0, 1, -1]), 16000, 16000))
  })

  // 0 -> 00 00, 1 -> ff 7f, -1 -> 00 80
  expect(encoded).toBe('AAD/fwCA')
})

// Dictation and conversation are distinct server channels; joining the wrong
// topic (or without the CSRF token) would silently route speech to the wrong mode.
test('voice transport joins the requested topic with the CSRF param', async ({ page }) => {
  await openUnits(page)

  const joined = await page.evaluate(async () => {
    const record = {}
    window.AiurVoiceSocket = class {
      constructor(path, options) { Object.assign(record, { path, options }) }
      connect() {}
      channel(topic, payload) {
        Object.assign(record, { topic, payload })
        return {
          on() {},
          onError() {},
          onClose() {},
          join() {
            const push = { receive(status, callback) { if (status === 'ok') queueMicrotask(() => callback({})); return push } }
            return push
          }
        }
      }
    }

    await window.AiurVoiceTransport.open({ topic: 'voice:conversation' }).joined
    return { ...record, csrf: document.querySelector("meta[name='csrf-token']")?.getAttribute('content') }
  })

  expect(joined.path).toBe('/voice')
  expect(joined.topic).toBe('voice:conversation')
  expect(joined.csrf).toBeTruthy()
  expect(joined.options.params._csrf_token).toBe(joined.csrf)
})

// A connection lost while the AudioWorklet loads must end the attempt: the
// drawer may not claim it is listening with no capture behind it, and the
// microphone must stay usable for a retry.
