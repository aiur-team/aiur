import { expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'

export const BUILD_FIXTURE_META = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/manifest.json', import.meta.url), 'utf8'))
const failures = new WeakMap()

export function checkProductPage(page) {
  const errors = failures.get(page) ?? []
  if (errors.length) throw new Error(errors.join('\n'))
}

export async function guardNetwork(page, allowedOrigins, serve) {
  const errors = []
  failures.set(page, errors)
  page.on('pageerror', error => errors.push(`page error: ${error.message}`))
  await page.context().route('**/*', async route => {
    const url = new URL(route.request().url())
    if (!allowedOrigins.includes(url.origin)) {
      errors.push(`network request refused: ${url.href}`)
      return route.abort()
    }
    if (serve) return serve(route, url, errors)
    return route.continue()
  })
  // WebSockets do not go through HTTP interception.
  await page.context().routeWebSocket(/.*/, socket => {
    const url = new URL(socket.url())
    const origin = url.origin.replace(/^ws/, 'http')
    if (!serve && allowedOrigins.includes(origin)) return socket.connectToServer()
    errors.push(`network request refused: ${url.href}`)
    socket.close()
  })
}

export async function seedProductRandom(page) {
  // Future re-import guard: the current home load does not call Math.random.
  await page.addInitScript(() => {
    let seed = 1
    Math.random = () => {
      let t = seed += 0x6D2B79F5
      t = Math.imul(t ^ t >>> 15, t | 1)
      t ^= t + Math.imul(t ^ t >>> 7, t | 61)
      return ((t ^ t >>> 14) >>> 0) / 4294967296
    }
  })
}

export async function waitProductReady(page, phase = 'board', motion = false) {
  await page.evaluate(() => document.fonts.ready)
  if (motion && phase === 'board') {
    for (let elapsed = 0; elapsed < 2000; elapsed += 16) {
      if (await page.locator('#bd-content').count() && !await page.locator('.bd-loading').count()) break
      await page.clock.runFor(16)
    }
  }
  if (phase !== 'shell') {
    await expect.poll(() => page.evaluate(phase => phase === 'loading'
      ? !!document.querySelector('.bd-loading')
      : !!document.querySelector('#bd-content, .bd-list') && !document.querySelector('.bd-loading') && !!document.querySelector('#build-root[data-bd-mounted][data-bd-paging="idle"]'),
    phase), { timeout: 10_000, message: `product not ready: ${phase === 'board' ? '.bd-loading still present or board not mounted' : 'loading skeleton absent'} after 10 s` }).toBe(true)
  }
  const frames = page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  if (motion) await page.clock.runFor(40)
  await frames
  checkProductPage(page)
}

export async function assertProductEnvironment(page, cell, expectedTime = BUILD_FIXTURE_META.now) {
  checkProductPage(page)
  const state = await page.evaluate(() => ({ theme: document.documentElement.dataset.theme, palette: document.documentElement.dataset.palette,
    zone: Intl.DateTimeFormat().resolvedOptions().timeZone, now: Date.now() }))
  expect(state.theme, 'theme not applied').toBe(cell.theme)
  expect(state.palette, 'palette not applied').toBe(cell.palette)
  expect(state.zone, `time zone ${state.zone}, expected ${BUILD_FIXTURE_META.tz}`).toBe(BUILD_FIXTURE_META.tz)
  expect(state.now, `clock not frozen: Date.now() != ${expectedTime}`).toBe(expectedTime)
}
