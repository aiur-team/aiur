// Read-only performance sampling for a running Build home. It deliberately does
// not use run-browser-tests: that runner starts a synthetic fixture and removes
// dashboard credentials from the child environment.
import { chromium } from '@playwright/test'
import process from 'node:process'
import { createReport } from './build-home-perf-report.mjs'

// `close-ticket` only closes the client modal; it does not change the ticket.
// The target runner accepts it because opening and closing one modal is part of
// the read-only probe. Background subscription events are discarded below.
// `build:url` synchronizes route state after history paging; it does not write
// a ticket, queue, or conversation. It is therefore safe in this read-only run.
const allowedEvents = new Set(['build-resync', 'build:url', 'load-earlier', 'open-ticket', 'close-ticket', 'conversation-page', 'conversation-close'])

export async function runTarget({ page, baseURL, record }) {
  const frames = { resync: null, loadEarlier: 0, events: [] }
  page.on('websocket', socket => observeFrames(socket, frames))
  await page.addInitScript(() => sessionStorage.setItem('bd-perf', '1'))
  await page.goto(new URL('/', baseURL).href)
  await page.locator('#build-root').waitFor({ state: 'attached', timeout: 30_000 })
  await page.locator('#bd-content .bd-card').first().waitFor({ state: 'visible', timeout: 30_000 })

  const population = await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    return {
      history_total: ctx.snap.history.total,
      rows: Object.fromEntries(Object.entries(ctx.snap.sections).map(([key, rows]) => [key, rows.length])),
      active_agents: ctx.D.now.filter(row => row.agent?.state === 'active').length
    }
  })

  await recordMeasure(record, 'C1', async () => measure(page, 'bd:first-board'), 'ms')
  await recordMeasure(record, 'C2', () => scrollP95(page), 'ms')
  await recordMeasure(record, 'C7', () => heap(page), 'B')

  // Mounting starts harmless background subscriptions; measure only the actions
  // this probe drives, then use the page's own history control for span=30.
  frames.events = []; frames.loadEarlier = 0
  await page.evaluate(async () => (await import('/build-home/history.js')).ensureDays(30))
  await page.locator('#bd-content .bd-card').first().click()
  await page.keyboard.press('Escape')

  record('W1', frames.resync === null ? { unavailable: 'build-resync reply not observed' } : { value: frames.resync, unit: 'B' }, { context: 'real', budget: { max: 65_536 } })
  record('C12', { value: frames.loadEarlier, unit: 'requests' }, { context: 'real', budget: { max: 2 } })
  return { population, events: frames.events }
}

function observeFrames(socket, frames) {
  socket.on('framesent', ({ payload }) => {
    const frame = parse(payload)
    if (frame?.[3] === 'event') {
      frames.events.push(frame[4]?.event)
      if (frame[4]?.event === 'load-earlier') frames.loadEarlier += 1
    }
  })
  socket.on('framereceived', ({ payload }) => {
    const frame = parse(payload)
    if (frame?.[3] === 'phx_reply' && frame[4]?.response?.kind === 'snapshot') frames.resync = Buffer.byteLength(String(payload))
  })
}

async function recordMeasure(record, id, read, unit) {
  try {
    record(id, { value: await read(), unit }, { context: 'real' })
  } catch (error) {
    record(id, { unavailable: String(error.message ?? error).split('\n')[0] }, { context: 'real' })
  }
}

async function measure(page, name) {
  const value = await page.evaluate(name => performance.getEntriesByName(name).at(-1)?.duration, name)
  if (!Number.isFinite(value)) throw new Error(`${name} was not measured`)
  return value
}

async function scrollP95(page) {
  const samples = await page.evaluate(() => new Promise(resolve => {
    const values = [], viewport = document.querySelector('#bd-vp')
    let previous = performance.now(), steps = 0
    const frame = now => {
      values.push(now - previous); previous = now; viewport.scrollTop += 300; steps += 1
      if (steps === 60) resolve(values); else requestAnimationFrame(frame)
    }
    requestAnimationFrame(frame)
  }))
  return samples.sort((left, right) => left - right)[Math.ceil(samples.length * 0.95) - 1]
}

async function heap(page) {
  const cdp = await page.context().newCDPSession(page)
  await cdp.send('Performance.enable')
  await cdp.send('HeapProfiler.collectGarbage')
  const { metrics } = await cdp.send('Performance.getMetrics')
  const value = metrics.find(metric => metric.name === 'JSHeapUsedSize')?.value
  if (!Number.isFinite(value)) throw new Error('JS heap metric unavailable')
  return value
}

function parse(payload) {
  try { return JSON.parse(String(payload)) } catch { return null }
}

function args(argv) {
  const values = new Map()
  for (let index = 0; index < argv.length; index += 2) values.set(argv[index], argv[index + 1])
  return values
}

async function main() {
  const values = args(process.argv.slice(2)), baseURL = values.get('--target'), commit = values.get('--commit') ?? 'unknown'
  if (!baseURL) throw new Error('usage: perf:build-home:target -- --target <dashboard-url> [--commit <sha>] [--out <directory>]')
  const username = process.env.AIUR_DASHBOARD_USERNAME, password = process.env.AIUR_DASHBOARD_PASSWORD
  if (!username || !password) throw new Error('AIUR_DASHBOARD_USERNAME and AIUR_DASHBOARD_PASSWORD are required')
  const browser = await chromium.launch(), context = await browser.newContext({ httpCredentials: { username, password } })
  const report = createReport({ commit })
  try {
    const result = await runTarget({ page: await context.newPage(), baseURL, record: report.record.bind(report) })
    process.stdout.write(`build-home target population: ${JSON.stringify(result.population)}\n`)
  } finally {
    await context.close(); await browser.close()
  }
  await report.write(values.get('--out') ?? process.env.AIUR_BROWSER_ARTIFACT_DIR ?? '.artifacts/build-home-perf')
}

if (import.meta.url === new URL(process.argv[1], 'file:').href) main().catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1 })

export { allowedEvents }
