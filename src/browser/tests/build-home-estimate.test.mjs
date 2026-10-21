import assert from 'node:assert/strict'
import { test } from 'node:test'
import { readFileSync } from 'node:fs'
import { estHours, estLabel, etaLabel } from '../../priv/static/build-home/estimate.js'
const data = (hours, max = 4, queue = 'ok') => ({ plan: hours.map(est => ({ est })), now: [], capacity: { max }, sources: { queue: { state: queue }, estimates: { state: 'ok' } } })
test('J1 overrides apply without complexity or a default', () => {
  assert.equal(estHours({ est: null, override: { hours: 6 } }), 6)
  assert.equal(estLabel({ est: null, override: { hours: 6 } }), '≈6h')
})
test('J2 unknown estimates never fall back to a complexity tier or zero', () => {
  assert.equal(estHours({ est: null, cx: 5 }), null)
  assert.equal(estLabel({ est: null, override: null, cx: 5 }), '—')
})
test('J3 partially estimated queues show a lower bound and missing count', () => {
  assert.deepEqual(etaLabel(data([4, 7, null])), { text: '3 to go · ETA ≥3h', title: '1 planned without an estimate · at 4 agents' })
})
test('J4 unknown cap does not fall back to four agents', () => {
  assert.deepEqual(etaLabel(data([4, 4], null)), { text: '2 to go · ETA —', title: 'Agent cap unknown' })
})
test('J5 live cap changes the divisor and running rows only affect to-go', () => {
  const D = data([20, 20]); D.now = [{ est: 999 }]
  assert.deepEqual(etaLabel(D), { text: '3 to go · ETA 10h', title: 'at 4 agents' })
  D.capacity.max = 20
  assert.deepEqual(etaLabel(D), { text: '3 to go · ETA 2h', title: 'at 20 agents' })
})
test('J6 unavailable and disabled queues remain distinct', () => {
  assert.deepEqual(etaLabel(data([], 4, 'unavailable')), { text: '— to go · ETA —', title: 'Queue unavailable' })
  const D = data([], 4, 'disabled'); D.now = [{}, {}]
  assert.deepEqual(etaLabel(D), { text: '2 to go · ETA —', title: '' })
})
test('J7 a small positive estimate never rounds down to zero', () => {
  assert.equal(etaLabel(data([1], 20)).text, '1 to go · ETA 1h')
})
test('J8 hostile override reason never enters estimate labels', () => {
  const fixture = JSON.parse(readFileSync(new URL('../../test/fixtures/build_home/hostile.json', import.meta.url)))
  const row = fixture.snapshot.sections.plan.find(t => t.override)
  assert.match(row.override.reason, /onmouseover/)
  assert.equal(estLabel(row), '≈' + row.override.hours + 'h')
  const D = data([]); D.plan = [row]
  assert.equal(etaLabel(D).text, '1 to go · ETA ' + Math.max(1, Math.round(row.override.hours / 4)) + 'h')
})
test('J9 incomplete queues label counts and hours as lower bounds', () => {
  assert.deepEqual(etaLabel(data([4, 4], 4, 'incomplete')), { text: '≥2 to go · ETA ≥2h', title: 'at 4 agents' })
})
test('J10 unavailable estimates carry the source cause', () => {
  const D = data([null, null]); D.sources.estimates.state = 'unavailable'
  assert.deepEqual(etaLabel(D), { text: '2 to go · ETA —', title: 'Estimates unavailable' })
  D.sources.estimates.state = 'ok'
  assert.deepEqual(etaLabel(D), { text: '2 to go · ETA —', title: 'No planned ticket has an estimate' })
})
