export const PAGES = [
  ['build-home', '/'],
  ['units', '/units'],
  ['commands', '/commands'],
  ['build-orders', '/build-orders'],
  ['build', '/build'],
  ['analytics', '/analytics']
]

export function buildDashboardIssues(name, snapshot, expectedActiveAgents = null) {
  if (name !== 'build' && name !== 'build-home') return []

  const issues = []
  if (/Build timeline unavailable/i.test(snapshot.buildUnavailable || '')) {
    issues.push({ kind: 'build-timeline-unavailable', detail: snapshot.buildUnavailable })
  }
  if (/Agent states unavailable/i.test(snapshot.buildBand || '') ||
      (/No agents are working right now/i.test(snapshot.buildBand || '') && expectedActiveAgents > 0)) {
    issues.push({ kind: 'build-agent-state-unavailable', detail: snapshot.buildBand })
  }
  if (!snapshot.buildHydrated) {
    issues.push({ kind: 'build-not-hydrated', detail: 'Build timeline did not render cards, an empty-queue state, or an unavailable state after hydration wait' })
  }
  if (snapshot.buildSkeleton) {
    issues.push({ kind: 'build-skeletons-remain', detail: 'Build timeline cards are still skeletons after LiveView settle' })
  }
  if (snapshot.buildOpenTicketCount > 0 && snapshot.buildTicketCount === 0) {
    issues.push({ kind: 'build-tickets-missing', detail: `${snapshot.buildOpenTicketCount} open tickets reported but no ticket cards rendered` })
  }
  return issues
}
