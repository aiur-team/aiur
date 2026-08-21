// Capture and assess every operator-facing dashboard page for one Aiur
// meta-check. This is deliberately a Node script instead of ad-hoc Playwright
// so hourly checks retain both their evidence and their interpretation.
//
// Usage:
//   AIUR_DASHBOARD_URL=http://host:port \
//   AIUR_DASHBOARD_USERNAME=… AIUR_DASHBOARD_PASSWORD=… \
//   node capture-dashboard.mjs <output-dir>
//
// It writes <page>.png, report.json, and verdict.md to the output directory
// and prints the JSON report. The runner resolves Playwright from src/browser,
// where it is vendored, rather than assuming the skill directory has a
// node_modules tree. Basic auth must use Playwright's httpCredentials (not URL
// userinfo), and each page must settle after domcontentloaded because LiveView
// otherwise leaves the static shell looking falsely empty.

import { createRequire } from 'node:module'
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url))
const REPOSITORY_ROOT = path.resolve(SCRIPT_DIR, '../../../../')
const BASE = process.env.AIUR_DASHBOARD_URL
const USER = process.env.AIUR_DASHBOARD_USERNAME || 'aiur'
const PASS = process.env.AIUR_DASHBOARD_PASSWORD
const OUT = process.argv[2] || './meta-captures'
const SETTLE_MS = positiveInteger(process.env.AIUR_META_SETTLE_MS, 6000)
const EXPECTED_CAPACITY = positiveInteger(process.env.AIUR_META_EXPECTED_CAPACITY, null)
const EXPECTED_ACTIVE_AGENTS = nonNegativeInteger(process.env.AIUR_META_EXPECTED_ACTIVE_AGENTS, null)
const PLAYWRIGHT_ROOT = process.env.AIUR_META_PLAYWRIGHT_ROOT || path.join(REPOSITORY_ROOT, 'src/browser')
const BOOTSTRAP_PATH = process.env.AIUR_META_BOOTSTRAP_PATH

const PAGES = [
  ['units', '/'],
  ['commands', '/commands'],
  ['build-orders', '/build-orders'],
  ['analytics', '/analytics']
]

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

export function extractCapacityReadings(kpis, text = '') {
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

  const capacityPattern = /(\d+)\s+now\s*\/\s*(\d+)\s+cap/gi
  for (const match of text.matchAll(capacityPattern)) {
    readings.push({ label: 'current concurrency', value: Number(match[1]), cap: Number(match[2]) })
  }
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

function pageLabel(name) {
  return {
    units: 'Units',
    commands: 'Commands',
    'build-orders': 'Build Order',
    analytics: 'Analytics'
  }[name] || name
}

function normalizeCell(value) {
  return String(value || '').replace(/\s+/g, ' ').trim()
}

function positiveInteger(value, fallback) {
  if (!value) return fallback
  const parsed = Number.parseInt(value, 10)
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback
}

function nonNegativeInteger(value, fallback) {
  if (value === undefined || value === '') return fallback
  const parsed = Number.parseInt(value, 10)
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : fallback
}

function knownNoiseRules() {
  const raw = process.env.AIUR_META_KNOWN_NOISE
  if (!raw) return DEFAULT_KNOWN_NOISE

  try {
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : DEFAULT_KNOWN_NOISE
  } catch {
    console.error('AIUR_META_KNOWN_NOISE must be a JSON array; baselining nothing instead.')
    return DEFAULT_KNOWN_NOISE
  }
}

function isKnownNoise(entry, rules) {
  return rules.some((rule) =>
    (!rule.kind || rule.kind === entry.kind) &&
    (!rule.status || rule.status === entry.status) &&
    (!rule.path || String(entry.url || '').includes(rule.path)) &&
    (!rule.text || entry.text.includes(rule.text))
  )
}

function loadChromium() {
  const require = createRequire(path.join(PLAYWRIGHT_ROOT, 'package.json'))
  return require('@playwright/test').chromium
}

export async function inspectPage(page, name) {
  return page.evaluate((pageName) => {
    const text = document.body ? document.body.innerText : ''
    const visible = (element) => {
      const style = window.getComputedStyle(element)
      return style.display !== 'none' && style.visibility !== 'hidden' && element.getClientRects().length > 0
    }
    const tables = Array.from(document.querySelectorAll('table')).map((table) => ({
      label: table.getAttribute('aria-label') || table.querySelector('caption')?.innerText?.trim() || table.className,
      headers: Array.from(table.querySelectorAll('thead th')).map((cell) => cell.innerText.trim()),
      rows: Array.from(table.querySelectorAll('tbody tr')).map((row) => Array.from(row.querySelectorAll('td')).map((cell) => cell.innerText.trim())),
      hasBody: Boolean(table.querySelector('tbody'))
    }))
    const filterGroups = Array.from(document.querySelectorAll('.filter-row[aria-label]'))
      .filter(visible)
      .map((group) => ({
        label: group.getAttribute('aria-label') || 'Filters',
        scope: group.getAttribute('data-count-scope'),
        options: Array.from(group.querySelectorAll('button.filter-chip')).map((button) => ({
          label: button.childNodes[0]?.textContent?.trim() || button.innerText.trim(),
          count: Number.parseInt(button.querySelector('.count')?.innerText.trim(), 10)
        }))
      }))
    const countSummaries = Array.from(document.querySelectorAll('.history-count'))
      .filter(visible)
      .flatMap((element) => {
        const match = element.innerText.match(/(\d+)\s+of\s+(\d+)/i)
        if (!match) return []

        const section = element.closest('section')
        const label = section?.querySelector('.recent-subtitle')?.innerText.trim() || 'Table'
        return [{ label, scope: element.getAttribute('data-count-scope'), loaded: Number(match[1]), total: Number(match[2]) }]
      })
    const staleBanners = Array.from(document.querySelectorAll('[role="status"], [role="alert"], .readonly-banner, .bo-state-card'))
      .filter(visible)
      .map((element) => element.innerText.replace(/\s+/g, ' ').trim())
      .filter((value) => /\bstale\b|not fresh|frozen|out of date/i.test(value))
    const kpis = Array.from(document.querySelectorAll('.an-kpi')).map((card) => ({
      label: card.querySelector('.an-kpi-label')?.innerText.trim() || '',
      value: card.querySelector('.an-kpi-val')?.innerText.trim() || '',
      sub: card.querySelector('.an-kpi-sub')?.innerText.trim() || ''
    }))
    const emptyStates = Array.from(document.querySelectorAll('.bo-state-card, .an-empty, .units-state.empty-state:not(.filtered-empty)'))
      .filter(visible)
      .map((element) => element.innerText.replace(/\s+/g, ' ').trim())
      .filter((value) => /no build orders|no run telemetry|no units have been observed|no active agents|no live units|loading units/i.test(value))
    const errorStates = Array.from(document.querySelectorAll('[role="alert"], .bo-state-card, .an-empty, .error-card, .empty-state, .readonly-banner'))
      .filter(visible)
      .map((element) => element.innerText.replace(/\s+/g, ' ').trim())
      .filter((value) => /\bunavailable\b|\bstructurally invalid\b|\berror\b|\bfailed\b|could not|unable to/i.test(value))
    const primaryContentSelector = {
      units: '#units-rows .units-row',
      commands: '.decision-inbox',
      'build-orders': '.bo-catalog-table, .bo-selected-summary',
      analytics: '#analytics-page .an-kpis'
    }[pageName]
    const metricCells = tables.flatMap((table) => table.rows.flatMap((row, rowIndex) => row.map((value, index) => ({ value, header: table.headers[index], rowIndex }))))
    const hasNAInMetric = metricCells.some((cell) => cell.value.trim() === 'N/A' && /progress|ticket|epic|wave|member|active|complete|capacity|concurrency|cpu|cost|count|total/i.test(cell.header || ''))

    return {
      title: document.title,
      text,
      chars: text.length,
      liveViewConnected: Boolean(document.querySelector('[data-phx-main], [data-phx-session]')),
      primaryContent: Boolean(primaryContentSelector && document.querySelector(primaryContentSelector)),
      tables,
      filterGroups,
      countSummaries,
      staleBanners,
      emptyStates,
      errorStates,
      kpis,
      hasNAInMetric
    }
  }, name)
}

async function main() {
  if (!BASE) {
    console.error('AIUR_DASHBOARD_URL is required; run through executor-retrospective.sh to discover the daemon URL.')
    process.exitCode = 64
    return
  }

  if (!PASS) {
    console.error('AIUR_DASHBOARD_PASSWORD is required.')
    process.exitCode = 64
    return
  }

  fs.mkdirSync(OUT, { recursive: true })
  const chromium = loadChromium()
  const browser = await chromium.launch()
  const context = await browser.newContext({
    httpCredentials: { username: USER, password: PASS },
    viewport: { width: 1600, height: 1200 }
  })
  const knownNoise = knownNoiseRules()
  const pages = []

  try {
    if (BOOTSTRAP_PATH) {
      const bootstrap = await context.newPage()
      await bootstrap.goto(new URL(BOOTSTRAP_PATH, BASE).toString(), { waitUntil: 'domcontentloaded', timeout: 45_000 })
      await bootstrap.close()
    }

    for (const [name, route] of PAGES) {
      const page = await context.newPage()
      const consoleErrors = []
      const failedRequests = []
      page.on('console', (message) => {
        if (message.type() === 'error') consoleErrors.push({ kind: 'console', text: message.text().slice(0, 300), url: message.location().url || null })
      })
      page.on('pageerror', (error) => consoleErrors.push({ kind: 'pageerror', text: String(error).slice(0, 300), url: null }))
      page.on('requestfailed', (request) => failedRequests.push({ kind: 'requestfailed', text: request.failure()?.errorText || 'request failed', url: request.url(), method: request.method(), status: null }))
      page.on('response', (response) => {
        if (response.status() >= 400) failedRequests.push({ kind: 'response', text: `HTTP ${response.status()}`, url: response.url(), method: response.request().method(), status: response.status() })
      })

      let status = null
      let navigationError = null
      const started = Date.now()
      try {
        const response = await page.goto(new URL(route, BASE).toString(), { waitUntil: 'domcontentloaded', timeout: 45_000 })
        status = response?.status() ?? null
        await page.waitForTimeout(SETTLE_MS)
      } catch (error) {
        navigationError = String(error).slice(0, 300)
      }

      const snapshot = await inspectPage(page, name).catch((error) => ({
        title: null,
        chars: 0,
        liveViewConnected: false,
        primaryContent: false,
        tables: [],
        filterGroups: [],
        countSummaries: [],
        staleBanners: [],
        emptyStates: [],
        errorStates: [],
        kpis: [],
        capacityReadings: [],
        hasNAInMetric: false,
        navigationError: String(error).slice(0, 300)
      }))
      snapshot.status = status
      snapshot.navigationError ||= navigationError
      snapshot.capacityReadings = extractCapacityReadings(snapshot.kpis || [], snapshot.text)
      const assessment = analyzeDashboardSnapshot(name, snapshot, EXPECTED_CAPACITY, EXPECTED_ACTIVE_AGENTS)
      const unexpectedConsoleErrors = consoleErrors.filter((entry) => !isKnownNoise(entry, knownNoise))
      const unexpectedFailedRequests = failedRequests.filter((entry) => !isKnownNoise(entry, knownNoise))

      if (unexpectedConsoleErrors.length > 0) assessment.issues.push({ kind: 'console-errors', detail: `${unexpectedConsoleErrors.length} unexpected error(s)` })
      if (unexpectedFailedRequests.length > 0) assessment.issues.push({ kind: 'failed-requests', detail: `${unexpectedFailedRequests.length} unexpected failed request(s)` })
      assessment.verdict = assessment.issues.length === 0 ? 'healthy' : 'attention'
      assessment.route = route
      assessment.status = status
      assessment.elapsedMs = Date.now() - started
      assessment.consoleErrors = consoleErrors
      assessment.failedRequests = failedRequests
      assessment.knownNoise = {
        consoleErrors: consoleErrors.filter((entry) => isKnownNoise(entry, knownNoise)),
        failedRequests: failedRequests.filter((entry) => isKnownNoise(entry, knownNoise))
      }

      await page.screenshot({ path: path.join(OUT, `${name}.png`), fullPage: true }).catch((error) => {
        assessment.issues.push({ kind: 'screenshot', detail: String(error).slice(0, 300) })
        assessment.verdict = 'attention'
      })
      pages.push(assessment)
      await page.close()
    }
  } finally {
    await context.close()
    await browser.close()
  }

  const report = {
    checkedAt: new Date().toISOString(),
    baseUrl: BASE,
    viewport: { width: 1600, height: 1200 },
    settleMs: SETTLE_MS,
    expectedCapacity: EXPECTED_CAPACITY,
    expectedActiveAgents: EXPECTED_ACTIVE_AGENTS,
    verdict: pages.every((page) => page.verdict === 'healthy') ? 'healthy' : 'attention',
    pages
  }
  fs.writeFileSync(path.join(OUT, 'report.json'), `${JSON.stringify(report, null, 2)}\n`)
  fs.writeFileSync(path.join(OUT, 'verdict.md'), renderVerdict(report))
  console.log(JSON.stringify(report, null, 2))
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error.stack || error)
    process.exitCode = 1
  })
}
