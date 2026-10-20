import assert from 'node:assert/strict'
import { test } from 'node:test'
import { readFileSync } from 'node:fs'
import { guardTarget, settleTarget, bandClock, bandCounts, bandEta, bandEmptyText } from '../../priv/static/build-home/band.js'
import { bandLayout } from '../../priv/static/build-home/band-layout.js'
const live = JSON.parse(readFileSync(new URL('../../test/fixtures/build_home/live.json', import.meta.url)))

test('B1 guard thresholds preserve strict boundaries and 72px give-up', () => {
  const run = (dir, y, botY = 500) => guardTarget({ dir, y, botY, topY: 46 })
  assert.deepEqual([83, 82, 499, 500].map(y => run(-1, y)), ['bottom', null, 'bottom', null])
  assert.deepEqual([463, 464, 47, 46].map(y => run(1, y)), ['top', null, 'top', null])
  assert.equal(run(0, 200), null)
  assert.equal(run(-1, 100, 118), null); assert.equal(run(-1, 100, 119), 'bottom')
})
test('B2 settling keeps 2px margins and sends midpoint ties to bottom', () => {
  assert.deepEqual([48, 49, 498, 273].map(y => settleTarget({ y, topY: 46, botY: 500 })), [null, 'top', null, 'bottom'])
  assert.equal(settleTarget({ y: 46, topY: 46, botY: 46 }), null)
})
test('B3 clock unknown branches never invent the live time', () => {
  const base = { now: live.now, stamp: live.now - 60000, daemon: { state: 'live' }, agents: { state: 'ok' }, socketDown: false }
  const text = options => bandClock({ ...base, ...options }).text
  assert.equal(text({}), '14:20'); assert.equal(text({ now: null }), '—')
  assert.equal(text({ daemon: { state: 'offline', heartbeat_at: live.now - 360000 } }), 'cached 14:14')
  assert.equal(text({ daemon: { state: 'offline', heartbeat_at: null } }), 'cached —')
  assert.equal(text({ daemon: { state: 'unknown' } }), '—')
  assert.equal(text({ agents: { state: 'stale', observed_at: live.now - 600000 } }), 'cached 14:10')
  assert.equal(text({ socketDown: true }), 'cached 14:19'); assert.equal(text({ socketDown: true, stamp: null }), 'cached —')
  assert.equal(text({ now: null, socketDown: true }), '—')
})
test('B4 missing agents and states stay outside known counts', () => {
  const rows = structuredClone(live.sections.now); rows.at(-1).agent.state = null; rows.push({ agent: null })
  assert.deepEqual(bandCounts(rows), { nr: 2, nt: 0, ns: 3, ni: 2, nu: 2 })
})
test('retrying agents get a timeline count and are not state unknown', () => {
  const retrying = { agent: { state: 'retrying' } }
  assert.deepEqual(bandCounts([retrying]), { nr: 0, nt: 1, ns: 0, ni: 0, nu: 0 })
})
test('B5 ETA stays unknown rather than dividing by demo capacity', () => {
  const D = { now: live.sections.now, plan: live.sections.plan, sources: live.sources }
  assert.equal(bandEta(D).text, `${D.now.length + D.plan.length} to go · ETA —`)
  assert.equal(bandEta({ ...D, sources: { queue: { state: 'unavailable' } } }).text, '— to go · ETA —')
})
test('B6 unavailable is distinct from an empty fleet', () => {
  const D = { now: [], sources: { agents: { state: 'unavailable' } } }
  assert.equal(bandEmptyText(D), 'Agent states unavailable')
  assert.equal(bandEmptyText({ ...D, sources: { agents: { state: 'ok' } } }), 'No agents are working right now.')
})
test('geometry stacks all agents despite epic filters and never caps tall bands', () => {
  const D = { now: live.sections.now, order: live.order }, dims = { vpW: 1200, gut: 84 }
  const sizes = { ch: 122.2, gap: 14, base: 'full', CH: { full: 122.2, line: 32.5 } }
  const S = { view: 'graph', span: 1, f: { epic: ['missing'] } }
  const band = bandLayout(D, S, dims, sizes)
  assert.equal(band.items.length, 8); assert.equal(band.BK, 4); assert.equal(band.h, 312.4)
  assert.equal(bandLayout(D, { ...S, liveMin: true }, dims, sizes).h, 38)
  assert.equal(bandLayout({ ...D, now: [] }, S, dims, sizes).h, 86)
  assert.equal(bandLayout({ ...D, now: Array(24).fill(D.now[0]) }, S, dims, sizes).items.length, 24)
})

test('scrollVP consumes lifecycle frame timestamps, eases, cancels and disposes', async t => {
  const { ctx } = await import('../../priv/static/build-home/state.js')
  const { createLife } = await import('../../priv/static/build-home/life.js')
  const { scrollVP } = await import('../../priv/static/build-home/band-scroll.js')
  const queued = new Map(); let next = 0
  t.mock.method(performance, 'now', () => 0)
  const names = ['window', 'matchMedia', 'requestAnimationFrame', 'cancelAnimationFrame']
  const previous = names.map(k => Object.getOwnPropertyDescriptor(globalThis, k))
  Object.assign(globalThis, { window: { matchMedia: true }, matchMedia: () => ({ matches: false }),
    requestAnimationFrame: fn => { queued.set(++next, fn); return next }, cancelAnimationFrame: id => queued.delete(id) })
  try {
    ctx.life = createLife(); ctx.vp = { scrollTop: 300, scrollHeight: 5000, clientHeight: 200 }
    const frame = now => { const callbacks = [...queued.values()]; queued.clear(); callbacks.forEach(fn => fn(now)) }
    scrollVP(1300, true); frame(210)
    assert.equal(ctx.vp.scrollTop, 1175)
    scrollVP(100, false); frame(420); assert.equal(ctx.vp.scrollTop, 100)
    scrollVP(-100, false); assert.equal(ctx.vp.scrollTop, 0)
    scrollVP(9000, false); assert.equal(ctx.vp.scrollTop, 4800)
    scrollVP(0, true); ctx.life.dispose(); assert.equal(queued.size, 0)
  } finally {
    names.forEach((name, i) => previous[i] ? Object.defineProperty(globalThis, name, previous[i]) : delete globalThis[name])
  }
})
