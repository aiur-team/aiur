import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import test from 'node:test'

const m = createRequire(import.meta.url)('../../priv/static/projects-home-hook.js')
const sum = (running, max) => ({ observed_at: 'x', age_ms: 0, capacity: { running, max }, projects: [] })
const now = 1_000_000_000
const cached = { observed_at_ms: now - 300_000, summary: sum(2, 4) }
const store = (v) => ({ getItem: () => v, setItem() {}, removeItem() { this.removed = true } })

test('timeouts and throws collapse to unknown without a cause', () => {
  assert.deepEqual(m.classifyResult({ timedOut: true }), { connectivity: 'unknown', reason: null })
  assert.deepEqual(m.classifyResult({ threw: true }), { connectivity: 'unknown', reason: null })
})

test('statuses and bodies classify', () => {
  assert.deepEqual(m.classifyResult({ status: 403 }), { connectivity: 'error', reason: 'signed out' })
  assert.deepEqual(m.classifyResult({ status: 502 }), { connectivity: 'error', reason: 'server 502' })
  assert.deepEqual(m.classifyResult({ status: 200, expectedGatewayId: 'A', body: { ...sum(1, 2), gateway_id: 'B' } }), { connectivity: 'error', reason: 'gateway id mismatch' })
  assert.deepEqual(m.classifyResult({ status: 200, body: { capacity: { running: 1, max: 2 } } }), { connectivity: 'error', reason: 'unreadable summary' })
  assert.deepEqual(m.classifyResult({ status: 200, expectedGatewayId: 'A', body: { ...sum(1, 2), gateway_id: 'A' } }), { connectivity: 'online', reason: null })
})

test('unknown shows last-seen age and never becomes zero or idle', () => {
  const d = m.displayState('unknown', null, cached, now)
  assert.equal(d.connectivityText, 'unreachable · last seen 5m ago')
  assert.match(d.workloadText, /^last known/)
  assert.doesNotMatch(JSON.stringify(d), /\b0 agents\b|idle/)
  const none = m.displayState('unknown', null, null, now)
  assert.equal(none.connectivityText, 'unknown · never seen on this device')
  assert.equal(none.workloadText, 'workload unknown')
})

test('totals sum online gateways only and mark the unknown part', () => {
  const online = { connectivity: 'online', summary: sum(7, 12) }
  assert.equal(m.totals([online, { connectivity: 'unknown', summary: null }]).text, 'Running 7 of 12+ · 1 gateway unknown')
  assert.equal(m.totals([online, { connectivity: 'online', summary: sum(2, 4) }]).text, 'Running 9 of 16')
})

test('cache expiry and poisoned entries read as never seen and are removed', () => {
  const old = store(JSON.stringify({ observed_at_ms: now - 8 * 86400_000, summary: sum(1, 1) }))
  assert.equal(m.readCache(old, 'N', now), null)
  assert.ok(old.removed)
  assert.equal(m.readCache(store('{'), 'N', now), null)
  assert.equal(m.readCache({ getItem() { throw new Error('private mode') }, removeItem() { throw new Error('x') } }, 'N', now), null)
  assert.deepEqual(m.readCache(store(JSON.stringify(cached)), 'N', now), cached)
})
