import { fileURLToPath } from 'node:url'
import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })
test.beforeEach(async ({ page }) => {
  page.on('pageerror', error => errors.push(error.message))
  const errors = []; page.columnErrors = errors
  // Resolve owned modules from this checkout even when the fixture uses a shared compiled release.
  await page.route(/\/build-home\/(columns|state|render|hook|match)\.js$/, route => route.fulfill({ path: fileURLToPath(new URL('../../priv/static/build-home/' + new URL(route.request().url()).pathname.split('/').at(-1), import.meta.url)), contentType: 'text/javascript' }))
  await page.goto('/build-fixture/live')
  await expect(page.locator('.bd-lane')).not.toHaveCount(0)
  await page.evaluate(async () => {
    window.st = await import('/build-home/state.js'); window.cols = await import('/build-home/columns.js')
    window.ren = await import('/build-home/render.js'); window.ctx = st.ctx; window.S = st.S
    S.ready = false
  })
})
test.afterEach(async ({ page }) => { expect(page.columnErrors).toEqual([]) })
async function freeze(page) {
  const now = await page.evaluate(() => Date.now())
  await page.clock.install({ time: now }); await page.clock.pauseAt(now + 1000)
  await page.evaluate(async () => {
    // Isolate the timers under test from bootstrap resize/scroll callbacks.
    ctx.life.dispose(); ctx.life = (await import('/build-home/life.js')).createLife()
    ctx.laneEls.forEach(el => el.remove()); ctx.guideEls.forEach(el => el.remove())
    ctx.laneEls.clear(); ctx.guideEls.clear(); ctx.cols = []
  })
}

for (const name of ['counts-changed', 'counts-unknown']) test(`live ${name} refills existing lanes`, async ({ page }) => {
  const before = await page.evaluate(() => {
    ctx.vp.scrollTop = ctx.secs.plan.el.offsetTop; ren.update(true)
    cols.applyCols(cols.visibleCols(), true)
    window.infra = ctx.laneEls.get('infra')
    return ctx.D.counts.infra
  })
  expect(await page.request.get('/build-control/diff?name=' + name).then(r => r.status())).toBe(200)
  if (name === 'counts-changed') await expect(page.locator('.bd-lane[title="Infra"] em')).toHaveText(String(before + 3))
  else {
    await expect.poll(() => page.evaluate(() => ctx.D.counts)).toBeNull()
    for (const em of await page.locator('.bd-lane:not(.lock):not(.leave) em').all()) {
      await expect(em).toHaveText('—'); await expect(em).toHaveAttribute('title', 'Ticket count unavailable')
    }
  }
  expect(await page.evaluate(() => ctx.laneEls.get('infra') === infra)).toBe(true)
})

test('missing counts are unknown, zero stays zero, and labels are text', async ({ page }) => {
  const result = await page.evaluate(() => {
    ctx.D.counts = { bugs: 0 }; ctx.D.epics.infra.label = '<b>x</b>'
    cols.applyCols(['bugs', 'infra'], true)
    const bug = ctx.laneEls.get('bugs'), infra = ctx.laneEls.get('infra')
    return { zero: bug.querySelector('em').textContent, unknown: infra.querySelector('em').textContent,
      title: infra.querySelector('em').title, label: infra.querySelector('span').textContent, children: infra.querySelector('span').childElementCount }
  })
  expect(result).toEqual({ zero: '0', unknown: '—', title: 'Ticket count unavailable', label: '<b>x</b>', children: 0 })
})

for (const general of [true, false]) test(`fallback uses payload general epics: ${general}`, async ({ page }) => {
  const result = await page.evaluate(general => {
    ctx.D.epics = { bug: { label: 'Bug', icon: 'bug', hue: 38, general }, ops: { label: 'Ops', icon: 'server', hue: 200, general }, unsorted: { label: 'Unsorted', icon: 'unsorted', hue: 0, unsorted: true } }
    ctx.D.order = ['bug', 'ops', 'unsorted']; ctx.cols = []
    cols.applyCols([], true)
    return ctx.cols
  }, general)
  expect(result).toEqual(general ? ['bug', 'ops'] : ['unsorted'])
})

for (const section of ['plan', 'hist']) test(`live ${section} epic invalidates visibility cache`, async ({ page }) => {
  await page.evaluate(section => {
    ctx.vp.scrollTop = section === 'plan' ? ctx.secs.plan.el.offsetTop : ctx.secs.hist.el.offsetTop + ctx.L.secs.hist.h - 500
    cols.applyCols(cols.visibleCols(), true)
  }, section)
  expect(await page.evaluate(() => ctx.cols.includes('design'))).toBe(false)
  expect(await page.request.get(`/build-control/diff?name=${section}-new-epic`).then(r => r.status())).toBe(200)
  await expect.poll(() => page.evaluate(() => ctx.cols.includes('design'))).toBe(true)
  expect(await page.evaluate(() => ctx.cols.join('|') === ctx.D.order.filter(k => ctx.cols.includes(k)).join('|'))).toBe(true)
})

test('whole days, forward union, feature locks and compact dependencies', async ({ page }) => {
  const result = await page.evaluate(() => {
    ctx.life.dispose()
    const end = new Date(2026, 8, 2, 12).getTime()
    const ticket = (epic, extra = {}) => ({ epic, end, also: [], deps: [], ...extra })
    const a = ticket('bugs', { feature: 'F', deps: ['dep'] }), b = ticket(null, { also: ['F'] }), dep = ticket('docs')
    ctx.D = { order: ['bugs', 'infra', 'docs', 'unsorted'], features: { F: { epics: ['infra'] } }, all: [a, b, dep], byId: { dep }, plan: [ticket('infra')], nq: [ticket('docs')] }
    ctx.L = { secs: { hist: { h: 10000, items: [{ t: a, key: 'bugs', y: 100, h: 20 }, { t: b, key: 'unsorted', y: 2000, h: 20 }] } } }
    ctx.vp = { scrollTop: 0, clientHeight: 1000 }; ctx.secs = { hist: { el: { offsetTop: 0 } } }
    const day = cols.visibleCols(); ctx.vp.scrollTop = 9500; const forward = cols.visibleCols()
    S.feature = 'F'; const focus = cols.visibleCols(); ctx.vp.scrollTop = 0; const locked = cols.visibleCols()
    S.fmode = 'compact'; const compact = cols.visibleCols()
    S.feature = null; S.f.epic = ['nope']; ctx.L.secs.hist.items = []; ctx.D._fwd = null; const unknown = cols.visibleCols()
    S.f.epic = ['docs', 'infra']; const fallback = cols.visibleCols()
    S.flow = true; S.K = 3; const flow = cols.visibleCols()
    return { day, forward, focus, locked, compact, unknown, fallback, flow }
  })
  expect(result).toEqual({ day: ['bugs', 'unsorted'], forward: ['infra', 'docs'], focus: ['bugs', 'infra', 'unsorted'], locked: ['bugs', 'infra', 'unsorted'], compact: ['bugs', 'infra', 'docs', 'unsorted'], unknown: [], fallback: ['docs'], flow: ['s0', 's1', 's2'] })
})

test('feature lanes lock and unsorted stays last; flow clears headers', async ({ page }) => {
  const result = await page.evaluate(() => {
    S.feature = Object.keys(ctx.D.features)[0]
    cols.applyCols(cols.visibleCols(), true)
    const locks = ctx.D.features[S.feature].epics.map(k => ctx.laneEls.get(k).classList.contains('lock') && !!ctx.laneEls.get(k).querySelector('em svg'))
    S.feature = null; cols.applyCols(['bugs', 'unsorted'], true)
    const unsorted = ctx.laneEls.get('unsorted')
    const cls = unsorted.className, label = unsorted.querySelector('span').textContent
    S.flow = true; S.K = 2; cols.applyCols(cols.visibleCols(), true)
    return { locks, cls, label, lanes: ctx.laneEls.size, guides: ctx.guideEls.size, caption: ctx.lanesEl.querySelector('.bd-lane-g').textContent, hidden: ctx.svg.classList.contains('hide'), band: ctx.bandMap.b0, group: ctx.colMap.g }
  })
  expect(result.locks.length).toBeGreaterThan(0); expect(result.locks.every(Boolean)).toBe(true)
  expect(result.cls).toContain('unsorted'); expect(result.label).toBe('Unsorted')
  expect(result.lanes).toBe(0); expect(result.guides).toBe(0); expect(result.caption).toBe('Colour = epic'); expect(result.hidden).toBe(true)
  expect(result.band.w).toBe(380); expect(result.group.x).toBe(84)
})

test('leave callback cannot delete a replacement element', async ({ page }) => {
  await freeze(page)
  await page.evaluate(() => {
    cols.applyCols(['bugs', 'infra'], true); cols.applyCols(['bugs'], true)
    ctx.life.later('replace', 100, () => {
      ctx.laneEls.clear(); ctx.guideEls.clear(); ctx.lanesEl.querySelectorAll('.bd-lane').forEach(el => el.remove()); ctx.guidesEl.replaceChildren(); ctx.cols = []
      cols.applyCols(['bugs', 'infra'], true)
    })
  })
  await page.clock.runFor(400)
  const result = await page.evaluate(() => {
    cols.applyCols(['bugs', 'infra'], true)
    return { lanes: ctx.lanesEl.querySelectorAll('.bd-lane').length, guides: ctx.guidesEl.children.length, tracked: ctx.laneEls.get('infra').isConnected }
  })
  expect(result).toEqual({ lanes: 2, guides: 2, tracked: true })
})

test('guard: debounce 220ms, independent leave timers 300ms, and returning keys', async ({ page }) => {
  await freeze(page)
  await page.evaluate(() => {
    S.flow = true; S.K = 2; ctx.cols = ['bugs']
    window.updates = 0; st.fx.update = () => updates++
    cols.scheduleCols();
  })
  await page.clock.runFor(200); expect(await page.evaluate(() => updates)).toBe(0)
  await page.clock.runFor(20); expect(await page.evaluate(() => updates)).toBe(1)
  await page.evaluate(() => { S.flow = false; cols.applyCols(['bugs', 'infra'], true); cols.applyCols(['bugs'], true) })
  await page.clock.runFor(100)
  await page.evaluate(() => { cols.applyCols(['bugs', 'infra'], true); cols.applyCols(['bugs'], true) })
  await page.clock.runFor(199); await expect(page.locator('.bd-lane.leave')).toHaveCount(1)
  await page.clock.runFor(1); await expect(page.locator('.bd-lane.leave')).toHaveCount(0)
})

test('destroy cancels debounce and leave DOM writes', async ({ page }) => {
  await freeze(page)
  await page.evaluate(() => {
    cols.applyCols(['bugs', 'infra'], true); cols.applyCols(['bugs'], true)
    S.feature = null; S.flow = true; S.K = 3; cols.scheduleCols()
    window.before = JSON.stringify(ctx.cols); window.writes = []
    new MutationObserver(records => writes.push(...records.map(r => r.type))).observe(ctx.lanesEl, { subtree: true, attributes: true, childList: true })
    ctx.life.dispose()
  })
  await page.clock.runFor(800)
  expect(await page.evaluate(() => ({ same: JSON.stringify(ctx.cols) === before, writes }))).toEqual({ same: true, writes: [] })
})


test('rendered cards keep the current layout back-reference through a live pass', async ({ page }) => {
  const result = await page.evaluate(() => {
    const before = new Map(ctx.R)
    ren.relayout({ live: true })
    return [...ctx.R].map(([uid, el]) => ({
      same: before.get(uid) === el,
      current: ctx.L.secs[uid.split(':')[0]].items.includes(el._it),
    }))
  })
  expect(result.length).toBeGreaterThan(0)
  expect(result.every(row => row.same && row.current)).toBe(true)
})

test('unknown URL epics cannot become lanes', async ({ page }) => {
  await page.goto('/build?epic=nope')
  await expect(page.locator('.bd-lane')).toHaveCount(4)
  expect(await page.locator('.bd-lane').evaluateAll(els => els.map(el => el.title))).toEqual(['Bugs', 'Design', 'Infra', 'Docs'])
})


test('shared matching API preserves epic and feature filter semantics', async ({ page }) => {
  const result = await page.evaluate(async () => {
    const { colKey, match, tstate, astate } = await import('/build-home/match.js')
    const row = { sec: 'plan', epic: null, type: ['bug', 'docs'], feature: 'khala', cue: { held: false, waitAny: false, failed: false, blockedChain: false } }
    S.f.feature = ['khala']; S.f.epic = ['unsorted']
    const yes = match(row); S.f.feature = ['other']; const no = match(row)
    return { key: colKey(row), yes, no, ticket: tstate(row), agent: astate(row) }
  })
  expect(result).toEqual({ key: 'unsorted', yes: true, no: false, ticket: 'queued', agent: 'none' })
})
