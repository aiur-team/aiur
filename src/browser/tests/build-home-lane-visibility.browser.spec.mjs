import { fileURLToPath } from 'node:url'
import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })
test.beforeEach(async ({ page }) => {
  await page.route(/\/build-home\/(columns|state|render|hook|match)\.js$/, route => route.fulfill({ path: fileURLToPath(new URL('../../priv/static/build-home/' + new URL(route.request().url()).pathname.split('/').at(-1), import.meta.url)), contentType: 'text/javascript' }))
  expect(await page.request.get('/build-control/stream?key=w' + test.info().workerIndex).then(r => r.status())).toBe(200)
  await page.goto('/build-fixture/live'); await expect(page.locator('.bd-lane')).not.toHaveCount(0)
  await page.evaluate(async () => {
    window.st = await import('/build-home/state.js'); window.cols = await import('/build-home/columns.js')
    window.ren = await import('/build-home/render.js'); window.ctx = st.ctx; window.S = st.S
  })
})

test('agent-only epic stays hidden while its live card keeps its hue', async ({ page }) => {
  const result = await page.evaluate(() => {
    ctx.D.epics = { bug: { label: 'Bug', icon: 'bug', hue: 38, general: true }, ops: { label: 'Ops', icon: 'server', hue: 200, general: true }, unsorted: { label: 'Unsorted', icon: 'unsorted', hue: 0, unsorted: true } }
    ctx.D.order = ['bug', 'ops', 'unsorted']; ctx.D.now = [{ id: 'agent-only', num: 91, epic: 'bug', sec: 'now', agent: { state: 'running' }, also: [], deps: [], type: 'bug', cue: {} }]
    ctx.D.hist = []; ctx.D.plan = []; ctx.D.nq = []; S.flow = false; S.feature = null; S.f.epic = []
    const item = { t: ctx.D.now[0], key: 'b0', y: 42, h: 32, sec: 'now' }, card = st.fx.makeCard(item)
    ctx.L = { secs: { hist: { items: [], h: 100 }, plan: { items: [] }, nq: { items: [] } }, band: { BK: 1, items: [{ ...item, el: card }] } }
    ctx.cols = []
    cols.applyCols([], true)
    return { visible: cols.visibleCols(), rendered: [...ctx.laneEls.values()].filter(el => !el.classList.contains('leave')).length, epicColor: card.style.getPropertyValue('--h') }
  })
  expect(result).toEqual({ visible: [], rendered: 0, epicColor: '38' })
})

test('visible ticket lanes follow filters and hide when the last ticket is filtered', async ({ page }) => {
  const result = await page.evaluate(async () => {
    const { computeLayout } = await import('/build-home/layout.js'), gantt = (await import('/build-home/gantt.js')).ganttExt
    const day = Date.now(), ticket = (id, epic, sec) => ({ id, epic, sec, end: day, also: [], deps: [], type: 'bug', cue: {} })
    const infra = ticket('infra-ticket', 'infra', 'plan'), docs = ticket('docs-ticket', 'docs', 'plan')
    const agent = { ...ticket('agent', 'docs', 'now'), num: 93, agent: { state: 'running' } }
    ctx.D.order = ['infra', 'docs', 'unsorted']; ctx.D.epics.infra = { label: 'Infra', icon: 'server', hue: 202 }; ctx.D.epics.docs = { label: 'Docs', icon: 'docs', hue: 46 }
    ctx.D.features = {}; ctx.D.byId.agent = agent; ctx.D.now = [agent]; ctx.D.plan = [infra, docs]; ctx.D.nq = []; ctx.D.hist = []; ctx.D.all = [infra, docs, agent]
    S.feature = null; S.flow = false; S.f.epic = ['infra']; ctx.vp.scrollTop = 100000; ctx.vp.clientHeight = 900
    const dims = { vpW: 1440, vpH: 900, gut: 84 }, setLayout = () => { ctx.L = computeLayout(ctx.D, S, dims, ctx.snap.sources, { gantt }) }
    setLayout(); ctx.L.band.items[0].el = st.fx.makeCard(ctx.L.band.items[0])
    const first = cols.visibleCols(), color = ctx.L.band.items[0].el.style.getPropertyValue('--h')
    S.f.epic = ['docs']; setLayout(); const second = cols.visibleCols()
    S.f.epic = ['absent']; setLayout(); const lastHidden = cols.visibleCols()
    return { first, second, lastHidden, color }
  })
  expect(result).toEqual({ first: ['infra'], second: ['docs'], lastHidden: [], color: '46' })
})
