import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

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
    for (const name of ['beforeUpdate', 'updated', 'disconnected', 'reconnected']) window.hook[name].call(window.ctx)
    return window.ctx.el.dataset.buildHomeHook
  })
}

async function health(page) {
  return page.evaluate(() => window.ctx.el.dataset.buildHomeHook)
}

test('B1: loader registration, factory health and every callback preserve context', async ({ page }) => {
  // Loader isolation uses a factory spy; the real hook now requires the server-rendered hosts.
  await page.route('**/build-home/hook.js', route => route.fulfill({ contentType: 'text/javascript', body: spyModule }))
  await openFixture(page)
  expect(await page.evaluate(() => Object.keys(window.BrowserHarnessHooks.BuildHome).sort())).toEqual([...callbacks].sort())
  expect(await mount(page)).toBe('loading')
  await expect.poll(() => health(page)).toBe('mounted')
  // A fresh document clears the browser module map before routing a spy module.
  await page.reload()
  await page.route('**/build-home/hook.js', route => route.fulfill({ contentType: 'text/javascript', body: spyModule }))
  expect(await mount(page)).toBe('loading')
  await expect.poll(() => health(page)).toBe('mounted')
  expect(await page.evaluate(() => window.calls)).toEqual([['mounted', true, true, true]])
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

// Moved from the removed home CSS design-parity specs (#6061).
test('ordered stylesheet imports preserve source order and Safari blur fallbacks', async () => {
  const entry = new URL('../../priv/static/build-home/home.css', import.meta.url)
  const imports = [...(await readFile(entry, 'utf8')).matchAll(/@import url\("home\/([^"/]+)"\);/g)]
  expect(imports.length).toBeGreaterThan(0)
  expect(imports.map(([, name]) => Number(name.slice(0, 2)))).toEqual(imports.map((_, i) => i + 1))
  const parts = await Promise.all(imports.map(([, name]) => readFile(new URL(`home/${name}`, entry), 'utf8')))
  for (const part of parts) expect(part.trimEnd().split('\n').length).toBeLessThan(500)
  const css = parts.join('\n')
  const markers = [...css.matchAll(/\/\* ([HC]):(\d+) \*\//g)]
  expect(markers.map(([, source, line]) => (source === 'C' ? 10000 : 0) + Number(line))).toEqual(
    markers.map(([, source, line]) => (source === 'C' ? 10000 : 0) + Number(line)).sort((a, b) => a - b))
  const blurRules = [...css.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    .filter(([, , body]) => body.includes('-webkit-backdrop-filter:'))
    .map(([, selector, body]) => ({ selector: selector.trim(), declarations: body.match(/(?:-webkit-)?backdrop-filter:[^;]+;/g) }))
  expect(blurRules).toEqual([
    { selector: '.bd-tree', declarations: ['backdrop-filter: blur(10px) saturate(.7);', '-webkit-backdrop-filter: blur(10px) saturate(.7);'] },
    { selector: '.bd-now, html[data-palette="gruvbox"] .bd-now', declarations: ['backdrop-filter: blur(5px);', '-webkit-backdrop-filter: blur(5px);'] },
  ])
})

test('home.css does not change other pages', async ({ page }) => {
  test.setTimeout(120_000)
  const snapshot = () => JSON.stringify([...document.body.querySelectorAll('*')].map(e => {
    const style = getComputedStyle(e)
    return [e.tagName, [...style].filter(p => !p.startsWith('--')).map(p => style.getPropertyValue(p))]
  }))
  let buttons = 0
  let anchors = 0
  for (const route of ['/route-shell', '/commands', '/units-fixture', '/ticket-context', '/provider-meters', '/meter-row', '/quota-panel', '/fixture']) {
    const snapshots = []
    for (const empty of [true, false]) {
      if (empty) await page.route('**/build-home/home.css', r => r.fulfill({ contentType: 'text/css', body: '' }))
      else await page.unroute('**/build-home/home.css')
      await openFixture(page, 'writable')
      await page.context().setHTTPCredentials(dashboardCredentials)
      await page.addInitScript(() => { localStorage.setItem('aiur-theme', 'dark'); localStorage.setItem('aiur-palette', 'gruvbox') })
      await page.goto(route)
      await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
      if (route === '/units-fixture') {
        await page.getByRole('button', { name: 'Select no filters' }).click()
        await expect(page.getByRole('button', { name: 'Reset Units filters' })).toBeVisible()
      }
      await page.evaluate(() => document.fonts.ready)
      await page.evaluate(() => { document.getAnimations().forEach(a => { if (a instanceof CSSTransition) a.finish(); else { a.pause(); a.currentTime = 0 } }) })
      snapshots.push(JSON.parse(await page.evaluate(snapshot)))
    }
    expect(snapshots[1], `stylesheet affected ${route}`).toEqual(snapshots[0])
    buttons += await page.locator('.btn').count()
    anchors += await page.locator('a').count()
  }
  expect(buttons, 'no button target').toBeGreaterThan(0)
  expect(anchors, 'no anchor target').toBeGreaterThan(0)
})
