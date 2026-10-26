import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { dashboardCredentials } from './support/layout-worker.mjs'

// list-edges.json: generated from live by slicing now[:3], hist[-5:], clearing deps,
// setting nullable/closure/skew/XSS cases and unavailable queue/open_tickets sources.
test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })
let errors
let liveViewConsoleEvents
let b4ConsoleStart
let b4CdpErrors
async function open(page, dataset = 'live') {
  await page.goto('/build-fixture/' + dataset + '?view=list')
  await expect(page.locator('.bd-list')).toHaveCount(1)
}
test.beforeEach(async ({ page }) => {
  errors = []; liveViewConsoleEvents = []; b4ConsoleStart = 0; b4CdpErrors = []
  page.on('pageerror', error => errors.push(error.message))
  page.on('console', message => {
    const text = message.text()
    if (/LiveView|LiveSocket|consecutive reloads|reloadWithJitter/i.test(text)) {
      liveViewConsoleEvents.push({ type: 'console', text })
    }
  })
  await open(page)
})
test.afterEach(async ({ page }, testInfo) => {
  if (testInfo.title.startsWith('B4 ') && testInfo.status !== testInfo.expectedStatus) {
    const browserEvents = await page.evaluate(() => ({
      liveViewEvents: window.__aiurB4Lifecycle || null,
      release: window.__aiurB4Release || null,
      mainViewAtFailure: {
        destroyed: window.liveSocket?.main?.isDestroyed?.(),
        joinCount: window.liveSocket?.main?.joinCount,
        joinAttempts: window.liveSocket?.main?.joinAttempts
      }
    }))
      .catch(error => ({ unavailable: error.message }))
    await testInfo.attach('b4-lifecycle-diagnostics', {
      body: JSON.stringify({
        browserEvents,
        cdpErrors: b4CdpErrors,
        liveViewConsoleEvents: liveViewConsoleEvents.slice(b4ConsoleStart)
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
test('List shows selection is keyboard accessible, persisted, and scoped to List view', async ({ page }) => {
  const tabs = page.getByRole('tablist', { name: 'List shows' })
  await expect(tabs).toBeVisible()
  await expect(tabs.getByRole('tab', { name: 'Tickets' })).toHaveAttribute('aria-selected', 'true')
  await tabs.getByRole('tab', { name: 'Tickets' }).focus()
  await page.keyboard.press('ArrowRight')
  await expect(tabs.getByRole('tab', { name: 'Features' })).toBeFocused()
  await page.keyboard.press('End')
  await page.keyboard.press('Enter')
  await expect(page).toHaveURL(/list=epics/)
  await expect(page.locator('.bd-list-placeholder')).toHaveText('Epics view is not available yet')
  await expect(tabs.getByRole('tab', { name: 'Epics' })).toHaveAttribute('aria-selected', 'true')
  await page.reload()
  const restored = page.getByRole('tablist', { name: 'List shows' })
  await expect(restored.getByRole('tab', { name: 'Epics' })).toHaveAttribute('aria-selected', 'true')
  await page.getByRole('tab', { name: 'Timeline' }).click()
  await expect(page.getByRole('tablist', { name: 'List shows' })).toHaveCount(0)
  await page.getByRole('tab', { name: 'List' }).click()
  await expect(page.getByRole('tablist', { name: 'List shows' }).getByRole('tab', { name: 'Epics' })).toHaveAttribute('aria-selected', 'true')
  await page.getByRole('tab', { name: 'Tickets' }).click()
  await expect(page).not.toHaveURL(/list=/)
  await expect(page.locator('.bd-list')).toHaveCount(1)
})
test('List shows label stays beside options on a narrow viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  const label = page.locator('.bd-list-label')
  const options = page.locator('.bd-list-shows')
  await expect(label).toBeVisible()
  await expect(options).toBeVisible()
  const layout = await page.evaluate(() => {
    const labelRect = document.querySelector('.bd-list-label').getBoundingClientRect()
    const optionsRect = document.querySelector('.bd-list-shows').getBoundingClientRect()
    return { labelBottom: labelRect.bottom, optionsTop: optionsRect.top, viewportWidth: innerWidth, pageWidth: document.documentElement.scrollWidth }
  })
  expect(layout.labelBottom).toBeGreaterThan(layout.optionsTop)
  expect(layout.pageWidth).toBeLessThanOrEqual(layout.viewportWidth)
})
test('Features list renders counts, proportional segments, unknowns and focus return', async ({ page }) => {
  const progress = {
    features: {
      'f-pag-api': { feature: 'pag', closed: 1, open: 1, ci_wait: 1, unpublished: 1, total: 4, observed_at: Date.now(), wave: '0', summary: 'Pagination work', icon: 'layers', code: 'MP-E8', plan_version: 'v1', extras: 0, reason: null },
      'f-khala-srv': { feature: 'khala', closed: null, open: 1, ci_wait: null, unpublished: 2, total: null, observed_at: Date.now(), wave: null, summary: null, icon: null, code: null, plan_version: 'v1', extras: 0, reason: 'states unavailable' },
      'f-khala-ui': { feature: 'khala', closed: 2, open: 1, ci_wait: 0, unpublished: 0, total: 3, observed_at: Date.now(), wave: null, summary: null, icon: null, code: null, plan_version: 'v1', extras: 0, reason: null }
    }, observed_at: Date.now(), plan_version: 'v1', extras: 0
  }
  await page.getByRole('tab', { name: 'Features' }).click()
  await page.evaluate(async progress => {
    const { ctx } = await import('/build-home/state.js')
    ctx.D.feature_progress = progress
    ctx.D.order = ['f-pag-api', 'f-khala-srv', 'f-khala-ui']
    ctx.D.epics = { 'f-pag-api': { feature: 'pag', label: 'Pagination · API' }, 'f-khala-srv': { feature: 'khala', label: 'Khala · server' }, 'f-khala-ui': { feature: 'khala', label: 'Khala · client' } }
    ctx.D.features = { pag: { label: 'Events pagination', hue: 272, epics: ['f-pag-api'], to: Infinity }, khala: { label: 'Khala chat', hue: 150, epics: ['f-khala-srv', 'f-khala-ui'], to: Infinity } }
    ctx.snap.order = ctx.D.order
    ctx.snap.epics = ctx.D.epics
    ctx.snap.features = ctx.D.features
    ctx.snap.feature_progress = progress
    const { fx } = await import('/build-home/state.js'); fx.renderList()
  }, progress)
  await expect(page.locator('.fp-row')).toHaveCount(2)
  await expect(page.locator('.fp-row').first()).toContainText('1 / 4')
  await expect(page.locator('.fp-row').first().locator('.fp-closed')).toHaveAttribute('style', /width:25%/)
  await expect(page.locator('.fp-row').first().locator('.fp-open')).toHaveAttribute('style', /width:50%/)
  await expect(page.locator('.fp-row').first().locator('.fp-unpublished')).toHaveAttribute('style', /width:25%/)
  await expect(page.locator('.fp-overall > b')).toHaveText('—')
  await expect(page.locator('.fp-overall > span')).toContainText('— tickets closed across all features')
  await expect(page.locator('.fp-wave h2')).toHaveText(['Wave 0', 'Feature: Khala chat'])
  await expect(page.locator('.fp-row').nth(1)).toContainText('Khala · server: — / — · Khala · client: 2 / 3')
  await expect(page.locator('.fp-row').nth(1)).toContainText('Khala · server: — / —')
  await expect(page.locator('.fp-row').nth(1).locator('.fp-bar')).toHaveClass(/unknown/)
  await expect(page.locator('.fp-row').first().locator('.fp-icon')).toHaveAttribute('aria-label', 'Events pagination')
  await expect(page.locator('.fp-row').first().locator('.fp-icon svg')).toHaveCount(1)
  await page.evaluate(async () => {
    const { ctx, fx } = await import('/build-home/state.js')
    const { applyDiff } = await import('/build-home/store.js')
    const changed = structuredClone(ctx.snap.feature_progress)
    changed.features['f-pag-api'].closed = 2
    changed.features['f-pag-api'].open = 0
    const set = { feature_progress: changed }
    const result = applyDiff({ now: Date.now(), generation: ctx.proto.generation + 1, remove: [], upsert: [], set })
    if (result.error) throw Error(result.error)
    fx.renderList()
  })
  await expect(page.locator('.fp-row').first()).toContainText('2 / 4')
  await expect(page.locator('.fp-row').first().locator('.fp-closed')).toHaveAttribute('style', /width:50%/)
  await expect(page.locator('.fp-row').nth(1)).toContainText('—')
  await expect(page.locator('.fp-row').nth(1)).toContainText('states unavailable')
  await expect(page.locator('.fp-row').nth(1).locator('.fp-numbers > b')).not.toHaveText('0%')
  await expect(page.locator('.fp-row').nth(1).locator('.fp-bar')).toHaveClass(/unknown/)
  await expect(page.locator('.fp-row').nth(1).locator('.fp-icon')).toHaveAttribute('aria-label', 'Khala chat')
  expect((await new AxeBuilder({ page }).include('.fp-card').analyze()).violations).toEqual([])
  await page.emulateMedia({ colorScheme: 'dark' })
  expect((await new AxeBuilder({ page }).include('.fp-card').analyze()).violations).toEqual([])
  await page.setViewportSize({ width: 390, height: 844 })
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
  await page.locator('.fp-row').first().press('Enter')
  await expect(page).toHaveURL(/feature=pag/)
  await expect(page).not.toHaveURL(/list=features/)
})
test('Build Order feature card shows the root date and lane captions without repeating the root title', async ({ page }) => {
  const progress = { features: { 'f-bo-99-home': { feature: 'bo-99', closed: 1, open: 0, ci_wait: 0, unpublished: 0, total: 1, observed_at: Date.now(), root_number: 99, root_title: 'Platform program', start_date: '2026-10-01' } }, observed_at: Date.now(), plan_version: 'v1', extras: 0 }
  await page.getByRole('tab', { name: 'Features' }).click()
  await page.evaluate(async progress => {
    const { ctx, fx } = await import('/build-home/state.js')
    ctx.D.feature_progress = progress
    ctx.D.order = ['f-bo-99-home']
    ctx.D.epics = { 'f-bo-99-home': { key: 'f-bo-99-home', feature: 'bo-99', label: 'Platform program · Home' } }
    ctx.D.features = { 'bo-99': { label: 'Platform program', epics: ['f-bo-99-home'], to: Infinity } }
    ctx.snap.order = ctx.D.order
    ctx.snap.epics = ctx.D.epics
    ctx.snap.features = ctx.D.features
    ctx.snap.feature_progress = progress
    fx.renderList()
  }, progress)
  await expect(page.locator('.fp-head p')).toContainText('root #99 · 2026-10-01')
  await expect(page.locator('.fp-row .fp-summary')).toHaveText('Home: 1 / 1')
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
test('Enter opens the real ticket modal and Escape restores the list row', async ({ page }) => {
  const row = rows(page).first(), id = await row.getAttribute('data-id')
  const title = await row.locator('.c-tt').textContent()
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), push = ctx.push
    window.keyboardOpens = []
    ctx.push = (event, params) => {
      if (event === 'open-ticket') window.keyboardOpens.push(params)
      return push(event, params)
    }
  })
  await row.focus(); await page.keyboard.press('Enter')
  await expect(page.locator('#tk-backdrop')).toHaveClass(/\bshow\b/)
  await expect(page.locator('#bm-title')).toContainText(title)
  await expect(page.locator('#bm-title')).toBeFocused()
  await expect(page).toHaveURL(new RegExp('ticket=' + id))
  expect(await page.evaluate(() => window.keyboardOpens)).toEqual([{ id, loaded: true }])
  await page.keyboard.press('Escape')
  await expect(page.locator('#tk-backdrop')).not.toHaveClass(/\bshow\b/)
  await expect(page).not.toHaveURL(/ticket=/)
  await expect(row).toBeFocused()
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
    const mainView = () => {
      const main = window.liveSocket?.main
      return {
        joinCount: main?.joinCount,
        joinAttempts: main?.joinAttempts,
        destroyed: main?.isDestroyed?.()
      }
    }
    const record = (type, detail = {}) => {
      const event = { type, ...mainView(), release: window.__aiurB4Release || null, ...detail }
      window.__aiurB4Lifecycle.push(event)
      console.info(`AIUR_B4_DIAG ${JSON.stringify(event)}`)
    }
    window.__aiurB4Record = record
    const liveSocket = window.liveSocket
    const previousLogger = liveSocket?.viewLogger
    window.__aiurB4Lifecycle = []
    record('initial')
    if (liveSocket) liveSocket.viewLogger = (view, kind, message, obj) => {
      if (kind === 'join' || kind === 'error') record('liveview-log', { kind, message, detail: obj, viewId: view?.id })
      previousLogger?.(view, kind, message, obj)
    }
    window.liveSocket?.getSocket()?.onClose(event => record('socket-close', {
      code: event?.code,
      reason: event?.reason,
      wasClean: event?.wasClean
    }))
  })
  b4ConsoleStart = liveViewConsoleEvents.length
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
      calls++
      window.__aiurB4Release = {
        state: 'held',
        viewAtHold: {
          destroyed: window.liveSocket?.main?.isDestroyed?.(),
          joinCount: window.liveSocket?.main?.joinCount
        }
      }
      return new Promise((resolve, reject) => {
        window.releasePage = () => {
          const release = window.__aiurB4Release
          release.state = 'sent'
          release.viewAtSend = {
            destroyed: window.liveSocket?.main?.isDestroyed?.(),
            joinCount: window.liveSocket?.main?.joinCount
          }
          window.__aiurB4Record('push-sent')
          const pending = push(event, params)
          return pending.then(reply => {
            release.state = 'resolved'
            window.__aiurB4Record('push-resolved')
            resolve(reply)
          }, error => {
            release.state = 'rejected'
            release.error = String(error)
            window.__aiurB4Record('push-rejected')
            reject(error)
            throw error
          })
        }
      })
    }
    const b = document.querySelector('#lr-more'); b.click(); b.click()
  })
  await expect(more).toBeDisabled(); await expect(more).toHaveAttribute('aria-busy', 'true')
  await page.evaluate(async () => { const { fx } = await import('/build-home/state.js'); fx.renderList() })
  await expect(more).toBeDisabled(); await expect(more).toHaveAttribute('aria-busy', 'true')
  const cdp = await page.context().newCDPSession(page)
  try {
    const evaluation = await cdp.send('Runtime.evaluate', {
      expression: 'window.releasePage()',
      awaitPromise: true,
      returnByValue: true
    })
    if (evaluation.exceptionDetails) {
      b4CdpErrors.push({
        kind: 'javascript-exception',
        method: 'Runtime.evaluate',
        expression: 'window.releasePage()',
        exceptionDetails: evaluation.exceptionDetails
      })
      throw new Error(evaluation.exceptionDetails.exception?.description || evaluation.exceptionDetails.text)
    }
  } catch (error) {
    if (!b4CdpErrors.length) {
      b4CdpErrors.push({
        kind: 'protocol-error',
        method: 'Runtime.evaluate',
        expression: 'window.releasePage()',
        error: { name: error.name, message: error.message, code: error.code, data: error.data }
      })
    }
    throw error
  } finally {
    await cdp.detach().catch(error => {
      b4CdpErrors.push({ kind: 'session-detach-error', error: error.message })
    })
  }
  expect(await page.evaluate(() => window.__aiurB4Release.state)).toBe('resolved')
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
