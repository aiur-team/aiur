export const PAGES = [
  ['units', '/'],
  ['commands', '/commands'],
  ['build-orders', '/build-orders'],
  ['build', '/build'],
  ['analytics', '/analytics']
]

export function inspectBuildPage(root) {
  if (!root) return {}

  const unavailable = root.querySelector('.bd-loading')?.innerText.replace(/\s+/g, ' ').trim() || ''
  const skeleton = Boolean(root.querySelector('.bd-skel, .bd-skel-lanes'))
  const ticketCount = root.querySelectorAll('.lr[data-id]').length
  const queueText = root.querySelector('#bd-sec-plan .lh em')?.innerText || ''
  const queueCount = queueText.match(/(\d[\d,]*)\s+in build-queue order\b/i)

  return {
    buildUnavailable: unavailable,
    buildSkeleton: skeleton,
    buildTicketCount: ticketCount,
    buildOpenTicketCount: queueCount ? Number.parseInt(queueCount[1].replaceAll(',', ''), 10) : null
  }
}

export function buildDashboardIssues(name, snapshot) {
  if (name !== 'build') return []

  const issues = []
  if (/Build timeline unavailable/i.test(snapshot.buildUnavailable || '')) {
    issues.push({ kind: 'build-timeline-unavailable', detail: snapshot.buildUnavailable })
  }
  if (snapshot.buildSkeleton) {
    issues.push({ kind: 'build-skeletons-remain', detail: 'Build timeline cards are still skeletons after LiveView settle' })
  }
  if (snapshot.buildOpenTicketCount > 0 && snapshot.buildTicketCount === 0) {
    issues.push({ kind: 'build-tickets-missing', detail: `${snapshot.buildOpenTicketCount} open tickets reported but no ticket cards rendered` })
  }
  return issues
}
