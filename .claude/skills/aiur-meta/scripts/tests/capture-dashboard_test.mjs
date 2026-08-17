import assert from 'node:assert/strict'
import test from 'node:test'
import { DEFAULT_KNOWN_NOISE, analyzeDashboardSnapshot, extractCapacityReadings, inspectPage, renderVerdict } from '../capture-dashboard.mjs'

const healthySnapshot = {
  title: 'Aiur',
  chars: 1400,
  liveViewConnected: true,
  primaryContent: true,
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
  errorStates: [],
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

test('flags missing metrics when a genuine empty row would otherwise mask populated rows', () => {
  const broken = structuredClone(healthySnapshot)
  broken.tables[0].rows = [
    ['Build Order dashboard', '100%', '54', '—', '—'],
    ['Analytics optimizations', '100%', '11', '—', '—'],
    ['Analytics + Streamdeck', '0%', '0', '0', '0'],
    ['Stream Deck Parity', '89%', '27', '—', '—']
  ]

  const result = analyzeDashboardSnapshot('build-orders', broken, 14)

  assert.equal(result.verdict, 'attention')
  assert.deepEqual(result.issues.filter((issue) => issue.kind === 'metric-column-missing').map((issue) => issue.detail), [
    'Epics is missing for 3 of 4 rows',
    'Waves is missing for 3 of 4 rows'
  ])
})

test('flags a missing metric on any populated row even when most values are present', () => {
  const broken = structuredClone(healthySnapshot)
  broken.tables[0].rows[0][3] = '—'

  const result = analyzeDashboardSnapshot('build-orders', broken, 14)

  assert.deepEqual(result.issues.filter((issue) => issue.kind === 'metric-column-missing').map((issue) => issue.detail), [
    'Epics is missing for 1 of 3 rows'
  ])
})

test('does not skip blank or one-row metric columns', () => {
  const onePopulatedRow = structuredClone(healthySnapshot)
  onePopulatedRow.tables[0].rows = [['Build Order dashboard', '100%', '54', '', '—']]

  const result = analyzeDashboardSnapshot('build-orders', onePopulatedRow, 14)

  assert.equal(result.verdict, 'attention')
  assert.deepEqual(result.issues.filter((issue) => issue.kind === 'metric-column-missing').map((issue) => issue.detail), [
    'Epics is blank for all 1 rows',
    'Waves is — for all 1 rows'
  ])
})

test('requires recognizable primary content before reporting a page healthy', () => {
  const missingCatalog = structuredClone(healthySnapshot)
  missingCatalog.primaryContent = false
  missingCatalog.tables = []

  const result = analyzeDashboardSnapshot('build-orders', missingCatalog, 14)

  assert.equal(result.verdict, 'attention')
  assert.deepEqual(result.issues.filter((issue) => issue.kind === 'primary-content-missing'), [
    { kind: 'primary-content-missing', detail: 'Build Order primary content was not found after LiveView settle' }
  ])
})

test('extracts visible error cards and reports them instead of treating them as an absence of findings', async () => {
  const visibleErrors = [
    'Catalog unavailable',
    'Structurally invalid graph',
    'Analytics unavailable',
    'Usage and cost unavailable'
  ]
  const brokenDetail = await inspectPage(fakePage({
    elements: visibleErrors.map((innerText, index) => ({
      innerText,
      selectors: [index < 2 ? '.bo-state-card' : '.an-empty']
    }))
  }), 'build-orders')
  brokenDetail.status = 200
  brokenDetail.navigationError = null
  brokenDetail.capacityReadings = []

  const result = analyzeDashboardSnapshot('build-orders', brokenDetail, 14)

  assert.equal(result.verdict, 'attention')
  assert.equal(brokenDetail.primaryContent, false)
  assert.deepEqual(result.issues.filter((issue) => issue.kind === 'error-state').map((issue) => issue.detail), visibleErrors)
})

test('recognizes primary content for every dashboard page', async () => {
  const selectors = {
    units: '#units-rows .units-row',
    commands: '.decision-inbox',
    'build-orders': '.bo-catalog-table, .bo-selected-summary',
    analytics: '#analytics-page .an-kpis'
  }

  for (const [name, selector] of Object.entries(selectors)) {
    const present = await inspectPage(fakePage({ primarySelectors: [selector] }), name)
    const absent = await inspectPage(fakePage(), name)
    assert.equal(present.primaryContent, true, `${name} primary content present`)
    assert.equal(absent.primaryContent, false, `${name} primary content absent`)
  }
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

test('flags the rendered Units zero-state while agents are active, but allows a confirmed idle run', async () => {
  const emptyUnits = await inspectPage(fakePage({
    elements: [{
      innerText: 'No live units.',
      selectors: ['.units-state.empty-state:not(.filtered-empty)', '.empty-state']
    }]
  }), 'units')
  emptyUnits.status = 200
  emptyUnits.navigationError = null
  emptyUnits.capacityReadings = []

  const activeRun = analyzeDashboardSnapshot('units', emptyUnits, 14, 9)
  assert.deepEqual(activeRun.issues.filter((issue) => issue.kind === 'empty-state').map((issue) => issue.detail), [
    'No live units.'
  ])

  const idleRun = analyzeDashboardSnapshot('units', emptyUnits, 14, 0)
  assert.equal(idleRun.verdict, 'healthy')

  const unavailableUnits = structuredClone(emptyUnits)
  unavailableUnits.emptyStates = []
  unavailableUnits.errorStates = ['Unit data unavailable']
  assert.equal(analyzeDashboardSnapshot('units', unavailableUnits, 14, 0).verdict, 'attention')
})

test('baselines nothing by default now that the dashboard asset 404 is fixed', () => {
  assert.deepEqual(DEFAULT_KNOWN_NOISE, [])
})

test('reports what a noise baseline suppressed so a stale rule stays visible', () => {
  const page = analyzeDashboardSnapshot('units', healthySnapshot, 14)
  page.knownNoise = { consoleErrors: [{ kind: 'console' }], failedRequests: [{ kind: 'response' }] }

  const verdict = renderVerdict({ verdict: 'healthy', pages: [page] })

  assert.match(verdict, /Baselined and not counted as issues: 2 browser error/)
  assert.doesNotMatch(renderVerdict({ verdict: 'healthy', pages: [analyzeDashboardSnapshot('units', healthySnapshot, 14)] }), /Baselined/)
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

function fakePage({ elements = [], primarySelectors = [] } = {}) {
  const nodes = elements.map(({ innerText, selectors }) => ({
    innerText,
    selectors,
    getClientRects: () => [{}]
  }))

  return {
    evaluate: async (callback, pageName) => {
      const priorDocument = globalThis.document
      const priorWindow = globalThis.window
      globalThis.document = {
        title: 'Aiur',
        body: { innerText: nodes.map((element) => element.innerText).join('\n') },
        querySelectorAll: (selector) => {
          const requested = selector.split(',').map((value) => value.trim())
          return nodes.filter((element) => element.selectors.some((value) => requested.includes(value)))
        },
        querySelector: (selector) => {
          if (selector === '[data-phx-main], [data-phx-session]') return {}
          return primarySelectors.includes(selector) ? {} : null
        }
      }
      globalThis.window = { getComputedStyle: () => ({ display: 'block', visibility: 'visible' }) }

      try {
        return callback(pageName)
      } finally {
        globalThis.document = priorDocument
        globalThis.window = priorWindow
      }
    }
  }
}
