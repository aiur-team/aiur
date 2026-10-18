import { test, expect } from '@playwright/test'
import { measureBrowserWork, assertMeasurementBudget } from './support/measurements.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })
test.beforeEach(async ({ page }) => {
  await page.goto('/build-fixture/live')
  await expect(page.locator('#bd-content')).toHaveCount(1)
  await page.evaluate(async () => {
    window.st = await import('/build-home/state.js')
    window.ren = await import('/build-home/render.js')
    window.hist = await import('/build-home/history.js')
    window.store = await import('/build-home/store.js')
    window.hook = await import('/build-home/hook.js')
    window.heads = await import('/build-home/render-heads.js')
    window.ctx = st.ctx; window.S = st.S
    // Keep the paging trigger inactive until each case explicitly scrolls into it.
    ctx.vp.scrollTop = Math.min(ctx.vp.scrollHeight - ctx.vp.clientHeight, 800)
    window.anchor = () => {
      const a = ren.takeAnchor()
      return { a, top: ctx.vp.scrollTop, h: ctx.L.secs.hist.h }
    }
  })
})
test.afterEach(async ({ page }) => { await page.request.get('/build-control/earlier') })

test('window recycles uids and renders only intersecting cards with a 700px margin', async ({ page }) => {
  const result = await page.evaluate(() => {
    const original = ctx.D.hist[0]
    const rows = Array.from({ length: 10000 }, (_, i) => ({ ...original, id: 'long-' + i, epic: 'unsorted', end: original.end + i }))
    store.acceptSnapshot({ ...ctx.snap, sections: { ...ctx.snap.sections, hist: rows }, history: { ...ctx.snap.history, more: false } })
    ren.relayout(); ctx.vp.scrollTop = 18000; ren.update()
    const check = () => ['hist', 'plan', 'nq'].flatMap(s => ctx.L.secs[s].items.filter(it => {
      const y = ctx.secs[s].el.offsetTop + it.y
      return y + it.h >= ctx.vp.scrollTop - 700 && y <= ctx.vp.scrollTop + ctx.vp.clientHeight + 700
    }).map(it => s + ':' + it.t.id)).sort()
    const expected = check(), actual = [...ctx.R.keys()].sort(), old = new Map(ctx.R)
    ctx.vp.scrollTop += 100; ren.update()
    const kept = [...ctx.R].filter(([id]) => old.has(id))
    return { actual, expected, count: actual.length, kept: kept.length, same: kept.every(([id, el]) => old.get(id) === el), dropped: [...old].filter(([id]) => !ctx.R.has(id)).every(([, el]) => !el.isConnected) }
  })
  expect(result.actual).toEqual(result.expected); expect(result.count).toBeLessThan(60)
  expect(result.kept).toBeGreaterThan(0); expect(result.same).toBe(true); expect(result.dropped).toBe(true)
})

test('paging single flight holds loading until anchor restoration', async ({ page }) => {
  const before = await page.evaluate(() => {
    window.calls = []; window.originalPush = ctx.push
    ctx.push = (event, params) => { calls.push(params); return new Promise(resolve => { window.reply = () => originalPush(event, params).then(resolve) }) }
    ctx.vp.scrollTop = 200; ren.update()
    const a = anchor(); window.flight = hist.loadEarlier(); window.sameFlight = flight === hist.loadEarlier()
    return a
  })
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'loading')
  const result = await page.evaluate(async () => {
    const base = st.fx.relayout
    st.fx.relayout = opts => { base(opts); window.flagDuring = hist.H.state }
    await reply(); const ok = await flight
    st.fx.relayout = base; ctx.push = originalPush
    return { ok, calls: calls.length, sameFlight, flagDuring, after: anchor() }
  })
  expect(result.ok).toBe(true); expect(result.calls).toBe(1); expect(result.sameFlight).toBe(true)
  expect(result.flagDuring).toBe('loading')
  expect(result.after.top - before.top).toBeCloseTo(result.after.h - before.h, 0)
})

for (const mode of ['fail=1', 'stall=1']) test(`paging error and retry: ${mode}`, async ({ page }) => {
  const configured = await page.request.get('/build-control/earlier?' + mode)
  expect([configured.status(), await configured.text()]).toEqual([200, 'earlier configured'])
  await page.evaluate(() => { ctx.vp.scrollTop = 0; ren.update() })
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'error')
  await expect(page.locator('#bd-sec-hist .bd-sech')).toContainText('earlier days could not load')
  expect(await page.evaluate(async () => { ren.update(); return await hist.loadEarlier() })).toBe(false)
  await page.request.get('/build-control/earlier')
  const from = await page.evaluate(() => { ctx.vp.scrollTop = 400; ren.update(); ctx.vp.scrollTop = 0; ren.update(); return S.histFrom })
  await expect.poll(() => page.evaluate(() => S.histFrom)).toBeLessThan(from)
})

for (const mode of ['epoch', 'destroy', 'reject']) test(`paging late reply: ${mode}`, async ({ page }) => {
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'idle')
  const result = await page.evaluate(async mode => {
    const oldFrom = S.histFrom, epoch = ctx.proto.epoch
    if (!hist.H.more || hist.H.state !== 'idle') throw new Error('Late-reply fixture must start with pageable idle history')
    let markPushIssued
    const pushIssued = new Promise(resolve => { markPushIssued = resolve })
    ctx.push = () => new Promise((resolve, reject) => {
      window.complete = resolve; window.reject = reject
      markPushIssued()
    })
    const flight = hist.loadEarlier()
    if (hist.H.state !== 'loading') throw new Error('Late-reply fixture did not start a new page request')
    await pushIssued
    if (mode === 'epoch') ctx.proto.epoch = 'new-epoch'
    if (mode === 'destroy') ctx.life.dispose()
    if (mode === 'reject') reject(new Error('socket gone'))
    else complete({ kind: 'earlier', epoch, history: { ...ctx.snap.history, from: 1 }, rows: [] })
    const ok = await flight
    return { ok, from: S.histFrom, oldFrom, state: hist.H.state }
  }, mode)
  expect(result.ok).toBe(false); expect(result.from).toBe(result.oldFrom)
  if (mode !== 'destroy') expect(result.state).toBe(mode === 'reject' ? 'error' : 'idle')
})

for (const mode of ['total', 'start', 'source']) test(`header unknown branch: ${mode}`, async ({ page }) => {
  const result = await page.evaluate(mode => {
    const D = structuredClone(ctx.D), H = { ...hist.H, more: false }, sources = structuredClone(ctx.snap.sources)
    if (mode === 'total') { H.total = null; H.more = true }
    if (mode === 'start') D.hist.forEach(row => { row.start = null })
    if (mode === 'source') { D.hist = []; H.total = 0; sources.history.state = 'unavailable' }
    return heads.headHTML(D, H, sources, S.histFrom).hist
  }, mode)
  if (mode === 'total') { expect(result).toContain('loaded · total unknown'); expect(result).not.toContain('of 0') }
  if (mode === 'start') { expect(result).not.toContain(' from '); expect(result).toContain('all ') }
  if (mode === 'source') expect(result).toBe('History <em>unavailable</em>')
})

test('headers keep design count formatting and empty strings', async ({ page }) => {
  const result = await page.evaluate(() => heads.headHTML({ hist: [], plan: Array(1000), nq: Array(1000) }, { total: 0, more: false }, Object.fromEntries(['history', 'queue', 'index', 'agents', 'features'].map(key => [key, { state: 'ok' }])), 0))
  expect(result).toEqual({ hist: 'History <em>empty</em>', plan: 'Planned <em>1000 in build-queue order · dependency waves</em>', nq: 'Not queued <em>1000 open · not in the queue</em>' })
})

test('complete history header uses earliest finite start and keeps shown count', async ({ page }) => {
  const result = await page.evaluate(() => heads.headHTML({
    hist: [
      { start: null, end: new Date(2026, 9, 12).getTime() },
      { start: new Date(2026, 9, 11).getTime(), end: new Date(2026, 9, 13).getTime() },
      { start: new Date(2026, 9, 9).getTime(), end: new Date(2026, 9, 14).getTime() },
    ], plan: [], nq: [],
  }, { total: 3, more: false }, { history: { state: 'ok' } }, new Date(2026, 9, 14).getTime()).hist)
  expect(result).toBe('History <em>all 3 from Oct 9</em><em style="margin-left:auto;padding-right:14px">1 of 3 loaded</em>')
})

test('complete history header counts loaded rows when server total is unknown', async ({ page }) => {
  const result = await page.evaluate(() => heads.headHTML({ hist: [{ start: null, end: 1 }, { start: null, end: 2 }], plan: [], nq: [] }, { total: null, more: false }, { history: { state: 'ok' } }, 2).hist)
  expect(result).toBe('History <em>all 2</em><em style="margin-left:auto;padding-right:14px">1 of 2 loaded</em>')
})

test('complete available history header is empty with zero rows and unknown total', async ({ page }) => {
  const result = await page.evaluate(() => heads.headHTML({ hist: [], plan: [], nq: [] }, { total: null, more: false }, { history: { state: 'ok' } }, 0).hist)
  expect(result).toBe('History <em>empty</em>')
})

test('live keeps focus and unchanged DOM identity; focused card stays outside render window', async ({ page }) => {
  const id = await page.evaluate(() => {
    const el = [...ctx.R.values()].find(el => el.closest('#bd-sec-hist')); window.focusedBefore = el; el.focus(); window.unchanged = [...ctx.R.values()].find(other => other !== el)
    window.unchangedId = unchanged.dataset.id; return el.dataset.id
  })
  await page.request.get(`/build-control/diff?op=title&id=${encodeURIComponent(id)}`)
  await expect.poll(() => page.evaluate(() => document.activeElement?.dataset.id)).toBe(id)
  await expect.poll(() => page.evaluate(id => ctx.D.byId[id].title.endsWith(' updated'), id)).toBe(true)
  await expect.poll(() => page.evaluate(() => performance.getEntriesByName('build-home-live-pass').length)).toBeGreaterThan(0)
  expect(await page.evaluate(() => [...ctx.R.values()].find(el => el.dataset.id === unchangedId) === unchanged)).toBe(true)
  expect(await page.evaluate(() => document.activeElement !== focusedBefore)).toBe(true)
  expect(await page.evaluate(id => { ctx.vp.scrollTop = ctx.vp.scrollHeight; ren.update(); return { rendered: [...ctx.R.values()].some(el => el.dataset.id === id), focus: ctx.a11y.focusId } }, id)).toEqual({ rendered: true, focus: id })
})

for (const flag of ['drag', 'snap', 'scroll']) test(`live deferred during ${flag} then coalesces`, async ({ page }) => {
  const result = await page.evaluate(async flag => {
    const originalLayout = ctx.L
    if (flag === 'drag') ctx.root.querySelector('.bd-sb').classList.add('drag')
    if (flag === 'snap') ctx.snapping = true
    if (flag === 'scroll') ctx.content.classList.add('scrolling')
    const message = { kind: 'diff', v: 1, epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now, upsert: [], remove: [], set: {} }
    for (let i = 0; i < 20; i++) { message.generation = ctx.proto.generation + 1; hook.receive(message) }
    ren.flushLive(); const deferred = ctx.L === originalLayout
    ctx.root.querySelector('.bd-sb').classList.remove('drag'); ctx.snapping = false; ctx.content.classList.remove('scrolling')
    return { deferred, before: performance.getEntriesByName('build-home-live-pass').length }
  }, flag)
  expect(result.deferred).toBe(true)
  await expect.poll(() => page.evaluate(() => performance.getEntriesByName('build-home-live-pass').length)).toBe(result.before + 1)
})

test('span ensures days via server days parameter; no board anchor is safe', async ({ page }) => {
  const result = await page.evaluate(async () => {
    await hist.loadEarlier() // Finish any initial page before measuring the helper's own requests.
    const push = ctx.push, requests = []
    ctx.push = (event, params) => { if (event === 'load-earlier') requests.push(params); return push(event, params) }
    const days = (await import('/build-home/layout.js')).histDays(ctx.D.hist).length
    await hist.ensureDays(days + 2)
    ctx.content = null
    return { requests, days: (await import('/build-home/layout.js')).histDays(ctx.D.hist).length, anchor: ren.takeAnchor(), restore: ren.restoreAnchor(null) }
  })
  expect(result.requests[0].days).toBe(2); expect(result.days).toBeGreaterThanOrEqual(4); expect(result.anchor).toBeNull()
})

for (const kind of ['card', 'band']) test(`live move keeps ${kind} anchor and suppresses sliding`, async ({ page }) => {
  const before = await page.evaluate(async kind => {
    if (kind === 'band') ctx.vp.scrollTop = ctx.secs.hist.el.offsetTop + ctx.L.secs.hist.h - 100
    else ctx.vp.scrollTop = ctx.secs.nq.el.offsetTop - 40
    ren.update();
    const a = ren.takeAnchor()
    const layout = await import('/build-home/layout.js')
    const row = kind === 'band' ? ctx.D.now[0] : ctx.D.plan.find(row => {
      const D = { ...ctx.D, plan: ctx.D.plan.filter(t => t.id !== row.id) }
      return layout.computeLayout(D, S, { vpH: ctx.vp.clientHeight }, ctx.snap.sources).secs.plan.h < ctx.L.secs.plan.h
    })
    if (!row) throw new Error('fixture needs a move that changes section height')
    window.kept = new Map(ctx.R)
    return { a, id: row.id, passes: performance.getEntriesByName('build-home-live-pass').length }
  }, kind)
  expect(before.a.kind).toBe(kind === 'band' ? 'band' : 'cards')
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  await page.request.get(`/build-control/diff?op=move&id=${before.id}&to=${kind === 'band' ? 'hist' : 'now'}`)
  await expect.poll(() => page.evaluate(() => performance.getEntriesByName('build-home-live-pass').length)).toBeGreaterThan(before.passes)
  const result = await page.evaluate(a => {
    const nat = ctx.secs.hist.el.offsetTop + ctx.L.secs.hist.h
    const candidate = a.cards?.find(c => ctx.R.has(c.uid))
    const off = candidate ? ctx.R.get(candidate.uid).getBoundingClientRect().top - ctx.content.getBoundingClientRect().top - ctx.vp.scrollTop : nat - ctx.vp.scrollTop
    return { expected: candidate?.off ?? a.off, off, sliding: [...ctx.R].filter(([id, el]) => kept.get(id) === el).some(([, el]) => el.getAnimations().some(anim => anim.constructor.name === 'CSSTransition')) }
  }, before.a)
  expect(Math.abs(result.off - result.expected)).toBeLessThanOrEqual(1); expect(result.sliding).toBe(false)
})

test('reconnect restores the paged window from a new epoch', async ({ page }) => {
  const before = await page.evaluate(async () => {
    await hist.ensureDays(5); ctx.vp.scrollTop = 1000; ren.update()
    return { from: S.histFrom, epoch: ctx.proto.epoch, anchor: ren.takeAnchor() }
  })
  await page.evaluate(() => { window.liveSocket.disconnect(); window.liveSocket.connect() })
  await expect(page.locator('#build-root')).not.toHaveAttribute('data-build-epoch', before.epoch)
  await expect.poll(() => page.evaluate(() => S.histFrom)).toBe(before.from)
  const after = await page.evaluate(() => ren.takeAnchor())
  expect(after.kind).toBe(before.anchor.kind)
  expect(after.cards?.[0]).toEqual(before.anchor.cards?.[0])
})

test('filtered days continue paging and use server DST boundary exactly', async ({ page }) => {
  const from = await page.evaluate(() => S.histFrom)
  await page.request.get('/build-control/earlier?from=' + (from - 23 * 3600000))
  expect(await page.evaluate(async () => { await hist.loadEarlier(); return S.histFrom })).toBe(from - 23 * 3600000)
  await page.request.get('/build-control/earlier')
  await page.evaluate(() => { S.f.epic = ['absent-epic']; ren.relayout(); ctx.vp.scrollTop = 0; ren.update() })
  await expect.poll(() => page.evaluate(() => hist.H.more)).toBe(false)
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'idle')
})

// Future regression guard for store.js: a diff received before a page must win.
test('paging keeps newer rows already installed by a diff', async ({ page }) => {
  expect(await page.evaluate(async () => {
    const push = ctx.push
    ctx.push = async (event, params) => {
      const reply = await push(event, params), row = { ...reply.rows[0], title: 'newer than page' }
      hook.receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now, upsert: [row], remove: [], set: {} })
      window.duplicateId = row.id
      return reply
    }
    await hist.loadEarlier()
    return { title: ctx.D.byId[duplicateId].title, count: ctx.D.hist.filter(row => row.id === duplicateId).length }
  })).toEqual({ title: 'newer than page', count: 1 })
})

// Future performance guard; C12-T06 owns final budgets and the full 10k benchmark.
test('performance regression guard: dense scroll stays bounded', async ({ page }) => {
  await page.goto('/build-fixture/dense')
  await expect(page.locator('#bd-content')).toHaveCount(1)
  await page.evaluate(async () => {
    const { ctx, fx } = await import('/build-home/state.js')
    ctx.vp.scrollTop = 800
    window.__aiurBrowserHarnessOperations = { 'bd-scroll-step': () => { ctx.vp.scrollTop += 300; fx.update() } }
  })
  const measured = await measureBrowserWork(page, { operation: 'bd-scroll-step', targetSelector: '#bd-content', warmups: 1, repetitions: 3 })
  // Evaluate measured scroll samples; buffered navigation tasks precede the operation.
  assertMeasurementBudget({ samples: measured.samples }, { maxLongTaskMs: 50 })
  const counts = await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    return { rendered: ctx.R.size, fits: Math.ceil(ctx.vp.clientHeight / ctx.L.pitch) * Math.max(1, ctx.cols.length) }
  })
  expect(counts.rendered).toBeLessThanOrEqual(3 * counts.fits)
})

test('span URL pages before settling and paging state survives server patches', async ({ page }) => {
  await page.evaluate(() => {
    window.spanRequests = []
    const send = WebSocket.prototype.send
    WebSocket.prototype.send = function (body) {
      const payload = typeof body === 'string' ? JSON.parse(body).at(-1) : null
      if (payload?.event === 'load-earlier') spanRequests.push(payload.value)
      return send.call(this, body)
    }
  })
  await page.request.get('/build-fixture/dense')
  // Nested harness HTTP routes drop queries; mount with a real LiveView navigation.
  await page.evaluate(() => window.liveSocket.main.pushLinkPatch(new Event('click'), '/commands', null))
  await expect(page.locator('#build-root')).toHaveCount(0)
  await page.evaluate(() => window.liveSocket.main.pushLinkPatch(new Event('click'), '/build?span=3', null))
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/state.js')).S.span)).toBe(3)
  await expect.poll(() => page.evaluate(() => spanRequests.some(params => params.days === 2))).toBe(true)
  await expect.poll(() => page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    return ctx.D ? (await import('/build-home/layout.js')).histDays(ctx.D.hist).length : 0
  })).toBeGreaterThanOrEqual(3)
  await page.locator('#ax-drag').evaluate(el => el.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true })))
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'true')
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'idle')
})

test('replaced cards release noanim after two frames', async ({ page }) => {
  // Stub the browser primitive, not ctx.life.frame, so the real keyed scheduler stays under test.
  await page.evaluate(() => {
    const q = new Map(); let id = 0
    window.requestAnimationFrame = fn => { q.set(++id, fn); return id }
    window.cancelAnimationFrame = i => { q.delete(i) }
    window.__step = () => { const batch = [...q.values()]; q.clear(); batch.forEach(fn => fn(performance.now())) }
  })
  expect(await page.evaluate(() => {
    const [uid, el] = [...ctx.R][0], row = ctx.D.byId[el.dataset.id]
    for (let i = 0; i < 2; i++) {
      hook.receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1,
        now: ctx.snap.now, upsert: [{ ...row, title: 'replacement ' + i }], remove: [], set: {} })
      ren.flushLive()
    }
    window.replacedCard = ctx.R.get(uid)
    return replacedCard !== el && replacedCard.classList.contains('noanim')
  })).toBe(true)
  await page.evaluate(() => __step())
  expect(await page.evaluate(() => replacedCard.classList.contains('noanim'))).toBe(true)
  await page.evaluate(() => __step())
  expect(await page.evaluate(() => replacedCard.isConnected && !replacedCard.classList.contains('noanim'))).toBe(true)
})
