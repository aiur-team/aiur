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
import {
  DEFAULT_KNOWN_NOISE,
  analyzeDashboardSnapshot,
  extractCapacityReadings,
  renderVerdict,
  didNotRunVerdict,
  timedOutAssessment,
  PageTimeoutError,
  withPageTimeout,
  pageLabel
} from './dashboard-analysis.mjs'

// Preserve the capture entry point's public helper exports for existing callers.
export {
  DEFAULT_KNOWN_NOISE,
  analyzeDashboardSnapshot,
  extractCapacityReadings,
  renderVerdict,
  didNotRunVerdict,
  timedOutAssessment,
  PageTimeoutError,
  withPageTimeout
} from './dashboard-analysis.mjs'

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url))
const REPOSITORY_ROOT = path.resolve(SCRIPT_DIR, '../../../../')
const BASE = process.env.AIUR_DASHBOARD_URL
const USER = process.env.AIUR_DASHBOARD_USERNAME || 'aiur'
const PASS = process.env.AIUR_DASHBOARD_PASSWORD
const OUT = process.argv[2] || './meta-captures'
const SETTLE_MS = positiveInteger(process.env.AIUR_META_SETTLE_MS, 6000)
// Hard bound for one page's whole turn (navigation + settle + inspection +
// screenshot). A page that stalls past this is reported as a timeout verdict
// naming the page, a partial screenshot is written, and the next page proceeds
// instead of the run hanging in silence. The bound sits well above a healthy
// page's nominal budget (45s navigation + 6s settle), so it catches a genuine
// hang without labelling a slow-but-healthy page as a timeout.
const PAGE_TIMEOUT_MS = positiveInteger(process.env.AIUR_META_PAGE_TIMEOUT_MS, 120_000)
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
          label: button.getAttribute('data-count-label') || button.innerText.trim(),
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

async function runPageCapture(page, name, route, knownNoise) {
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
  return assessment
}

// Bound one page's whole capture turn so a hung page yields a timeout verdict
// naming the page, keeps whatever partial screenshot completed, and lets the
// remaining pages proceed instead of the run hanging in silence. newPage and
// runCapture are injected so the loop's use of the bound is testable without
// launching a browser; main() supplies context.newPage() and a runCapture that
// closes over the page's own navigation/settle/inspection.
export async function capturePageBounded(newPage, runCapture, name, route, timeoutMs) {
  const page = await newPage()
  let assessment
  try {
    assessment = await withPageTimeout(runCapture(page), timeoutMs, name)
  } catch (error) {
    if (error instanceof PageTimeoutError) {
      // The page hung past its bound. Keep whatever partial screenshot exists
      // so a hang reads as evidence, not silence.
      await page.screenshot({ path: path.join(OUT, `${name}.png`), fullPage: true }).catch(() => {})
      assessment = timedOutAssessment(name, route, timeoutMs, error)
    } else {
      assessment = {
        name,
        verdict: 'attention',
        route,
        status: null,
        timedOut: false,
        elapsedMs: timeoutMs,
        issues: [{ kind: 'capture-error', detail: `${pageLabel(name)} capture failed: ${String(error).slice(0, 200)}` }],
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
  } finally {
    await page.close().catch(() => {})
  }
  return assessment
}

// Write the precondition "did not run" evidence so a direct invocation of this
// script (not just the wrapper) can never produce silence on a skipped run.
function writeDidNotRun(out, detail) {
  fs.writeFileSync(path.join(out, 'verdict.md'), didNotRunVerdict(detail))
  fs.writeFileSync(path.join(out, 'report.json'), `${JSON.stringify({
    checkedAt: new Date().toISOString(),
    baseUrl: BASE || null,
    verdict: 'did-not-run',
    precondition: detail,
    pages: []
  }, null, 2)}\n`)
}

async function main() {
  // A precondition failure must never look like a pass: it exits non-zero and
  // writes a "did not run" verdict rather than the "attention" one a completed
  // capture produces. The exit codes are distinct so a wrapper can tell which
  // precondition failed (67 = URL missing, 69 = password missing).
  fs.mkdirSync(OUT, { recursive: true })
  if (!BASE) {
    console.error('AIUR_DASHBOARD_URL is required; set it or run through executor-retrospective.sh to discover the daemon URL.')
    writeDidNotRun(OUT, 'AIUR_DASHBOARD_URL is not set; no dashboard URL to capture.')
    process.exitCode = 67
    return
  }

  if (!PASS) {
    console.error('AIUR_DASHBOARD_PASSWORD is required; set it or let executor-retrospective.sh read it from the running daemon.')
    writeDidNotRun(OUT, 'AIUR_DASHBOARD_PASSWORD is not set; the dashboard refuses all requests without it.')
    process.exitCode = 69
    return
  }

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
      const assessment = await capturePageBounded(
        () => context.newPage(),
        (page) => runPageCapture(page, name, route, knownNoise),
        name,
        route,
        PAGE_TIMEOUT_MS
      )
      pages.push(assessment)
      process.stdout.write(`assessed ${name}: ${assessment.verdict} in ${assessment.elapsedMs} ms\n`)
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
    pageTimeoutMs: PAGE_TIMEOUT_MS,
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
