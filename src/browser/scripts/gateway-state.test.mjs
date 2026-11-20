import test from 'node:test'
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const { connectivity, deliveryReport } = createRequire(import.meta.url)('../../priv/static/gateway-state.js')
const gateways = [{ name: 'pc', label: 'PC', url: 'https://pc.test' }, { name: 'nook', label: 'Nook', url: 'https://nook.test' }]
const ok = { status: 200, globallyPaused: true }
const line = (report, name) => report.lines.find(l => l.name === name).text

test('pause-all with Nook offline and the store up: Nook will pause on reconnect', () => {
  const r = deliveryReport({ intentWritten: true, gateways, results: { pc: ok, nook: { noAnswer: true } } })
  assert.equal(r.header, 'Pause all — 2 gateways')
  assert.equal(line(r, 'pc'), 'paused ✓')
  assert.match(line(r, 'nook'), /^will pause on reconnect/)
})

test('pause-all with the store down never promises a later pause', () => {
  const r = deliveryReport({ intentWritten: false, gateways, results: { pc: ok, nook: { noAnswer: true } } })
  assert.equal(line(r, 'nook'), 'not paused: unreachable and no shared store')
})

test('other delivery outcomes', () => {
  const r = deliveryReport({
    intentWritten: true,
    gateways: [...gateways, { name: 'lab', label: 'Lab' }, { name: 'x', url: 'u' }, { name: 'y', url: 'u' }],
    results: { pc: { status: 200, globallyPaused: false }, nook: { status: 401 }, x: { status: 503 }, y: { status: 403 } }
  })
  assert.equal(line(r, 'pc'), 'error: pause not applied')
  assert.equal(line(r, 'nook'), 'not paused: signed out')
  assert.equal(r.lines.find(l => l.name === 'nook').signIn, true)
  assert.match(line(r, 'lab'), /^not paused: off tailnet/)
  assert.equal(line(r, 'x'), 'error: 503')
})

const now = 1_000_000_000
const cached = { observed_at_ms: now - 300_000, summary: { workload: 'active' } }

test('online idle gateway: connectivity and workload are separate fields', () => {
  const c = connectivity({ status: 200, idMatches: true, summary: { workload: 'idle' }, now })
  assert.deepEqual([c.state, c.text, c.workload], ['online', 'online', 'idle'])
})

test('no answer and no cache is unknown with no workload', () => {
  const c = connectivity({ threw: true, now })
  assert.deepEqual([c.state, c.text, c.workload], ['unknown', 'unknown · never seen on this device', null])
})

test('no answer with a 5 minute old cache is unreachable, last known workload', () => {
  const c = connectivity({ threw: true, cached, now })
  assert.equal(c.text, 'unreachable · last seen 5m ago')
  assert.equal(c.workload, 'last known active (5m ago)')
})

test('offline flag from the server reads offline; id mismatch is an error', () => {
  assert.equal(connectivity({ timedOut: true, offlineFlag: true, cached, now }).text, 'offline · last seen 5m ago')
  const c = connectivity({ status: 200, idMatches: false, summary: { workload: 'idle' }, now })
  assert.deepEqual([c.state, c.reason], ['error', 'gateway id mismatch'])
})
