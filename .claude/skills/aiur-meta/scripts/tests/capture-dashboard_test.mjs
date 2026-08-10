import assert from 'node:assert/strict'
import test from 'node:test'
import { analyzeDashboardSnapshot, extractCapacityReadings, renderVerdict } from '../capture-dashboard.mjs'

const healthySnapshot = {
  title: 'Aiur',
  chars: 1400,
  liveViewConnected: true,
  tables: [
    {
      label: 'Build Orders',
      hasBody: true,
      headers: ['Title', 'Progress', 'Tickets', 'Epics', 'Waves'],
      rows: [
        ['Meta', '40%', '12', '3', '4'],
        ['Dashboard', '70%', '8', '2', '3'],
        ['Runner', '20%', '15', '4', '5']
      ]
    }
  ],
  staleBanners: [],
  emptyStates: [],
  capacityReadings: [{ label: 'peak concurrency', value: 11, cap: 14 }],
  hasNAInMetric: false,
  status: 200,
  navigationError: null
}

test('flags the all-em-dash metric-column signature without flagging a healthy dashboard', () => {
  const broken = structuredClone(healthySnapshot)
  broken.tables[0].rows = broken.tables[0].rows.map((row) => [row[0], '—', '—', '—', '—'])

  const result = analyzeDashboardSnapshot('build-orders', broken, 14)

  assert.equal(result.verdict, 'attention')
  assert.deepEqual(result.issues.filter((issue) => issue.kind === 'metric-column-missing').map((issue) => issue.detail), [
    'Progress is — for all 3 rows',
    'Tickets is — for all 3 rows',
    'Epics is — for all 3 rows',
    'Waves is — for all 3 rows'
  ])
  assert.equal(analyzeDashboardSnapshot('build-orders', healthySnapshot, 14).verdict, 'healthy')
})

test('keeps a healthy dashboard healthy across repeated settled observations', () => {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const result = analyzeDashboardSnapshot('analytics', healthySnapshot, 14)
    assert.equal(result.verdict, 'healthy', `attempt ${attempt + 1}`)
  }
})

test('reports visible staleness, empty tables, and configured-cap contradictions', () => {
  const stale = structuredClone(healthySnapshot)
  stale.staleBanners = ['Units may be stale. current-run membership is healthy']
  stale.tables.push({ label: 'Analytics', hasBody: true, headers: ['Metric'], rows: [] })
  stale.capacityReadings = [{ label: 'peak concurrency', value: 33, cap: 32 }]

  const result = analyzeDashboardSnapshot('units', stale, 14)

  assert.equal(result.verdict, 'attention')
  assert.deepEqual(result.issues.map((issue) => issue.kind), ['stale-banner', 'empty-table', 'capacity-mismatch', 'capacity-overrun'])
  assert.match(renderVerdict({ verdict: result.verdict, pages: [result] }), /Units may be stale/)
})

test('flags a settled Units zero-state while agents are active, but allows a confirmed idle run', () => {
  const emptyUnits = structuredClone(healthySnapshot)
  emptyUnits.emptyStates = ['No units have been observed in this run.']

  const activeRun = analyzeDashboardSnapshot('units', emptyUnits, 14, 9)
  assert.deepEqual(activeRun.issues.filter((issue) => issue.kind === 'empty-state').map((issue) => issue.detail), [
    'No units have been observed in this run.'
  ])

  const idleRun = analyzeDashboardSnapshot('units', emptyUnits, 14, 0)
  assert.equal(idleRun.verdict, 'healthy')
})

test('extracts the peak card value separately from current concurrency and its cap', () => {
  const readings = extractCapacityReadings([
    { label: 'Peak concurrency', value: '33', sub: '20 now / 32 cap' }
  ])

  assert.deepEqual(readings, [
    { label: 'peak concurrency', value: 33, cap: 32 },
    { label: 'current concurrency', value: 20, cap: 32 }
  ])
  const result = analyzeDashboardSnapshot('analytics', { ...healthySnapshot, capacityReadings: readings }, 14)
  assert.deepEqual(result.issues.filter((issue) => issue.kind === 'capacity-overrun').map((issue) => issue.detail), ['peak concurrency is 33 above its cap 32'])
})
