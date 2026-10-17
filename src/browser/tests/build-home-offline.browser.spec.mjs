import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'

const NOW = 1791408000000
test.use({ timezoneId: 'America/Los_Angeles' })
test.beforeEach(async ({ page }) => {
  await page.route('**/offline-harness', route => route.fulfill({ contentType: 'text/html', body: '<main id="build-root"><div id="bd-offline"></div></main>' }))
  await page.goto('/offline-harness')
  await page.clock.install({ time: NOW - 1000 })
  await page.clock.pauseAt(NOW)
  await page.evaluate(async NOW => {
    const state = await import('/build-home/state.js')
    const life = await import('/build-home/life.js')
    const clock = await import('/build-home/clock.js')
    const offline = await import('/build-home/offline.js')
    const hook = await import('/build-home/hook.js')
    state.resetState({})
    Object.assign(state.ctx, { life: life.createLife(), root: document.querySelector('#build-root'), snap: { daemon: { state: 'live' } } })
    window.calls = { teardown: 0, connect: 0, resync: 0, status: 0, ticks: 0 }
    const every = window.setInterval.bind(window)
    window.setInterval = (fn, ms) => every(() => { calls.ticks++; fn() }, ms)
    state.ctx.resync = () => calls.resync++
    state.fx.renderStatus = () => calls.status++
    window.liveSocket = { disconnectedTimeout: 500, getSocket: () => ({ isConnected: () => false,
      teardown(cb) { calls.teardown++; cb() }, connect() { calls.connect++ } }) }
    window.m = { ...state, ...clock, ...offline, ...hook }
    window.hook = hook.createBuildHomeHook()
    window.hook.buildActive = true
    clock.setNow(NOW)
    offline.renderOffline()
  }, NOW)
})
const down = page => page.evaluate(() => hook.disconnected())
const up = page => page.evaluate(() => { m.ctx.push = () => new Promise(() => {}); hook.reconnected() })
const daemon = (page, state, heartbeat = NOW - 360000) => page.evaluate(({ state, heartbeat }) => {
  m.ctx.snap = { daemon: { state, heartbeat_at: heartbeat } }; m.renderOffline()
}, { state, heartbeat })

test('short socket drops are debounced through hook callbacks', async ({ page }) => {
  await down(page); await page.clock.runFor(400)
  await expect(page.locator('.bd-offline')).toHaveCount(0)
  await expect(page.locator('#build-root')).not.toHaveClass(/stale/)
  await up(page)
  await expect(page.locator('.bd-offline')).toHaveCount(0)
  await expect(page.locator('#build-root')).not.toHaveClass(/stale/)
})
test('socket loss renders unreachable, freezes heartbeat and updates age', async ({ page }) => {
  await down(page); await page.clock.runFor(600)
  await expect(page.locator('.bd-offline b')).toHaveText('Daemon unreachable')
  await expect(page.locator('#build-root')).toHaveClass(/stale/)
  expect(await page.evaluate(() => m.daemonView())).toMatchObject({ dotOff: true, socketDown: true, dotText: 'Daemon unreachable' })
  expect(await page.evaluate(() => calls.status)).toBe(1)
  await page.clock.runFor(360000)
  await expect(page.locator('.bd-offline')).toContainText('last heartbeat 6 min ago (14:20)')
})
test('offline design copy and accessible status markup', async ({ page }) => {
  await daemon(page, 'offline')
  await expect(page.locator('.bd-offline')).toHaveAttribute('role', 'status')
  await expect(page.locator('.bd-offline')).toHaveText('Daemon offline · last heartbeat 6 min ago (14:14). Showing cached state — agent states and usage may be stale.Reconnect')
  expect(await page.evaluate(() => m.daemonView().socketDown)).toBe(false)
  await page.clock.resume()
  const audit = await new AxeBuilder({ page }).include('#bd-offline').analyze()
  expect(audit.violations).toEqual([])
})
test('stale cause and previous local day retain their own copy', async ({ page }) => {
  await daemon(page, 'stale', NOW - 10800000)
  await expect(page.locator('.bd-offline')).toContainText('Daemon stale · last heartbeat 3 h ago (11:20)')
  await daemon(page, 'offline', NOW - 86400000)
  await expect(page.locator('.bd-offline')).toContainText('(Tue Oct 6 14:20)')
  expect(await page.evaluate(() => m.fmtWhen(new Date(2026, 9, 7, 0, 5).getTime(), 1791408000000))).toBe('00:05')
  expect(await page.evaluate(() => [m.fmtAge(-1), m.fmtAge(60000), m.fmtAge(172800000)])).toEqual(['less than 1 min ago', '1 min ago', '2 days ago'])
})
test('missing and malformed heartbeat never render a plausible timestamp', async ({ page }) => {
  for (const heartbeat of [null, '1791408000000']) {
    await daemon(page, 'offline', heartbeat)
    await expect(page.locator('.bd-offline')).toContainText('no heartbeat recorded')
    await expect(page.locator('.bd-offline')).not.toContainText('min ago')
  }
  await page.evaluate(() => { m.ctx.life.dispose(); m.resetState(); m.ctx.life = null })
  // Reset also resets the shared clock; a first-drop heartbeat cannot be invented.
  await page.evaluate(async () => {
    const { createLife } = await import('/build-home/life.js')
    m.ctx.life = createLife(); m.ctx.root = document.querySelector('#build-root'); m.ctx.socket = 'down'; m.renderOffline()
  })
  await page.clock.runFor(600)
  await expect(page.locator('.bd-offline')).toContainText('no heartbeat recorded')
})
test('unread daemon on an open socket says up with the last good age and never becomes live', async ({ page }) => {
  for (const state of ['unknown', 'bogus', undefined]) {
    await daemon(page, state)
    expect(await page.evaluate(() => ({ view: m.daemonView(), live: m.ctx.offline.isLive() }))).toMatchObject({
      view: { dotText: 'Daemon up · unread, last good 6m', dotTitle: 'Daemon up · fleet snapshot unread, last good 6 min ago', dotOff: false, banner: null, stale: false }, live: false,
    })
    await expect(page.locator('.bd-offline')).toHaveCount(0)
    await expect(page.locator('#build-root')).not.toHaveClass(/stale/)
  }
})
test('a GitHub-held source with a live daemon is named with its age, never as an unknown daemon', async ({ page }) => {
  // Shape from Aiur.BuildOrder.Index.Sources: a held catch-up marks history stale; index is always ok.
  const held = { history: { state: 'stale', observed_at: NOW - 120000, reason: 'catch_up_held' }, index: { state: 'ok', observed_at: NOW, reason: null } }
  const view = (state, heartbeat) => page.evaluate(({ state, heartbeat, held }) => {
    m.ctx.snap = { daemon: { state, heartbeat_at: heartbeat }, sources: held }; return m.daemonView()
  }, { state, heartbeat, held })
  expect(await view('live', NOW)).toMatchObject({
    dotText: 'Daemon live · history held 2m', dotTitle: 'Daemon live · history held by GitHub, read 2 min ago', dotOff: false,
  })
  expect(await view('unknown', null)).toMatchObject({
    dotText: 'Daemon up · unread · history held 2m',
    dotTitle: 'Daemon up · fleet snapshot unread, no good reading yet · history held by GitHub, read 2 min ago', dotOff: false, banner: null,
  })
  await down(page); await page.clock.runFor(600)
  expect(await view('unknown', null)).toMatchObject({ dotText: 'Daemon unreachable', dotOff: true, stale: true })
})
test('no snapshot yet stays unknown', async ({ page }) => {
  await page.evaluate(() => { m.ctx.snap = null })
  expect(await page.evaluate(() => m.daemonView())).toMatchObject({ dotText: 'Daemon status unknown', dotOff: true })
})
test('reconnect tears down the dropped socket once and times out without hiding banner', async ({ page }) => {
  await down(page); await page.clock.runFor(600)
  await page.locator('#bd-retry').click()
  await expect(page.locator('#bd-retry')).toBeDisabled()
  await expect(page.locator('#bd-retry')).toHaveText('Reconnecting…')
  await page.evaluate(() => document.querySelector('#bd-retry').click())
  expect(await page.evaluate(() => calls)).toMatchObject({ teardown: 1, connect: 1, resync: 0 })
  await page.clock.runFor(10000)
  await expect(page.locator('#bd-retry')).toBeEnabled()
  await expect(page.locator('#bd-retry')).toHaveText('Reconnect')
  await expect(page.locator('.bd-offline')).toBeVisible()
})
test('reconnected hook clears stale state and restores live consumers', async ({ page }) => {
  await down(page); await page.clock.runFor(600); await page.locator('#bd-retry').click(); await up(page)
  await expect(page.locator('.bd-offline')).toHaveCount(0)
  await expect(page.locator('#build-root')).not.toHaveClass(/stale/)
  expect(await page.evaluate(() => m.ctx.offline.isLive())).toBe(true)
})
test('server degradation resyncs and applied empty-set diff clears retry', async ({ page }) => {
  await page.evaluate(() => m.receive({ v: 1, kind: 'snapshot', epoch: 'test', generation: 1, now: 1791408000000,
    sections: { hist: [], now: [], plan: [], nq: [] }, features: {}, daemon: { state: 'offline', heartbeat_at: 1791407640000 } }))
  await page.locator('#bd-retry').click()
  expect(await page.evaluate(() => calls)).toMatchObject({ resync: 1, teardown: 0 })
  await expect(page.locator('#bd-retry')).toBeDisabled()
  await page.evaluate(() => m.receive({ v: 1, kind: 'diff', epoch: 'test', generation: 2, now: 1791408000100, set: {}, upsert: [], remove: [] }))
  await expect(page.locator('#bd-retry')).toBeEnabled()
  await expect(page.locator('.bd-offline')).toBeVisible()
})
test('dispose and reset release pending offline timers and state', async ({ page }) => {
  await down(page); await page.clock.runFor(600); await page.locator('#bd-retry').click()
  await page.evaluate(() => { m.ctx.life.dispose(); m.resetState(); document.querySelector('#bd-offline').innerHTML = '' })
  await page.clock.runFor(60000)
  expect(await page.evaluate(() => calls.ticks)).toBe(0)
  await expect(page.locator('.bd-offline')).toHaveCount(0)
  expect(await page.evaluate(() => m.daemonView().socketDown)).toBe(false)
})
test('mounted exposes the real single-flight resync function', async ({ page }) => {
  await page.evaluate(() => {
    m.ctx.life.dispose()
    for (const id of ['bd-usage', 'bd-fh', 'bd-tools-l', 'bd-filters', 'bd-tools', 'bd-vp', 'bd-sb', 'bd-tree', 'bd-status']) {
      const el = document.createElement('div'); el.id = id; m.ctx.root.append(el)
    }
    document.querySelector('#bd-sb').innerHTML = '<i></i>'
    hook.el = m.ctx.root; hook.pushEvent = () => new Promise(() => {}); hook.handleEvent = () => {}
    hook.mounted()
  })
  expect(await page.evaluate(() => m.ctx.resync === m.resync)).toBe(true)
  await page.evaluate(() => hook.destroyed())
})
