import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { dashboardCredentials } from './support/layout-worker.mjs'

// list-edges.json: generated from live by slicing now[:3], hist[-5:], clearing deps,
// setting nullable/closure/skew/XSS cases and unavailable queue/open_tickets sources.
test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })
let errors
let lifecycleEvents
let b4LifecycleStart
async function open(page, dataset = 'live') {
  await page.goto('/build-fixture/' + dataset + '?view=list')
  await expect(page.locator('.bd-list')).toHaveCount(1)
}
test.beforeEach(async ({ page }) => {
  errors = []; lifecycleEvents = []; b4LifecycleStart = 0
  page.on('pageerror', error => errors.push(error.message))
  page.on('framenavigated', frame => {
    if (frame === page.mainFrame()) lifecycleEvents.push({ type: 'framenavigated', url: frame.url() })
  })
  page.on('load', () => lifecycleEvents.push({ type: 'load', url: page.url() }))
  page.on('crash', () => lifecycleEvents.push({ type: 'crash', url: page.url() }))
  page.on('console', message => {
    const text = message.text()
    if (/^AIUR_B4_DIAG |^AIUR_BUILD_HOME_DIAG |LiveView|LiveSocket|consecutive reloads|reloadWithJitter/i.test(text)) {
      lifecycleEvents.push({ type: 'console', text })
    }
  })
  await open(page)
})
test.afterEach(async ({ page }, testInfo) => {
  if (testInfo.title.startsWith('B4 ') && testInfo.status !== testInfo.expectedStatus) {
    const browserEvents = await page.evaluate(() => window.__aiurB4Lifecycle || null)
      .catch(error => ({ unavailable: error.message }))
    await testInfo.attach('b4-lifecycle-diagnostics', {
      body: JSON.stringify({
        browserEvents,
        playwrightEvents: lifecycleEvents.slice(b4LifecycleStart)
      }, null, 2),
      contentType: 'application/json'
    })
  }
  await page.request.get('/build-control/earlier')
  expect(errors).toEqual([])
})
const rows = page => page.locator('.lr[data-id]')

test('B1 list registration renders sections and counts in design order', async ({ page }) => {
  expect(await page.locator('.lh b').allTextContents()).toEqual(['Live', 'Planned', 'Not queued', 'History'])
  const result = await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    return { layout: ctx.L, content: ctx.content, expected: Object.fromEntries(['now', 'plan', 'nq', 'hist'].map(sec => [sec, ctx.D[sec].length])),
      hist: ctx.D.hist.filter(t => t.end >= 0).sort((a, b) => b.end - a.end).map(t => t.id) }
  })
  expect(result.layout).toBeNull(); expect(result.content).toBeNull()
  for (const sec of ['now', 'plan', 'nq', 'hist']) await expect(page.locator('.lr.' + sec)).toHaveCount(result.expected[sec])
  expect(await page.locator('.lr.hist').evaluateAll(els => els.map(el => el.dataset.id))).toEqual(result.hist)
})
test('B2 delegated Enter opens once across renders and remounts', async ({ page }) => {
  for (let mount = 0; mount < 2; mount++) {
    if (mount) {
      await page.evaluate(() => window.liveSocket.main.pushLinkPatch(new Event('click'), '/commands', null))
      await expect(page.locator('#build-root')).toHaveCount(0)
      await page.evaluate(() => window.liveSocket.main.pushLinkPatch(new Event('click'), '/build?view=list', null))
      await expect(page.locator('.bd-list')).toHaveCount(1)
      expect(await page.evaluate(() => window.listSentinel)).toBe(true)
    } else await page.evaluate(() => { window.listSentinel = true })
    await page.evaluate(async () => {
      const { fx } = await import('/build-home/state.js'); window.opened = []; fx.openModal = t => opened.push(t.id)
      fx.relayout(); fx.relayout()
    })
    await rows(page).first().focus(); await page.keyboard.press('Enter')
    expect(await page.evaluate(() => opened)).toEqual([await rows(page).first().getAttribute('data-id')])
    await expect(rows(page).first()).toHaveCSS('outline-width', '2px')
    await rows(page).first().click()
    expect(await page.evaluate(() => opened.length)).toBe(2)
  }
})
test('B3 real live diff preserves focus and position; removal and empty filters move focus safely', async ({ page }) => {
  const row = rows(page).nth(4), id = await row.getAttribute('data-id')
  await row.focus(); const before = await row.boundingBox()
  const target = await rows(page).nth(1).getAttribute('data-id')
  await page.request.get('/build-control/diff?op=title&id=' + target)
  await expect(rows(page).nth(1)).toContainText('updated')
  await expect(page.locator('.lr[data-id="' + id + '"]')).toBeFocused()
  expect(Math.abs((await row.boundingBox()).y - before.y)).toBeLessThanOrEqual(1)
  const fallback = await page.evaluate(async id => {
    const { ctx, fx } = await import('/build-home/state.js')
    const all = [...ctx.vp.querySelectorAll('.lr[data-id]')], index = all.findIndex(el => el.dataset.id === id), next = all[index + 1].dataset.id
    ctx.D.now = ctx.D.now.filter(t => t.id !== id); ctx.D.plan = ctx.D.plan.filter(t => t.id !== id); ctx.D.nq = ctx.D.nq.filter(t => t.id !== id); ctx.D.hist = ctx.D.hist.filter(t => t.id !== id)
    fx.relayout(); return { next, focused: document.activeElement.dataset.id }
  }, id)
  expect(fallback.focused).toBe(fallback.next)
  await page.evaluate(async () => { const { S, fx } = await import('/build-home/state.js'); S.f.epic = ['none']; fx.relayout() })
  await expect(page.locator('.bd-list')).toBeFocused()
})
test('B4 server paging disables duplicate clicks and permits an explicit retry', async ({ page }) => {
  await page.evaluate(() => {
    const snapshot = () => ({
      url: location.href,
      trackedStatic: [...document.querySelectorAll('[phx-track-static]')].map(node => node.src || node.href),
      joinCount: window.liveSocket?.main?.joinCount,
      joinAttempts: window.liveSocket?.main?.joinAttempts
    })
    const record = (type, detail = {}) => {
      const event = { type, ...snapshot(), ...detail }
      window.__aiurB4Lifecycle.push(event)
      console.info(`AIUR_B4_DIAG ${JSON.stringify(event)}`)
    }
    const liveSocket = window.liveSocket
    const previousLogger = liveSocket?.viewLogger
    window.__aiurB4Lifecycle = []
    record('initial')
    if (liveSocket) liveSocket.viewLogger = (view, kind, message, obj) => {
      if (kind === 'join' || kind === 'error') record('liveview-log', { kind, message, detail: obj, viewId: view?.id })
      previousLogger?.(view, kind, message, obj)
    }
    addEventListener('phx:page-loading-start', event => record('phx:page-loading-start', { to: event.detail?.to }))
    addEventListener('beforeunload', () => record('beforeunload'))
    addEventListener('pagehide', event => record('pagehide', { persisted: event.persisted }))
    window.liveSocket?.getSocket()?.onClose(event => record('socket-close', {
      code: event?.code,
      reason: event?.reason,
      wasClean: event?.wasClean
    }))
  })
  b4LifecycleStart = lifecycleEvents.length
  await page.request.get('/build-control/earlier?fail=1')
  const more = page.locator('#lr-more')
  await more.click()
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'error')
  await expect(page.locator('.lh[data-sec=hist] em')).toContainText('earlier days could not load')
  await page.request.get('/build-control/earlier')
  const count = await page.locator('.lr.hist').count()
  await more.focus()
  const scroll = await page.locator('#bd-vp').evaluate(vp => vp.scrollTop)
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'); const push = ctx.push; window.calls = 0
    ctx.push = (event, params) => {
      if (event !== 'load-earlier') return push(event, params)
      calls++; return new Promise(resolve => { window.releasePage = () => push(event, params).then(resolve) })
    }
    const b = document.querySelector('#lr-more'); b.click(); b.click()
  })
  await expect(more).toBeDisabled(); await expect(more).toHaveAttribute('aria-busy', 'true')
  await page.evaluate(async () => { const { fx } = await import('/build-home/state.js'); fx.renderList() })
  await expect(more).toBeDisabled(); await expect(more).toHaveAttribute('aria-busy', 'true')
  await page.evaluate(() => window.releasePage())
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'idle')
  await expect(more).toBeEnabled()
  await expect(more).toBeFocused()
  expect(await page.locator('#bd-vp').evaluate(vp => vp.scrollTop)).toBeCloseTo(scroll, 0)
  expect(await page.evaluate(() => calls)).toBe(1)
  expect(await page.locator('.lr.hist').count()).toBeGreaterThan(count)
})
test('B5 unavailable sections name cause and age; healthy empty queue stays hidden', async ({ page }) => {
  await open(page, 'list-edges')
  await expect(page.locator('.lh[data-sec=plan] em')).toHaveText('unavailable · timed out · read 6 min ago (14:14)')
  await expect(page.locator('.lh[data-sec=nq]')).toHaveAttribute('data-st', 'unavailable')
  await expect(page.locator('.lh[data-sec=hist] em')).toContainText('stale, read 6 min ago (14:14)')
  await open(page, 'noqueue'); await expect(page.locator('.lh[data-sec=plan]')).toHaveCount(0)
})
test('B6 table accessibility and forced-colour focus; B7 hostile title stays text', async ({ page }) => {
  for (const dataset of ['live', 'list-edges']) {
    await open(page, dataset)
    const a11y = await new AxeBuilder({ page }).include('#bd-vp').analyze()
    expect(a11y.violations).toEqual([])
  }
  expect(await page.evaluate(() => window.__xss)).toBeUndefined()
  await expect(page.locator('.c-tt').filter({ hasText: '<img src=x' })).toHaveCount(1)
  await page.emulateMedia({ forcedColors: 'active' }); await rows(page).first().focus()
  await expect(rows(page).first()).toHaveCSS('outline-style', 'solid')
  for (const text of await page.locator('.lst').allTextContents()) expect(text.length).toBeGreaterThan(0)
})

test('history button focus survives live rerenders and falls back when exhausted', async ({ page }) => {
  const more = page.locator('#lr-more'); await more.focus()
  await page.evaluate(async () => { const { fx } = await import('/build-home/state.js'); fx.renderList() })
  await expect(more).toBeFocused()
  await page.evaluate(async () => {
    const { H } = await import('/build-home/history.js'), { fx } = await import('/build-home/state.js')
    H.more = false; fx.renderList()
  })
  await expect(rows(page).last()).toBeFocused()
})
