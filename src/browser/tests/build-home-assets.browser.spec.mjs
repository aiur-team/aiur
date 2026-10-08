import { test, expect } from '@playwright/test'
import { fileURLToPath } from 'node:url'
import { openFixture } from './support/browser-helpers.mjs'

const callbacks = ['mounted', 'beforeUpdate', 'updated', 'destroyed', 'disconnected', 'reconnected']
const spyModule = `export function createBuildHomeHook() {
  window.created = true;
  return Object.fromEntries(${JSON.stringify(callbacks)}.map(name => [name, function () {
    window.calls.push([name, this.el === window.ctx.el, this.pushEvent === window.ctx.pushEvent,
      this.handleEvent === window.ctx.handleEvent]);
    if (name === 'mounted') this.el.dataset.buildHomeHook = 'mounted';
  }]));
}`

async function mount(page) {
  return page.evaluate(() => {
    window.calls = []
    window.ctx = { el: document.createElement('div'), pushEvent() {}, handleEvent() {} }
    window.hook = window.AiurBuildHome.createLiveViewHook()
    window.hook.mounted.call(window.ctx)
    return window.ctx.el.dataset.buildHomeHook
  })
}

async function health(page) {
  return page.evaluate(() => window.ctx.el.dataset.buildHomeHook)
}

test('B1: fixture registration, stub health and every callback preserve context', async ({ page }) => {
  await openFixture(page)
  expect(await page.evaluate(() => Object.keys(window.BrowserHarnessHooks.BuildHome).sort())).toEqual([...callbacks].sort())
  expect(await mount(page)).toBe('loading')
  await expect.poll(() => health(page)).toBe('mounted')
  // A fresh document clears the browser module map before routing a spy module.
  await page.reload()
  await page.route('**/build-home/hook.js', route => route.fulfill({ contentType: 'text/javascript', body: spyModule }))
  expect(await mount(page)).toBe('loading')
  await expect.poll(() => health(page)).toBe('mounted')
  await page.evaluate(names => [...names.filter(name => name !== 'mounted' && name !== 'destroyed'), 'destroyed'].forEach(name => window.hook[name].call(window.ctx)), callbacks)
  expect(await page.evaluate(() => window.calls)).toEqual(['mounted', 'beforeUpdate', 'updated', 'disconnected', 'reconnected', 'destroyed'].map(name => [name, true, true, true]))
  expect(await page.evaluate(() => window.ctx.__buildHome)).toBeNull()
})

for (const [name, response] of [
  ['B2: HTTP failure', { status: 500, body: 'unavailable' }],
  ['B2: syntax error', { contentType: 'text/javascript', body: 'export function {' }],
  ['B3: missing factory', { contentType: 'text/javascript', body: 'export const other = true' }],
  ['B3: mounted throws', { contentType: 'text/javascript', body: 'export function createBuildHomeHook() { return { mounted() { throw new Error("broken") } } }' }]
]) {
  test(name, async ({ page }) => {
    await page.route('**/build-home/hook.js', route => route.fulfill(response))
    await openFixture(page)
    expect(await mount(page)).toBe('loading')
    await expect.poll(() => health(page)).toBe('failed')
  })
}

for (const failure of [false, true]) {
  test(`B4: destroy before ${failure ? 'failed' : 'successful'} import drops late work`, async ({ page }) => {
    let release
    const held = new Promise(resolve => { release = resolve })
    let received
    const requested = new Promise(resolve => { received = resolve })
    const errors = []
    page.on('pageerror', error => errors.push(error.message))
    await page.route('**/build-home/hook.js', async route => {
      received()
      await held
      await route.fulfill(failure ? { status: 500, body: 'unavailable' } : { contentType: 'text/javascript', body: spyModule })
    })
    await openFixture(page)
    expect(await mount(page)).toBe('loading')
    await requested
    await page.evaluate(() => {
      for (const name of ['beforeUpdate', 'updated', 'disconnected', 'reconnected', 'destroyed']) window.hook[name].call(window.ctx)
    })
    const response = page.waitForResponse('**/build-home/hook.js')
    release()
    await response
    // Wait for the module task, rather than asserting before the import settles.
    await page.evaluate(async () => {
      await import('/build-home/hook.js').catch(() => {})
      await new Promise(resolve => setTimeout(resolve, 0))
    })
    expect(await health(page)).toBe('loading')
    expect(await page.evaluate(() => ({ created: Boolean(window.created), calls: window.calls }))).toEqual({ created: false, calls: [] })
    expect(errors).toEqual([])
  })
}

test('B5: logo keys, paths, fill flags and immutable null prototype', async ({ page }) => {
  await openFixture(page)
  const actual = await page.evaluate(async () => {
    const { LOGOS } = await import('/build-home/logos.js')
    return {
      entries: Object.entries(LOGOS), frozen: Object.isFrozen(LOGOS),
      frozenEntries: Object.values(LOGOS).every(Object.isFrozen), nullPrototype: Object.getPrototypeOf(LOGOS) === null,
      missing: ['muse', 'openrouter', 'gemini', 'unknown', undefined, 'constructor', 'toString', '__proto__'].every(key => LOGOS[key] === undefined)
    }
  })
  expect(actual).toEqual({
    entries: [
      ['claude', { src: '/provider-assets/claude-symbol.svg', fill: false }],
      ['codex', { src: '/provider-assets/codex-color.svg', fill: false }],
      ['deepseek', { src: '/build-home/logos/deepseek-logo.png', fill: true }],
      ['kimi', { src: '/build-home/logos/kimi-logo.png', fill: true }]
    ], frozen: true, frozenEntries: true, nullPrototype: true, missing: true
  })
})

test.describe('B6: DeepSeek pixel parity', () => {
  test.use({ deviceScaleFactor: 3 })
  test('original and product match in both design slots', async ({ page }) => {
    const original = fileURLToPath(new URL('../../test/fixtures/build_home/design-source/assets/deepseek-logo.png', import.meta.url))
    await page.route('**/original-deepseek.png', route => route.fulfill({ path: original }))
    await openFixture(page)
    for (const size of [24.05, 20]) {
      await page.evaluate(size => {
        document.body.innerHTML = `<div style="background:white;position:relative;height:100px">
          ${['/original-deepseek.png', '/build-home/logos/deepseek-logo.png'].map((src, index) =>
            `<img id="logo-${index}" src="${src}" style="position:absolute;top:20px;left:${20 + index * 60}px;width:${size}px;height:${size}px;border-radius:50%;object-fit:cover">`).join('')}
        </div>`
      }, size)
      await page.locator('img').evaluateAll(images => Promise.all(images.map(image => image.decode())))
      const shots = await Promise.all([0, 1].map(index => page.locator(`#logo-${index}`).screenshot()))
      const ratio = await page.evaluate(async buffers => {
        const pixels = await Promise.all(buffers.map(async bytes => {
          const bitmap = await createImageBitmap(new Blob([new Uint8Array(bytes)], { type: 'image/png' }))
          const canvas = document.createElement('canvas')
          canvas.width = bitmap.width; canvas.height = bitmap.height
          const context = canvas.getContext('2d')
          context.drawImage(bitmap, 0, 0)
          return context.getImageData(0, 0, canvas.width, canvas.height).data
        }))
        if (pixels[0].length !== pixels[1].length) throw new Error('slot dimensions differ')
        let changed = 0
        for (let offset = 0; offset < pixels[0].length; offset += 4) {
          if ([0, 1, 2, 3].some(channel => Math.abs(pixels[0][offset + channel] - pixels[1][offset + channel]) > 8)) changed++
        }
        return changed / (pixels[0].length / 4)
      }, shots.map(shot => Array.from(shot)))
      console.log(`DeepSeek ${size}px DPR 3: ${(ratio * 100).toFixed(4)}% pixels exceed 8/255`)
      expect.soft(ratio).toBeLessThanOrEqual(0.02)
    }
  })
})
