export const PAGES = [
  ['units', '/'],
  ['commands', '/commands'],
  ['build-orders', '/build-orders'],
  ['build', '/build'],
  ['analytics', '/analytics']
]

export function inspectBuildPage(root) {
  if (!root) return { buildHydrated: false }

  const unavailable = root.querySelector('.bd-loading')?.innerText.replace(/\s+/g, ' ').trim() || ''
  const skeleton = Boolean(root.querySelector('.bd-skel, .bd-skel-lanes'))
  const ticketCount = root.querySelectorAll('.bd-card[data-id], .lr[data-id]').length
  const queueText = root.querySelector('#bd-sec-plan .bd-sech em, #bd-sec-plan .lh em')?.innerText || ''
  const queueCount = queueText.match(/(\d[\d,]*)\s+in build-queue order\b/i)
  const band = root.querySelector('.bd-now-empty')?.innerText.replace(/\s+/g, ' ').trim() || ''

  return {
    buildUnavailable: unavailable,
    buildSkeleton: skeleton,
    buildTicketCount: ticketCount,
    buildOpenTicketCount: queueCount ? Number.parseInt(queueCount[1].replaceAll(',', ''), 10) : null,
    buildBand: band,
    buildHydrated: ticketCount > 0 || Boolean(root.querySelector('.bd-mk.empty')) || /Build timeline unavailable/i.test(unavailable)
  }
}

export function buildDashboardIssues(name, snapshot, expectedActiveAgents = null) {
  if (name !== 'build') return []

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
