// Dashboard snapshot analysis and verdicts, independent of browser capture.

import { buildDashboardIssues } from './capture-dashboard-build.mjs'

// No dashboard noise is baselined by default. The historic entry here was the
// `/conversation-drawer-hook.js` 404 from the missing Plug.Static (#1681);
// that issue is closed and the endpoint serves the asset, so keeping the rule
// would silently re-arm for any future regression on the same path.
//
// A baseline must always name an open issue and be removed when it closes —
// otherwise the check degrades into "ignore this URL forever". Add temporary
// entries through AIUR_META_KNOWN_NOISE rather than here, and note that every
// suppressed entry is counted in verdict.md so a baseline is never invisible.
export const DEFAULT_KNOWN_NOISE = []

export function analyzeDashboardSnapshot(name, snapshot, expectedCapacity = null, expectedActiveAgents = null) {
  const issues = []
  const metricColumns = snapshot.tables.flatMap((table) => tableMetricIssues(table))
  const filterCounts = filterCountIssues(snapshot)

  for (const issue of metricColumns) issues.push(issue)
  for (const issue of filterCounts) issues.push(issue)
  if (name === 'analytics') issues.push(...analyticsAxisIssues(snapshot.analyticsCharts || []))
  issues.push(...buildDashboardIssues(name, snapshot, expectedActiveAgents))
  for (const banner of snapshot.staleBanners) issues.push({ kind: 'stale-banner', detail: banner })
  for (const errorState of snapshot.errorStates || []) issues.push({ kind: 'error-state', detail: errorState })
  for (const emptyState of snapshot.emptyStates) {
    // A settled Units empty-state can be legitimate only when the run itself
    // confirms that it has no active agents. With no external count, retain it
    // as attention rather than silently accepting a confidently-rendered zero.
    if (name !== 'units' || expectedActiveAgents === null || expectedActiveAgents > 0) {
      issues.push({ kind: 'empty-state', detail: emptyState })
    }
  }
  for (const table of snapshot.tables.filter((table) => table.hasBody && table.rows.length === 0)) {
    issues.push({ kind: 'empty-table', detail: table.label || 'unnamed table' })
  }

  if (snapshot.status === null || snapshot.status < 200 || snapshot.status >= 400) {
    issues.push({ kind: 'http-status', detail: snapshot.status === null ? 'navigation did not return a response' : String(snapshot.status) })
  }
  if (snapshot.navigationError) issues.push({ kind: 'navigation', detail: snapshot.navigationError })
  if (snapshot.hasNAInMetric) issues.push({ kind: 'metric-na', detail: 'N/A appears in a numeric metric position' })
  if (!snapshot.primaryContent && !confirmedIdleUnits(name, snapshot, expectedActiveAgents)) {
    issues.push({ kind: 'primary-content-missing', detail: `${pageLabel(name)} primary content was not found after LiveView settle` })
  }

  if (expectedCapacity) {
    for (const observed of snapshot.capacityReadings) {
      if (observed.cap !== expectedCapacity) {
        issues.push({ kind: 'capacity-mismatch', detail: `${observed.label} reports cap ${observed.cap}; configured cap is ${expectedCapacity}` })
      }
      if (observed.value > observed.cap) {
        issues.push({ kind: 'capacity-overrun', detail: `${observed.label} is ${observed.value} above its cap ${observed.cap}` })
      }
    }
  } else {
    for (const observed of snapshot.capacityReadings.filter((reading) => reading.value > reading.cap)) {
      issues.push({ kind: 'capacity-overrun', detail: `${observed.label} is ${observed.value} above its cap ${observed.cap}` })
    }
  }

  return {
    name,
    verdict: issues.length === 0 ? 'healthy' : 'attention',
    issues,
    signals: {
      title: snapshot.title,
      chars: snapshot.chars,
      liveViewConnected: snapshot.liveViewConnected,
      primaryContent: snapshot.primaryContent,
      rows: snapshot.tables.reduce((count, table) => count + table.rows.length, 0),
      tables: snapshot.tables.length,
      staleBanners: snapshot.staleBanners,
      errorStates: snapshot.errorStates || [],
      filterGroups: snapshot.filterGroups || [],
      countSummaries: snapshot.countSummaries || [],
      capacityReadings: snapshot.capacityReadings
    }
  }
}

export function analyticsAxisIssues(charts) {
  const issues = []
  for (const chart of charts) {
    const yValues = (chart.yLabels || []).map((label) => Number(label.replaceAll(',', '').match(/^-?[\d.]+/)?.[0])).filter(Number.isFinite)
    if (yValues.length > 1 && yValues.some((value, index) => index > 0 && value < yValues[index - 1])) {
      issues.push({ kind: 'axis-non-monotonic', detail: `${chart.label} y-axis labels are not monotonic: ${yValues.join(', ')}` })
    }
    for (const [axis, labels] of [['x', chart.xLabels || []], ['y', chart.yLabels || []]]) {
      const duplicates = [...new Set(labels.filter((label, index) => labels.indexOf(label) !== index))]
      if (duplicates.length > 0) {
        issues.push({ kind: 'axis-repeated-label', detail: `${chart.label} ${axis}-axis repeats ${duplicates.join(', ')}` })
      }
    }
  }
  return issues
}

export function extractCapacityReadings(kpis) {
  const readings = []

  for (const kpi of kpis) {
    if (!/^peak concurrency$/i.test(kpi.label)) continue

    const peak = Number.parseInt(kpi.value, 10)
    const currentAndCap = kpi.sub.match(/(\d+)\s+now\s*\/\s*(\d+)\s+cap/i)
    if (!Number.isInteger(peak) || !currentAndCap) continue

    const current = Number.parseInt(currentAndCap[1], 10)
    const cap = Number.parseInt(currentAndCap[2], 10)
    readings.push({ label: 'peak concurrency', value: peak, cap })
    readings.push({ label: 'current concurrency', value: current, cap })
  }

  if (readings.length > 0) return readings

  return readings
}

export function renderVerdict(report) {
  const lines = ['# Dashboard visual check', '']

  for (const page of report.pages) {
    const details = page.issues.length === 0
      ? 'healthy after LiveView settle'
      : page.issues.map((issue) => `${issue.kind}: ${issue.detail}`).join('; ')
    lines.push(`- ${page.name}: **${page.verdict}** — ${details}`)
  }

  lines.push('', `Overall: **${report.verdict}**. Captures: ${report.pages.map((page) => `${page.name}.png`).join(', ')}.`)

  // A baseline that hides errors without saying so is how a suppression rule
  // outlives the defect it was written for. Always report what was swallowed.
  const suppressed = report.pages.reduce((count, page) => count + suppressedCount(page), 0)
  if (suppressed > 0) {
    lines.push('', `Baselined and not counted as issues: ${suppressed} browser error(s)/failed request(s). Drop the rule once its issue closes.`)
  }

  return `${lines.join('\n')}\n`
}

// The verdict a precondition failure must write. It says "did not run", never
// "attention", so an empty or redacted log cannot be mistaken for a capture
// that ran and found nothing.
export function didNotRunVerdict(detail) {
  return [
    '# Dashboard visual check',
    '',
    `- capture: **did not run** — ${detail}`,
    '',
    'Overall: **did not run**. Captures were not attempted.',
    ''
  ].join('\n')
}

// A page whose whole turn exceeded its bound. The verdict names the page it
// hung on, the run's other screenshots remain, and the hung page keeps
// whatever partial screenshot the runner could still capture.
export function timedOutAssessment(name, route, timeoutMs, reason = null) {
  const detail = reason ? String(reason).slice(0, 200) : null
  return {
    name,
    verdict: 'attention',
    route,
    status: null,
    timedOut: true,
    elapsedMs: timeoutMs,
    timeoutMs,
    issues: [{
      kind: 'timeout',
      detail: `${pageLabel(name)} capture exceeded ${timeoutMs} ms${detail ? `: ${detail}` : ''}; partial screenshot only`
    }],
    signals: {
      title: null,
      chars: 0,
      liveViewConnected: false,
      primaryContent: false,
      rows: 0,
      tables: 0,
      staleBanners: [],
      errorStates: [],
      filterGroups: [],
      countSummaries: [],
      capacityReadings: []
    },
    consoleErrors: [],
    failedRequests: [],
    knownNoise: { consoleErrors: [], failedRequests: [] }
  }
}

// Bound one async operation by wall clock. The losing promise keeps running
// but its eventual rejection is consumed by the race machinery, so a stalled
// page cannot crash the whole capture as an unhandled rejection. A timeout
// rejects with a PageTimeoutError so the caller can tell a hang from any other
// capture failure.
export class PageTimeoutError extends Error {
  constructor(name, timeoutMs) {
    super(`capture of ${name} exceeded ${timeoutMs} ms`)
    this.name = 'PageTimeoutError'
    this.pageName = name
    this.timeoutMs = timeoutMs
  }
}

export function withPageTimeout(promise, timeoutMs, name) {
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      setTimeout(() => reject(new PageTimeoutError(name, timeoutMs)), timeoutMs)
    })
  ])
}

function suppressedCount(page) {
  const noise = page.knownNoise
  if (!noise) return 0
  return (noise.consoleErrors?.length || 0) + (noise.failedRequests?.length || 0)
}

function tableMetricIssues(table) {
  const memberIndex = table.headers.findIndex((header) => /^\s*(tickets?|members?)\s*$/i.test(header))

  return table.headers.flatMap((header, index) => {
    if (!isMetricHeader(header)) return []
    const values = table.rows.map((row) => normalizeCell(row[index]))
    const missingRows = values
      .map((value, rowIndex) => ({ value, rowIndex }))
      .filter(({ value }) => isMissingMetric(value))

    if (missingRows.length === values.length && values.length > 0) {
      const missingValue = values.every((value) => value === values[0]) ? displayMetric(values[0]) : 'missing'
      return [{ kind: 'metric-column-missing', detail: `${header} is ${missingValue} for all ${values.length} rows` }]
    }

    const missingMajority = missingRows.length > values.length / 2
    const missingOnPopulatedRow = missingRows.some(({ rowIndex }) => rowHasMembers(table.rows[rowIndex], memberIndex))
    if (missingRows.length > 0 && (missingMajority || missingOnPopulatedRow)) {
      return [{ kind: 'metric-column-missing', detail: `${header} is missing for ${missingRows.length} of ${values.length} rows` }]
    }

    if (values.length >= 3 && new Set(values).size === 1) {
      return [{ kind: 'metric-column-repeated', detail: `${header} repeats ${values[0]} for all ${values.length} rows` }]
    }

    return []
  })
}

function filterCountIssues(snapshot) {
  const summaries = snapshot.countSummaries || []

  return (snapshot.filterGroups || []).flatMap((group) => {
    const all = group.options.find((option) => /^all$/i.test(option.label) && Number.isInteger(option.count))
    if (!all) return []

    const largerOptions = group.options.filter((option) =>
      !/^all$/i.test(option.label) && Number.isInteger(option.count) && option.count > all.count
    )
    const largerSummaries = summaries.filter((summary) =>
      group.scope && summary.scope === group.scope && Number.isInteger(summary.total) && summary.total > all.count
    )

    if (largerOptions.length === 0 && largerSummaries.length === 0) return []

    const contradictions = [
      ...largerOptions.map((option) => `${option.label} ${option.count}`),
      ...largerSummaries.map((summary) => `${summary.label} total ${summary.total}`)
    ]

    return [{
      kind: 'filter-count-contradiction',
      detail: `${group.label} All reports ${all.count}, below ${contradictions.join(' and ')}`
    }]
  })
}

function isMetricHeader(header) {
  return /progress|ticket|epic|wave|member|active|complete|capacity|concurrency|cpu|cost|count|total/i.test(header)
}

function isMissingMetric(value) {
  return value === '' || /^(?:—|–|-|n\/a|unresolved)$/i.test(value)
}

function displayMetric(value) {
  return value === '' ? 'blank' : value
}

function rowHasMembers(row, memberIndex) {
  if (memberIndex < 0) return false

  const count = Number.parseInt(normalizeCell(row[memberIndex]).replaceAll(',', ''), 10)
  return Number.isInteger(count) && count > 0
}

function confirmedIdleUnits(name, snapshot, expectedActiveAgents) {
  return name === 'units' &&
    expectedActiveAgents === 0 &&
    snapshot.emptyStates.some((state) => /no units have been observed|no active agents|no live units/i.test(state))
}

export function pageLabel(name) {
  return {
    build: 'Build',
    'build-home': 'Build home',
    units: 'Units',
    commands: 'Commands',
    analytics: 'Analytics'
  }[name] || name
}

function normalizeCell(value) {
  return String(value || '').replace(/\s+/g, ' ').trim()
}
