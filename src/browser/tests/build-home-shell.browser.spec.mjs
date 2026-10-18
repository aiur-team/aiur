// Lifecycle scenarios share the real server shell and its dataset/navigation helpers.
import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

// Shell lifecycle cases share one live fixture to verify transitions across mounts.
const pageErrors = new WeakMap()
test.beforeEach(({ page }) => { const errors = []; pageErrors.set(page, errors); page.on('pageerror', error => errors.push(error.message)) })
test.afterEach(({ page }) => { expect(pageErrors.get(page), 'uncaught browser errors').toEqual([]) })

async function open(page, dataset = 'live') {
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.setViewportSize({ width: 1440, height: 900 })
  await page.goto(`/build-fixture/${dataset}`)
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected())).toBe(true)
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-state', dataset === 'unavailable' ? 'unavailable' : 'ready')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-home-hook', 'mounted')
  await expect(page.locator('#build-root')).not.toHaveClass(/\bphx-hook-loading\b/)
}

async function patch(page) {
  const toggle = page.locator('#ax-drag')
  const previous = await toggle.getAttribute('data-nav-collapsed')
  await toggle.click()
  await expect(toggle).toHaveAttribute('data-nav-collapsed', previous === 'true' ? 'false' : 'true')
}

test('hook-owned DOM survives a server patch', async ({ page }) => {
  await open(page)
  await page.locator('#build-root').evaluate(root => root.append(Object.assign(document.createElement('b'), { id: 'probe' })))
  await patch(page)
  await expect(page.locator('#probe')).toHaveCount(1)
})

test('an open modal survives a server patch', async ({ page }) => {
  await open(page)
  await page.evaluate(() => {
    document.querySelector('#tk-backdrop').classList.add('show')
    document.querySelector('#tk-body').append(Object.assign(document.createElement('b'), { id: 'mprobe' }))
  })
  // The modal deliberately overlays navigation once its styles have landed.
  await page.locator('#ax-drag').evaluate(handle => handle.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true })))
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'true')
  await expect(page.locator('#tk-backdrop')).toHaveClass(/\bshow\b/)
  await expect(page.locator('#mprobe')).toHaveCount(1)
})

test('server state reaches the ignored root', async ({ page }) => {
  await open(page)
  await expect(page.locator('#build-root')).not.toHaveAttribute('data-build-reason')
  await open(page, 'unavailable')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-reason', 'unknown')
})

test('fixture endpoint picks only known datasets and carries query strings', async ({ request }) => {
  for (const dataset of ['live', 'dense', 'newrepo', 'noqueue', 'offline', 'hold', 'unavailable']) {
    const response = await request.get(`/build-fixture/${dataset}?ticket=12`, { maxRedirects: 0 })
    expect(response.status()).toBe(302)
    expect(response.headers().location).toBe('/build?ticket=12')
  }
  for (const dataset of ['manifest', 'usage-sets', 'nope', '..%2Flive']) {
    expect((await request.get(`/build-fixture/${dataset}`, { maxRedirects: 0 })).status()).toBe(404)
  }
})

test('future regression guard: hook-written data attributes are removed but classes survive', async ({ page }) => {
  await open(page)
  await page.locator('#build-root').evaluate(root => { root.dataset.probe = '1'; root.classList.add('probe') })
  await patch(page)
  await expect(page.locator('#build-root')).not.toHaveAttribute('data-probe')
  await expect(page.locator('#build-root')).toHaveClass(/\bprobe\b/)
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-state', 'ready')
})

async function ready(page) {
  await open(page)
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
}
async function pauseHistory(page) {
  // Stop new near-top pages, then drain any reply already repainting the board.
  await page.evaluate(async () => { (await import('/build-home/state.js')).S.ready = false })
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'idle')
}
async function isolateScrollbar(page) {
  await pauseHistory(page)
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    ctx.L = null; ctx.vp.replaceChildren()
  })
}
const state = page => page.evaluate(async () => {
  const { S, ctx } = await import('/build-home/state.js')
  return { loading: S.loading, view: S.view, generation: ctx.proto.generation }
})

test('B1 skeleton stays past the design timer until a payload arrives', async ({ page }) => {
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.clock.install()
  await page.goto('/build-fixture/hold')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-home-hook', 'mounted')
  await page.clock.runFor(2000)
  await expect(page.locator('.bd-skel > i')).toHaveCount(16)
  await expect(page.locator('.bd-spin')).toHaveCount(1)
  await expect(page.locator('#bd-content')).toHaveCount(0)
  expect((await state(page)).loading).toBe(true)
})

test('B2 unavailable state and error replies remove the spinner', async ({ page }) => {
  await open(page, 'unavailable')
  await expect(page.locator('.bd-loading')).toHaveText('Build timeline unavailable · build index read failed')
  await patch(page)
  await expect(page.locator('.bd-loading')).toHaveText('Build timeline unavailable · unknown cause (unknown)')
  await expect(page.locator('.bd-spin, #bd-content, .bd-mk.empty')).toHaveCount(0)
  await page.evaluate(async () => (await import('/build-home/hook.js')).receive({ v: 1, kind: 'error', reason: 'unavailable' }))
  await expect(page.locator('.bd-loading')).toHaveText('Build timeline unavailable · unknown cause (unavailable)')
  expect((await state(page)).loading).toBe(true)
})

test('B3 clock ignores wall time; B3b invalid now never applies', async ({ page }) => {
  await page.clock.install({ time: new Date('2030-01-01') }); await ready(page)
  expect(await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { nowMs } = await import('/build-home/clock.js')
    return Math.abs(nowMs() - ctx.snap.now)
  })).toBeLessThan(1000)
  const snapshot = await page.evaluate(async () => (await import('/build-home/state.js')).ctx.snap)
  await open(page, 'unavailable')
  expect(await page.evaluate(async snapshot => {
    const { receive } = await import('/build-home/hook.js'), { ctx } = await import('/build-home/state.js')
    receive({ ...snapshot, now: null })
    return { D: ctx.D, now: (await import('/build-home/clock.js')).nowMs() }
  }, snapshot)).toEqual({ D: null, now: null })
  await expect(page.locator('.bd-loading')).toHaveText('Build timeline unavailable · invalid data')
})

test('B4 actual server diff updates the row and generation', async ({ page }) => {
  await ready(page)
  const before = await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'); return { row: ctx.D.plan[0], generation: ctx.proto.generation }
  })
  await page.request.get('/build-control/diff')
  await expect.poll(async () => (await state(page)).generation).toBe(before.generation + 1)
  expect(await page.evaluate(async id => (await import('/build-home/state.js')).ctx.D.byId[id].pct, before.row.id)).toBe(before.row.pct + 1)
})

test('B5 gaps single-flight; B6 invalid diff leaves all data unchanged', async ({ page }) => {
  await ready(page)
  expect(await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { receive } = await import('/build-home/hook.js')
    const before = JSON.stringify(ctx.snap), D = ctx.D; let calls = 0
    ctx.push = () => { calls++; return new Promise(() => {}) }
    receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1,
      now: ctx.snap.now, upsert: [{ sec: 'now' }], remove: [ctx.D.all[0].id], set: {} })
    receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1,
      now: ctx.snap.now, upsert: [{ ...ctx.D.all[0], title: 'must not leak' }], remove: [], set: { features: null } })
    const unchanged = before === JSON.stringify(ctx.snap) && D === ctx.D
    for (let i = 0; i < 2; i++) receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 3 })
    return { unchanged, calls, inFlight: ctx.proto.inFlight }
  })).toEqual({ unchanged: true, calls: 1, inFlight: true })
})

test('B7 reconnect requests new epoch and repaints without viewport', async ({ page }) => {
  await ready(page)
  await pauseHistory(page)
  const epoch = await page.locator('#build-root').getAttribute('data-build-epoch')
  await page.evaluate(async () => {
    const { fx } = await import('/build-home/state.js'); window.paint = { viewport: 0, relayout: 0 }
    fx.viewport = () => window.paint.viewport++; fx.relayout = () => window.paint.relayout++
    window.liveSocket.disconnect()
  })
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-socket', 'down')
  await page.evaluate(() => window.liveSocket.connect())
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-socket', 'up')
  await expect(page.locator('#build-root')).not.toHaveAttribute('data-build-epoch', epoch)
  expect(await page.evaluate(() => window.paint)).toEqual({ viewport: 0, relayout: 1 })
})

test('B8 offline URL write reaches server after reconnect', async ({ page }) => {
  await ready(page); await page.evaluate(() => window.liveSocket.disconnect())
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-socket', 'down')
  await page.evaluate(async () => {
    (await import('/build-home/state.js')).S.view = 'list'
    await (await import('/build-home/url.js')).writeURL(); window.liveSocket.connect()
  })
  await expect(page).toHaveURL(/\?view=list$/)
})

test('B9 canonical initial state; B10 corrected URL never echoes', async ({ page }) => {
  await page.context().setHTTPCredentials(dashboardCredentials)
  await open(page)
  // A live navigation mounts with params; the harness's nested HTTP router drops query params.
  await page.evaluate(() => window.liveSocket.main.pushLinkPatch(new Event('click'), '/commands', null))
  await expect(page.locator('#build-root')).toHaveCount(0)
  await page.evaluate(() => window.liveSocket.main.pushLinkPatch(new Event('click'), '/build?feature=%3Cb%3E&astate=bogus,paused&example=dense&span=7', null))
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
  const before = await page.evaluate(async () => {
    const { S, ctx } = await import('/build-home/state.js'); window.urlCalls = 0; const push = ctx.push
    ctx.push = (event, params) => { if (event === 'build:url') window.urlCalls++; return push(event, params) }
    return { feature: S.feature, astate: S.f.astate, span: S.span, demo: 'demo' in S, history: history.length }
  })
  expect(before).toMatchObject({ feature: null, astate: ['paused'], span: 7, demo: false })
  await page.evaluate(async () => {
    const { S } = await import('/build-home/state.js'); S.span = 1; S.f.astate = ['bogus', 'paused']
    await (await import('/build-home/url.js')).writeURL()
  })
  await expect(page).toHaveURL(/\?astate=paused$/)
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/state.js')).S.f.astate)).toEqual(['paused'])
  expect(await page.evaluate(() => ({ calls: window.urlCalls, history: history.length }))).toEqual({ calls: 1, history: before.history })
})

test('B11 remount resets state and disposes old listeners and intervals', async ({ page }) => {
  await page.addInitScript(() => {
    window.buildIntervals = new Set(); const set = window.setInterval, clear = window.clearInterval
    window.setInterval = (fn, ms, ...args) => {
      const id = set(fn, ms, ...args); if (new Error().stack.includes('/build-home/')) window.buildIntervals.add(id); return id
    }
    window.clearInterval = id => { window.buildIntervals.delete(id); clear(id) }
  })
  await ready(page)
  await page.evaluate(() => window.liveSocket.main.pushLinkPatch(new Event('click'), '/commands', null))
  await expect(page.locator('#build-root')).toHaveCount(0)
  expect(await page.evaluate(() => window.buildIntervals.size)).toBe(0)
  await page.evaluate(() => window.liveSocket.main.pushLinkPatch(new Event('click'), '/build?view=list', null))
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-home-hook', 'mounted')
  // The initial snapshot creates the viewport and clears its lock after mounting.
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
  expect((await state(page)).view).toBe('list')
  await page.evaluate(async () => {
    const { ctx, fx } = await import('/build-home/state.js'); ctx.lockId = '1'; window.unlocks = 0; fx.unlock = () => window.unlocks++
  })
  await page.keyboard.press('Escape')
  expect(await page.evaluate(() => ({ unlocks: window.unlocks, intervals: window.buildIntervals.size }))).toEqual({ unlocks: 1, intervals: 3 })
})

for (const event of ['pointercancel', 'lostpointercapture']) test(`B12 ${event} ends drag`, async ({ page }) => {
  await ready(page)
  await isolateScrollbar(page)
  expect(await page.evaluate(async event => {
    const { ctx } = await import('/build-home/state.js'), { syncSB } = await import('/build-home/shell.js')
    ctx.vp.append(Object.assign(document.createElement('div'), { style: 'height:4000px' })); syncSB()
    ctx.vp.scrollTop = 0
    const th = document.querySelector('#bd-sb i'); th.setPointerCapture = () => {}
    th.dispatchEvent(new PointerEvent('pointerdown', { clientY: 60, pointerId: 1 }))
    th.dispatchEvent(new PointerEvent(event)); th.dispatchEvent(new PointerEvent('pointermove', { clientY: 160 }))
    return { drag: document.querySelector('#bd-sb').classList.contains('drag'), top: ctx.vp.scrollTop }
  }, event)).toEqual({ drag: false, top: 0 })
})

test('B13 version mismatch reloads only once', async ({ page }) => {
  await open(page, 'unavailable')
  expect(await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { receive } = await import('/build-home/hook.js')
    sessionStorage.removeItem('aiur-build-reloaded'); let reloads = 0; ctx.reload = () => reloads++
    receive({ v: 2 }); receive({ v: 2 }); return reloads
  })).toBe(1)
  await expect(page.locator('.bd-loading')).toHaveText('Build timeline unavailable · page out of date, reload')
})

test('B14 missing host fails loudly without throwing', async ({ page }) => {
  const errors = []; page.on('console', msg => { if (msg.type() === 'error') errors.push(msg.text()) })
  let release; const gate = new Promise(resolve => { release = resolve })
  await page.route('**/build-home/hook.js', async route => { await gate; await route.continue() })
  await page.context().setHTTPCredentials(dashboardCredentials); await page.goto('/build-fixture/live')
  await page.locator('#bd-sb').evaluate(el => el.remove()); release()
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-home-hook', 'failed')
  expect(errors.filter(message => message.includes('BuildHome missing host: bd-sb'))).toHaveLength(1)
})

test('B15 live motion preference; B16 apostrophe escaping', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' }); await ready(page)
  await expect(page.locator('#build-root')).toHaveClass(/\brm\b/)
  await page.emulateMedia({ reducedMotion: 'no-preference' })
  await expect(page.locator('#build-root')).not.toHaveClass(/\brm\b/)
  expect(await page.evaluate(async () => (await import('/build-home/dom.js')).esc("<'\"&>"))).toBe('&lt;&#39;&quot;&amp;&gt;')
})

test('B17 hook attributes survive server patches', async ({ page }) => {
  await ready(page)
  const attrs = () => page.locator('#build-root').evaluate(el => Object.fromEntries(['buildHomeHook', 'bdMounted', 'buildSocket', 'buildEpoch', 'buildGeneration'].map(key => [key, el.dataset[key]])))
  const before = await attrs(); await patch(page); expect(await attrs()).toEqual(before)
})

test('B18 disconnect releases in-flight guard and ignores old reply', async ({ page }) => {
  await ready(page)
  expect(await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { resync, createBuildHomeHook } = await import('/build-home/hook.js')
    const replies = []; ctx.push = event => event === 'build-resync' ? new Promise(resolve => replies.push(resolve)) : Promise.resolve({})
    const hook = createBuildHomeHook(); hook.buildActive = true
    resync(); hook.disconnected(); hook.reconnected()
    replies[0]({ ...ctx.snap, epoch: 'old-reply' }); await Promise.resolve()
    const inFlight = ctx.proto.inFlight, epoch = ctx.proto.epoch
    replies[1]({ ...ctx.snap, epoch: 'new-reply' }); await Promise.resolve()
    return { calls: replies.length, inFlight, ignored: epoch !== 'old-reply', epoch: ctx.proto.epoch }
  })).toEqual({ calls: 2, inFlight: true, ignored: true, epoch: 'new-reply' })
})

test('B19 scrollbar geometry, track click, active timer and drag', async ({ page }) => {
  await ready(page); await isolateScrollbar(page)
  await page.clock.install({ time: new Date('2030-01-01T00:00:00Z') }); await page.clock.pauseAt(new Date('2030-01-02T00:00:00Z'))
  const measure = () => page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'); (await import('/build-home/shell.js')).syncSB()
    const sb = document.querySelector('#bd-sb'), th = sb.querySelector('i')
    return { range: ctx.vp.scrollHeight - ctx.vp.clientHeight, ch: ctx.vp.clientHeight, sh: ctx.vp.scrollHeight,
      track: sb.clientHeight, height: parseFloat(th.style.height), y: parseFloat(th.style.transform.slice(11)), off: sb.classList.contains('off') }
  })
  await page.locator('#bd-vp').evaluate(el => el.append(Object.assign(document.createElement('div'), { id: 'spacer', style: 'height:20000px' })))
  let m = await measure(); expect(m.off).toBe(false); expect(m.height).toBeCloseTo(Math.max(28, m.track * m.ch / m.sh))
  await page.locator('#bd-vp').evaluate(el => new Promise(resolve => {
    el.addEventListener('scroll', resolve, { once: true }); el.scrollTop = (el.scrollHeight - el.clientHeight) / 2
  }))
  m = await measure(); expect(m.y).toBeCloseTo(0.5 * (m.track - m.height), 0)
  await page.clock.runFor(699); await expect(page.locator('#bd-sb')).toHaveClass(/\bact\b/)
  await page.clock.runFor(2); await expect(page.locator('#bd-sb')).not.toHaveClass(/\bact\b/)
  await page.locator('#bd-vp').evaluate(el => { el.scrollTop = 0 }); await measure()
  const box = await page.locator('#bd-sb i').boundingBox()
  await page.mouse.move(box.x + box.width / 2, box.y + 3); await page.mouse.down(); await page.mouse.move(box.x + box.width / 2, box.y + 103)
  await expect(page.locator('#bd-sb')).toHaveClass(/\bdrag\b/)
  expect(Math.abs(await page.locator('#bd-vp').evaluate(el => el.scrollTop) - 100 * m.range / (m.track - m.height))).toBeLessThan(2)
  await page.mouse.up(); await expect(page.locator('#bd-sb')).not.toHaveClass(/\bdrag\b/)
  await page.locator('#bd-sb').evaluate(el => { const r = el.getBoundingClientRect(); el.dispatchEvent(new PointerEvent('pointerdown', { clientY: r.top + r.height * .75 })) })
  expect(Math.abs(await page.locator('#bd-vp').evaluate(el => el.scrollTop) - .75 * m.range)).toBeLessThan(2)
  await page.locator('#spacer').evaluate(el => el.remove()); expect((await measure()).off).toBe(true)
})

test('store moves rows, removes ids, replaces blocks and merges older pages without overwriting diffs', async ({ page }) => {
  await ready(page)
  expect(await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { applyDiff, mergeEarlier } = await import('/build-home/store.js')
    const [row, removed] = ctx.D.plan, snap = ctx.snap
    const moved = { ...row, sec: 'now', title: 'updated title' }
    const result = applyDiff({ now: snap.now + 1000, generation: snap.generation + 1, upsert: [moved], remove: [removed.id], set: { counts: { now: 22 }, sources: { state: 'test' }, capacity: 42 } })
    const beforePageGeneration = ctx.proto.generation
    const page = mergeEarlier({ epoch: snap.epoch, rows: [row, { ...removed, sec: 'hist' }], history: { more: false } })
    return { result, page, moved: ctx.D.byId[row.id].title, sec: ctx.D.byId[row.id].sec,
      duplicate: ctx.D.all.filter(r => r.id === row.id).length, removedFromPlan: !ctx.D.plan.some(r => r.id === removed.id),
      counts: ctx.D.counts, sources: ctx.D.sources, capacity: ctx.D.capacity, history: ctx.snap.history,
      generation: ctx.proto.generation === beforePageGeneration,
      oldEpoch: mergeEarlier({ epoch: 'old', rows: [] }) }
  })).toEqual({ result: { ok: true }, page: { ok: true }, moved: 'updated title', sec: 'now', duplicate: 1,
    removedFromPlan: true, counts: { now: 22 }, sources: { state: 'test' }, capacity: 42, history: { more: false }, generation: true, oldEpoch: { error: 'epoch' } })
})

test('destroy cancels timers, frames and late replies without mutating a new mount', async ({ page }) => {
  await ready(page); await isolateScrollbar(page)
  await page.clock.install({ time: new Date('2030-01-01T00:00:00Z') }); await page.clock.pauseAt(new Date('2030-01-02T00:00:00Z'))
  expect(await page.evaluate(async () => {
    const { ctx, resetState } = await import('/build-home/state.js'), { resync, createBuildHomeHook } = await import('/build-home/hook.js')
    const { createLife } = await import('/build-home/life.js'); let resolve, calls = 0
    const old = ctx.life, saved = ctx.snap, hook = createBuildHomeHook(); hook.buildLife = old
    old.later('probe', 10, () => calls++); old.frame('probe', () => calls++)
    ctx.push = () => new Promise(reply => { resolve = reply }); resync(); hook.destroyed()
    resetState(); ctx.life = createLife(); resolve(saved); await Promise.resolve()
    window.destroyProbeCalls = () => calls
    return { snap: ctx.snap, disposed: old.disposed }
  })).toEqual({ snap: null, disposed: true })
  await page.clock.runFor(100)
  expect(await page.evaluate(() => window.destroyProbeCalls())).toBe(0)
})
