import assert from 'node:assert/strict'
import test from 'node:test'
import { analyzeDashboardSnapshot, inspectPage, runPageCapture } from '../capture-dashboard.mjs'
import { buildDashboardIssues, PAGES } from '../capture-dashboard-build.mjs'

function buildSnapshot(overrides = {}) {
  return {
    buildUnavailable: '', buildSkeleton: false, buildTicketCount: 0, buildOpenTicketCount: 0,
    buildBand: '', buildHydrated: true, ...overrides
  }
}

test('the dashboard capture inventory includes the /build home page', () => {
  assert.deepEqual(PAGES.map(([, route]) => route), ['/', '/commands', '/build-orders', '/build', '/analytics'])
})

test('an unavailable build timeline is an attention finding', () => {
  const snapshot = buildSnapshot({ buildUnavailable: 'Build timeline unavailable · source unavailable' })

  assert.deepEqual(buildDashboardIssues('build', snapshot), [{
    kind: 'build-timeline-unavailable',
    detail: 'Build timeline unavailable · source unavailable'
  }])
})

test('the snapshot analyzer reports the unavailable banner through production wiring', () => {
  const result = analyzeDashboardSnapshot('build', {
    status: 200, title: 'Build', chars: 10, liveViewConnected: true, primaryContent: true,
    tables: [], staleBanners: [], emptyStates: [], errorStates: [], capacityReadings: [],
    hasNAInMetric: false,
    ...buildSnapshot({ buildUnavailable: 'Build timeline unavailable · build data failed validation' })
  })

  assert.equal(result.verdict, 'attention')
  assert.ok(result.issues.some(({ kind }) => kind === 'build-timeline-unavailable'))
})

test('a build root without hydrated timeline content is attention', () => {
  const result = analyzeDashboardSnapshot('build', {
    status: 200, title: 'Build', chars: 10, liveViewConnected: true, primaryContent: true,
    tables: [], staleBanners: [], emptyStates: [], errorStates: [], capacityReadings: [],
    hasNAInMetric: false,
    ...buildSnapshot({ buildSkeleton: true, buildOpenTicketCount: null, buildHydrated: false })
  })

  assert.equal(result.verdict, 'attention')
  assert.ok(result.issues.some(({ kind }) => kind === 'build-not-hydrated'))
})

test('remaining skeletons and missing cards for a non-empty queue are attention findings', () => {
  const snapshot = buildSnapshot({ buildSkeleton: true, buildOpenTicketCount: 12, buildHydrated: false })

  assert.deepEqual(buildDashboardIssues('build', snapshot).map(({ kind }) => kind), [
    'build-not-hydrated',
    'build-skeletons-remain',
    'build-tickets-missing'
  ])
})

test('a known empty queue with no skeletons or cards remains healthy', () => {
  const snapshot = buildSnapshot({ buildHydrated: true })
  assert.deepEqual(buildDashboardIssues('build', snapshot), [])
})

test('flags the production validation and timeout unavailable messages', () => {
  for (const message of [
    'Build timeline unavailable · build data failed validation',
    'Build timeline unavailable · build index read timed out'
  ]) {
    assert.ok(buildDashboardIssues('build', buildSnapshot({ buildUnavailable: message }))
      .some(({ kind }) => kind === 'build-timeline-unavailable'))
  }
})

test('flags unavailable agent state always and no-agent state when active agents are expected', () => {
  const unavailable = buildSnapshot({ buildBand: 'Agent states unavailable' })
  assert.ok(buildDashboardIssues('build', unavailable).some(({ kind }) => kind === 'build-agent-state-unavailable'))

  const noAgents = buildSnapshot({ buildBand: 'No agents are working right now.' })
  assert.deepEqual(buildDashboardIssues('build', noAgents), [])
  assert.ok(buildDashboardIssues('build', noAgents, 1).some(({ kind }) => kind === 'build-agent-state-unavailable'))
})

function inspectedBuildRoot({ skeleton = false, band = '', queue = '', tickets = 0 } = {}) {
  const root = {
    querySelector(selector) {
      if (selector === '.bd-loading') return null
      if (selector === '.bd-now-empty') return band ? { innerText: band } : null
      if (selector === '.bd-skel, .bd-skel-lanes') return skeleton ? {} : null
      if (selector === '#bd-sec-plan .bd-sech em, #bd-sec-plan .lh em') return queue ? { innerText: queue } : null
      return null
    },
    querySelectorAll(selector) {
      if (selector === '.bd-card[data-id], .lr[data-id]') return Array.from({ length: tickets }, () => ({}))
      return []
    }
  }
  return root
}

async function inspectBuild(root) {
  const priorDocument = globalThis.document
  const priorWindow = globalThis.window
  globalThis.document = {
    title: 'Build', body: { innerText: '' },
    querySelector: (selector) => selector === '#build-root' ? root : null,
    querySelectorAll: () => []
  }
  globalThis.window = { getComputedStyle: () => ({ display: 'block', visibility: 'visible' }) }
  try {
    return await inspectPage({ evaluate: (callback, name) => callback(name) }, 'build')
  } finally {
    globalThis.document = priorDocument
    globalThis.window = priorWindow
  }
}

function analyzeInspectedBuild(snapshot, expectedActiveAgents = null) {
  return analyzeDashboardSnapshot('build', {
    status: 200, title: 'Build', chars: 10, liveViewConnected: true, primaryContent: true,
    tables: [], staleBanners: [], emptyStates: [], errorStates: [], capacityReadings: [],
    hasNAInMetric: false,
    ...snapshot
  }, null, expectedActiveAgents)
}

test('production /build DOM inspection detects skeleton markup and raises attention', async () => {
  const snapshot = await inspectBuild(inspectedBuildRoot({ skeleton: true }))
  const result = analyzeInspectedBuild(snapshot)

  assert.equal(snapshot.buildSkeleton, true)
  assert.equal(result.verdict, 'attention')
  assert.ok(result.issues.some(({ kind }) => kind === 'build-skeletons-remain'))
})

test('production /build DOM inspection detects the Live empty band with active agents', async () => {
  const snapshot = await inspectBuild(inspectedBuildRoot({ band: 'No agents are working right now.' }))
  const result = analyzeInspectedBuild(snapshot, 1)

  assert.equal(snapshot.buildBand, 'No agents are working right now.')
  assert.equal(result.verdict, 'attention')
  assert.ok(result.issues.some(({ kind }) => kind === 'build-agent-state-unavailable'))
})

test('the /build capture waits for hydration and treats a hydration timeout as attention', async () => {
  async function capture({ root, timeout = false }) {
    const fakeDocument = {
      title: 'Build',
      body: { innerText: '' },
      querySelectorAll: () => [],
      querySelector: (selector) => selector === '#build-root' ? root : null
    }
    const page = {
      on() {},
      goto: async () => ({ status: () => 200 }),
      waitForFunction: async (callback, _argument, options) => {
        assert.equal(options.timeout, 6000)
        if (timeout) throw new Error('Timeout 6000ms exceeded waiting for build hydration')
        const priorDocument = globalThis.document
        globalThis.document = fakeDocument
        try {
          assert.equal(callback(), true)
        } finally {
          globalThis.document = priorDocument
        }
      },
      waitForTimeout: async () => {},
      evaluate: async (callback, pageName) => {
        const priorDocument = globalThis.document
        const priorWindow = globalThis.window
        globalThis.document = fakeDocument
        globalThis.window = { getComputedStyle: () => ({ display: 'block', visibility: 'visible' }) }
        try {
          return callback(pageName)
        } finally {
          globalThis.document = priorDocument
          globalThis.window = priorWindow
        }
      },
      screenshot: async () => {}
    }

    return runPageCapture(page, 'build', '/build', [], 'http://dashboard.test')
  }

  const settled = await capture({ root: {
    querySelector: (selector) => selector.includes('.bd-mk.empty') ? {} : null,
    querySelectorAll: () => []
  } })
  assert.equal(settled.verdict, 'healthy', JSON.stringify(settled.issues))

  const timedOut = await capture({ root: { querySelector: () => null, querySelectorAll: () => [] }, timeout: true })
  assert.equal(timedOut.verdict, 'attention')
  assert.ok(timedOut.issues.some(({ kind }) => kind === 'navigation'))
  assert.ok(timedOut.issues.some(({ kind }) => kind === 'build-not-hydrated'))
})
