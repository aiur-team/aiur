import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { dashboardCredentials } from './support/layout-worker.mjs'
test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })
test.beforeEach(async ({ page }) => {
  page.featureErrors = []; page.on('pageerror', error => page.featureErrors.push(error.message))
  const root = test.info().project.metadata.featuresRoot
  if (root) await page.route('**/build-home/home.css*', async route => route.fulfill({ contentType: 'text/css', body: await readFile(root + '/src/priv/static/build-home/home.css', 'utf8') }))
  if (root) await page.route('**/build-home/home/*.css*', async route => route.fulfill({ contentType: 'text/css', body: await readFile(root + '/src/priv/static' + new URL(route.request().url()).pathname, 'utf8') }))
  if (root) await page.route('**/build-home/*.js', async route => route.fulfill({ contentType: 'text/javascript', body: await readFile(root + '/src/priv/static/build-home/' + new URL(route.request().url()).pathname.split('/').at(-1), 'utf8') }))
})
test.afterEach(async ({ page }) => { await page.request.get('/build-control/earlier'); expect(page.featureErrors).toEqual([]) })
async function open(page, query = '?feature=pag', dataset = 'live') {
  await page.goto('/build-fixture/' + dataset + query)
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
  await page.evaluate(async () => {
    window.m = await import('/build-home/state.js')
    window.h = await import('/build-home/hook.js'); window.hist = await import('/build-home/history.js')
  })
}
const mode = (p, m) => p.locator(`#bd-fh [data-m="${m}"]`)
async function diff(page, patch) {
  await page.evaluate(patch => {
    const { ctx } = m, feature = { ...ctx.D.features.pag, ...patch }
    h.receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now, set: { features: { ...ctx.D.features, pag: feature } }, remove: [], upsert: [] })
  }, patch)
}
test('header uses whole-index figures, mode buttons and clear restore the board', async ({ page }) => {
  await open(page)
  const values = await page.evaluate(() => m.ctx.D.features.pag.stats)
  await expect(page.locator('.bd-kv b').nth(0)).toHaveText(`${values.done}/${values.total}`)
  await expect(page.locator('.bd-kv b').nth(1)).toHaveText(`${values.pct}%`)
  await expect(page.locator('.bd-kv b').nth(2)).toContainText(`${values.orig} → ${values.total}`)
  expect(await page.locator('.bd-card.dim').count()).toBeGreaterThan(0)
  await mode(page, 'compact').click()
  await expect(page).toHaveURL(/fmode=compact/)
  await expect(mode(page, 'compact')).toHaveClass('on')
  const counts = await page.evaluate(() => {
    const { ctx } = m, items = ['hist', 'plan', 'nq'].flatMap(k => ctx.L.secs[k].items)
    return { ghosts: items.filter(i => i.ghost).length, unrelated: items.filter(i => !i.ghost && i.t.feature !== 'pag' && !i.t.also.includes('pag')).length }
  })
  expect(counts.unrelated).toBe(0)
  await expect(page.locator('.bd-mk.gap').first()).toBeAttached()
  await page.locator('#bd-fx').click()
  await expect(page.locator('#bd-fh')).toBeEmpty()
  await expect(page.locator('.bd-card.dim, .bd-card.feat-on, .bd-card.also, .bd-card.ghost')).toHaveCount(0)
  await expect(page).not.toHaveURL(/feature=/)
})
test('unknown stats, baseline, missing stats and labels update through live diffs', async ({ page }) => {
  await open(page)
  const stats = await page.evaluate(() => m.ctx.D.features.pag.stats)
  await diff(page, { label: '<b>renamed</b>', epics: ['missing'], stats: { ...stats, done: null, done_min: 5, pct: null, pct_min: 41, reasons: ['progress', 'status'], baseline: false } })
  await expect(page.locator('.bd-fh-name')).toHaveText('<b>renamed</b>')
  await expect(page.locator('.bd-fh-name b, .bd-chip svg')).toHaveCount(0)
  await expect(page.locator('.bd-kv b').nth(0)).toHaveText(`—/${stats.total}`)
  await expect(page.locator('.bd-kv b').nth(1)).toHaveText('—')
  await expect(page.locator('.bd-kv b').nth(1)).toHaveAttribute('title', 'at least 41% weighted · unknown: progress, status')
  await expect(page.locator('.bd-kv b').nth(2)).toHaveText(`— → ${stats.total}`)
  await expect(page.locator('.bd-kv em')).toHaveCount(0)
  await diff(page, { stats: null })
  await expect(page.locator('.bd-kv b')).toHaveText(['—', '—', '—'])
  await expect(page.locator('.sp polyline')).toHaveCount(0)
})
test('feature list shows a proportional bar for known membership', async ({ page }) => {
  await open(page, '?view=list')
  await expect(page.locator('.bd-list')).toBeVisible()
  await page.getByRole('tab', { name: 'Features' }).click()
  const progress = {
    features: {
      'f-pag-api': { feature: 'pag', closed: 1, open: 2, ci_wait: 1, unpublished: 0, total: 4, observed_at: Date.now(), wave: '0', summary: 'Pagination work', icon: 'layers', code: 'MP-E8', plan_version: 'v1', extras: 0, reason: null },
      'f-pag-client': { feature: 'pag', closed: 2, open: 3, ci_wait: 1, unpublished: 0, total: 6, observed_at: Date.now(), wave: '0', summary: null, icon: null, code: null, plan_version: 'v1', extras: 0, reason: null }
    }, observed_at: Date.now(), plan_version: 'v1', extras: 0
  }
  await page.evaluate(async progress => {
    const { ctx, fx } = await import('/build-home/state.js')
    ctx.D.feature_progress = progress
    ctx.D.order = ['f-pag-api', 'f-pag-client']
    ctx.D.epics = { 'f-pag-api': { feature: 'pag', label: 'Pagination · API' }, 'f-pag-client': { feature: 'pag', label: 'Pagination · client' } }
    ctx.D.features = { pag: { label: 'Events pagination', hue: 272, epics: ['f-pag-api', 'f-pag-client'], to: Infinity } }
    ctx.snap.order = ctx.D.order
    ctx.snap.epics = ctx.D.epics
    ctx.snap.features = ctx.D.features
    ctx.snap.feature_progress = progress
    fx.renderList()
  }, progress)
  const row = page.locator('.fp-row')
  await expect(row).toHaveCount(1)
  await expect(row).toContainText('3 / 10')
  await expect(row).toContainText('MP-E8')
  await expect(row).toContainText('Pagination · API: 1 / 4 · Pagination · client: 2 / 6')
  const closed = row.locator('.fp-closed')
  await expect(closed).toBeVisible()
  await expect(closed).toHaveAttribute('style', /width:30%/)
})
test('feature list keeps known closed progress solid when other counts are unknown', async ({ page }) => {
  await open(page, '?view=list')
  await page.getByRole('tab', { name: 'Features' }).click()
  const entries = [
    ['f-part-2', 'part2', 'Wave 1 refactor (part 2/3)', '1', 88, 6, 0, 94],
    ['f-part-3', 'part3', 'Wave 1 refactor (part 3/3)', '1', 49, 20, 0, 71],
    ['f-other', 'other', 'Other work', '2', 298, 32, 0, 330],
    ['f-bo-6368', 'unassigned', 'Unassigned tickets', '2', 0, 0, 0, 0]
  ]
  const features = Object.fromEntries(entries.map(([epic, slug, label]) => [slug, { label, hue: 272, epics: [epic] }]))
  const epics = Object.fromEntries(entries.map(([key, , label]) => [key, { key, feature: entries.find(entry => entry[0] === key)[1], label: key.startsWith('f-bo-') ? 'Build Order 6368' : label }]))
  const progress = {
    features: Object.fromEntries(entries.map(([key, slug, summary, wave, closed, open, unpublished, total]) => [key, {
      feature: slug, closed, open, ci_wait: slug === 'part3' || slug === 'part2' ? null : 0,
      unpublished, total, observed_at: Date.now(), wave, summary, extras: 0, reason: null
    }])),
    observed_at: Date.now(), plan_version: 'v1', extras: 0
  }
  await page.evaluate(({ features, epics, progress }) => {
    const { ctx, fx } = window.m
    ctx.D.features = features
    ctx.D.epics = epics
    ctx.D.feature_progress = progress
    ctx.snap.features = features
    ctx.snap.epics = epics
    ctx.snap.feature_progress = progress
    fx.renderList()
  }, { features, epics, progress })

  const overall = page.locator('.fp-total')
  await expect(page.locator('.fp-overall')).toContainText('435 / 495')
  await expect(page.locator('.fp-overall')).toContainText('CI state unknown')
  await expect(overall.locator('.fp-closed')).toHaveAttribute('style', /width:87\.8/)
  await expect(overall.locator('.fp-open')).toHaveAttribute('style', /width:11\.717/)
  await expect(overall.locator('.fp-unknown')).toHaveAttribute('style', /width:0\.404/)
  const accent = await page.locator('.fp-legend .closed').evaluate(el => getComputedStyle(el).backgroundColor)
  await expect(overall.locator('.fp-closed')).toHaveCSS('background-color', accent)
  const part2 = page.locator('.fp-row').filter({ hasText: 'Wave 1 refactor (part 2/3)' })
  const part3 = page.locator('.fp-row').filter({ hasText: 'Wave 1 refactor (part 3/3)' })
  await expect(part2.locator('.fp-closed')).toHaveAttribute('style', /width:93\.6/)
  await expect(part3.locator('.fp-closed')).toHaveAttribute('style', /width:69\.0/)
  await expect(part3.locator('.fp-open')).toHaveAttribute('style', /width:28\.169/)
  await expect(part3.locator('.fp-unknown')).toHaveAttribute('style', /width:2\.8169/)
  await expect(part3.locator('.fp-closed')).toHaveCSS('background-color', accent)
  await expect(part3.locator('.fp-unknown')).toHaveCSS('background-image', /repeating-linear-gradient/)
  await expect(page.locator('.fp-row')).not.toContainText('Unassigned: 0 / 0')
  const empty = page.locator('.fp-row[data-feature="unassigned"] .fp-bar')
  await expect(empty).toHaveAttribute('aria-label', 'No tickets to count')
  await expect(empty.locator('.fp-unknown')).toHaveCount(0)

  await page.evaluate(() => {
    const { ctx, fx } = window.m
    ctx.D.features.unknown = { label: 'Unknown closed count', hue: 272, epics: ['f-bo-6369-core'] }
    ctx.D.epics['f-bo-6369-core'] = { key: 'f-bo-6369-core', feature: 'unknown', label: 'Build Order 6369 · Core' }
    ctx.D.feature_progress.features['f-bo-6369-core'] = { feature: 'unknown', closed: null, open: 3, ci_wait: 0, unpublished: 0, total: 10, observed_at: Date.now(), wave: '3', reason: 'states unavailable' }
    fx.renderList()
  })
  const unknown = page.locator('.fp-row[data-feature="unknown"] .fp-bar')
  await expect(unknown.locator('.fp-open')).toHaveAttribute('style', /width:30%/)
  await expect(unknown.locator('.fp-unknown')).toHaveAttribute('style', /width:70%/)
  await expect(unknown.locator('.fp-unknown')).toHaveCSS('background-image', /repeating-linear-gradient/)
  await expect(unknown.locator('.fp-closed')).toHaveCount(0)
})
for (const slug of ['nope', 'constructor', 'toString']) test(`unknown ${slug} stays inactive in graph, compact and list`, async ({ page }) => {
  const errors = []; page.on('pageerror', e => errors.push(e.message))
  await open(page, `?feature=${slug}&fmode=compact`)
  await expect(page.locator('#bd-fh')).toBeEmpty()
  await expect(page.locator('.bd-card.dim, .bd-card.also, .bd-card.feat-on, .bd-card.ghost, .bd-mk.gap')).toHaveCount(0)
  await expect(page).toHaveURL(new RegExp('feature=' + slug))
  const positions = () => page.evaluate(() => ({ cols: m.ctx.cols, sections: Object.fromEntries(['hist', 'plan', 'nq'].map(sec => [sec, m.ctx.L.secs[sec].items.map(it => [it.t.id, it.key, it.y, it.h])])) }))
  const inactive = await positions()
  await open(page, '')
  expect(await positions()).toEqual(inactive)
  await page.goto(`/build-fixture/live?feature=${slug}&view=list`)
  await expect(page.locator('.bd-list')).toBeVisible()
  await expect(page.locator('.lr.dim')).toHaveCount(0)
  expect(errors).toEqual([])
})
test('first-paint feature focus loads oldest history, back/forward restores focus', async ({ page }) => {
  await page.request.get('/build-control/earlier?delay=300')
  await open(page, '?feature=khala')
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'loading')
  const bandTop = () => page.evaluate(() => m.ctx.bandEl.getBoundingClientRect().top - m.ctx.vp.getBoundingClientRect().top)
  const before = await bandTop()
  await expect(page.locator('.bd-fh-name')).toContainText('Khala')
  await expect.poll(() => page.evaluate(() => m.S.histFrom <= m.ctx.D.features.khala.oldest)).toBe(true)
  expect(await page.evaluate(() => m.ctx.D.hist.filter(t => t.feature === 'khala').length)).toBeGreaterThan(0)
  expect(Math.abs(await bandTop() - before)).toBeLessThanOrEqual(1)
  await page.evaluate(() => { const a = document.createElement('a'); a.id = 'feature-navigation'; a.href = '/build-fixture/live?feature=pag'; a.dataset.phxLink = 'patch'; a.dataset.phxLinkState = 'push'; a.textContent = 'Pagination feature'; document.body.appendChild(a) })
  await page.locator('#feature-navigation').click()
  await expect(page.locator('.bd-fh-name')).toContainText('Events pagination')
  await page.goBack()
  await expect(page.locator('.bd-fh-name')).toContainText('Khala')
})
for (const action of ['clear', 'switch', 'destroy']) test(`${action} during an in-flight page stops the prior feature span`, async ({ page }) => {
  await open(page, '')
  await page.evaluate(async () => {
    const { ctx, fx } = m; window.calls = 0; const push = ctx.push;
    ctx.push = (e, p) => { if (e !== 'load-earlier') return push(e, p); calls++; const reply = push(e, p); if (calls > 1) return reply; return new Promise(resolve => { window.finish = () => reply.then(resolve) }) }
    fx.setFeature('khala')
  })
  await expect(page.locator('.bd-fh-name')).toContainText('Khala')
  await expect.poll(() => page.evaluate(() => calls)).toBe(1)
  if (action === 'clear') await page.locator('#bd-fx').click()
  else if (action === 'switch') await page.evaluate(() => m.fx.setFeature('pag'))
  else await page.evaluate(() => h.createBuildHomeHook().destroyed.call({ buildLife: m.ctx.life }))
  await page.evaluate(async () => { await finish() })
  if (action !== 'destroy') await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'idle')
  else expect(await page.evaluate(() => m.ctx.life.disposed)).toBe(true)
  if (action === 'switch') {
    await expect.poll(() => page.evaluate(() => m.S.histFrom <= m.ctx.D.features.pag.oldest)).toBe(true)
    expect(await page.evaluate(() => m.S.histFrom > m.ctx.D.features.khala.oldest)).toBe(true)
  } else expect(await page.evaluate(() => calls)).toBe(1)
})
test('a feature page error stops loading and preserves server figures', async ({ page }) => {
  await open(page, '')
  await page.request.get('/build-control/earlier?fail=1')
  const values = await page.evaluate(() => {
    const { ctx, fx } = m, push = ctx.push; window.errorCalls = 0
    ctx.push = (event, params) => { if (event === 'load-earlier') errorCalls++; return push(event, params) }
    fx.setFeature('khala'); return ctx.D.features.khala.stats
  })
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'error')
  await expect(page.locator('.bd-kv b').nth(0)).toHaveText(`${values.done}/${values.total}`)
  // Away from the top, viewport updates may re-arm an explicit retry. The failed
  // feature span must still stop instead of automatically requesting another day.
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  expect(await page.evaluate(() => ({ calls: errorCalls, state: hist.H.state }))).toEqual({ calls: 1, state: 'error' })
})
test('late feature activation and live dependencies rebuild compact ghosts', async ({ page }) => {
  await open(page, '?feature=late&fmode=compact')
  await expect(page.locator('#bd-fh')).toBeEmpty()
  const ids = await page.evaluate(() => {
    const { ctx } = m, member = ctx.D.plan[0], external = ctx.D.nq.find(t => t.epic !== member.epic)
    const feature = { ...ctx.D.features.pag, key: 'late', label: 'Late feature', oldest: null, epics: [member.epic] }
    h.receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now,
      set: { features: { ...ctx.D.features, late: feature } }, remove: [], upsert: [{ ...member, feature: 'late', deps: [external.id], dep_states: { [external.id]: 'blocking' } }] })
    m.fx.flushLive()
    return { member: member.id, ghost: external.id, epic: external.epic }
  })
  await expect(page.locator('.bd-fh-name')).toHaveText('Late feature')
  // The header updates synchronously, while a snapping viewport defers layout.
  await expect.poll(() => page.evaluate(ids => {
    const { ctx } = m, ghost = ctx.L.secs.nq.items.find(it => it.t.id === ids.ghost)
    return { ghost: ghost?.ghost, lane: ctx.cols.includes(ids.epic), others: ctx.L.secs.plan.items.filter(it => it.t.id !== ids.member && !it.ghost).length }
  }, ids)).toEqual({ ghost: true, lane: true, others: 0 })
  await page.evaluate(ids => { const { ctx, fx } = m; ctx.vp.scrollTop = ctx.secs.nq.el.offsetTop; fx.update() }, ids)
  await expect(page.locator(`.bd-card[data-id="${ids.ghost}"]`)).toHaveClass(/ghost/)
})
test('compact Gantt and list focus use active membership', async ({ page }) => {
  await open(page, '?feature=pag&fmode=compact&view=gantt')
  const result = await page.evaluate(() => ['hist', 'plan', 'nq'].flatMap(k => m.ctx.L.secs[k].items).filter(i => !i.ghost && i.t.feature !== 'pag' && !i.t.also.includes('pag')).length)
  expect(result).toBe(0)
  await page.goto('/build-fixture/live?feature=pag&view=list')
  await expect(page.locator('.lr.dim').first()).toBeVisible()
  const mismatch = await page.locator('.lr[data-id]').evaluateAll(async rows => { const { ctx } = await import('/build-home/state.js'); return rows.filter(el => {
    const t = ctx.D.byId[el.dataset.id]; return el.classList.contains('dim') === (t.feature === 'pag' || t.also.includes('pag'))
  }).length })
  expect(mismatch).toBe(0)
})
test('a feature with only also-affects members shows no invented weighted figure', async ({ page }) => {
  await open(page, '')
  await page.evaluate(() => {
    const { ctx, fx } = m, t = ctx.D.plan[0]
    const feature = { key: 'alsoonly', label: 'Also only', hue: 42, epics: [], oldest: null, from: null, to: null,
      stats: { total: 0, done: 0, done_min: 0, pct: null, pct_min: null, reasons: ['no_weight'], orig: 0, added: 0, baseline: false, spark: [], also: 1 } }
    h.receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now,
      set: { features: { ...ctx.D.features, alsoonly: feature } }, remove: [], upsert: [{ ...t, also: [...t.also, 'alsoonly'] }] })
    fx.flushLive(); fx.setFeature('alsoonly')
  })
  await expect(page.locator('.bd-kv b').nth(0)).toHaveText('0/0')
  await expect(page.locator('.bd-kv b').nth(1)).toHaveText('—')
  await expect(page.locator('.bd-kv b').nth(1)).toHaveAttribute('title', 'No weighted tickets')
  await expect(page.locator('.bd-chip')).toHaveText('+1 also affect')
  await mode(page, 'compact').click()
  expect(await page.evaluate(() => m.ctx.L.secs.plan.items.filter(it => it.t.also.includes('alsoonly') && !it.ghost).length)).toBe(1)
})
test('a feature outside the six filter options focuses from its URL without paging empty membership', async ({ page }) => {
  await open(page, '?feature=d0', 'dense')
  await expect(page.locator('.bd-fh-name')).toHaveText('Auth v2')
  // The current design fixture retains d0 metadata but has no closed d0 members.
  expect(await page.evaluate(() => m.ctx.D.features.d0.oldest)).toBeNull()
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'idle')
  await expect(page.locator('.bd-kv b').nth(0)).toHaveText('0/0')
  await page.locator('#bd-fx').click()
  await expect(page.locator('#bd-fh')).toBeEmpty()
})
test('reduced motion disables the focus fade and retains design inner color timing', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.request.get('/build-fixture/live')
  await page.goto('/?feature=pag')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
  const fade = await page.locator('.bd-card').first().evaluate(el => Math.max(...getComputedStyle(el).transitionDuration.split(',').map(parseFloat)))
  expect(fade).toBeLessThanOrEqual(0.00001)
  await expect(page.locator('.bd-card .bd-in').first()).toHaveCSS('transition-duration', '0.14s, 0.14s, 0.14s, 0.14s')
})

async function tabTo(page, target) {
  for (let i = 0; i < 60; i++) {
    await page.keyboard.press('Tab')
    if (await target.evaluate(el => el === document.activeElement)) return
  }
  throw new Error('Tab did not reach ' + await target.evaluate(el => el.outerHTML))
}
async function expectKeyboardFocus(target) {
  await expect(target).toBeFocused()
  expect(await target.evaluate(el => el.matches(':focus-visible'))).toBe(true)
}
test('keyboard Tab and Enter or Space switch feature modes and clear with visible focus', async ({ page }) => {
  await open(page)
  await tabTo(page, mode(page, 'compact'))
  await expectKeyboardFocus(mode(page, 'compact'))
  await page.keyboard.press('Enter')
  await expect(page).toHaveURL(/fmode=compact/)
  await expect(mode(page, 'compact')).toHaveClass('on')
  await expectKeyboardFocus(mode(page, 'compact'))
  await page.keyboard.press('Shift+Tab')
  await expectKeyboardFocus(mode(page, 'focus'))
  await page.keyboard.press('Space')
  await expect(page).not.toHaveURL(/fmode=compact/)
  await expect(mode(page, 'focus')).toHaveClass('on')
  await expectKeyboardFocus(mode(page, 'focus'))
  await tabTo(page, page.locator('#bd-fx'))
  await page.keyboard.press('Enter')
  await expect(page.locator('#bd-fh')).toBeEmpty()
  await expect(page).not.toHaveURL(/feature=/)
  await expectKeyboardFocus(page.locator('[data-g="feature"]'))
})
for (const fmode of ['focus', 'compact']) test(`390px ${fmode} header has no sideways overflow and reachable controls`, async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await open(page, '?feature=pag' + (fmode === 'compact' ? '&fmode=compact' : ''))
  await expect(mode(page, fmode)).toHaveClass('on')
  const overflow = await page.evaluate(() => ({ viewport: innerWidth, document: document.documentElement.scrollWidth,
    header: document.querySelector('#bd-fh').scrollWidth, headerClient: document.querySelector('#bd-fh').clientWidth }))
  expect(overflow.document).toBeLessThanOrEqual(overflow.viewport)
  expect(overflow.header).toBeLessThanOrEqual(overflow.headerClient)
  for (const button of [mode(page, 'focus'), mode(page, 'compact'), page.locator('#bd-fx')]) {
    await expect(button).toBeVisible()
    const box = await button.boundingBox()
    expect(box.x).toBeGreaterThanOrEqual(0)
    expect(box.x + box.width).toBeLessThanOrEqual(390)
    expect(box.y).toBeGreaterThanOrEqual(0)
    expect(box.y + box.height).toBeLessThanOrEqual(844)
  }
})
