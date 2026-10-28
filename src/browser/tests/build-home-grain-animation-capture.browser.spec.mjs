import { test, expect } from '@playwright/test'
import { productScreenshot } from '../support/build-home-product.mjs'
import { assertStaticGrainCapture } from './support/build-home-grain-capture-test.mjs'

test('static grain capture pauses ambient infinite animations and resumes them', async ({ browser }) => {
  await assertStaticGrainCapture(browser)
})

// productScreenshot self-checks, moved from the removed design-parity harness (#6061).
// Synthetic captures: a real page.screenshot here can hit the same Chromium transient on the retry (#4054).
test('settle guard survives a transient capture failure', async () => {
  let n = 0
  let calls = 0
  let failed = false
  const target = { screenshot: async () => {
    calls++
    if (n === 3 && !failed) {
      failed = true
      throw new Error('page.screenshot: Protocol error (Page.captureScreenshot): Unable to capture screenshot')
    }
    return Buffer.from([n++])
  } }
  await expect(productScreenshot(target, { scale: 'device' })).rejects.toThrow('product capture did not settle after 10 attempts')
  expect(n).toBe(10)
  expect(calls).toBe(11)
})
test('stable capture recovers from a transient capture failure', async () => {
  const opts = { scale: 'device' }
  let calls = 0
  const target = { screenshot: async options => {
    expect(options).toMatchObject(opts)
    expect(options.style).toContain('*::-webkit-scrollbar-thumb { background: transparent !important; }')
    if (++calls === 1) throw new Error('page.screenshot: Protocol error (Page.captureScreenshot): Unable to capture screenshot')
    return Buffer.from('stable')
  } }
  expect((await productScreenshot(target, opts)).equals(Buffer.from('stable'))).toBe(true)
  expect(calls).toBe(3)
  expect(opts).toEqual({ scale: 'device' })
})
test('stable clipped capture includes thumb-hiding style without mutating caller options', async () => {
  const opts = { scale: 'device' }
  let calls = 0
  const target = { boundingBox: async () => ({ x: 10, y: 20, width: 30, height: 40 }) }
  const page = {
    evaluate: async () => ({ x: 2, y: 3 }),
    screenshot: async options => {
      expect(options).toMatchObject(opts)
      expect(options.style).toContain('*::-webkit-scrollbar-thumb { background: transparent !important; }')
      expect(options).toMatchObject({ fullPage: true, clip: { x: 12, y: 23, width: 30, height: 40 } })
      if (++calls === 1) throw new Error('page.screenshot: Protocol error (Page.captureScreenshot): Unable to capture screenshot')
      return Buffer.from('stable')
    }
  }
  expect((await productScreenshot(target, opts, page)).equals(Buffer.from('stable'))).toBe(true)
  expect(calls).toBe(3)
  expect(opts).toEqual({ scale: 'device' })
})
for (const [name, message, attempts] of [
  ['persistent capture failure', 'page.screenshot: Protocol error (Page.captureScreenshot): Unable to capture screenshot', 2],
  // Future regression guard: unrelated errors already propagated before the retry was added.
  ['unrelated protocol error', 'page.screenshot: Protocol error (Page.captureScreenshot): Target closed', 1]
]) {
  test(`stable capture propagates ${name}`, async () => {
    const error = new Error(message)
    let calls = 0
    const target = { screenshot: async () => { calls++; throw error } }
    await expect(productScreenshot(target, {})).rejects.toBe(error)
    expect(calls).toBe(attempts)
  })
}
