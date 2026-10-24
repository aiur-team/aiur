import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { readFile } from 'node:fs/promises'

test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 } })
let errors
const group = (p, k) => p.locator(`[data-g="${k}"]`)
const option = (p, v) => p.locator(`[data-o="${v}"]`)
async function open(page, dataset = 'unknowns', query = '') {
  await page.goto('/build-fixture/' + dataset + query)
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/history.js')).H.state)).toBe('idle')
  await page.evaluate(async () => {
    window.m = await import('/build-home/state.js'); window.f = await import('/build-home/filters.js')
    window.matching = await import('/build-home/match.js')
  })
}
test.beforeEach(async ({ page }) => {
  errors = []; page.on('pageerror', e => errors.push(e.message))
  // Mutation runs use the actual isolated-worktree source, never copied logic.
  const mutationRoot = test.info().project.metadata.filtersRoot
  if (mutationRoot) await page.route('**/build-home/home.css', async route => route.fulfill({ contentType: 'text/css', body: await readFile(mutationRoot + '/src/priv/static/build-home/home.css', 'utf8') }))
  if (mutationRoot) await page.route('**/build-home/*.js', async route => {
    const name = new URL(route.request().url()).pathname.split('/').at(-1)
    await route.fulfill({ contentType: 'text/javascript', body: await readFile(mutationRoot + '/src/priv/static/build-home/' + name, 'utf8') })
  })
})
test.afterEach(() => expect(errors).toEqual([]))

test('F1 bar renders five groups before and after data', async ({ page }) => {
  await open(page, 'live')
  await expect(page.locator('.bd-fg')).toHaveText(['Epic', 'Feature', 'Model', 'Ticket', 'Agent'])
  await expect(page.locator('#bd-filters > svg')).toHaveCount(1)
  await expect(page.locator('.bd-fg.has, .bd-pop, .bd-fclear')).toHaveCount(0)
})
test('unknown live counts preserve epic options without page errors', async ({ page }) => {
  expect(await page.request.get('/build-control/stream?key=w' + test.info().workerIndex).then(r => r.status())).toBe(200)
  await open(page, 'live')
  expect(await page.request.get('/build-control/diff?name=counts-unknown').then(r => r.status())).toBe(200)
  await expect.poll(() => page.evaluate(() => m.ctx.D.counts)).toBeNull()
  await group(page, 'epic').click()
  expect(await page.locator('#bd-pop [data-o]').evaluateAll(nodes => nodes.map(node => node.dataset.o))).toEqual(['bugs', 'design', 'infra', 'docs', 'f-khala-srv', 'f-khala-ui', 'f-pag-api', 'f-pag-ui', 'unsorted'])
  expect(errors).toEqual([])
})
test('loading filter bar accepts selections before a snapshot', async ({ page }) => {
  await page.goto('/build-fixture/hold')
  await expect(page.locator('.bd-loading')).toBeVisible()
  await expect(page.locator('.bd-fg')).toHaveText(['Epic', 'Feature', 'Model', 'Ticket', 'Agent'])
  await group(page, 'model').click(); await option(page, 'claude').click()
  await expect(option(page, 'claude')).toHaveAttribute('aria-pressed', 'true')
  await expect(page.locator('.bd-loading')).toBeVisible()
  expect(await page.evaluate(async () => {
    const { S } = await import('/build-home/state.js')
    return { loading: S.loading, models: S.f.model }
  })).toEqual({ loading: true, models: ['claude'] })
})
test('F2 F3 not planned removes layout space, toggles via URL and hides incoming rows', async ({ page }) => {
  await open(page)
  expect(await page.evaluate(() => m.ctx.L.secs.hist.items.some(i => ['9010', '9020'].includes(i.t.id)))).toBe(false)
  await group(page, 'tstate').click()
  await expect(option(page, 'not planned')).toHaveClass('bd-opt lst st-np')
  await option(page, 'not planned').click()
  await expect(page).toHaveURL(/tstate=not\+planned/)
  await expect(group(page, 'tstate').locator('b')).toHaveText('1')
  expect(await page.evaluate(() => m.ctx.L.secs.hist.items.filter(i => ['9010', '9020'].includes(i.t.id)).map(i => i.t.id).sort())).toEqual(['9010', '9020'])
  await expect(page.locator('.bd-card.hist.dim').first()).toBeAttached()
  await option(page, 'not planned').click()
  await expect(page).not.toHaveURL(/tstate/)
  await page.evaluate(async () => {
    const { receive } = await import('/build-home/hook.js'), { ctx } = m
    const row = { ...ctx.D.byId['9010'], id: '9021', num: 9021 }
    receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now, set: {}, remove: [], upsert: [row] })
    m.fx.flushLive()
  })
  expect(await page.evaluate(() => m.ctx.L.secs.hist.items.some(i => ['9010', '9020', '9021'].includes(i.t.id)))).toBe(false)
  await expect(option(page, 'not planned')).toBeVisible()
})
test('F4 F8 features sort by date, retain selection and show unknown percentages', async ({ page }) => {
  await open(page, 'dense', '?feature=d0')
  await page.evaluate(() => {
    m.ctx.D.features = Object.fromEntries(Object.entries(m.ctx.D.features).reverse())
    m.ctx.D.features.d9.stats = { ...m.ctx.D.features.d9.stats, pct: null, pct_min: 40, reasons: ['progress'] }
    m.ctx.D.features.d8.stats = null
  })
  await group(page, 'feature').click()
  expect(await page.locator('.bd-opt').evaluateAll(els => els.map(e => e.dataset.o))).toEqual(['d6', 'd7', 'd8', 'd9', 'khala', 'pag', 'd0'])
  await expect(option(page, 'd0')).toHaveAttribute('aria-pressed', 'true')
  await expect(option(page, 'd9')).toContainText('  —')
  await expect(option(page, 'd9')).toHaveAttribute('title', 'at least 40% weighted · unknown: progress')
  await expect(option(page, 'd8')).toContainText('  —')
  await option(page, 'd9').click()
  await expect(group(page, 'feature')).toBeFocused()
  await expect(page).toHaveURL(/feature=d9/)
})
test('F5 F12 model options include logos and sorted letters and unknown keys persist', async ({ page }) => {
  await open(page)
  await group(page, 'model').click()
  expect(await page.locator('.bd-opt').evaluateAll(els => els.map(e => e.dataset.o))).toEqual(['claude', 'codex', 'deepseek', 'kimi', 'muse', 'openrouter', 'zz-new'])
  await expect(page.locator('.bd-opt img')).toHaveCount(4)
  await expect(page.locator('.bd-opt .ax-mono')).toHaveText(['M', 'O', 'Z'])
  await expect(option(page, 'muse').locator('.ax-mono')).toHaveCSS('width', '14px')
  await expect(option(page, 'muse').locator('.ax-mono')).toHaveCSS('border-radius', '50%')
  await option(page, 'zz-new').click()
  await expect(page).toHaveURL(/model=zz-new/)
  await expect(option(page, 'zz-new')).toHaveAttribute('aria-pressed', 'true')
  expect(await page.evaluate(() => m.ctx.D.now.filter(t => matching.match(t)).map(t => t.id))).toEqual(['9014'])
  await option(page, 'zz-new').click(); await option(page, 'muse').click()
  expect(await page.evaluate(() => m.ctx.D.now.filter(t => matching.match(t)).map(t => t.id))).toEqual(['9007'])
})
test('F6 F7 unknown status, cue and agent never match plausible defaults', async ({ page }) => {
  await open(page)
  expect(await page.evaluate(() => {
    const hist = status => matching.tstate({ sec: 'hist', status })
    const agents = [null, { state: null }, { state: 'weird' }].map(agent => matching.astate({ sec: 'now', agent }))
    return { hist: ['closed', 'weird'].map(hist), cue: matching.tstate({ sec: 'plan', cue: null }), agents }
  })).toEqual({ hist: [null, null], cue: null, agents: [null, null, null] })
  await group(page, 'astate').click(); await option(page, 'active').click()
  await expect(page.locator('.bd-now-st [data-ast="active"]')).toHaveClass(/\bon\b/)
  expect(await page.evaluate(() => ['9008', '9009', '9016'].map(id => matching.match(m.ctx.D.byId[id])))).toEqual([false, false, true])
  await option(page, 'active').click(); await option(page, 'none').click()
  expect(await page.evaluate(() => ['9008', '9009'].map(id => matching.match(m.ctx.D.byId[id])))).toEqual([false, false])
  await expect(page.locator('.bd-now-st [data-ast="active"]')).not.toHaveClass(/\bon\b/)
})
test('F9 unknown slugs remain clearable with no feature count', async ({ page }) => {
  await open(page, 'live', '?feature=ghost&epic=ghost-epic')
  await expect(group(page, 'feature')).not.toHaveClass(/has/)
  await expect(group(page, 'epic').locator('b')).toHaveText('1')
  await group(page, 'feature').click(); await expect(option(page, 'ghost')).toHaveAttribute('aria-pressed', 'true')
  await group(page, 'epic').click(); await expect(option(page, 'ghost-epic')).toHaveAttribute('aria-pressed', 'true')
  expect(await page.evaluate(() => Object.values(m.ctx.L.secs).flatMap(s => s.items).length)).toBe(0)
  await page.locator('#bd-fclr').click()
  await expect(page).not.toHaveURL(/feature|epic/)
  await expect(page.locator('.bd-card').first()).toBeAttached()
})
test('F10 filters survive reload, navigation and history without URL echo', async ({ page }) => {
  await open(page, 'live')
  for (const [k, v] of [['epic', 'bugs'], ['model', 'claude'], ['astate', 'error']]) {
    await group(page, k).click(); await option(page, v).click()
  }
  await expect(page).toHaveURL(/epic=bugs&model=claude&astate=error/)
  await page.reload()
  for (const [k, v] of [['epic', 'bugs'], ['model', 'claude'], ['astate', 'error']]) {
    await group(page, k).click(); await expect(option(page, v)).toHaveAttribute('aria-pressed', 'true')
  }
  await page.locator('a[href="/commands"]').first().click()
  await expect(page.locator('#build-root')).toHaveCount(0)
  await page.goBack()
  await expect(group(page, 'astate').locator('b')).toHaveText('1')
})
for (const width of [1440, 390]) test(`F11 F15 popover position, outside click and keyboard at ${width}`, async ({ page }) => {
  await page.setViewportSize({ width, height: 900 }); await open(page, 'live')
  await group(page, 'model').focus(); await page.keyboard.press('Enter')
  await expect(group(page, 'model')).toHaveAttribute('aria-expanded', 'true')
  await expect(group(page, 'model')).not.toHaveAttribute('aria-haspopup')
  if (width === 390) await expect(page.locator('#bd-pop')).toHaveCSS('position', 'fixed')
  else expect(await page.locator('#bd-pop').evaluate(e => e.style.left)).toBe(await group(page, 'model').evaluate(e => e.offsetLeft + 'px'))
  await option(page, 'codex').focus(); await page.keyboard.press('Enter')
  await expect(option(page, 'codex')).toBeFocused(); await expect(option(page, 'codex')).toHaveAttribute('aria-pressed', 'true')
  await page.evaluate(() => document.querySelector('#bd-tree').hidden = false)
  await page.keyboard.press('Escape')
  await expect(page.locator('#bd-pop')).toHaveCount(0); await expect(group(page, 'model')).toBeFocused()
  expect(await page.locator('#bd-tree').evaluate(e => e.hidden)).toBe(false)
  await group(page, 'model').click(); await group(page, 'model').click(); await expect(page.locator('#bd-pop')).toHaveCount(0)
  await group(page, 'model').click(); await page.locator('#bd-usage').click({ position: { x: 5, y: 5 } }); await expect(page.locator('#bd-pop')).toHaveCount(0)
})
test('F13 option labels and hue cannot inject markup or styles', async ({ page }) => {
  await open(page, 'live')
  const label = '<img src=x onerror="window.__xss=1">\'&'
  await page.evaluate(label => { m.ctx.D.epics.bugs.label = label; m.ctx.D.epics.bugs.hue = '0);background:url(x' }, label)
  await group(page, 'epic').click(); await expect(option(page, 'bugs')).toHaveText(label)
  await expect(option(page, 'bugs').locator('i, img')).toHaveCount(0)
  expect(await page.evaluate(() => window.__xss)).toBeUndefined()
})
test('F14 epic removes rows, other groups dim; list uses the same visibility rule', async ({ page }) => {
  await open(page, 'live')
  const before = await page.evaluate(() => Object.values(m.ctx.L.secs).flatMap(s => s.items).length)
  await group(page, 'epic').click(); await option(page, 'docs').click()
  const epics = await page.evaluate(() => Object.values(m.ctx.L.secs).flatMap(s => s.items).map(i => i.t.epic))
  expect(epics.length).toBeLessThan(before); expect(epics.every(e => e === 'docs')).toBe(true)
  await page.locator('#bd-fclr').click(); await group(page, 'tstate').click(); await option(page, 'merged').click()
  expect(await page.evaluate(() => Object.values(m.ctx.L.secs).flatMap(s => s.items).length)).toBe(before)
  await expect(page.locator('.bd-card.plan.dim').first()).toBeAttached()
  await open(page, 'unknowns', '?view=list')
  await expect(page.locator('.lr[data-id="9010"], .lr[data-id="9020"]')).toHaveCount(0)
  await group(page, 'tstate').click(); await option(page, 'not planned').click()
  await expect(page.locator('.lr[data-id="9010"], .lr[data-id="9020"]')).toHaveCount(2)
})
for (const dataset of ['live', 'dense', 'newrepo', 'noqueue', 'unknowns']) test(`F16 every group opens without errors: ${dataset}`, async ({ page }) => {
  await open(page, dataset)
  for (const key of ['epic', 'feature', 'model', 'tstate', 'astate']) { await group(page, key).click(); await expect(page.locator('#bd-pop')).toBeVisible() }
})

test('Feature selection and Clear redraw direct list view without graph columns', async ({ page }) => {
  await open(page, 'live', '?view=list')
  await group(page, 'feature').click(); await option(page, 'pag').click()
  await expect(page).toHaveURL(/feature=pag/)
  await expect(group(page, 'feature').locator('b')).toHaveText('1')
  await expect(page.locator('.lr.dim').first()).toBeAttached()
  await page.locator('#bd-fclr').click()
  await expect(page).not.toHaveURL(/feature/)
  await expect(page.locator('.lr.dim')).toHaveCount(0)
})

test('phone filter row scrolls internally and keeps every group reachable', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await open(page, 'live')
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
  const filters = page.locator('#bd-filters')
  expect(await filters.evaluate(el => ({ client: el.clientWidth, scroll: el.scrollWidth })).then(s => s.scroll > s.client)).toBe(true)
  for (const key of ['epic', 'feature', 'model', 'tstate', 'astate']) {
    await group(page, key).click()
    const box = await group(page, key).boundingBox()
    expect(box.x).toBeGreaterThanOrEqual(0)
    expect(box.x + box.width).toBeLessThanOrEqual(390)
    await expect(page.locator('#bd-pop')).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(page.locator('#bd-pop')).toHaveCount(0)
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
})
