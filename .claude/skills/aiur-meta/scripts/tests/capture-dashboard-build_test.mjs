import assert from 'node:assert/strict'
import test from 'node:test'
import { buildDashboardIssues, inspectBuildPage, PAGES } from '../capture-dashboard-build.mjs'

function buildRoot({ unavailable = '', skeleton = false, cards = 0, queued = null } = {}) {
  return {
    querySelector(selector) {
      if (selector === '.bd-loading') return { innerText: unavailable }
      if (selector === '.bd-skel, .bd-skel-lanes' && skeleton) return {}
      if (selector === '#bd-sec-plan .bd-sech em, #bd-sec-plan .lh em' && queued !== null) return { innerText: `${queued} in build-queue order · dependency waves` }
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

test('remaining skeletons and missing cards for a non-empty queue are attention findings', () => {
  const snapshot = inspectBuildPage(buildRoot({ skeleton: true, queued: 12 }))

  assert.deepEqual(buildDashboardIssues('build', snapshot).map(({ kind }) => kind), [
    'build-skeletons-remain',
    'build-tickets-missing'
  ])
})

test('a known empty queue with no skeletons or cards remains healthy', () => {
  const snapshot = inspectBuildPage(buildRoot({ queued: 0 }))
  assert.deepEqual(buildDashboardIssues('build', snapshot), [])
})
