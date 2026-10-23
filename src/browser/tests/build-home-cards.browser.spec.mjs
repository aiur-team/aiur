import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { openParityPair, expectDesignParity, waitParityReady } from '../support/design-parity.mjs'

// unknowns.json: live.json plus schema-valid rows 9001–9012 and pack:unknowns/alpha.
// Reproduce from repo root (frozen now retained; only schema-valid values):
// jq -c '
// def add($s;$n;$x): . as $d | .sections[$s] += [($d.sections[$s][0] + {id:($n|tostring),num:$n,ord:($d.sections[$s]|length)} + $x)];
// add("now";9001;{pct:null}) | add("now";9002;{pct:40}) | add("nq";9003;{cx:null}) | add("nq";9004;{pts:null}) |
// add("plan";9005;{est:null,pts:2,override:null}) | add("now";9006;{agent:{model:null,name:null,state:"active",effort:null}}) |
// add("now";9007;{agent:{model:"muse",name:null,state:"active",effort:null}}) | add("now";9008;{agent:{model:"claude",name:null,state:null,effort:null}}) |
// add("now";9009;{agent:null}) | add("hist";9010;{status:"not_planned",end:.now}) | add("hist";9011;{status:"closed",end:.now}) |
// add("plan";9012;{}) | .sections.plan[-1].cue.failed={by:7,blocks:[]} | add("plan";9013;{id:"pack:unknowns/alpha",num:null,qpos:null}) |
// .history.total=(.sections.hist|length)' src/test/fixtures/build_home/live.json > src/test/fixtures/build_home/unknowns.json
// Non-Gantt density belongs to layout.js: span 1 is full. Element parity below
// covers line/mini/bar independently of the unfinished columns and Now band.
test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })
let errors

test.beforeEach(async ({ page }, info) => {
  errors = []; page.on('pageerror', error => errors.push(error.message))
  // Mutation runs serve the actual asset from an isolated worktree while reusing
  // the unchanged fixture backend. No source is inlined or reimplemented here.
  await routeCardAsset(page, info.project.metadata.cardsAsset)
})
test.afterEach(() => expect(errors).toEqual([]))

async function routeCardAsset(target, asset) {
  if (asset) await target.route('**/build-home/cards.js', async route =>
    route.fulfill({ contentType: 'text/javascript', body: await readFile(asset, 'utf8') }))
}
async function openCardParityPair(browser, cell, options) {
  const asset = test.info().project.metadata.cardsAsset
  const pair = await openParityPair(asset ? { newContext: async options => {
    const context = await browser.newContext(options), newPage = context.newPage.bind(context)
    context.newPage = async () => {
      const page = await newPage(), goto = page.goto.bind(page)
      // The parity network guard installs a page route. Install the asset route
      // immediately before navigation so it takes precedence over that guard.
      page.goto = async (...args) => { await routeCardAsset(page, asset); return goto(...args) }
      return page
    }
    return context
  } } : browser, cell, options)
  await expect(pair.product.locator('#bd-content')).toHaveCount(1)
  // Element parity owns card rendering, not history paging. Install the same
  // complete frozen fixture through the real store; paging has its own suite.
  const full = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/' + cell.dataset + '.json', import.meta.url), 'utf8'))
  await pair.product.evaluate(async sections => {
    const { ctx } = await import('/build-home/state.js'), { acceptSnapshot } = await import('/build-home/store.js')
    if (acceptSnapshot({ ...ctx.snap, sections }).error) throw new Error('Parity fixture intake failed')
  }, full.sections)
  return pair
}
async function open(page, dataset = 'unknowns') {
  await page.goto('/build-fixture/' + dataset)
  await expect(page.locator('#bd-content')).toHaveCount(1)
  await page.evaluate(async () => {
    window.st = await import('/build-home/state.js')
    window.cards = await import('/build-home/cards.js')
    window.store = await import('/build-home/store.js')
    window.ren = await import('/build-home/render.js')
    window.ctx = st.ctx; window.S = st.S
    window.draw = (id, tier = 'full') => {
      document.querySelector('#card-probe')?.remove()
      const det = ctx.L.det; ctx.L.det = tier
      const row = ctx.D.byId[id], el = st.fx.makeCard({ t: row, sec: row.sec, h: 160 })
      ctx.L.det = det
      el.id = 'card-probe'
      Object.assign(el.style, { position: 'fixed', left: '300px', top: '180px', width: '260px', height: tier === 'full' ? '160px' : '32px', zIndex: '9999' })
      ctx.content.append(el)
      return el.outerHTML
    }
    window.inject = (id, change) => {
      const snap = structuredClone(ctx.snap)
      const row = Object.values(snap.sections).flat().find(row => row.id === id)
      Object.assign(row, change)
      if (store.acceptSnapshot(snap).error) throw new Error('snapshot injection rejected')
    }
  })
  // Initial history paging relayouts replace ctx.L, including its band items.
  // Settle that response before a test captures or supplies layout objects.
  await expect.poll(() => page.evaluate(async () =>
    (await import('/build-home/history.js')).H.state)).toBe('idle')
}
const probe = page => page.locator('#card-probe')
async function draw(page, id, tier = 'full') { await page.evaluate(([id, tier]) => draw(id, tier), [id, tier]); return probe(page) }
async function unknownProgress(card) {
  await expect(card.locator('.bd-bar')).toHaveCount(0)
  expect(await card.evaluate(el => [el.style.getPropertyValue('--pct'), el.style.getPropertyValue('--ph')])).toEqual(['', ''])
}

test('hook replaces the placeholder; real section cards carry identity, status and modal origin', async ({ page }) => {
  await open(page, 'live')
  const card = page.locator('#bd-sec-plan .bd-card.full').first()
  await expect(card.locator('.bd-top')).toHaveCount(1)
  await expect(card.locator('.bd-status')).toContainText(/Q\d+/)
  await expect(card).not.toHaveClass(/dim|also|feat-on/)
  await page.evaluate(() => { st.fx.openModal = (row, options) => { window.clicked = { id: row.id, origin: options.origin.dataset.id } } })
  await card.click()
  const id = await card.getAttribute('data-id')
  expect(await page.evaluate(() => clicked)).toEqual({ id, origin: id })
})

for (const tier of ['full', 'line', 'mini', 'bar']) test(`tier markup: ${tier}`, async ({ page }) => {
  await open(page)
  const card = await draw(page, '9002', tier)
  await expect(card).toHaveClass(new RegExp('\\b' + tier + '\\b'))
  await expect(card.locator('.bd-title')).toHaveCount(['full', 'line'].includes(tier) ? 1 : 0)
  await expect(card.locator('.bd-top')).toHaveCount(tier === 'full' ? 1 : 0)
  await expect(card.locator('.bd-dot')).toHaveCount(['mini', 'line'].includes(tier) ? 1 : 0)
  await expect(card.locator('.bd-id')).toHaveCount(tier === 'bar' ? 0 : 1)
  if (tier === 'bar') { await expect(card.locator('.bd-in > :not(.sr-only)')).toHaveCount(0); await expect(card.locator('.bd-in')).toHaveAttribute('title', /#9002 · .* · Running/) }
  if (tier === 'mini') expect(await card.locator('.bd-in').evaluate(el => [...el.children].map(el => el.className))).toEqual(['sr-only', 'bd-dot', 'bd-id'])
})

test('Gantt detail respects height, lane caps and base cap', async ({ page }) => {
  await open(page)
  expect(await page.evaluate(() => {
    ctx.L.fs = 10; ctx.L.base = 'full'
    const tier = (h, lanes = 1) => cards.cardDetail({ gantt: true, h, lanes })
    const result = [tier(10), tier(20), tier(21), tier(88), tier(88, 2), tier(88, 3)]
    ctx.L.base = 'mini'; result.push(tier(100))
    return result
  })).toEqual(['bar', 'mini', 'line', 'full', 'line', 'mini', 'mini'])
})

for (const tier of ['full', 'line']) test(`unknown progress and models: ${tier}`, async ({ page }) => {
  await open(page)
  for (const value of [null, '50', -1, 101, '50%;background:red', 'NaN']) {
    await page.evaluate(value => inject('9001', { pct: value === 'NaN' ? NaN : value }), value)
    const card = await draw(page, '9001', tier); await unknownProgress(card)
    if (tier === 'full') await expect(card.locator('[data-unknown="pct"]')).toHaveText('—')
  }
  const card = await draw(page, '9007', tier)
  await expect(card.locator(tier === 'full' ? '.bd-ag > .ax-mono' : '.bd-lg.ax-mono')).toHaveText('M')
  await expect(card.locator(tier === 'full' ? '.bd-ag img, .bd-ag.fill' : 'img.bd-lg')).toHaveCount(0)
  await card.screenshot({ path: test.info().outputPath('unknown-model-' + tier + '.png') })
  await page.evaluate(() => inject('9007', { agent: { model: null, name: null, state: 'active' } }))
  await draw(page, '9007', tier)
  await expect(card.locator('.ax-mono')).toHaveText('?')
  if (tier === 'full') await expect(card.locator('.bd-ag')).toHaveAttribute('title', 'Model unknown · Running')
})

for (const theme of ['dark', 'light']) test(`unknown complexity uses faint in ${theme}`, async ({ page }) => {
  await open(page); await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme)
  const card = await draw(page, '9003')
  await expect(card.locator('.bd-cx.unk')).toHaveText('—')
  expect(await card.locator('.bd-cx').evaluate(el => {
    const ref = document.createElement('span'); ref.style.color = 'var(--faint)'; el.parentElement.append(ref)
    const same = getComputedStyle(ref).color === getComputedStyle(el).color; ref.remove()
    return { same, hue: el.style.getPropertyValue('--cxh') }
  })).toEqual({ same: true, hue: '' })
  await card.screenshot({ path: test.info().outputPath('unknown-complexity-' + theme + '.png') })
})

test('unknown points, estimates, queue numbers and unfiled identity stay explicit', async ({ page }) => {
  await open(page)
  await draw(page, '9004'); await expect(probe(page).locator('.bd-status')).toContainText('Open · not queued'); await expect(probe(page).locator('[data-unknown="pts"]')).toHaveText('—')
  await expect(probe(page).locator('.bd-cx')).toHaveAttribute('title', /points unknown/)
  await draw(page, '9005'); await expect(probe(page).locator('.bd-status')).toContainText('— · 2 pts')
  await expect(probe(page).locator('[data-unknown="est"]')).toHaveAttribute('title', 'Estimate unknown')
  await page.evaluate(() => inject('9005', { qpos: null, override: { hours: '3', reason: 'bad' } }))
  await draw(page, '9005'); await expect(probe(page).locator('.bd-status > span').first()).toContainText('Q?')
  await expect(probe(page).locator('[data-unknown="est"]')).toHaveCount(1)
  await page.evaluate(() => inject('9005', { override: { hours: 3, reason: 'approved' } }))
  await draw(page, '9005'); await expect(probe(page).locator('.bd-status')).toContainText('≈3h · 2 pts')
  await draw(page, 'pack:unknowns/alpha'); await expect(probe(page).locator('.bd-id')).toHaveText('—')
  await expect(probe(page).locator('.bd-id [title="Not filed yet"]')).toHaveCount(1)
  await expect(probe(page).locator('.bd-id [data-unknown]')).toHaveCount(0)
  await expect(probe(page).locator('.bd-status')).toContainText('Not filed')
})

test('history distinguishes outcomes and guards unknown dates and state', async ({ page }) => {
  await open(page)
  for (const [status, label] of [['done', 'Merged'], ['failed', 'Failed · closed'], ['not_planned', 'Not planned'], ['closed', 'Closed'], ['running', 'State unknown']]) {
    await page.evaluate(status => inject('9010', { status }), status)
    const card = await draw(page, '9010'); await expect(card.locator('.bd-status > span').first()).toHaveText(label)
    await expect(card.locator('.bd-status > span').last()).toHaveText('Oct 7')
    if (status === 'not_planned') await card.screenshot({ path: test.info().outputPath('not-planned.png') })
    expect(await card.evaluate(el => [el.classList.contains('failed'), el.classList.contains('np')])).toEqual([status === 'failed', status === 'not_planned'])
    await draw(page, '9010', 'line'); await expect(card.locator('.bd-lx')).toHaveCount(status === 'failed' ? 1 : 0)
    await page.evaluate(() => { S.f.tstate = ['merged']; st.fx.decorateAll(); cards.decorate(document.querySelector('#card-probe')) })
    expect(await card.evaluate(el => el.classList.contains('dim'))).toBe(status !== 'done')
    await page.evaluate(() => { S.f.tstate = [] })
  }
  await page.evaluate(() => inject('9010', { end: null }))
  await draw(page, '9010'); await expect(probe(page).locator('[data-unknown="end"]')).toHaveText('—')
  await expect(probe(page)).not.toContainText(/Jan 1|Dec 31/)
})

test('unknown state and missing agent never borrow a running look', async ({ page }) => {
  await open(page)
  for (const id of ['9008', '9009']) {
    const card = await draw(page, id)
    await expect(card.locator('.bd-status > span').first()).toHaveText('State unknown')
    await expect(card).not.toHaveClass(/ag-/); await expect(card.locator('.bd-glow')).toHaveCount(0)
    await draw(page, id, 'bar'); await expect(card.locator('.bd-in')).toHaveAttribute('title', / · State unknown$/)
  }
})

test('cues preserve order, failed blocks and override tooltips', async ({ page }) => {
  await open(page, 'live')
  const cues = await page.evaluate(() => ctx.D.plan.map(t => ({ id: t.id, cue: t.cue, override: t.override })))
  for (const row of cues) {
    if (!row.cue.promoted && !row.cue.held && !row.cue.wait && !row.cue.failed && !row.cue.blockedChain && !row.override) continue
    const card = await draw(page, row.id)
    if (row.cue.failed) await expect(card.locator('.bd-alert')).toContainText('Prereq #' + row.cue.failed.by + ' failed · blocks ' + row.cue.failed.blocks.map(n => '#' + n).join(' '))
    else {
      if (row.cue.promoted) await expect(card.locator('.promo')).toContainText('promoted 6m ago')
      if (row.cue.held) await expect(card.locator('.held')).toHaveAttribute('title', row.cue.held)
      if (row.cue.wait && !row.cue.blockedChain) await expect(card.locator('.bd-cues')).toContainText('waits on #' + row.cue.wait)
      if (row.cue.blockedChain) await expect(card.locator('.bd-cues')).toContainText('prereq chain failed')
      if (row.override) await expect(card.locator('.ovr')).toHaveAttribute('title', row.override.reason)
    }
  }
  await open(page)
  await draw(page, '9012'); await expect(probe(page).locator('.bd-alert')).toHaveText('Prereq #7 failed')
  await page.evaluate(() => inject('9012', { cue: { blockedChain: true, failed: null, wait: 7 } }))
  await draw(page, '9012'); await expect(probe(page)).toHaveClass(/blk/)
  await expect(probe(page).locator('.bd-cues')).toContainText('prereq chain failed')
  await expect(probe(page).locator('.bd-cues')).not.toContainText('waits on')
  await page.evaluate(() => inject('9012', { cue: { promoted: ctx.snap.now - 360000, held: 'held reason', wait: 7 }, override: { hours: 4, reason: 'override reason' } }))
  await draw(page, '9012')
  expect(await probe(page).locator('.bd-q').allTextContents()).toEqual([' promoted 6m ago', ' held', ' waits on #7', ' estimate overridden'])
})

test('hostile text stays literal in all tiers, cues and model slots', async ({ page }) => {
  await open(page, 'hostile')
  const rows = await page.evaluate(() => ctx.D.all.filter(t => t.title.includes('<') || t.cue?.held?.includes('<') || t.override?.reason?.includes('<')))
  expect(rows.length).toBeGreaterThan(0)
  for (const row of rows) for (const tier of ['full', 'line', 'mini', 'bar']) {
    const card = await draw(page, row.id, tier)
    if (['full', 'line'].includes(tier)) await expect(card.locator('.bd-title')).toHaveText(row.title)
    if (tier !== 'full') await expect(card.locator('.bd-in')).toHaveAttribute('title', new RegExp(row.title.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
    if (tier === 'full' && row.cue?.held && !row.cue.failed) await expect(card.locator('.held')).toHaveAttribute('title', row.cue.held)
    if (tier === 'full' && row.override && !row.cue?.failed) await expect(card.locator('.ovr')).toHaveAttribute('title', row.override.reason)
  }
  const hostile = '<img src=x onerror="window.__xss=1">\'"&'
  const planId = await page.evaluate(hostile => {
    const row = ctx.D.plan[0]
    inject(row.id, { cue: { ...row.cue, held: hostile, failed: null }, override: { hours: 3, reason: hostile } })
    return row.id
  }, hostile)
  await draw(page, planId)
  await expect(probe(page).locator('.held')).toHaveAttribute('title', hostile)
  await expect(probe(page).locator('.ovr')).toHaveAttribute('title', hostile)
  const nowId = rows[0].id
  await page.evaluate(([id, hostile]) => inject(id, { agent: { model: 'claude', name: hostile, state: 'active' } }), [nowId, hostile])
  await draw(page, nowId)
  await expect(probe(page).locator('.bd-ag')).toHaveAttribute('title', hostile + ' · Running')
  await expect(probe(page).locator('.bd-ag img')).toHaveAttribute('alt', '')
  await page.evaluate(([id, hostile]) => inject(id, { agent: { model: hostile, name: null, state: 'active' } }), [nowId, hostile])
  await draw(page, nowId)
  await expect(probe(page).locator('.bd-ag')).toHaveAttribute('title', hostile + ' · Running')
  await expect(probe(page).locator('.ax-mono')).toHaveText('<')
  await probe(page).hover()
  expect(await page.evaluate(() => window.__xss)).toBeUndefined()
  await expect(page.locator('#bd-content img[src="x"]')).toHaveCount(0)
})

test('client guards malicious numbers, missing epic and feature keys', async ({ page }) => {
  await open(page)
  const warnings = []; page.on('console', msg => { if (msg.type() === 'warning') warnings.push(msg.text()) })
  await page.evaluate(() => {
    inject('9001', { cx: 9, num: '1<b>', epic: 'ghost-epic', pct: '50%;background:red' })
    ctx.D.epics.bugs.hue = '1);x'; S.feature = 'ghost-feature'
  })
  let card = await draw(page, '9001'); await draw(page, '9001')
  await expect(card).toHaveClass(/unsorted/); await expect(card.locator('.bd-id')).toHaveText('#—')
  await expect(card.locator('.bd-id [data-unknown="num"]')).toHaveAttribute('title', 'Ticket number unknown')
  await expect(card.locator('.bd-cx.unk')).toHaveText('—'); await unknownProgress(card)
  expect(warnings.filter(s => s.includes('ghost-epic')).length).toBe(1)
  expect(await card.evaluate(el => el.style.getPropertyValue('--ec'))).toBe('var(--muted)')
  for (const cx of [0, 2.5]) { await page.evaluate(cx => inject('9001', { cx, epic: 'bugs' }), cx); card = await draw(page, '9001'); await expect(card.locator('.bd-cx.unk')).toHaveText('—') }
  expect(await card.evaluate(el => el.style.getPropertyValue('--h'))).toBe('')
  expect(await card.innerHTML()).not.toContain('background:red'); await expect(card.locator('.bd-id b')).toHaveCount(0)
  await page.evaluate(() => inject('9012', { qpos: '1<b>' }))
  card = await draw(page, '9012')
  await expect(card.locator('.bd-status > span').first()).toContainText('Q—')
  await expect(card.locator('[data-unknown="qpos"]')).toHaveAttribute('title', 'Queue position unknown')
  await expect(card.locator('.bd-status b')).toHaveCount(0)
  await page.evaluate(() => inject('9012', { cue: { failed: { by: '1<b>', blocks: ['2<img>'] }, promoted: 'bad', wait: '3<i>' } }))
  await draw(page, '9012')
  await expect(probe(page).locator('.bd-alert')).toHaveText('Prereq #— failed · blocks #—')
  await expect(probe(page).locator('.bd-alert b, .bd-alert img')).toHaveCount(0)
  expect(await page.evaluate(() => { delete ctx.D.byId['9012']; cards.decorate(document.querySelector('#card-probe')); return true })).toBe(true)
})

test('promotion ages use payload time, tick without rebuilding and restart after remount', async ({ page }) => {
  await page.clock.install()
  await page.addInitScript(() => {
    window.minuteTimers = new Set(); window.minuteRegistrations = 0
    const start = window.setInterval, stop = window.clearInterval
    window.setInterval = (fn, delay, ...args) => {
      const id = start(fn, delay, ...args)
      if (delay === 60000) { minuteTimers.add(id); minuteRegistrations++ }
      return id
    }
    window.clearInterval = id => { minuteTimers.delete(id); return stop(id) }
  })
  await open(page, 'live')
  for (let mount = 0; mount < 2; mount++) {
    // Finish any history response before observing identity across the age tick.
    // Paging legitimately rebuilds section cards independently of this timer.
    await page.evaluate(async () => {
      const { loadEarlier } = await import('/build-home/history.js')
      ctx.vp.scrollTop = ctx.secs.plan.el.offsetTop; ren.update()
      await loadEarlier()
      ctx.vp.scrollTop = ctx.secs.plan.el.offsetTop; ren.update()
    })
    const promo = page.locator('#bd-sec-plan .bd-q.promo').first()
    await expect(promo).toContainText('promoted 6m ago')
    expect(await page.evaluate(() => ({ active: minuteTimers.size, registered: minuteRegistrations }))).toEqual({ active: 1, registered: mount + 1 })
    await promo.evaluate(el => { window.promoNode = el })
    await page.clock.runFor(60000)
    await expect(promo).toContainText('promoted 7m ago')
    expect(await promo.evaluate(el => el === window.promoNode)).toBe(true)
    if (mount === 0) {
      await page.evaluate(() => window.liveSocket.main.pushLinkPatch(new Event('click'), '/commands', null))
      await expect(page.locator('#build-root')).toHaveCount(0)
      await page.evaluate(() => window.liveSocket.main.pushLinkPatch(new Event('click'), '/build', null))
      await expect(page.locator('#bd-content')).toHaveCount(1)
    }
  }
  await page.request.get('/build-control/diff?name=card-clock-3h')
  await expect(page.locator('#bd-sec-plan .bd-q.promo').first()).toContainText('promoted 3h ago')
  expect(await page.evaluate(async () => {
    const { setNow } = await import('/build-home/clock.js')
    setNow(1); const future = cards.age(100000); setNow(null)
    return { future, unknown: cards.age(100000) }
  })).toEqual({ future: 'just now', unknown: '<span data-unknown="promoted" title="Promotion time unknown">—</span>' })
})

test('named live diff clears known progress, band refresh rereads rows by id', async ({ page }) => {
  await open(page)
  const card = await draw(page, '9002'); await expect(card.locator('.bd-status')).toContainText('40%')
  await page.evaluate(() => {
    window.beforeRefresh = document.querySelector('#card-probe')
    const it = beforeRefresh._it
    // C9-T08 owns band creation; refresh consumes its documented existing-item
    // contract. Hold real live relayout while testing this independent refresh.
    it.key = 'probe-band'; it.y = 20; it.el = beforeRefresh
    // Any other relayout may still replace ctx.L, so supply the band per refresh.
    window.refreshBand = id => {
      ctx.bandMap[it.key] = { x: 120, w: 260 }; ctx.L.band.items = [it]; cards.refreshTicket(id)
    }
    ctx.bandMap[it.key] = { x: 120, w: 260 }; ren.place(beforeRefresh, it); window.bandItem = it; ctx.snapping = true
  })
  await page.request.get('/build-control/diff?name=card-pct-null')
  await expect.poll(() => page.evaluate(() => ctx.D.byId['9002'].pct)).toBeNull()
  expect(await page.evaluate(() => {
    refreshBand('9002'); bandItem.el.id = 'card-probe'
    return { replaced: bandItem.el !== beforeRefresh, connected: !beforeRefresh.isConnected,
      noanim: bandItem.el.classList.contains('noanim'), left: bandItem.el.style.left, top: bandItem.el.style.top }
  })).toEqual({ replaced: true, connected: true, noanim: true, left: '120px', top: '20px' })
  await unknownProgress(card); await expect(card.locator('[data-unknown="pct"]')).toHaveText('—')
  await expect(card.locator('.bd-status')).not.toContainText('40%')
  expect(await page.evaluate(() => {
    ctx.D.byId['9002'] = { ...bandItem.t, pct: 73 }; refreshBand('9002')
    return bandItem.el.querySelector('.bd-status').textContent
  })).toBe('Running73%')
})

// Future regression guard for C9-T03's existing two-frame rule.
test('new section cards release noanim only after two frames', async ({ page }) => {
  await open(page, 'live')
  const now = await page.evaluate(() => ctx.snap.now)
  await page.clock.install({ time: now - 1000 }); await page.clock.pauseAt(now)
  expect(await page.evaluate(() => { ren.relayout(); window.firstCard = [...ctx.R.values()][0]; return firstCard.classList.contains('noanim') })).toBe(true)
  await page.clock.runFor(48)
  expect(await page.evaluate(() => !firstCard.classList.contains('noanim'))).toBe(true)
})

// Page-wide parity also needs C9-T04 columns and C9-T08's Now band. Compare
// actual design card elements in their original tier here, with equal region
// geometry; do not mask differences or substitute design HTML into the product.
async function compareCard(pair, selector, name, parts = []) {
  const design = pair.design.locator(selector).first()
  const input = await design.evaluate(el => {
    const box = el.getBoundingClientRect(), style = getComputedStyle(el)
    window.cardAnchor = document.createComment('card origin'); el.before(window.cardAnchor)
    window.cardOriginal = { id: el.id, style: el.getAttribute('style') }; el.id = 'parity-card'
    return { num: el._it.t.num, tier: ['full', 'line', 'mini', 'bar'].find(k => el.classList.contains(k)),
      width: box.width, height: box.height, fontSize: style.fontSize, it: { h: el._it.h, sec: el._it.sec, ghost: el._it.ghost } }
  })
  expect(input.tier).toBeTruthy()
  await pair.product.evaluate(async input => {
    const { ctx, fx } = await import('/build-home/state.js')
    document.querySelector('#parity-card')?.remove()
    const t = ctx.D.all.find(t => t.num === input.num)
    if (!t) throw new Error('Design card missing from product fixture: ' + input.num)
    const det = ctx.L.det; ctx.L.det = input.tier
    const el = fx.makeCard({ ...input.it, t })
    ctx.L.det = det
    el.id = 'parity-card'; ctx.content.append(el)
  }, input)
  for (const side of ['design', 'product']) await pair[side].evaluate(input => {
    const el = document.querySelector('#parity-card')
    // A region comparison has a stable integer raster origin and canvas.
    const holder = document.createElement('div'); holder.id = 'parity-region'
    Object.assign(holder.style, { position: 'fixed', left: '0', top: '100px', width: Math.ceil(input.width + 16) + 'px', height: Math.ceil(input.height + 16) + 'px', background: 'var(--bg)', zIndex: '99999' })
    holder.className = 'bd-root'; document.body.append(holder); holder.append(el)
    Object.assign(holder.style, { display: 'block', margin: '0', padding: '0', minHeight: '0', overflow: 'visible' })
    Object.assign(el.style, { position: 'absolute', left: '8px', top: '8px', width: input.width + 'px', height: input.height + 'px', fontSize: input.fontSize, transition: 'none' })
  }, input)
  try {
    await expect(pair.product.locator('#parity-card')).toHaveClass(new RegExp('\\b' + input.tier + '\\b'))
    if (parts.length) for (const part of parts) {
      const region = '#parity-card .' + part, visible = await pair.design.locator(region).isVisible()
      expect(await pair.product.locator(region).isVisible(), part + ' responsive visibility').toBe(visible)
      if (visible) await expectDesignParity(pair, { name: name + '-' + part, region })
    }
    else await expectDesignParity(pair, { name, region: '#parity-region' })
  } finally {
    await pair.design.evaluate(() => {
      const el = document.querySelector('#parity-card'); cardAnchor.replaceWith(el)
      el.id = cardOriginal.id
      if (cardOriginal.style === null) el.removeAttribute('style'); else el.setAttribute('style', cardOriginal.style)
      document.querySelector('#parity-region').remove()
    })
    await pair.product.locator('#parity-region').evaluate(el => el.remove())
  }
  return input.tier
}

test.describe('parity', () => {
  test.setTimeout(180000)
  for (const dataset of ['live', 'dense', 'newrepo', 'noqueue']) for (const span of [1, 7, 21, 30])
    for (const width of [1440, 390]) for (const theme of ['dark', 'light']) for (const palette of ['gruvbox', 'aiur']) {
      const name = `${dataset}-${span}-${width}-${theme}-${palette}`
      test(`card elements ${name}`, async ({ browser }) => {
        const cell = { dataset, viewport: { width, height: 900 }, theme, palette }
        const pair = await openCardParityPair(browser, cell, { query: `span=${span}`, productPending: true })
        try {
          await expect(pair.product.locator('#bd-content')).toHaveCount(1)
          // Fixture estimates preserve the design values across every section.
          const selector = '.bd-card.hist, .bd-card.nq, .bd-card.now, .bd-card.plan'
          const count = await pair.design.locator(selector).count()
          expect(count).toBeGreaterThan(0)
          const tier = await compareCard(pair, selector, 'card-' + name)
          test.info().annotations.push({ type: 'span-tier', description: `${dataset}: span=${span}, width=${width} -> ${tier}` })
        } finally { await pair.close() }
      })
    }
  for (const width of [1440, 390]) for (const theme of ['dark', 'light']) for (const palette of ['gruvbox', 'aiur']) {
    test(`now states and plan cues ${width}-${theme}-${palette}`, async ({ browser }) => {
      const name = `${width}-${theme}-${palette}`
      const pair = await openCardParityPair(browser, { dataset: 'live', viewport: { width, height: 900 }, theme, palette }, { productPending: true })
      try {
        await expect(pair.product.locator('#bd-content')).toHaveCount(1)
        const states = ['active', 'error', 'retries', 'command', 'paused', 'parked']
        for (const state of states) {
          const id = await pair.design.locator('.bd-card.now').evaluateAll((nodes, state) => nodes.find(el => el._it.t.agent.state === state)?.dataset.id, state)
          expect(id, `design must expose ${state}`).toBeTruthy()
          await compareCard(pair, `.bd-card[data-id="${id}"]`, 'state-' + state + '-' + name)
        }
        const plans = await pair.design.locator('.bd-card.plan.full').evaluateAll(nodes => nodes.map(el => ({ id: el.dataset.id, cue: !!el.querySelector('.bd-cues'), alert: !!el.querySelector('.bd-alert') })))
        expect(plans.some(p => p.cue)).toBe(true)
        for (const row of plans.filter(p => p.cue || p.alert)) {
          // Include the shared estimate label alongside the override cue.
          await compareCard(pair, `.bd-card[data-id="${row.id}"]`, 'plan-' + row.id + '-' + name,
            ['bd-top', 'bd-title', row.alert ? 'bd-alert' : 'bd-cues', 'bd-status'])
        }
      } finally { await pair.close() }
    })
  }

  for (const theme of ['dark', 'light']) for (const palette of ['gruvbox', 'aiur']) {
    test(`original-renderer tier and container witnesses ${theme}-${palette}`, async ({ browser }) => {
      const cell = { dataset: 'live', viewport: { width: 390, height: 900 }, theme, palette }
      const pair = await openCardParityPair(browser, cell, { productPending: true })
      try {
        const source = await readFile(new URL('../../test/fixtures/build_home/design-source/assets/build.js', import.meta.url), 'utf8')
        const anchor = '  window.AiurBuild = {'
        expect(source.split(anchor)).toHaveLength(2)
        // Expose the original renderer, as the existing render-parity harness
        // does for update(). Neither implementation nor SVG/CSS is copied.
        const original = source.replace(anchor, `window.__cardWitness = (tier, width) => {
          const t = D.hist.find(t => t.status === "done"), det = L.det;
          L.det = tier; const el = makeCard({t, sec:t.sec, h:tier === "full" ? 122.2 : 30}); L.det = det;
          el.id = "card-witness"; el.style.width = width + "px"; el.style.height = (tier === "full" ? 122.2 : 30) + "px";
          content.append(el);
        };\n${anchor}`)
        await pair.design.route('**/assets/build.js*', route => route.fulfill({ contentType: 'text/javascript', body: original }))
        await pair.design.reload(); await waitParityReady(pair.design, 'board', 'design')
        for (const [tier, width] of [['line', 140], ['mini', 90], ['full', 90]]) {
          await pair.design.evaluate(([tier, width]) => window.__cardWitness(tier, width), [tier, width])
          expect(await pair.design.locator('#card-witness').evaluate(el => el.getBoundingClientRect().width)).toBe(width)
          await compareCard(pair, '#card-witness', `witness-${tier}-${width}-${theme}-${palette}`)
          await pair.design.locator('#card-witness').evaluate(el => el.remove())
        }
      } finally { await pair.close() }
    })
  }

})
