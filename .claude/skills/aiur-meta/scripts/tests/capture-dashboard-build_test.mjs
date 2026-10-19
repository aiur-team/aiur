import assert from 'node:assert/strict'
import test from 'node:test'
import { analyzeDashboardSnapshot, runPageCapture } from '../capture-dashboard.mjs'
import { buildDashboardIssues, inspectBuildPage, PAGES } from '../capture-dashboard-build.mjs'

function buildRoot({ unavailable = '', skeleton = false, cards = 0, queued = null, band = '', empty = false } = {}) {
  return {
    querySelector(selector) {
      if (selector === '.bd-loading') return { innerText: unavailable }
      if (selector === '.bd-skel, .bd-skel-lanes' && skeleton) return {}
      if (selector === '#bd-sec-plan .bd-sech em, #bd-sec-plan .lh em' && queued !== null) return { innerText: `${queued} in build-queue order · dependency waves` }
      if (selector === '.bd-now-empty' && band) return { innerText: band }
      if (selector.includes('.bd-mk.empty') && empty) return {}
      return null
    },
    querySelectorAll(selector) {
      return selector === '.bd-card[data-id], .lr[data-id]' ? Array.from({ length: cards }, () => ({})) : []
    }
  }
}

test('the dashboard capture inventory includes the /build home page', () => {
  assert.deepEqual(PAGES.map(([, route]) => route), ['/', '/commands', '/build-orders', '/build', '/analytics'])
})

test('an unavailable build timeline is an attention finding', () => {
  const snapshot = inspectBuildPage(buildRoot({ unavailable: 'Build timeline unavailable · source unavailable' }))

  assert.deepEqual(buildDashboardIssues('build', snapshot), [{
    kind: 'build-timeline-unavailable',
    detail: 'Build timeline unavailable · source unavailable'
  }])
})

test('the snapshot analyzer reports the unavailable banner through production wiring', () => {
  const result = analyzeDashboardSnapshot('build', {
    status: 200, title: 'Build', chars: 10, liveViewConnected: true, primaryContent: true,
    tables: [], staleBanners: [], emptyStates: [], errorStates: [], capacityReadings: [],
    hasNAInMetric: false, buildUnavailable: 'Build timeline unavailable · build data failed validation',
    buildSkeleton: false, buildTicketCount: 0, buildOpenTicketCount: 0, buildHydrated: true
  })

  assert.equal(result.verdict, 'attention')
  assert.ok(result.issues.some(({ kind }) => kind === 'build-timeline-unavailable'))
})

test('a build root without hydrated timeline content is attention', () => {
  const result = analyzeDashboardSnapshot('build', {
    status: 200, title: 'Build', chars: 10, liveViewConnected: true, primaryContent: true,
    tables: [], staleBanners: [], emptyStates: [], errorStates: [], capacityReadings: [],
    hasNAInMetric: false, buildUnavailable: '', buildSkeleton: true,
    buildTicketCount: 0, buildOpenTicketCount: null, buildHydrated: false
  })

  assert.equal(result.verdict, 'attention')
  assert.ok(result.issues.some(({ kind }) => kind === 'build-not-hydrated'))
})

test('remaining skeletons and missing cards for a non-empty queue are attention findings', () => {
  const snapshot = inspectBuildPage(buildRoot({ skeleton: true, queued: 12 }))

  assert.deepEqual(buildDashboardIssues('build', snapshot).map(({ kind }) => kind), [
    'build-not-hydrated',
    'build-skeletons-remain',
    'build-tickets-missing'
  ])
})

test('a known empty queue with no skeletons or cards remains healthy', () => {
  const snapshot = inspectBuildPage(buildRoot({ queued: 0, empty: true }))
  assert.deepEqual(buildDashboardIssues('build', snapshot), [])
})

test('flags the production validation and timeout unavailable messages', () => {
  for (const message of [
    'Build timeline unavailable · build data failed validation',
    'Build timeline unavailable · build index read timed out'
  ]) {
    assert.ok(buildDashboardIssues('build', inspectBuildPage(buildRoot({ unavailable: message })))
      .some(({ kind }) => kind === 'build-timeline-unavailable'))
  }
})

test('flags unavailable agent state always and no-agent state when active agents are expected', () => {
  const unavailable = inspectBuildPage(buildRoot({ band: 'Agent states unavailable', empty: true }))
  assert.ok(buildDashboardIssues('build', unavailable).some(({ kind }) => kind === 'build-agent-state-unavailable'))

  const noAgents = inspectBuildPage(buildRoot({ band: 'No agents are working right now.', empty: true }))
  assert.deepEqual(buildDashboardIssues('build', noAgents), [])
  assert.ok(buildDashboardIssues('build', noAgents, 1).some(({ kind }) => kind === 'build-agent-state-unavailable'))
})

test('a blank build root is not considered hydrated', () => {
  const snapshot = inspectBuildPage(buildRoot())
  assert.equal(snapshot.buildHydrated, false)
  assert.ok(buildDashboardIssues('build', snapshot).some(({ kind }) => kind === 'build-not-hydrated'))
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

  const settled = await capture({ root: buildRoot({ queued: 0, empty: true }) })
  assert.equal(settled.verdict, 'healthy', JSON.stringify(settled.issues))

  const timedOut = await capture({ root: buildRoot(), timeout: true })
  assert.equal(timedOut.verdict, 'attention')
  assert.ok(timedOut.issues.some(({ kind }) => kind === 'navigation'))
  assert.ok(timedOut.issues.some(({ kind }) => kind === 'build-not-hydrated'))
})
