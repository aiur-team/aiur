import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { createReport } from '../scripts/build-home-perf-report.mjs'

// Report mode for MP-E8-C12-T06: `npm run perf:build-home`. Measures every client metric in
// desktop (D) and phone emulation (P) and writes build-home-perf.{json,md} to the artifact dir.
// Timings depend on the host, so nothing here gates CI; build-home-performance.browser.spec.mjs
// holds the enforced byte, count and ratio guards. Phone emulation is a CI proxy only (EC-27
// needs the device run).
const BUDGETS = {
  C1: { D: 1_500, P: 3_500 }, C2: { D: 20, P: 50 }, C3: { D: 3, P: 3 }, C4: { D: 8, P: 30 },
  C5_30: { D: 60 }, C5_90: { D: 150 }, C6_90: { D: 16 }, C6_all: { D: 50 },
  C7_first: { D: 40 }, C7_90: { D: 80 }, C7_modal: { D: 5 }, C8_open: { D: 400, P: 1_000 }, C8_dom: { D: 500, P: 500 },
  C8_page: { D: 16 }, C8_heap: { D: 25 }, C9: { D: 250, P: 900 }, C10: { D: 20, P: 50 }, C11: { D: 409_600 },
  C12_requests: { D: 2 }, C12_ms: { D: 1_500 }, C13: { D: 150 }, C14_chain: { D: 4 }, C14_hover: { D: 16 },
  C15: { D: 16 }, C16: { D: 5_000 }, C17: { P: 10 }, W1: { D: 65_536, P: 65_536 }
}
const CONTEXTS = {
  D: { viewport: { width: 1440, height: 900 } },
  P: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, throttle: 4 }
}
const dense = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/dense.json', import.meta.url), 'utf8'))
const perfTicket = dense.sections.now[0].id
const MiB = 1_048_576
// A failed test restarts the worker and re-evaluates this module, so rows written so far are reloaded.
const dir = process.env.AIUR_BROWSER_ARTIFACT_DIR ?? '.artifacts/unmanaged'
const report = createReport()
report.rows.push(...await readFile(path.join(dir, 'build-home-perf.json'), 'utf8').then(JSON.parse, () => []))

test.use({ trace: 'off', screenshot: 'off' })
test.afterEach(async () => { await report.write(dir) })

function record(id, context, key, measure) {
  const budget = BUDGETS[key]?.[context]
  return measure().then(
    ({ value, unit }) => report.record(id, { value, unit }, { context, budget: budget === undefined ? null : { max: budget } }),
    error => report.record(id, { unavailable: String(error.message ?? error).split('\n')[0].slice(0, 160) }, { context, budget: budget === undefined ? null : { max: budget } })
  )
}

async function session(browser, name, { palette } = {}) {
  const { throttle, ...options } = CONTEXTS[name]
  const context = await browser.newContext({ ...options, httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles' })
  await context.addInitScript(palette => {
    sessionStorage.setItem('bd-perf', '1')
    if (palette) document.addEventListener('DOMContentLoaded', () => { document.documentElement.dataset.palette = palette })
  }, palette ?? null)
  const page = await context.newPage()
  const cdp = await context.newCDPSession(page)
  await cdp.send('Performance.enable')
  if (throttle) await cdp.send('Emulation.setCPUThrottlingRate', { rate: throttle })
  const bytes = { js: 0, css: 0, font: 0, image: 0 }
  page.on('response', async response => {
    const type = response.request().resourceType(), url = response.url()
    const kind = type === 'script' ? 'js' : type === 'stylesheet' ? 'css' : type === 'font' ? 'font' : type === 'image' ? 'image' : null
    if (!kind || !/\/(build-home|dashboard\.css|assets|fonts|aiur-logo)/.test(url)) return
    try { bytes[kind] += (await response.body()).length } catch { /* redirected or aborted */ }
  })
  const frames = { resync: null }
  page.on('websocket', ws => {
    // Only the newest socket counts: a previous page's socket can still deliver frames after navigation.
    const sent = new Set(); frames.ws = ws
    ws.on('framesent', ({ payload }) => { const f = parse(payload); if (f?.[3] === 'event' && f[4]?.event === 'build-resync') sent.add(f[1]) })
    ws.on('framereceived', ({ payload }) => { const f = parse(payload); if (frames.ws === ws && f?.[3] === 'phx_reply' && sent.has(f[1]) && frames.resync === null) frames.resync = Buffer.byteLength(String(payload)) })
  })
  const heap = async () => {
    await cdp.send('HeapProfiler.collectGarbage')
    const { metrics } = await cdp.send('Performance.getMetrics')
    return metrics.find(m => m.name === 'JSHeapUsedSize').value
  }
  return { context, page, bytes, frames, heap }
}
function parse(payload) { try { return JSON.parse(String(payload)) } catch { return null } }

async function load(page, dataset) {
  await page.goto(`/build-fixture/${dataset}`)
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/state.js')).ctx.D?.now.length > 0), { timeout: 60_000 }).toBe(true)
}

const durations = (page, name, since = 0) => page.evaluate(({ name, since }) => performance.getEntriesByName('bd:' + name).filter(m => m.startTime >= since).map(m => m.duration), { name, since })
const now = page => page.evaluate(() => performance.now())
const p95 = values => { if (!values.length) throw new Error('no samples'); const sorted = [...values].sort((a, b) => a - b); return sorted[Math.min(sorted.length - 1, Math.floor(0.95 * sorted.length))] }
const last = values => { if (!values.length) throw new Error('no samples'); return values.at(-1) }

// rAF intervals over 60 scripted 300 px steps.
const scrollFrames = page => page.evaluate(async () => {
  const { ctx } = await import('/build-home/state.js')
  const gaps = []; let prev = performance.now()
  for (let i = 0; i < 60; i++) {
    ctx.vp.scrollTop += (i < 30 ? 300 : -300); ctx.vp.dispatchEvent(new Event('scroll'))
    await new Promise(resolve => requestAnimationFrame(resolve))
    const t = performance.now(); gaps.push(t - prev); prev = t
  }
  return gaps
})

for (const name of ['D', 'P']) {
  test(`report ${name}: board, scroll, paging, list, gantt, hover, columns, idle and page weight`, async ({ browser }) => {
    test.setTimeout(600_000)
    const s = await session(browser, name)
    try {
      const { page } = s
      await load(page, 'dense')
      await record('C1 dense', name, 'C1', async () => ({ value: last(await durations(page, 'first-board')), unit: 'ms' }))
      await record('W1 dense', name, 'W1', async () => { await expect.poll(() => s.frames.resync).not.toBeNull(); return { value: s.frames.resync, unit: 'B' } })
      await record('C11 home JS + CSS', name, 'C11', async () => ({ value: s.bytes.js + s.bytes.css, unit: 'B' }))
      await record('C11 fonts', name, null, async () => ({ value: s.bytes.font, unit: 'B' }))
      await record('C11 images (icon)', name, null, async () => ({ value: s.bytes.image, unit: 'B' }))

      s.frames.resync = null
      await load(page, 'scale10k')
      await record('C1 scale10k', name, 'C1', async () => ({ value: last(await durations(page, 'first-board')), unit: 'ms' }))
      await record('W1 scale10k', name, 'W1', async () => { await expect.poll(() => s.frames.resync).not.toBeNull(); return { value: s.frames.resync, unit: 'B' } })
      await record('C7 heap at first paint', name, 'C7_first', async () => ({ value: (await s.heap()) / MiB, unit: 'MiB' }))
      let since = await now(page)
      await record('C2 scroll frame p95', name, 'C2', async () => ({ value: p95(await scrollFrames(page)), unit: 'ms' }))
      await record('C4 drawEdges p95', name, 'C4', async () => ({ value: p95(await durations(page, 'drawEdges', since)), unit: 'ms' }))
      await record('C3 cards per fit (band)', name, 'C3', () => page.evaluate(async () => {
        const { ctx } = await import('/build-home/state.js')
        return { value: ctx.R.size / (Math.ceil(ctx.vp.clientHeight / ctx.L.pitch) * Math.max(1, ctx.cols.length)), unit: 'x' }
      }))

      const relayoutAt = days => page.evaluate(async days => {
        const { ctx, fx } = await import('/build-home/state.js'), hist = await import('/build-home/history.js'), { histDays } = await import('/build-home/layout.js')
        await hist.ensureDays(days)
        const start = performance.now(); fx.relayout(); fx.update()
        const [m] = performance.getEntriesByName('bd:relayout').filter(e => e.startTime >= start)
        return { value: m.duration, unit: 'ms', days: histDays(ctx.D.hist).length, rows: ctx.D.hist.length }
      }, days)
      await record('C5 relayout at 30 days', name, 'C5_30', () => relayoutAt(30))
      await record('C5 relayout at 90 days', name, 'C5_90', () => relayoutAt(90))
      await record('C3 cards per fit (90 days)', name, 'C3', () => page.evaluate(async () => {
        const { ctx, fx } = await import('/build-home/state.js')
        ctx.vp.scrollTop = Math.floor(ctx.vp.scrollHeight / 3); fx.update()
        return { value: ctx.R.size / (Math.ceil(ctx.vp.clientHeight / ctx.L.pitch) * Math.max(1, ctx.cols.length)), unit: 'x' }
      }))
      await record('C7 heap at 90 days', name, 'C7_90', async () => ({ value: (await s.heap()) / MiB, unit: 'MiB' }))
      since = await now(page)
      await page.request.get('/build-control/diff?name=card-pct-null')
      await record('C6 applyDiff at 90 days', name, 'C6_90', async () => { await expect.poll(async () => (await durations(page, 'applyDiff', since)).length).toBeGreaterThan(0); return { value: last(await durations(page, 'applyDiff', since)), unit: 'ms' } })

      await record('C14 chainOf p95 (20 hovers)', name, 'C14_chain', async () => {
        if (name === 'P') throw new Error('touch devices have no hover')
        since = await now(page)
        // Pointer hover on rendered history cards; a scroll in between would suppress hover (the .scrolling guard).
        await page.evaluate(async () => {
          const { S, ctx } = await import('/build-home/state.js')
          S.trees = true; ctx.content.classList.remove('scrolling')
          const cards = [...ctx.R.values()].filter(el => el.closest('#bd-sec-hist'))
          for (let i = 0; i < 20 && cards.length; i++) {
            cards[i % cards.length].dispatchEvent(new PointerEvent('pointerover', { bubbles: true, pointerType: 'mouse' }))
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
          }
        })
        return { value: p95(await durations(page, 'chainOf', since)), unit: 'ms' }
      })
      await record('C14 hover edge redraw p95', name, 'C14_hover', async () => {
        if (name === 'P') throw new Error('touch devices have no hover')
        return { value: p95(await durations(page, 'drawEdges', since)), unit: 'ms' }
      })
      await record('C15 applyCols p95 (1440 -> 1100 -> 1440)', name, 'C15', async () => {
        const start = await now(page), base = CONTEXTS[name].viewport
        await page.setViewportSize({ width: Math.round(base.width * 1100 / 1440), height: base.height }); await page.waitForTimeout(400)
        await page.setViewportSize(base); await page.waitForTimeout(400)
        return { value: p95(await durations(page, 'applyCols', start)), unit: 'ms' }
      })
      await record('C13 gantt relayout at 90 days', name, 'C13', () => page.evaluate(async () => {
        const { fx } = await import('/build-home/state.js')
        fx.setView('gantt'); const start = performance.now(); fx.relayout()
        const [m] = performance.getEntriesByName('bd:relayout').filter(e => e.startTime >= start)
        fx.setView('graph')
        return { value: m.duration, unit: 'ms' }
      }))
      await record('C5 relayout per 1,000 rows (all loaded)', name, null, () => page.evaluate(async () => {
        const { ctx, fx } = await import('/build-home/state.js'), hist = await import('/build-home/history.js')
        while (hist.H.more && await hist.loadEarlier(31));
        const start = performance.now(); fx.relayout()
        const [m] = performance.getEntriesByName('bd:relayout').filter(e => e.startTime >= start)
        return { value: m.duration / (ctx.D.hist.length / 1000), unit: 'ms/1k rows' }
      }))
      since = await now(page)
      await page.request.get('/build-control/diff?name=card-pct-null')
      await record('C6 applyDiff with all history', name, 'C6_all', async () => { await expect.poll(async () => (await durations(page, 'applyDiff', since)).length).toBeGreaterThan(0); return { value: last(await durations(page, 'applyDiff', since)), unit: 'ms' } })

      await load(page, 'nq1000')
      await record('C9 list view, 1,000 not-queued rows', name, 'C9', async () => {
        since = await now(page)
        await page.evaluate(async () => (await import('/build-home/state.js')).fx.setView('list'))
        return { value: last(await durations(page, 'renderList', since)), unit: 'ms' }
      })

      await load(page, 'agents20')
      await record('C10 idle frame p95, 20 active agents', name, 'C10', () => page.evaluate(async () => {
        const gaps = []; let prev = performance.now(); const end = prev + 5_000
        while (performance.now() < end) { await new Promise(resolve => requestAnimationFrame(resolve)); const t = performance.now(); gaps.push(t - prev); prev = t }
        gaps.sort((a, b) => a - b)
        return { value: gaps[Math.floor(0.95 * gaps.length)], unit: 'ms' }
      }))
      await record('C16 feature focus paging (d0)', name, 'C16', async () => { throw new Error('not scripted: feature focus paging needs C10-T03 loadFeatureSpan, absent on main') })
    } finally { await s.context.close() }
  })

  test(`report ${name}: span 30, modal leak, 5,000-entry transcript`, async ({ browser }) => {
    test.setTimeout(600_000)
    const s = await session(browser, name)
    try {
      const { page } = s
      await load(page, 'scale10k')
      await record('C12 span=30 fill', name, 'C12_ms', () => page.evaluate(async () => {
        const { ctx } = await import('/build-home/state.js'), hist = await import('/build-home/history.js')
        let requests = 0; const push = ctx.push
        ctx.push = (event, payload) => { if (event === 'load-earlier') requests++; return push(event, payload) }
        const start = performance.now(); await hist.ensureDays(30)
        window.spanRequests = requests; ctx.push = push
        return { value: performance.now() - start, unit: 'ms' }
      }))
      await record('C12 span=30 requests', name, 'C12_requests', async () => ({ value: await page.evaluate(() => window.spanRequests), unit: 'requests' }))

      const before = await s.heap()
      await record('C7 heap growth, 20 modal cycles', name, 'C7_modal', async () => {
        for (let i = 0; i < 20; i++) await page.evaluate(async () => {
          const { ctx } = await import('/build-home/state.js'), { openModal, closeModal } = await import('/build-home/modal/frame.js')
          openModal(ctx.D.now[1] ?? ctx.D.now[0])
          for (let j = 0; j < 100 && !document.querySelector('#cv-log [data-k]'); j++) await new Promise(resolve => setTimeout(resolve, 20))
          closeModal()
        })
        return { value: ((await s.heap()) - before) / MiB, unit: 'MiB' }
      })

      const modalStart = await s.heap()
      await record('C8 modal open to first entries (5,000-entry log)', name, 'C8_open', () => page.evaluate(async id => {
        const { ctx } = await import('/build-home/state.js'), { openModal } = await import('/build-home/modal/frame.js')
        const start = performance.now(); openModal(ctx.D.byId[id])
        while (!document.querySelector('#cv-log [data-k]')) await new Promise(resolve => requestAnimationFrame(resolve))
        return { value: performance.now() - start, unit: 'ms' }
      }, perfTicket))
      let maxDom = 0
      await record('C8 DOM entries after all pages', name, 'C8_dom', async () => {
        // 5,000 entries are 50 pages; the throttled phone context stops at 20 and records how far it got.
        for (let pageNo = 0; pageNo < (name === 'P' ? 20 : 60); pageNo++) {
          const more = await page.locator('#cv-log').evaluate(async el => {
            const count = performance.getEntriesByName('bd:convPage').length
            el.scrollTop = 0; el.dispatchEvent(new Event('scroll'))
            for (let i = 0; i < 200 && performance.getEntriesByName('bd:convPage').length === count; i++) await new Promise(resolve => setTimeout(resolve, 25))
            return performance.getEntriesByName('bd:convPage').length > count
          })
          maxDom = Math.max(maxDom, await page.locator('#cv-log [data-k]').count())
          if (!more) break
        }
        return { value: maxDom, unit: 'entries' }
      })
      await record('C8 convPage p95', name, 'C8_page', async () => ({ value: p95(await durations(page, 'convPage')), unit: 'ms' }))
      await record('C8 buildMap p95', name, 'C8_page', async () => { throw new Error('no buildMap on main: C11-T05 live map not shipped') })
      await record('C8 heap growth', name, 'C8_heap', async () => ({ value: ((await s.heap()) - modalStart) / MiB, unit: 'MiB' }))
    } finally { await s.context.close() }
  })
}

test('report P: Gruvbox fixed body wash scroll cost (C17)', async ({ browser }) => {
  test.setTimeout(300_000)
  const runs = {}
  for (const palette of ['gruvbox', 'aiur']) {
    const s = await session(browser, 'P', { palette })
    try {
      await load(s.page, 'dense')
      runs[palette] = p95(await scrollFrames(s.page))
    } finally { await s.context.close() }
  }
  await record('C17 gruvbox minus aiur scroll p95', 'P', 'C17', async () => ({ value: runs.gruvbox - runs.aiur, unit: 'ms' }))
})
