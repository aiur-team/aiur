import { test, expect } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'
test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles' })
test.beforeEach(async ({ page }) => {
  await openFixture(page)
  await page.evaluate(async () => {
    window.layout = await import('/build-home/layout.js')
    window.sources = Object.fromEntries(['history', 'queue', 'index'].map(k => [k, { state: 'ok' }]))
    window.state = { view: 'graph', span: 1, histFrom: 0, feature: null, fmode: 'focus', f: { epic: [] }, flow: false, K: 2 }
    window.dims = { vpW: 990, vpH: 386, gut: 84 }
    window.data = (n = 0) => ({ hist: Array.from({ length: n }, (_, i) => ({ id: `h${i}`, epic: 'a', end: Date.parse('2026-11-01T12:00:00-08:00') + i })), now: [], plan: [], nq: [] })
    window.run = (D, st = {}, src = sources, dm = dims, ext) => layout.computeLayout(D, { ...state, ...st }, dm, src, ext)
  })
})
test('flow boundary', async ({ page }) => {
  expect(await page.evaluate(() => { const D = data(); D.now = ['a', 'b', 'c', 'd', 'e'].map(epic => ({ epic })); return [356, 370].map(vpW => layout.measureFlow(D, { vpW, gut: 46 })) })).toEqual([{ flow: true, K: 2 }, { flow: false, K: 2 }])
})
test('lane count follows the packed day columns (#4769)', async ({ page }) => {
  expect(await page.evaluate(() => {
    const day = Date.parse('2026-11-01T12:00:00-08:00'), D = data()
    D.hist = [...'abcdefghijkl'].map((epic, i) => ({ id: 'h' + i, epic, end: day + i })).concat(['a', 'm', 'n'].map((epic, i) => ({ id: 'g' + i, epic, end: day + 864e5 + i })))
    D.plan = [{ epic: 'x' }, { epic: 'a' }]
    const L = run(D), fwd = layout.fwdLanes(D, state), all = L.secs.hist.h + 1000
    return [layout.laneMax(L, new Set(), 1), layout.laneMax(L, new Set(), all), layout.laneMax(L, fwd, all), [...layout.fwdLanes(D, { f: { epic: ['x'] } })],
      layout.crowded({ vpW: 1440, gut: 84 }, 18), layout.crowded({ vpW: 1440, gut: 84 }, 17)]
  })).toEqual([12, 14, 15, ['x'], true, false])
})
test('zero viewport', async ({ page }) => {
  expect(await page.evaluate(() => { const L = run(data(6), { span: 2 }, sources, { vpW: 0, vpH: 0, gut: 46 }); return [L.det, L.ch, L.gap, Object.values(L.secs).every(s => Number.isFinite(s.h) && s.items.every(t => Number.isFinite(t.y) && Number.isFinite(t.h)))] })).toEqual(['line', 41, 9, true])
})
test('tier boundaries', async ({ page }) => {
  expect(await page.evaluate(() => [12, 10, 7, 2].map(n => { const L = run(data(n), { span: 2 }); return [L.det, L.ch, L.gap, L.pitch] }))).toEqual([['bar', 20.5, 4.5, 25], ['mini', 24.6, 5.3999999999999995, 30], ['line', 300 / 7 - 300 / 7 * 0.18, 300 / 7 * 0.18, 300 / 7], ['full', 9.4 * 13, 14, 9.4 * 13 + 14]])
})
test('unavailable is not empty', async ({ page }) => {
  const actual = await page.evaluate(() => [undefined, 'nonsense', 'unavailable', 'disabled'].map(st => {
    const src = st === undefined ? {} : Object.fromEntries(['history', 'queue', 'index'].map(k => [k, { state: st }])); return Object.values(run(data(), {}, src).secs).map(s => ({ label: s.marks[0].label, state: s.marks[0].state, source: s.marks[0].source, h: s.h, text: layout.makeMark(s.marks[0]).textContent }))
  }))
  for (const [i, sections] of actual.entries()) {
    expect(sections.map(s => s.label)).toEqual(i === 3 ? ['History disabled', 'Build queue disabled', 'Open-ticket index disabled'] : ['History unavailable', 'Queue unavailable', 'Open tickets unavailable'])
    expect(sections.map(s => s.source)).toEqual(['history', 'queue', 'index']); for (const s of sections) { expect(s.h).toBe(140); expect(s.state).toBe(i === 3 ? 'disabled' : 'unavailable'); expect(s.text).toContain(s.label) }
  }
})
test('unknown count is not zero', async ({ page }) => {
  expect(await page.evaluate(() => run(data(), {}, { ...sources, index: { state: 'unavailable' } }).secs.plan.marks[0].sub)).toBe('The build queue is empty. The open-ticket index is unavailable, so the number not queued is unknown.')
})
test('stale empty keeps age input', async ({ page }) => {
  expect(await page.evaluate(() => run(data(), {}, { ...sources, queue: { state: 'stale', observed_at: 123456 } }).secs.plan.marks[0])).toEqual({ kind: 'empty', y: 36, h: 96, label: 'Nothing planned', sub: 'The build queue is empty. 0 open tickets are not queued — promote some to keep agents busy. No successful read recorded; this may be out of date.', source: 'queue', state: 'stale', observed_at: 123456 })
})
test('unknown wave', async ({ page }) => {
  expect(await page.evaluate(() => { const D = data(); D.plan = [null, 2, 0, 1, 1.5].map((wave, id) => ({ id, epic: 'a', wave })); return run(D).secs.plan.labels.map(lb => [lb.day, lb.t, lb.line]) })).toEqual([['W1', '1 · ready', false], ['W2', '1', true], ['W?', '3 · wave unknown', true]])
})
test('history row without end', async ({ page }) => {
  expect(await page.evaluate(() => {
    const D = data(1); D.hist.push({ id: 'bad', end: null }); const warnings = [], warn = console.warn; console.warn = (...args) => warnings.push(args)
    try { const L = run(D); run(D); return { unplaced: L.secs.hist.unplaced, ids: L.secs.hist.items.map(i => i.t.id), days: layout.histDays(D.hist), warnings } } finally { console.warn = warn }
  })).toEqual({ unplaced: ['bad'], ids: ['h0'], days: [Date.parse('2026-11-01T00:00:00-07:00')], warnings: [['History rows without finite end:', ['bad']]] })
})
for (const zone of ['America/Los_Angeles', 'UTC']) test(`day labels follow the browser zone: ${zone}`, async ({ browser }) => {
  const context = await browser.newContext({ timezoneId: zone, httpCredentials: dashboardCredentials })
  try {
    const page = await context.newPage(); await openFixture(page)
    const actual = await page.evaluate(async () => {
      const { computeLayout } = await import('/build-home/layout.js')
      const hist = ['2026-10-31T23:30:00-07:00', '2026-11-01T00:30:00-07:00', '2026-11-01T01:30:00-07:00', '2026-11-01T01:30:00-08:00', '2026-11-01T23:30:00-08:00'].map((end, id) => ({ id, epic: 'a', end: Date.parse(end) }))
      return computeLayout({ hist, now: [], plan: [], nq: [] }, { span: 1, f: { epic: [] }, flow: false, K: 2 }, { vpH: 700 }, {}).secs.hist.labels
    })
    const pitch = 9.4 * 13 + 14
    expect(actual).toEqual(zone === 'UTC' ? [{ y: 40, day: 'Nov 1', t: 'Sun', line: false }, { y: 40 + 4 * pitch, day: 'Nov 2', t: 'Mon', line: true }] : [{ y: 40, day: 'Oct 31', t: 'Sat', line: false }, { y: 40 + pitch, day: 'Nov 1', t: 'Sun', line: true }])
  } finally { await context.close() }
})
test('factories escape', async ({ page }) => {
  expect(await page.evaluate(() => {
    const text = '<img src=x onerror="window.__xss=1">\'&', els = [layout.makeMark({ kind: 'gap', label: text }), layout.makeMark({ kind: 'empty', label: text, sub: text }), layout.makeLabel({ y: 1, t: text })[0]]
    document.body.append(...els); return { texts: els.map(el => el.textContent), imgs: els.map(el => el.querySelectorAll('img').length), xss: window.__xss ?? null }
  })).toEqual({ texts: ['<img src=x onerror="window.__xss=1">\'&', '<img src=x onerror="window.__xss=1">\'&<img src=x onerror="window.__xss=1">\'&', '<img src=x onerror="window.__xss=1">\'&'], imgs: [0, 0, 0], xss: null })
})
test('histDays follows new arrays', async ({ page }) => {
  expect(await page.evaluate(() => { const D = data(6), first = layout.histDays(D.hist), next = [...D.hist, { id: 'new', epic: 'a', end: Date.parse('2026-11-02T12:00:00-08:00') }]; return { same: first === layout.histDays(D.hist), days: layout.histDays(next), ch: run({ ...D, hist: next }, { span: 2 }).ch } })).toEqual({ same: true, days: [Date.parse('2026-11-01T00:00:00-07:00'), Date.parse('2026-11-02T00:00:00-08:00')], ch: 300 / 7 - 300 / 7 * 0.18 })
})
test('gantt slot guard', async ({ page }) => {
  expect(await page.evaluate(() => { try { run(data(), { view: 'gantt' }); return null } catch (e) { return e.message } })).toBe('gantt layout not installed')
})
test('flow slots and compact gaps', async ({ page }) => {
  expect(await page.evaluate(() => {
    const D = data(3), flow = run(D, { flow: true, K: 2 }).secs.hist.items.map(i => [i.key, i.y])
    D.plan = [{ id: 'p', wave: 1 }]
    const entries = () => [{ gap: { n: 3 } }]
    const L = run(D, {}, sources, dims, { compact: true, entries, gapLabel: g => `${g.n} hidden` })
    return { flow, hist: L.secs.hist.marks, plan: L.secs.plan.marks }
  })).toEqual({ flow: [['s0', 40], ['s1', 40], ['s0', 40 + 9.4 * 13 + 14]], hist: [{ kind: 'gap', y: 40, h: 26, label: '3 hidden' }], plan: [{ kind: 'gap', y: 40, h: 26, label: 'W1 · 3 hidden' }] })
})
test('gantt slots preserve section output and advance waves', async ({ page }) => {
  expect(await page.evaluate(() => {
    const D = data(1); D.plan = [{ id: 'p1', wave: 1 }, { id: 'p2', wave: 2 }]
    const calls = []
    const L = run(D, { view: 'gantt' }, sources, dims, { gantt: {
      hist(ents, ctx) { ctx.hs.h = 99; calls.push([ents[0].t.id, ctx.span, ctx.pph]) },
      plan(ents, ctx) { calls.push([ents[0].t.id, ctx.y, ctx.cum, ctx.unknown]); return { items: [], end: ctx.y + 36, label: { y: ctx.y + 30, t: 'estimate' }, unknown: true } }
    } })
    return { calls, histH: L.secs.hist.h, planH: L.secs.plan.h, labels: L.secs.plan.labels.filter(lb => !lb.wave) }
  })).toEqual({ calls: [['h0', 1, 18], ['p1', 48.4, 0, false], ['p2', 99.80000000000001, (48.4 + 36 - 48.4) / 18, true]], histH: 99, planH: 156.8, labels: [{ y: 78.4, t: 'estimate' }, { y: 129.8, t: 'estimate' }] })
})
test('shared date helpers use local dates and duration formatting', async ({ page }) => {
  expect(await page.evaluate(async () => {
    const u = await import('/build-home/util.js'), a = Date.parse('2026-10-31T23:30:00-07:00'), b = Date.parse('2026-11-01T01:30:00-08:00')
    return [u.MON.length, u.WD.length, u.p2(3), u.fmtD(a), u.fmtWD(a), u.fmtT(a), u.dayKey(a), u.fmtH(0), u.fmtH(0.25), u.fmtH(1.3), u.fmtH(11.2), u.fmtRange(null, b), u.fmtRange(a, a), u.fmtRange(a, b), u.fmtRange(b, b + 86400000)]
  })).toEqual([12, 7, '03', 'Oct 31', 'Sat Oct 31', '23:30', 2026 * 400 + 9 * 32 + 31, '5m', '15m', '1.5h', '11h', '', 'Oct 31', 'Oct 31–Nov 1', 'Nov 1–2'])
})
