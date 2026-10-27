import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { createReport, verdict } from './build-home-perf-report.mjs'

const fixed = () => new Date('2026-10-22T12:00:00Z')

// A missing measurement reported as 0 or pass would hide exactly the regression the budget exists for.
test('R1 unavailable is never zero', () => {
  const report = createReport({ commit: 'abc123', now: fixed })
  report.record('C7', { unavailable: 'no CDP' }, { budget: { max: 40, unit: 'MiB' } })
  const [row] = report.rows
  assert.equal(row.value, null)
  assert.equal(row.verdict, 'unmeasured')
  assert.match(report.markdown(), /\| C7 \| D \| unavailable \(no CDP\) \| MiB \| 40 \| unmeasured \|/)
  assert.doesNotMatch(report.markdown(), /\| 0 \|/)
})

test('R2 unavailable is never pass, even though null <= budget is true in JS', () => {
  assert.equal(verdict(null, { max: 10 }), 'unmeasured')
  assert.equal(verdict(undefined, { max: 10 }), 'unmeasured')
  assert.equal(verdict(Number.NaN, { max: 10 }), 'unmeasured')
  assert.equal(verdict(10, { max: 10 }), 'pass')
  assert.equal(verdict(10.5, { max: 10 }), 'fail')
  assert.equal(verdict(3, null), 'recorded')
})

test('R3 rows carry age and commit in both outputs', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'bd-perf-report-'))
  try {
    const report = createReport({ commit: 'abc123', now: fixed })
    report.record('C1', { value: 812.4, unit: 'ms' }, { context: 'P', budget: { max: 3500 } })
    const { json, md } = await report.write(dir)
    const [row] = JSON.parse(await readFile(json, 'utf8'))
    assert.deepEqual({ observed_at: row.observed_at, commit: row.commit, verdict: row.verdict }, { observed_at: '2026-10-22T12:00:00.000Z', commit: 'abc123', verdict: 'pass' })
    assert.match(await readFile(md, 'utf8'), /\| C1 \| P \| 812\.4 \| ms \| 3500 \| pass \| 2026-10-22T12:00:00\.000Z \| abc123 \|/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})
