import { expect } from '@playwright/test'
import { readFile, readdir } from 'node:fs/promises'
import { realpathSync } from 'node:fs'
import { createHash } from 'node:crypto'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const DESIGN_ORIGIN = 'http://design.parity.invalid'
export const DESIGN_ROOT = fileURLToPath(new URL('../../test/fixtures/build_home/design-source/', import.meta.url)).replace(/\/$/, '')
export const FIXTURE_META = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/manifest.json', import.meta.url), 'utf8'))
// Copied from website/tests/support/visual.ts; font bytes stay in its fixture folder.
const families = [
  ['Bungee', 'Bungee-Regular.woff2', '400'],
  ['Space Grotesk', 'SpaceGrotesk-Variable.woff2', '300 700'],
  ['JetBrains Mono', 'JetBrainsMono-Variable.woff2', '100 800']
]
const failures = new WeakMap()

export function checkPage(page) {
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

export function resolveDesignPath(input, root = DESIGN_ROOT) {
  let decoded
  try { decoded = decodeURIComponent(input) } catch { return null }
  const file = path.resolve(root, decoded.replace(/^\//, ''))
  if (!file.startsWith(`${root}${path.sep}`)) return null
  try {
    const target = realpathSync(file)
    return target.startsWith(`${realpathSync(root)}${path.sep}`) ? target : null
  } catch { return null }
}

export async function verifyDesignSource(root = DESIGN_ROOT, meta = FIXTURE_META) {
  const entries = await readdir(root, { recursive: true, withFileTypes: true })
  if (entries.some(e => e.isSymbolicLink())) throw new Error('design source contains a symlink')
  const actual = {}
  for (const entry of entries.filter(e => e.isFile())) {
    const file = path.join(entry.parentPath, entry.name)
    actual[path.relative(root, file)] = createHash('sha256').update(await readFile(file)).digest('hex')
  }
  if (JSON.stringify(Object.entries(actual).sort()) !== JSON.stringify(Object.entries(meta.design_sha256).sort())) {
    throw new Error('design source changed without re-export')
  }
}

export async function routeDesign(page) {
  await guardNetwork(page, [DESIGN_ORIGIN, 'https://fonts.googleapis.com', 'https://fonts.gstatic.com', 'https://cdn.jsdelivr.net'], async (route, url, errors) => {
    if (url.origin === 'https://fonts.googleapis.com') return route.fulfill({ contentType: 'text/css', body: families.map(([family, file, weight]) =>
      `@font-face { font-family: '${family}'; font-style: normal; font-weight: ${weight}; font-display: block; src: url('https://fonts.gstatic.com/visual/${file}') format('woff2'); }`).join('\n') })
    if (url.origin === 'https://fonts.gstatic.com') {
      const file = url.pathname.split('/').pop()
      if (families.some(([, name]) => name === file)) return route.fulfill({ contentType: 'font/woff2', path: fileURLToPath(new URL(`../../../website/tests/fixtures/fonts/${file}`, import.meta.url)) })
    }
    if (url.href === 'https://cdn.jsdelivr.net/npm/d3@7/dist/d3.min.js') return route.fulfill({ contentType: 'application/javascript', body: '' })
    if (url.origin === DESIGN_ORIGIN) {
      if (url.pathname === '/blank') return route.fulfill({ contentType: 'text/html', body: '<!doctype html>' })
      const file = resolveDesignPath(url.pathname)
      if (!file) return route.fulfill({ status: 404, body: 'path outside design root' })
      try { return await route.fulfill({ path: file }) } catch (error) { errors.push(`design request unavailable: ${url.href}: ${error.message}`) }
    } else errors.push(`network request refused: ${url.href}`)
    return route.abort()
  })
}

export async function seedRandom(page) {
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

export async function waitParityReady(page, phase = 'board', side = 'design', motion = false) {
  await page.evaluate(() => document.fonts.ready)
  for (const [family] of families) {
    await expect.poll(() => page.evaluate(f => [...document.fonts].some(face => face.family.replace(/["']/g, '') === f && face.status === 'loaded'), family), {
      timeout: 10_000, message: `font not loaded: "${family}"`
    }).toBe(true)
  }
  if (motion && phase === 'board') {
    for (let elapsed = 0; elapsed < 2000; elapsed += 16) {
      if (await page.locator('#bd-content').count() && !await page.locator('.bd-loading').count()) break
      await page.clock.runFor(16)
    }
  }
  if (phase !== 'shell') {
    await expect.poll(() => page.evaluate(({ phase, side }) => phase === 'loading'
      ? !!document.querySelector('.bd-loading')
      : !!document.querySelector('#bd-content') && !document.querySelector('.bd-loading') && (side === 'design' || !!document.querySelector('#build-root[data-bd-mounted][data-bd-paging="idle"]')),
    { phase, side }), { timeout: 10_000, message: `${side} not ready: ${phase === 'board' ? '.bd-loading still present or board not mounted' : 'loading skeleton absent'} after 10 s` }).toBe(true)
  }
  const frames = page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  if (motion || (phase === 'loading' && side === 'design')) await page.clock.runFor(40)
  await frames
  checkPage(page)
}

export async function assertCellState(page, cell, expectedTime = FIXTURE_META.now) {
  checkPage(page)
  const state = await page.evaluate(() => ({ theme: document.documentElement.dataset.theme, palette: document.documentElement.dataset.palette,
    zone: Intl.DateTimeFormat().resolvedOptions().timeZone, now: Date.now() }))
  expect(state.theme, 'theme not applied').toBe(cell.theme)
  expect(state.palette, 'palette not applied').toBe(cell.palette)
  expect(state.zone, `time zone ${state.zone}, expected ${FIXTURE_META.tz}`).toBe(FIXTURE_META.tz)
  expect(state.now, `clock not frozen: Date.now() != ${expectedTime}`).toBe(expectedTime)
}
