import { fileURLToPath } from 'node:url'
import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ colorScheme: 'light', httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })
async function open(page, dataset = 'live') {
  await page.route(/\/build-home\/[\w-]+\.js$/, route => route.fulfill({ path: fileURLToPath(new URL('../../priv/static/build-home/' + new URL(route.request().url()).pathname.split('/').at(-1), import.meta.url)), contentType: 'text/javascript' }))
  await page.clock.setFixedTime(1791408000000)
  await page.goto('/build-fixture/' + dataset)
  await expect(page.locator('#bd-content')).toHaveCount(1)
  await page.evaluate(async () => { window.st = await import('/build-home/state.js') })
  await expect.poll(() => page.evaluate(() => !!st.ctx.D)).toBe(true)
}
const navigate = (page, path) => page.evaluate(path => window.liveSocket.main.pushLinkPatch(new Event('click'), path, null), path)

// B2/B11: the oracle uses payload rows and visible cards, independently of the renderer.
for (const dataset of ['live', 'dense']) test(`windowed edge count follows visible endpoint pairs: ${dataset}`, async ({ page }) => {
  await open(page, dataset)
  const snapshot = await import(`../../test/fixtures/build_home/${dataset}.json`, { with: { type: 'json' } })
  const samples = await page.evaluate(rows => {
    const { ctx, fx } = st, samples = []
    for (const sec of ['hist', 'plan', 'nq']) for (const offset of [1000, 0]) {
      ctx.vp.scrollTop = ctx.secs[sec].el.offsetTop + offset; fx.update(); fx.drawEdges(true)
      const visible = new Set([...ctx.root.querySelectorAll('.bd-card[data-id]')].filter(el => el.style.opacity !== '0').map(el => el.dataset.id))
      const expected = rows.filter(row => visible.has(row.id)).flatMap(row => row.deps.filter(did => visible.has(did)).map(did => [did, row.id]))
      samples.push({ expected: expected.length, actual: ctx.svg.querySelectorAll('.bd-eh').length,
        missing: [...visible].flatMap(id => (ctx.D.byId[id]?.deps ?? []).filter(did => !visible.has(did))).length,
        rendered: visible.size, total: Object.keys(ctx.D.byId).length })
    }
    return samples
  }, Object.values(snapshot.default.sections).flat())
  for (const s of samples) expect(s.actual).toBe(s.expected)
  expect(samples.some(s => s.missing > 0)).toBe(true)
  expect(samples.some(s => s.actual > 0)).toBe(true)
  expect(samples.every(s => s.rendered < s.total)).toBe(true)
})

test('B4/B12 odd edges draw cycles, failed and unknown without errors', async ({ page }, info) => {
  const errors = []; page.on('pageerror', e => errors.push(e.message))
  await open(page, 'odd-edges')
  const edges = await page.evaluate(() => {
    const { ctx, fx } = st, result = {}
    for (const sec of ['hist', 'nq']) {
      ctx.vp.scrollTop = ctx.secs[sec].el.offsetTop; fx.update(); fx.drawEdges(true)
      for (const hit of ctx.svg.querySelectorAll('.bd-eh')) result[hit.dataset.e] = hit.nextElementSibling.getAttribute('class').trim()
    }
    return result
  })
  expect(edges).toMatchObject({ 12: 'bd-e bad', 19: 'bd-e', 1: 'bd-e bl', 2: 'bd-e bl', 3: 'bd-e bl', 4: 'bd-e bl', 5: 'bd-e bl' })
  info.annotations.push({ type: 'pending-sign-off', description: 'S-24 odd edges / C4-T05' })
  for (const [name, id] of [['order-violation', '12'], ['unknown', '19'], ['two-cycle', '1'], ['three-cycle', '3']]) {
    await page.evaluate(id => {
      const { ctx, fx } = st
      const item = Object.values(ctx.L.secs).flatMap(sec => sec.items).find(it => it.t.id === id)
      ctx.vp.scrollTop = ctx.secs[item.t.sec].el.offsetTop + item.y - 100; fx.update(); fx.drawEdges(true)
    }, id)
    await expect(page.locator(`.bd-card[data-id="${id}"]`)).toBeVisible()
    // Hide cards and chrome so the baseline records the edge layer only.
    const hide = await page.addStyleTag({ content: 'body * { visibility: hidden !important } #bd-edges, #bd-edges * { visibility: visible !important }' })
    await expect(page.locator('#bd-edges')).toHaveScreenshot(`${name}.png`)
    await hide.evaluate(el => el.remove())
  }
  expect(errors).toEqual([])
})

test('B8 destroy cancels pending draws and disconnected content is untouched', async ({ page }) => {
  await open(page)
  await page.clock.install({ time: 1791408000000 })
  await page.clock.pauseAt(1791408000000)
  await page.evaluate(() => {
    window.oldSVG = st.ctx.svg; window.mutations = 0
    window.edgeObserver = new MutationObserver(() => { if (!oldSVG.isConnected) mutations++ })
    edgeObserver.observe(oldSVG, { attributes: true, childList: true, subtree: true })
    st.fx.drawEdgesSoon(420)
  })
  await page.clock.runFor(50)
  await navigate(page, '/commands')
  await expect(page.locator('#bd-content')).toHaveCount(0)
  await page.clock.runFor(600)
  expect(await page.evaluate(() => mutations)).toBe(0)
  // Also exercise the defensive guard independently of lifecycle cancellation.
  expect(await page.evaluate(() => {
    edgeObserver.takeRecords()
    st.fx.drawEdges(true)
    return edgeObserver.takeRecords().length === 0
  })).toBe(true)
})

test('B8b navigating back during a draw loop renders a fresh mount', async ({ page, context }) => {
  await open(page)
  const fresh = await context.newPage()
  await open(fresh)
  const expected = await fresh.evaluate(() => {
    const { ctx, fx } = st
    ctx.vp.scrollTop = ctx.secs.plan.el.offsetTop; fx.update()
    return ctx.svg.querySelectorAll('.bd-eh').length
  })
  await fresh.close()
  expect(expected).toBeGreaterThan(0)

  // Freeze performance.now across navigation: the old 420 ms deadline stays active.
  await page.clock.install({ time: 1791408000000 })
  await page.clock.pauseAt(1791408010000)
  await page.clock.runFor(600)
  await page.evaluate(() => {
    window.soon = st.fx.drawEdgesSoon
    soon(420)
    // Mount/layout also draw directly and schedule short loops. Isolate the pending-loop
    // restart through the public fx seams; the real loop calls drawEdges lexically.
    st.fx.drawEdges = () => {}
    st.fx.drawEdgesSoon = () => {}
  })
  await navigate(page, '/commands')
  await expect(page.locator('#bd-content')).toHaveCount(0)
  await navigate(page, '/build')
  await expect(page.locator('#bd-content')).toHaveCount(1)
  await expect.poll(() => page.evaluate(() => !!st.ctx.D && !!st.ctx.secs.plan)).toBe(true)
  await page.evaluate(() => {
    const { ctx, fx } = st
    ctx.vp.scrollTop = ctx.secs.plan.el.offsetTop; fx.update()
    fx.drawEdgesSoon = soon
    fx.drawEdgesSoon(420)
  })
  // No forced draw: only the restarted animation-frame loop can populate the new SVG.
  await page.clock.runFor(100)
  expect(await page.locator('#bd-edges .bd-eh').count()).toBe(expected)
})

test('B3 an unloaded blocker has no edge until earlier history is loaded', async ({ page }) => {
  await open(page)
  const full = await import('../../test/fixtures/build_home/live.json', { with: { type: 'json' } })
  const result = await page.evaluate(async snapshot => {
    const { ctx, fx, S } = st, history = await import('/build-home/history.js')
    const rows = Object.fromEntries(snapshot.sections.hist.map(row => [row.id, row]))
    const child = ctx.D.hist.find(row => row.deps.some(id => rows[id] && !ctx.D.byId[id]))
    if (!child) throw new Error('fixture needs a dependency in an unloaded history day')
    const parent = rows[child.deps.find(id => rows[id] && !ctx.D.byId[id])]
    const read = () => [...ctx.svg.querySelectorAll(`.bd-eh[data-e="${child.id}"]`)].length
    ctx.vp.scrollTop = ctx.secs.hist.el.offsetTop; fx.update(); fx.drawEdges(true)
    const before = read()
    await history.ensureFrom(parent.end)
    S.span = 7; fx.relayout()
    const item = ctx.L.secs.hist.items.find(it => it.t.id === child.id)
    ctx.vp.scrollTop = ctx.secs.hist.el.offsetTop + item.y; fx.update(); fx.drawEdges(true)
    return { before, loaded: !!ctx.D.byId[parent.id], parentRendered: [...ctx.R.values()].some(el => el.dataset.id === parent.id), after: read() }
  }, full.default)
  expect(result).toEqual({ before: 0, loaded: true, parentRendered: true, after: 1 })
})
