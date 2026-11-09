import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { allowedEvents, runTarget } from '../scripts/build-home-perf-target.mjs'

// Enforced build-home performance budgets (MP-E8-C12-T06). CI runners are shared and noisy,
// so this spec gates only bytes and counts. First-paint timing gets a loose absolute ceiling
// with CI-variance headroom; the dense/scale ratio is report-only. The full timing table runs
// in report mode (npm run perf:build-home).
const BUDGETS = {
  resyncFrameBytes: 65_536, // W1: the same bound as the S1 snapshot, seen from the browser
  resyncGrowthBytes: 2_048, // W1: 10,000 tickets may not grow the window
  cardsPerFit: 3, // B1: render window bounded at any history depth
  transcriptDom: 500, // B2: C11-T03 MAX_DOM
  firstPaintMs: 3_000, // B4: generous CI ceiling; report mode holds 1,500 ms
  modalLeakBytes: 10 * 1_048_576, // B5: 20 open/close cycles
  spanRequests: 2 // B7: ensureDays sends one days:29 request
}
const dense = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/dense.json', import.meta.url), 'utf8'))
const perfTicket = dense.sections.now[0].id // Scale.perf_ticket_id(dense): its scale10k transcript has 5,000 entries

test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 }, timezoneId: 'America/Los_Angeles' })

async function open(browser, { perf = false, blockStorage = false } = {}) {
  const context = await browser.newContext({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 }, timezoneId: 'America/Los_Angeles' })
  await context.addInitScript(({ perf, blockStorage }) => {
    if (perf) sessionStorage.setItem('bd-perf', '1')
    // Only getItem fails, so other modules' storage use is not what breaks.
    if (blockStorage) Storage.prototype.getItem = () => { throw new DOMException('blocked', 'SecurityError') }
  }, { perf, blockStorage })
  const page = await context.newPage()
  const errors = []
  page.on('pageerror', error => errors.push(error))
  return { context, page, errors }
}

async function load(page, dataset, query = '') {
  await page.goto(`/build-fixture/${dataset}${query}`)
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/state.js')).ctx.D?.now.length > 0), { timeout: 20_000 }).toBe(true)
  await expect(page.locator('#bd-content .bd-card').first()).toBeVisible()
}

const measures = page => page.evaluate(() => performance.getEntriesByType('measure').filter(m => m.name.startsWith('bd:')).map(m => m.name))

async function cardCounts(page) {
  return page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    return { rendered: ctx.R.size, fits: Math.ceil(ctx.vp.clientHeight / ctx.L.pitch) * Math.max(1, ctx.cols.length) }
  })
}

test('P1 perf.js is off by default: no measures and timed() is the identity', async ({ browser }) => {
  const { context, page } = await open(browser)
  try {
    await load(page, 'live')
    expect(await measures(page)).toEqual([])
    expect(await page.evaluate(async () => { const { timed } = await import('/build-home/perf.js'); const fn = () => 1; return timed('x', fn) === fn })).toBe(true)
  } finally { await context.close() }
})

test('P2 perf.js records the hot path when the tab opts in', async ({ browser }) => {
  const { context, page } = await open(browser, { perf: true })
  try {
    await load(page, 'live')
    await page.evaluate(async () => {
      const { ctx } = await import('/build-home/state.js')
      ctx.vp.scrollTop += 300; ctx.vp.dispatchEvent(new Event('scroll'))
    })
    const expected = ['bd:first-board', 'bd:relayout', 'bd:update', 'bd:drawEdges']
    await expect.poll(async () => { const names = new Set(await measures(page)); return expected.filter(name => !names.has(name)) }).toEqual([])
  } finally { await context.close() }
})

test('P3 blocked storage keeps the page working with timing off', async ({ browser }) => {
  const { context, page, errors } = await open(browser, { perf: true, blockStorage: true })
  try {
    await load(page, 'live')
    expect(errors).toEqual([])
    expect(await measures(page)).toEqual([])
  } finally { await context.close() }
})

test('P4 every wrap is on the binding its callers use', async ({ browser }) => {
  test.setTimeout(60_000)
  const { context, page } = await open(browser, { perf: true })
  try {
    await load(page, 'live')
    // Chain hover runs with dependency trees on, over a history card (band cards do not highlight chains).
    await page.evaluate(async () => { (await import('/build-home/state.js')).S.trees = true })
    await page.locator('#bd-sec-hist .bd-card').first().hover()
    await page.setViewportSize({ width: 1100, height: 900 })
    await page.waitForTimeout(400) // the design's 220 ms column debounce
    await page.setViewportSize({ width: 1440, height: 900 })
    await page.getByRole('tab', { name: 'List', exact: true }).click()
    await page.getByRole('tab', { name: 'Timeline', exact: true }).click()
    expect(await page.request.get('/build-control/diff?name=card-pct-null').then(r => r.status())).toBe(200)
    await page.evaluate(async () => { const hist = await import('/build-home/history.js'); await hist.loadEarlier(1) })
    const expected = ['bd:chainOf', 'bd:applyCols', 'bd:renderList', 'bd:applyDiff', 'bd:mergeEarlier']
    await expect.poll(async () => { const names = new Set(await measures(page)); return expected.filter(name => !names.has(name)) }).toEqual([])
  } finally { await context.close() }
})

test('guard: B1 render window stays bounded at 10,000 tickets and 91 loaded days', async ({ browser }) => {
  test.setTimeout(60_000)
  const { context, page } = await open(browser)
  try {
    await load(page, 'scale10k')
    const band = await cardCounts(page)
    expect(band.rendered).toBeLessThanOrEqual(BUDGETS.cardsPerFit * band.fits)
    const loaded = await page.evaluate(async () => {
      const { ctx, fx } = await import('/build-home/state.js'), hist = await import('/build-home/history.js'), { histDays } = await import('/build-home/layout.js')
      await hist.ensureDays(91)
      ctx.vp.scrollTop = Math.floor(ctx.vp.scrollHeight / 3); fx.update()
      return histDays(ctx.D.hist).length
    })
    expect(loaded).toBeGreaterThanOrEqual(91)
    const deep = await cardCounts(page)
    expect(deep.rendered).toBeLessThanOrEqual(BUDGETS.cardsPerFit * deep.fits)
  } finally { await context.close() }
})

test('guard: B2 transcript DOM stays capped while paging a 5,000-entry log', async ({ browser }) => {
  test.setTimeout(90_000)
  const { context, page } = await open(browser, { perf: true })
  try {
    await load(page, 'scale10k')
    await page.evaluate(async id => {
      const { ctx } = await import('/build-home/state.js'), { openModal } = await import('/build-home/modal/frame.js')
      window.pages = 0; const push = ctx.push
      ctx.push = (event, payload) => push(event, payload).then(reply => { if (event === 'conversation-page' && payload.before) window.pages++; return reply })
      openModal(ctx.D.byId[id])
    }, perfTicket)
    const rows = page.locator('#cv-log [data-k]')
    await expect(rows).toHaveCount(100)
    // CI pages 8 times (900 entries fetched); report mode pages to more:false.
    for (let fetched = 1; fetched <= 8; fetched++) {
      await page.locator('#cv-log').evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')) })
      await expect.poll(() => page.evaluate(() => window.pages)).toBeGreaterThanOrEqual(fetched)
      expect(await rows.count()).toBeLessThanOrEqual(BUDGETS.transcriptDom)
    }
    expect(new Set(await measures(page)).has('bd:convPage')).toBe(true)
  } finally { await context.close() }
})

async function resyncFrameBytes(browser, dataset) {
  const { context, page } = await open(browser)
  try {
    const sent = new Map(), replies = new Map()
    page.on('websocket', ws => {
      ws.on('framesent', ({ payload }) => {
        const frame = parse(payload)
        if (frame?.[3] === 'event' && frame[4]?.event === 'build-resync') sent.set(frame[1], true)
      })
      ws.on('framereceived', ({ payload }) => {
        const frame = parse(payload)
        if (frame?.[3] === 'phx_reply') replies.set(frame[1], Buffer.byteLength(String(payload)))
      })
    })
    await load(page, dataset)
    await expect.poll(() => [...sent.keys()].some(ref => replies.has(ref))).toBe(true)
    return replies.get([...sent.keys()].find(ref => replies.has(ref)))
  } finally { await context.close() }
}
function parse(payload) { try { return JSON.parse(String(payload)) } catch { return null } }

test('guard: B3 resync frame size does not grow with history', async ({ browser }) => {
  const small = await resyncFrameBytes(browser, 'dense'), large = await resyncFrameBytes(browser, 'scale10k')
  test.info().annotations.push({ type: 'W1', description: `dense=${small}B scale10k=${large}B` })
  expect(small).toBeLessThanOrEqual(BUDGETS.resyncFrameBytes)
  expect(large).toBeLessThanOrEqual(BUDGETS.resyncFrameBytes)
  expect(Math.abs(large - small)).toBeLessThanOrEqual(BUDGETS.resyncGrowthBytes)
})

test('B4 first paint stays within the CI ceiling at 10,000 tickets', async ({ browser }) => {
  test.setTimeout(90_000)
  const median = async dataset => {
    const samples = []
    for (let run = 0; run < 4; run++) {
      const { context, page } = await open(browser, { perf: true })
      try {
        await load(page, dataset)
        const [entry] = await page.evaluate(() => performance.getEntriesByName('bd:first-board').map(m => m.duration))
        if (run > 0) samples.push(entry) // the first load builds the dataset in the fixture VM
      } finally { await context.close() }
    }
    return samples.sort((a, b) => a - b)[1]
  }
  const small = await median('dense'), large = await median('scale10k')
  // Navigation-to-paint includes network and fixture-VM work, so this ratio is useful evidence
  // for report readers but not a stable shared-runner correctness gate.
  test.info().annotations.push({ type: 'C1', description: `dense=${Math.round(small)}ms scale10k=${Math.round(large)}ms ratio=${(large / small).toFixed(2)} report-only` })
  expect(large).toBeLessThanOrEqual(BUDGETS.firstPaintMs)
})

test('B5 modal open and close do not leak', async ({ browser }) => {
  test.setTimeout(90_000)
  const { context, page } = await open(browser)
  try {
    await load(page, 'live')
    const cdp = await context.newCDPSession(page)
    await cdp.send('Performance.enable')
    const heap = async () => {
      await cdp.send('HeapProfiler.collectGarbage')
      const { metrics } = await cdp.send('Performance.getMetrics')
      return metrics.find(m => m.name === 'JSHeapUsedSize').value
    }
    const cycle = () => page.evaluate(async () => {
      const { ctx } = await import('/build-home/state.js'), { openModal, closeModal } = await import('/build-home/modal/frame.js')
      openModal(ctx.D.now[0])
      for (let i = 0; i < 100 && !document.querySelector('#cv-log [data-k]'); i++) await new Promise(resolve => setTimeout(resolve, 20))
      closeModal()
    })
    await cycle()
    const before = await heap()
    for (let i = 0; i < 20; i++) await cycle()
    const growth = (await heap()) - before
    test.info().annotations.push({ type: 'C7', description: `20 modal cycles grew ${Math.round(growth / 1024)} KiB` })
    expect(growth).toBeLessThanOrEqual(BUDGETS.modalLeakBytes)
  } finally { await context.close() }
})

test('guard: B7 span 30 fills with one load-earlier request', async ({ browser }) => {
  const { context, page } = await open(browser)
  try {
    await page.addInitScript(() => {
      window.spanRequests = []
      const send = WebSocket.prototype.send
      WebSocket.prototype.send = function (body) {
        const payload = typeof body === 'string' ? JSON.parse(body).at(-1) : null
        if (payload?.event === 'load-earlier') window.spanRequests.push(payload.value)
        return send.call(this, body)
      }
    })
    await load(page, 'scale10k')
    // Nested harness HTTP routes drop queries; mount with a real LiveView navigation.
    await page.evaluate(() => window.liveSocket.main.pushLinkPatch(new Event('click'), '/commands', null))
    await expect(page.locator('#build-root')).toHaveCount(0)
    await page.evaluate(() => { window.spanRequests = []; window.liveSocket.main.pushLinkPatch(new Event('click'), '/build?span=30', null) })
    await expect.poll(() => page.evaluate(async () => (await import('/build-home/state.js')).S.span)).toBe(30)
    await expect.poll(() => page.evaluate(async () => {
      const { ctx } = await import('/build-home/state.js'), { H } = await import('/build-home/history.js'), { histDays } = await import('/build-home/layout.js')
      return !!ctx.D && H.state === 'idle' && histDays(ctx.D.hist).length >= 30
    }), { timeout: 20_000 }).toBe(true)
    const requests = await page.evaluate(() => window.spanRequests)
    expect(requests.length).toBeGreaterThanOrEqual(1)
    expect(requests.length).toBeLessThanOrEqual(BUDGETS.spanRequests)
    expect(requests[0].days).toBe(29)
  } finally { await context.close() }
})

test('B6 target run is read-only against the production route', async ({ browser, baseURL }) => {
  test.setTimeout(60_000)
  const context = await browser.newContext({ httpCredentials: dashboardCredentials })
  const page = await context.newPage(), requests = [], rows = []
  page.on('request', request => requests.push(new URL(request.url()).pathname))
  try {
    const result = await runTarget({ page, baseURL, record: (id, measurement) => rows.push({ id, measurement }) })
    expect(requests).not.toContain('/build-fixture/scale10k')
    expect(requests).not.toContain('/auth/read_only')
    const unexpected = result.events.filter(event => event && !allowedEvents.has(event))
    expect(unexpected, `target emitted unexpected events: ${unexpected.join(', ')}`).toEqual([])
    expect(rows.map(row => row.id)).toEqual(expect.arrayContaining(['C1', 'C2', 'C7', 'C12', 'W1']))
  } finally { await context.close() }
})
