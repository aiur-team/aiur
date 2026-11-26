import {expect, test} from '@playwright/test'
import {openWritableVoice} from './support/voice-drawer-helpers.mjs'

for (const width of [1280, 390]) {
  test(`Executor comparison controls remain usable at ${width}px`, async ({page}) => {
    await page.setViewportSize({width, height: 720})
    await openWritableVoice(page)
    await page.getByRole('button', {name: 'Open chat for its-everdred/aiur #1110'}).click()
    const drawer = page.getByRole('dialog', {name: 'Responsive Units interface'})
    const provider = drawer.getByLabel('Conversation provider')
    await expect(provider).toBeVisible()
    await provider.selectOption('openai_realtime')
    await expect(provider).toHaveValue('openai_realtime')
    const model = drawer.getByLabel('Model for this session')
    await model.fill('chosen-model')
    await expect(model).toHaveValue('chosen-model')
    await provider.selectOption('elevenlabs_agents')
    await expect(provider).toHaveValue('elevenlabs_agents')
    await drawer.getByText('Compare providers and record Kevin’s rating', {exact: true}).click()
    await expect(drawer.getByRole('columnheader', {name: 'ElevenLabs', exact: true})).toBeVisible()
    await expect(drawer.getByRole('columnheader', {name: 'OpenAI', exact: true})).toBeVisible()
    await expect(drawer.getByText('Comparison usage unavailable.', {exact: true})).toBeVisible()
    await drawer.getByRole('button', {name: 'Choose voice input'}).click()
    await expect(drawer.getByRole('menuitem', {name: 'Dictate message'})).toBeVisible()
    await page.keyboard.press('Escape')
    await drawer.getByLabel('Message agent').fill('Comparison drawer remains usable')
    await expect(drawer.getByRole('button', {name: 'Send', exact: true})).toBeEnabled()
    const box = await provider.boundingBox()
    expect(box.x).toBeGreaterThanOrEqual(0)
    expect(box.x + box.width).toBeLessThanOrEqual(width)
  })
}

// Exercises the real Home link, production /voice LiveView and ExecutorVoice hook.
// Only media/provider transport is synthetic; no controller is manually constructed.
test('Home Settings opens the working Executor prototype with comparison and receipt delivery', async ({page}) => {
  const {dashboardCredentials} = await import('./support/layout-worker.mjs')
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.addInitScript(() => {
    window.__executorPushes = []
    window.__executorCaptureStarts = 0
    window.__executorCaptureStops = 0
    window.__executorMicrophones = 0
    window.AudioContext = class {
      async resume() {}
      async close() {}
    }
    const at = '2026-10-29T18:00:00Z'
    const comparison = {
      rows: [{id: 'browser-session', provider: 'openai_realtime', at, model: 'chosen-model', first_audio_ms: 140,
        minutes: 0.5, estimated_cost_usd: 0.09, status: 'ended', rating: null, note: ''}],
      meters: [{provider: 'elevenlabs_agents', used_seconds: 0, cap_seconds: 2700},
        {provider: 'openai_realtime', used_seconds: 30, cap_seconds: 2700}]
    }
    Object.defineProperty(window, 'AiurVoiceCapture', {
      configurable: true,
      set(value) {
        this.__executorCapture = {...value,
          requestMicrophone: async () => {
            window.__executorMicrophones++
            return {getTracks: () => [{stop() {}}]}
          },
          Capture: class {
            async start() { window.__executorCaptureStarts++ }
            stop() { window.__executorCaptureStops++ }
          }
        }
      },
      get() { return this.__executorCapture }
    })
    Object.defineProperty(window, 'AiurVoiceTransport', {
      configurable: true,
      set(_value) {
        this.__executorTransport = {open(options) {
          const transport = {
            joined: Promise.resolve({}),
            close() {},
            push(event, payload) {
              window.__executorPushes.push({topic: options.topic, event, payload})
              if (event === 'comparison_list') queueMicrotask(() => options.handlers.comparison(comparison))
              if (event === 'comparison_rate') {
                comparison.rows[0] = {...comparison.rows[0], rating: payload.rating, note: payload.note}
                queueMicrotask(() => options.handlers.comparison(comparison))
              }
              if (event === 'watch') queueMicrotask(() => options.handlers.receipt_status({id: payload.id, ack_status: 'received', wake_id: 'acceptance-wake', observed_at: at}))
              if (event === 'stop') queueMicrotask(() => {
                options.handlers.receipt({id: 101, at, summary_status: 'structured'})
                options.handlers.ended({})
              })
            }
          }
          if (options.topic === 'voice:executor') {
            window.__executorJoin = options.joinPayload()
            queueMicrotask(() => options.handlers.state({state: 'listening'}))
          }
          return transport
        }}
      },
      get() { return this.__executorTransport }
    })
  })
  await page.goto('/auth/writable')
  expect((await page.request.get('/executor-voice-control/configured')).ok()).toBe(true)
  try {
    await page.goto('/')
    await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
    await page.locator('#ax-cog').click()
    await page.getByRole('menuitem', {name: 'Talk to Executor', exact: true}).click()
    await expect(page).toHaveURL(/\/voice$/)
    const host = page.locator('#executor-voice-host')
    await expect(host.locator('[data-executor-voice-meter]')).toHaveText('ElevenLabs: 0.00 / 45 min used or reserved · OpenAI: 0.50 / 45 min used or reserved')
    await host.getByLabel('Conversation provider').selectOption('openai_realtime')
    await host.getByLabel('Model for this session').fill('chosen-model')
    await host.getByRole('button', {name: 'Talk to Executor', exact: true}).click()
    await expect(host.getByRole('button', {name: 'End Executor conversation', exact: true})).toBeEnabled()
    await expect.poll(() => page.evaluate(() => window.__executorJoin)).toEqual({provider: 'openai_realtime', model: 'chosen-model'})
    await expect.poll(() => page.evaluate(() => window.__executorCaptureStarts)).toBe(1)
    expect(await page.evaluate(() => window.__executorMicrophones)).toBe(1)
    await host.getByRole('button', {name: 'End Executor conversation', exact: true}).click()
    await expect(host.locator('[data-executor-voice-receipt]')).toContainText('SENT — receipt 101')
    await expect(host.locator('[data-executor-voice-receipt]')).toContainText('RECEIVED — wake acceptance-wake')
    await expect.poll(() => page.evaluate(() => window.__executorCaptureStops)).toBe(1)
    await host.getByText('Compare providers and record Kevin’s rating', {exact: true}).click()
    await expect(host.getByRole('columnheader', {name: 'ElevenLabs', exact: true})).toBeVisible()
    await expect(host.getByRole('columnheader', {name: 'OpenAI', exact: true})).toBeVisible()
    await expect(host.locator('[data-executor-voice-comparisons]')).toContainText('chosen-model · First audio: 140 ms · 0.50 min · USD 0.09 estimate')
    await host.getByLabel(/Kevin’s rating for openai_realtime/).selectOption('5')
    await host.getByLabel(/Kevin’s note for openai_realtime/).fill('acceptance browser')
    await host.getByRole('button', {name: 'Save rating and note', exact: true}).click()
    await expect.poll(() => page.evaluate(() => window.__executorPushes.filter(item => item.event === 'comparison_rate'))).toEqual([
      {topic: 'voice:executor_receipts', event: 'comparison_rate', payload: {id: 'browser-session', rating: 5, note: 'acceptance browser'}}
    ])
    await expect(host.getByLabel(/Kevin’s rating for openai_realtime/)).toHaveValue('5')
    await expect(host.getByLabel(/Kevin’s note for openai_realtime/)).toHaveValue('acceptance browser')
  } finally {
    expect((await page.request.get('/executor-voice-control/reset')).ok()).toBe(true)
  }
})
