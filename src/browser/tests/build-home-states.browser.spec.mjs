import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
const NOW = 1791408000000
const design = await readFile(new URL('../../test/fixtures/build_home/design-source/assets/build.js', import.meta.url), 'utf8')
const loading = design.slice(design.indexOf('  function renderLoading()'), design.indexOf('  function setDemo('))
test.use({ timezoneId: 'America/Los_Angeles' })
test.beforeEach(async ({ page }) => {
  await page.route('**/states-harness', r => r.fulfill({ contentType: 'text/html', body: '<link rel="stylesheet" href="/build-home/home.css"><main class="bd-root" id="build-root"><div id="bd-vp"></div></main>' }))
  await page.goto('/states-harness')
  await page.evaluate(async NOW => {
    window.m = await import('/build-home/states.js'); window.state = await import('/build-home/state.js')
    window.clock = await import('/build-home/clock.js'); window.layout = await import('/build-home/layout.js')
    window.heads = await import('/build-home/render-heads.js')
    state.resetState(); clock.setNow(NOW)
    Object.assign(state.ctx, { root: document.querySelector('main'), vp: document.querySelector('#bd-vp') })
    window.D = { hist: [], plan: [], nq: [], now: [] }
    window.P = { sources: Object.fromEntries(['history', 'queue', 'index', 'agents', 'features'].map(k => [k, { state: 'ok', observed_at: NOW }])) }
    window.H = { more: false, total: 0 }
    window.mark = (sec, src, rows = [], filtered = rows) => {
      P.sources[{ hist: 'history', plan: 'queue', nq: 'index' }[sec]] = src; D[sec] = rows
      return m.emptyMark(sec, m.sectionState(P, D, H, sec, filtered), { now: NOW, nqCount: 6, index: P.sources.index })
    }
  }, NOW)
})
test('loading matches design DOM and preserves existing animation nodes', async ({ page }) => {
  const result = await page.evaluate(loading => {
    const vp = state.ctx.vp, $$ = (q, el) => [...el.querySelectorAll(q)]; let content
    eval(loading + '; renderLoading()')
    vp.querySelector('.bd-loading').setAttribute('role', 'status')
    const oracle = vp.innerHTML; vp.innerHTML = ''; m.renderLoading()
    const actual = vp.innerHTML, first = vp.querySelector('.bd-skel i'); m.renderLoading()
    return { actual, oracle, same: first === vp.querySelector('.bd-skel i'), count: vp.querySelectorAll('.bd-skel i').length }
  }, loading)
  expect(result.actual).toBe(result.oracle); expect(result.same).toBe(true); expect(result.count).toBe(16)
})
test('failure stops loading animation and announces the cause', async ({ page }) => {
  await page.evaluate(() => m.renderLoading())
  expect(await page.locator('.bd-skel i').first().evaluate(el => getComputedStyle(el).animationName)).toBe('bdPulse')
  await page.evaluate(() => m.renderUnavailable('timeout'))
  await expect(page.locator('[role=status]')).toHaveText('Build timeline unavailable · timed out')
  await expect(page.locator('.bd-spin')).toHaveCount(0)
  expect(await page.locator('.bd-skel i').evaluateAll(els => els.every(el => getComputedStyle(el).animationName === 'none'))).toBe(true)
})
test('unread and partial sections never become empty; disabled preserves its cause', async ({ page }) => {
  const results = await page.evaluate(NOW => ['hist', 'plan', 'nq'].flatMap(sec => ['unavailable', 'incomplete', 'disabled'].map(state => {
    const value = mark(sec, { state, reason: state === 'disabled' ? 'configured off' : 'timeout', observed_at: NOW - 720000 })
    return { sec, state, value, header: heads.headHTML(D, H, P.sources, 0)[sec] }
  })), NOW)
  for (const { sec, state, value, header } of results) {
    expect(value.label).toContain(state); expect(header).toContain(`<em>${state}</em>`)
    expect(header).not.toContain('empty'); expect(header).not.toContain('0 open')
    if (state === 'disabled') expect(value.sub).toBe('configured off.')
    else { expect(value.sub).toContain('read 12 min ago (14:08)'); expect(value.sub).toContain('timed out') }
    if (sec !== 'nq' && state !== 'disabled') expect(value.sub).toContain('This does not mean')
  }
})
test('window and filter markers distinguish loaded data from empty data', async ({ page }) => {
  expect(await page.evaluate(() => {
    H.more = true; const windowed = mark('hist', P.sources.history).label
    H.more = false; H.total = 2; const counted = mark('hist', P.sources.history).label
    return [windowed, counted, mark('hist', P.sources.history, [{ id: 'h' }], []).label, mark('plan', P.sources.queue, [{ id: 'p' }], []).label]
  })).toEqual(['No history in the loaded days', 'No history in the loaded days', 'No history in the selected epics', 'No planned tickets in the selected epics'])
})
test('stale empty markers and retained rows expose read ages in headers', async ({ page }) => {
  const result = await page.evaluate(NOW => {
    const stale = mark('plan', { state: 'stale', observed_at: NOW - 10800000 }).sub
    D.plan = [{ id: 'p' }]; P.sources.queue = { state: 'unavailable', observed_at: NOW - 720000 }
    const retained = m.sectionState(P, D, H, 'plan', D.plan), failed = heads.headHTML(D, H, P.sources, 0).plan
    P.sources.queue = { state: 'incomplete', observed_at: NOW - 720000 }
    const partial = heads.headHTML(D, H, P.sources, 0).plan
    P.sources.queue = { state: 'stale', observed_at: NOW - 10800000 }
    return { stale, retained, failed, partial, old: heads.headHTML(D, H, P.sources, 0).plan }
  }, NOW)
  expect(result.stale).toContain('Last read 3 h ago (11:20); this may be out of date.')
  expect(result.retained).toMatchObject({ show: 'rows', stale: true })
  expect(result.failed).toContain('unavailable, showing the read 12 min ago (14:08)')
  expect(result.partial).toContain('partial, read 12 min ago (14:08)'); expect(result.old).toContain('stale, read 3 h ago (11:20)')
})
test('unknown clocks, missing sources and failed index never invent facts', async ({ page }) => {
  expect(await page.evaluate(NOW => {
    const ages = [m.ageText({ observed_at: null }, NOW), m.ageText({ observed_at: NOW }, null)]
    const missing = m.sectionState({}, D, H, 'hist', []), invalid = m.sectionState({ sources: { history: { state: 'bogus' } } }, D, H, 'hist', [])
    P.sources.index = { state: 'unavailable' }
    return { ages, missing, invalid, sub: mark('plan', P.sources.queue).sub }
  }, NOW)).toEqual({ ages: ['no successful read recorded', 'no successful read recorded'], missing: { show: 'unavailable', stale: false, src: { state: 'unavailable', observed_at: null, reason: 'unknown' } }, invalid: { show: 'unavailable', stale: false, src: { state: 'unavailable', observed_at: null, reason: 'unknown' } }, sub: 'The build queue is empty. The open-ticket index is unavailable, so the number not queued is unknown.' })
})
test('reason tags are bounded and hostile copy is escaped by the marker factory', async ({ page }) => {
  expect(await page.evaluate(() => {
    const why = '<img src=x onerror="window.hacked=1">'
    const el = layout.makeMark(mark('hist', { state: 'unavailable', reason: why, observed_at: null })); document.body.append(el)
    return [m.reasonText('not_wired'), m.reasonText(null), m.reasonText('unknown'), m.reasonText('unavailable'), m.reasonText('x'.repeat(100)).length, el.querySelectorAll('img').length, el.textContent.includes(why), window.hacked ?? null]
  })).toEqual(['not connected', 'unknown cause', 'unknown cause', 'unknown cause', 80, 0, true, null])
})
test('metadata covers five sources and arms just one age tick when needed', async ({ page }) => {
  expect(await page.evaluate(async () => {
    const hook = await import('/build-home/hook.js')
    let callback, intervals = 0, passes = 0
    Object.assign(state.ctx, { snap: P, life: { every(ms, cb) { if (ms !== 30000) throw Error(ms); intervals++; callback = cb } } })
    state.fx.requestLivePass = () => passes++
    m.syncStates(); const healthy = intervals
    P.sources.features.state = 'incomplete'; P.sources.queue.state = 'disabled'; m.syncStates(); m.syncStates(); callback()
    const text = state.ctx.root.dataset.bdStates
    state.ctx.root.removeAttribute('data-bd-states')
    hook.writeOwnData()
    const rewritten = state.ctx.root.dataset.bdStates
    P.sources.features.state = P.sources.queue.state = 'ok'; callback()
    return { healthy, intervals, passes, text, rewritten }
  })).toEqual({ healthy: 0, intervals: 1, passes: 1, text: 'features:incomplete queue:disabled', rewritten: 'features:incomplete queue:disabled' })
})
