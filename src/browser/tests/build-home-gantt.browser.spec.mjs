import { test, expect } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles' })
test.beforeEach(async ({ page }) => {
  await openFixture(page)
  await page.evaluate(async () => {
    window.g = await import('/build-home/gantt.js')
    window.layout = await import('/build-home/layout.js')
    window.state = await import('/build-home/state.js')
    window.cards = await import('/build-home/cards.js')
    window.NOW = Date.parse('2026-10-07T14:20:00-07:00')
    window.H = 3600000
    window.at = text => Date.parse(text + '-07:00')
    window.context = (extra = {}) => ({ now: NOW, nowRows: [], span: 1, pph: 18, flow: false, K: 2, compact: false, colKey: layout.colKey, CH: layout.CH, gap: 14, det: 'full', hs: { items: [], marks: [], labels: [], h: 0 }, y: 40, cum: 0, unknown: false, ...extra })
    window.histRun = (rows, extra) => {
      const ctx = context(extra), result = g.ganttHist(rows.map(t => ({ t })), ctx)
      return { ...result, ...ctx.hs }
    }
    window.row = (id, start, end, extra = {}) => ({ id, num: 7, title: 'Ticket', sec: 'hist', status: 'done', epic: 'a', start, end, est: null, pts: 3, deps: [], also: [], ...extra })
    window.initCards = () => {
      state.resetState(); state.S.view = 'gantt'
      state.ctx.snap = { daemon: { state: 'live' }, sources: { agents: { state: 'ok' } } }
      state.ctx.L = { det: 'full', base: 'full', fs: 13 }
      state.ctx.D = { epics: { a: { key: 'a', hue: 100 } }, features: {}, byId: {} }
    }
  })
})

test('U1 start unknown is end-anchored, marked, and clear of breaks and section header', async ({ page }) => {
  const result = await page.evaluate(() => {
    const end = at('2026-10-06T12:00:00'), unknown = row('u', null, end)
    return [histRun([row('known', end - 16 * H, end - 15 * H), unknown]), histRun([unknown])].map(o => {
      const it = o.items.find(i => i.t.id === 'u')
      return { error: Math.abs(it.y + it.h - o.tY(end)), h: it.h, marked: it.startUnknown, y: it.y, clear: o.marks.every(m => it.y + it.h <= m.y || it.y >= m.y + m.h) }
    })
  })
  for (const it of result) {
    expect(it.error).toBeLessThan(1e-9); expect(it.h).toBeCloseTo(29.9, 10)
    expect(it.marked).toBe(true); expect(it.y).toBeGreaterThanOrEqual(48); expect(it.clear).toBe(true)
  }
})
test('U2 all starts unknown reserve real axis space without overlapping breaks', async ({ page }) => {
  expect(await page.evaluate(() => {
    const o = histRun([row('a', null, NOW - 30 * H), row('b', null, NOW - H)])
    return { n: o.items.length, anchored: o.items.every(i => Math.abs(i.y + i.h - o.tY(i.t.end)) < 1e-9), clear: o.items.every(i => o.marks.every(m => i.y + i.h <= m.y || i.y >= m.y + m.h)) }
  })).toEqual({ n: 2, anchored: true, clear: true })
})
test('U3 no interval produces an empty finite section', async ({ page }) => {
  expect(await page.evaluate(() => {
    const o = histRun([], { nowRows: [row('running', null, null)] })
    return { h: o.h, items: o.items, segs: o.segs, marks: o.marks, labels: o.labels }
  })).toEqual({ h: 58, items: [], segs: [], marks: [], labels: [] })
})
test('U4 unknown end is skipped even for direct callers', async ({ page }) => {
  expect(await page.evaluate(() => {
    const o = histRun([row('no-end', NOW - H, null)])
    return { items: o.items, segs: o.segs, h: o.h }
  })).toEqual({ items: [], segs: [], h: 58 })
})
test('U5 zero duration keeps design minimum; negative duration clamps to end', async ({ page }) => {
  const result = await page.evaluate(() => [1, 3].map(span => {
    const o = histRun([row('zero', NOW - H, NOW - H), row('negative', NOW - H + 300000, NOW - H), row('axis', NOW - 2 * H, NOW)], { span })
    return o.items.filter(i => i.t.id !== 'axis').map(i => ({ h: i.h, y: i.y, endY: o.tY(i.t.end) }))
  }))
  for (const [n, items] of result.entries()) for (const it of items) { expect(it.h).toBeCloseTo(n ? 4 : 29.9, 10); expect(it.y).toBe(it.endY) }
})
test('U6 design guard: gaps greater than three hours fold; labels begin at twenty hours', async ({ page }) => {
  const result = await page.evaluate(() => [3, 4.5, 26].map(hours => {
    const end = at('2026-10-05T18:00:00'), next = end + hours * H
    const o = histRun([row('a', end - H, end), row('b', next, next + H)], { now: next + H })
    return o.marks
  }))
  expect(result[0]).toEqual([])
  expect(result[1]).toEqual([{ kind: 'brk', y: 66, h: 30, label: '' }])
  expect(result[2]).toEqual([{ kind: 'brk', y: 66, h: 30, label: 'Idle · Mon Oct 5 18:00 → Tue Oct 6 20:00 · 26h' }])
})
test('U7 design guard: full history cards display times and duration badges', async ({ page }) => {
  expect(await page.evaluate(() => {
    initCards()
    return [['2026-10-05T22:00:00', '2026-10-07T02:00:00'], ['2026-10-07T09:10:00', '2026-10-07T11:40:00']].map(([a, b], i) => {
      const t = row('card' + i, at(a), at(b)); state.ctx.D.byId[t.id] = t
      const el = cards.makeCard({ t, sec: 'hist', h: 150 })
      return [el.querySelector('.bd-time').innerHTML, el.querySelector('.bd-badges').textContent, el.querySelectorAll('.bd-status').length]
    })
  })).toEqual([['Oct 5 22:00<br>→ Oct 7 02:00', '28h3 pts', 0], ['Oct 7 09:10<br>→ 11:40', '2.5h3 pts', 0]])
})
test('U8 design guard: overlapping cards split lanes and cap card tiers', async ({ page }) => {
  expect(await page.evaluate(() => {
    initCards()
    const o = histRun([0, 1, 2].map(n => row('overlap' + n, NOW - (8 - n) * H, NOW)))
    return o.items.map(i => [i.lane, i.lanes, cards.cardDetail(i)])
  })).toEqual([[0, 3, 'mini'], [1, 3, 'mini'], [2, 3, 'mini']])
})
test('U9 unknown planned estimates are marked and propagate a lower bound; overrides count', async ({ page }) => {
  expect(await page.evaluate(() => {
    const first = g.planGantt([{ t: row('unknown', null, null, { sec: 'plan' }) }, { t: row('override', null, null, { sec: 'plan', epic: 'b', est: 2, override: { hours: 6 } }) }], context())
    const next = g.planGantt([{ t: row('next', null, null, { sec: 'plan', est: 1 }) }], context({ cum: (first.end - 40) / 18, unknown: first.unknown }))
    return { items: first.items.map(i => [i.h, i.estUnknown ?? false, i.gantt]), unknown: first.unknown, label: next.label.t }
  })).toEqual({ items: [[32.5, true, true], [108, false, true]], unknown: true, label: '≈ ≥+6h' })
})
test('U10 band height honors overrides and unknown estimate uses the floor', async ({ page }) => {
  expect(await page.evaluate(async () => { const estimate = await import('/build-home/estimate.js'); return [g.bandGanttHeight({ est: 2, override: { hours: 8 } }, context()), g.bandGanttHeight({ est: null }, context()), estimate.estHours({ est: null, cx: 5 }), estimate.estHours({ est: 2, override: { hours: 8 } })] })).toEqual([144, 32.5, null, 8])
  expect(await page.evaluate(() => {
    initCards()
    const t = row('band-unknown', null, null, { sec: 'now' })
    state.ctx.D.byId[t.id] = t
    const el = cards.makeCard({ t, sec: 'now', h: g.bandGanttHeight(t, context()), gt: true })
    return { marked: el.classList.contains('est-unknown'), planned: el.classList.contains('gplan'), gt: el.classList.contains('gt'), title: el.querySelector('.bd-in').title }
  })).toEqual({ marked: true, planned: false, gt: false, title: '#7 · Ticket · State unknown · estimate unknown' })
})
test('U11 EC-20 design guard: DST nights terminate, labels remain ordered, elapsed time sets heights', async ({ page }) => {
  const result = await page.evaluate(() => [
    ['2026-11-01T00:30:00-07:00', '2026-11-01T03:30:00-08:00'],
    ['2026-03-08T01:30:00-08:00', '2026-03-08T03:30:00-07:00']
  ].map(([a, b]) => {
    const end = Date.parse(b), o = histRun([row('dst', Date.parse(a), end)], { now: end })
    return { h: o.items[0].h, ticks: o.labels.map(l => l.t), count: o.labels.length, finite: o.labels.every(l => Number.isFinite(l.y)), ordered: o.labels.every((l, i) => i === 0 || l.y > o.labels[i - 1].y) }
  }))
  expect(result.map(r => r.h)).toEqual([71, 2.3 * 13])
  expect(result.map(r => r.ticks)).toEqual([['02:00'], []])
  for (const r of result) { expect(r.count).toBeLessThan(400); expect(r.finite).toBe(true); expect(r.ordered).toBe(true) }
})
test('U12 trailing segment uses payload now despite an unrelated browser clock', async ({ page }) => {
  await page.clock.setFixedTime(new Date('2030-01-01T00:00:00Z'))
  expect(await page.evaluate(() => {
    const o = histRun([row('clock', NOW - 2 * H, NOW - H)])
    return o.segs.at(-1).t1
  })).toBe(Date.parse('2026-10-07T14:20:00-07:00'))
})

test('B3 unknown cards expose honest markers and escape hostile titles', async ({ page }) => {
  expect(await page.evaluate(() => {
    initCards()
    const t = row('unknown', null, NOW, { title: '<img src=x onerror="window.__ganttXss=1">' })
    state.ctx.D.byId[t.id] = t
    const o = histRun([t]), el = cards.makeCard(o.items[0]); document.body.append(el)
    const plan = row('estimate', null, null, { sec: 'plan' }); state.ctx.D.byId[plan.id] = plan
    const planned = cards.makeCard(g.planGantt([{ t: plan }], context()).items[0]); document.body.append(planned)
    return { start: el.classList.contains('start-unknown'), title: el.querySelector('.bd-in').title, est: planned.classList.contains('est-unknown'), estTitle: planned.querySelector('.bd-in').title, imgs: el.querySelectorAll('img').length, xss: window.__ganttXss ?? null, nan: document.body.innerText.includes('NaN') }
  })).toEqual({ start: true, title: '#7 · <img src=x onerror="window.__ganttXss=1"> · start unknown', est: true, estTitle: '#7 · Ticket · estimate unknown', imgs: 0, xss: null, nan: false })
})

test('B3 unknown-start snapshot renders its card end-anchored on the history axis', async ({ page }) => {
  await page.goto('/build-fixture/live?view=gantt')
  await expect(page.locator('#bd-content')).toHaveCount(1)
  const result = await page.evaluate(async () => {
    const { ctx, S, fx } = await import('/build-home/state.js'), { receive } = await import('/build-home/hook.js')
    const { ganttHist } = await import('/build-home/gantt.js'), { CH, colKey } = await import('/build-home/layout.js')
    const end = ctx.snap.now, title = '<img src=x onerror="window.__ganttXss=1">'
    const t = { ...ctx.snap.sections.hist[0], id: 'unknown-snapshot', num: 7, start: null, end, title }
    S.span = 1; S.histFrom = end - 86400000
    receive({ ...ctx.snap, kind: 'snapshot', generation: ctx.proto.generation + 1, sections: { hist: [t], now: [], plan: [], nq: [] }, history: { ...ctx.snap.history, from: end - 86400000, total: 1, more: false } })
    S.ready = false; ctx.vp.scrollTop = 0; fx.update()
    const it = ctx.L.secs.hist.items.find(i => i.t.id === t.id)
    const hs = { items: [], marks: [], labels: [], h: 0 }
    const { tY } = ganttHist([{ t }], { now: end, nowRows: [], span: 1, pph: 18, flow: S.flow, colKey, CH, compact: false, hs })
    const el = document.querySelector('#bd-sec-hist .bd-card[data-id="unknown-snapshot"]')
    const rect = el.getBoundingClientRect(), origin = ctx.secs.hist.el.getBoundingClientRect().top
    return { marked: el.classList.contains('start-unknown'), title: el.querySelector('.bd-in').title, axisError: Math.abs(it.y + it.h - tY(end)), renderedError: Math.abs(rect.bottom - origin - tY(end)), h: parseFloat(el.style.height), imgs: el.querySelectorAll('img').length, xss: window.__ganttXss ?? null, nan: document.body.innerText.includes('NaN') }
  })
  expect(result.marked).toBe(true); expect(result.title).toBe('#7 · <img src=x onerror="window.__ganttXss=1"> · start unknown')
  expect(result.axisError).toBeLessThan(1e-9); expect(result.renderedError).toBeLessThan(0.1); expect(result.h).toBeCloseTo(29.9, 9)
  expect(result.imgs).toBe(0); expect(result.xss).toBe(null); expect(result.nan).toBe(false)
})

test('B5/B7 fixture route switches Gantt and Timeline with the legend, time label and planned hatching', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await page.goto('/build-fixture/live?view=gantt')
  await expect(page.locator('#bd-content')).toHaveCount(1)
  await expect(page.locator('.bd-leg-h')).toHaveCount(1)
  await expect(page.locator('.bd-lane-g')).toHaveText('Time')
  expect(await page.evaluate(async () => {
    const { ctx, S } = await import('/build-home/state.js')
    return { view: S.view, hist: ctx.L.secs.hist.items.length, plan: ctx.L.secs.plan.items.every(i => i.gantt), finite: ['hist', 'plan'].every(s => ctx.L.secs[s].items.every(i => Number.isFinite(i.y) && Number.isFinite(i.h))) }
  })).toMatchObject({ view: 'gantt', plan: true, finite: true })
  await page.evaluate(async () => {
    const { ctx, fx } = await import('/build-home/state.js')
    ctx.snapping = true; fx.scrollVP(ctx.secs.plan.el.offsetTop, false); fx.update()
  })
  await expect(page.locator('.bd-card.gplan').first()).toBeVisible()
  expect(await page.locator('.bd-card.gplan .bd-in').first().evaluate(el => {
    const style = getComputedStyle(el)
    return { border: style.borderTopStyle, hatch: style.backgroundImage.includes('gradient') }
  })).toEqual({ border: 'dashed', hatch: true })
  await page.getByRole('tab', { name: 'Timeline', exact: true }).click()
  await expect(page.locator('.bd-card.gplan')).toHaveCount(0)
  await expect(page.locator('.bd-leg-h')).toHaveCount(0)
  await expect(page.locator('.bd-lane-g')).toHaveText('Order')
  const timelineClasses = async () => {
    await page.evaluate(async () => {
      const { ctx, fx } = await import('/build-home/state.js')
      ctx.snapping = true; fx.scrollVP(ctx.secs.plan.el.offsetTop, false); fx.update()
    })
    await expect.poll(() => page.evaluate(async () => {
      const { ctx } = await import('/build-home/state.js')
      return [...ctx.R.values()].filter(el => el.classList.contains('noanim')).length
    })).toBe(0)
    return page.evaluate(async () => {
      const { ctx } = await import('/build-home/state.js')
      return [...ctx.R].map(([id, el]) => [id, el.className]).sort()
    })
  }
  const first = await timelineClasses()
  expect(first.length).toBeGreaterThan(0)
  await page.getByRole('tab', { name: 'Gantt', exact: true }).click()
  await expect(page.locator('.bd-leg-h')).toHaveCount(1)
  await expect(page.locator('#bd-edges')).toHaveClass(/gantt/)
  await page.getByRole('tab', { name: 'Timeline', exact: true }).click()
  await expect(page.locator('.bd-card.gplan')).toHaveCount(0)
  await expect(page.locator('.bd-lane-g')).toHaveText('Order')
  expect(await timelineClasses()).toEqual(first)
})

test('Gantt hides history time labels at 150 px width or less', async ({ page }) => {
  const result = await page.evaluate(() => {
    initCards()
    const ticket = row('short-history', NOW - 4 * H, NOW, { pts: 3 })
    state.ctx.D.byId[ticket.id] = ticket
    const inspect = width => {
      const card = cards.makeCard({ t: ticket, sec: 'hist', h: width })
      card.style.width = `${width}px`; document.body.append(card)
      const time = card.querySelector('.bd-time')
      const badge = card.querySelector('.bd-badges span')
      return { hasTime: !!time, display: getComputedStyle(time).display, width: card.getBoundingClientRect().width,
        badgeFont: badge && parseFloat(getComputedStyle(badge).fontSize) }
    }
    return [250, 150, 96].map(inspect)
  })
  expect(result).toHaveLength(3)
  for (const [index, width] of [250, 150, 96].entries()) {
    const card = result[index]
    expect(card.hasTime).toBe(true)
    expect(card.width).toBe(width)
    expect(card.display).toBe(width <= 150 ? 'none' : 'block')
    expect(card.badgeFont).toBeCloseTo(13 * (width <= 150 ? 0.62 : 0.7), 2)
  }
})

test('B4 EC-20 rendered card heights stay equal across zones while tick labels differ', async ({ browser }) => {
  const results = []
  for (const timezoneId of ['America/Los_Angeles', 'Asia/Kolkata']) {
    const context = await browser.newContext({ timezoneId, httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 } })
    try {
      const page = await context.newPage(); await page.goto('/build-fixture/live?view=gantt')
      await expect(page.locator('#bd-content')).toHaveCount(1)
      results.push(await page.evaluate(async () => {
        const { ctx, S, fx } = await import('/build-home/state.js'), { acceptSnapshot } = await import('/build-home/store.js')
        const end = Date.parse('2026-10-07T02:00:00Z'), original = ctx.snap.sections.hist[0]
        const row = { ...original, id: 'timezone-history', start: end - 8 * 3600000, end }
        const result = acceptSnapshot({ ...ctx.snap, now: end, sections: { hist: [row], now: [], plan: [], nq: [] }, history: { ...ctx.snap.history, from: end - 86400000, more: false, total: 1 } })
        if (!result.ok) throw new Error('controlled timezone snapshot rejected')
        S.histFrom = 0; S.ready = false; fx.relayout(); ctx.vp.scrollTop = 0; fx.update()
        return { heights: [...document.querySelectorAll('#bd-sec-hist .bd-card')].map(el => parseFloat(el.style.height)), labels: [...document.querySelectorAll('#bd-sec-hist .bd-lbl')].map(el => el.textContent) }
      }))
    } finally { await context.close() }
  }
  expect(results[0].heights).toEqual([143]); expect(results[1].heights).toEqual(results[0].heights)
  expect(results[0].labels).not.toEqual(results[1].labels)
})

test('full unknown-start card shows no invented timestamp or duration; skew uses zero elapsed time', async ({ page }) => {
  expect(await page.evaluate(() => {
    initCards()
    return [row('unknown-full', null, NOW), row('skew-full', NOW + H, NOW)].map(t => {
      state.ctx.D.byId[t.id] = t
      const el = cards.makeCard({ t, sec: 'hist', h: 150, startUnknown: t.start === null })
      return { time: el.querySelector('.bd-time').textContent, duration: el.querySelector('.bd-badges .h').textContent }
    })
  })).toEqual([{ time: 'Start unknown→ Oct 7 14:20', duration: '—' }, { time: 'Oct 7 14:20→ 14:20', duration: '5m' }])
})

test('B5 live now-to-history diff lays out the actual completed interval', async ({ page }) => {
  await page.goto('/build-fixture/live?view=gantt')
  await expect(page.locator('#bd-content')).toHaveCount(1)
  const before = await page.evaluate(async () => {
    const { ctx, fx } = await import('/build-home/state.js'), { receive } = await import('/build-home/hook.js')
    const original = ctx.snap.sections.now[0]
    if (!original) throw new Error('live fixture must contain a running ticket')
    const now = ctx.snap.now, neighbor = { ...original, id: 'gantt-neighbor', sec: 'hist', status: 'done', start: now - 8 * 3600000, end: now }
    receive({ ...ctx.snap, kind: 'snapshot', generation: ctx.proto.generation + 1,
      sections: { hist: [neighbor], now: [original], plan: [], nq: [] },
      history: { ...ctx.snap.history, from: now - 86400000, total: 1, more: false } })
    ctx.snapping = true; fx.scrollVP(ctx.secs.hist.el.offsetTop, false); fx.update()
    ctx.snapping = false
    const el = ctx.R.get('hist:' + neighbor.id)
    return { id: original.id, tier: el.classList.contains('full'), time: !!el.querySelector('.bd-time') }
  })
  expect(before).toMatchObject({ tier: true, time: true })
  const id = before.id
  await page.evaluate(async id => {
    const { ctx } = await import('/build-home/state.js'), { receive } = await import('/build-home/hook.js')
    const original = ctx.snap.sections.now.find(t => t.id === id), now = ctx.snap.now
    const t = { ...original, sec: 'hist', status: 'done', start: now - 8 * 3600000, end: now }
    receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now, upsert: [t], remove: [], set: {} })
  }, id)
  await expect.poll(() => page.evaluate(async id => {
    const { ctx } = await import('/build-home/state.js')
    return ctx.L.secs.hist.items.some(i => i.t.id === id)
  }, id)).toBe(true)
  const result = await page.evaluate(async id => {
    const { ctx } = await import('/build-home/state.js')
    const it = ctx.L.secs.hist.items.find(i => i.t.id === id)
    ctx.vp.scrollTop = ctx.secs.hist.el.offsetTop + it.y; (await import('/build-home/render.js')).update()
    const el = document.querySelector(`#bd-sec-hist .bd-card[data-id="${CSS.escape(id)}"]`)
    return { hist: !!el, stillNow: ctx.D.now.some(r => r.id === id), h: it.h, domH: parseFloat(el.style.height) }
  }, id)
  expect(result).toMatchObject({ hist: true, stillNow: false })
  expect(result.h).toBeCloseTo(143, 9); expect(result.domH).toBeCloseTo(143, 9)
  const neighbor = page.locator('#bd-sec-hist .bd-card[data-id="gantt-neighbor"]')
  await expect(neighbor).toHaveClass(/\bline\b/)
  await expect(neighbor.locator('.bd-time')).toHaveCount(0)
  expect(await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    return ctx.L.secs.hist.items.find(it => it.t.id === 'gantt-neighbor').lanes
  })).toBe(2)
})

test('known Unsorted follows the palette while missing epics remain neutral', async ({ page }) => {
  await page.goto('/build-fixture/dense?view=gantt')
  await expect(page.locator('.bd-card').first()).toBeVisible()
  const colors = await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { makeCard } = await import('/build-home/cards.js')
    document.documentElement.dataset.palette = 'gruvbox'
    ctx.D.epics['palette-reference'] = { key: 'palette-reference', hue: 0 }
    const color = epic => {
      const t = { ...ctx.D.hist[0], id: 'palette-probe', epic }, el = makeCard({ t, sec: 'hist', h: 32.5 })
      ctx.root.append(el)
      const value = getComputedStyle(el.querySelector('.bd-dot')).backgroundColor
      el.remove(); return value
    }
    const swatch = document.createElement('i'); swatch.style.background = 'var(--muted)'; ctx.root.append(swatch)
    const neutral = getComputedStyle(swatch).backgroundColor; swatch.remove()
    return { known: color(null), reference: color('palette-reference'), missing: color('missing-palette-epic'), neutral }
  })
  expect(colors.known).toBe(colors.reference); expect(colors.known).not.toBe(colors.neutral)
  expect(colors.missing).toBe(colors.neutral)
})

for (const width of [1440, 390]) test(`Gantt dependency edges connect existing cards: ${width}`, async ({ page }) => {
  await page.setViewportSize({ width, height: width === 390 ? 844 : 900 })
  await page.goto('/build-fixture/live?view=gantt')
  await expect(page.locator('#bd-content')).toBeVisible()
  const result = await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    const content = document.querySelector('#bd-content').getBoundingClientRect()
    const same = (actual, expected) => Math.abs(actual - expected) <= 1
    const matches = (actual, expected) => actual.length >= 8 &&
      same(actual[0], expected[0]) && same(actual[1], expected[1]) && same(actual[6], expected[2]) && same(actual[7], expected[3])
    return [...document.querySelectorAll('#bd-edges .bd-eh')].map(hit => {
      const line = hit.nextElementSibling, arrow = line?.nextElementSibling
      const dependent = document.querySelector(`.bd-card[data-id="${CSS.escape(hit.dataset.e)}"]`)
      const coords = line?.getAttribute('d')?.match(/-?[\d.]+/g)?.map(Number) ?? []
      const ticket = ctx.D.byId[hit.dataset.e]
      const startsAtDependency = (ticket?.deps ?? []).some(id => {
        const dependency = document.querySelector(`.bd-card[data-id="${CSS.escape(id)}"]`)
        if (!dependency || !dependent) return false
        const a = dependency.getBoundingClientRect(), b = dependent.getBoundingClientRect()
        const ar = { left: a.left - content.left, right: a.right - content.left, top: a.top - content.top, bottom: a.bottom - content.top, width: a.width, height: a.height }
        const br = { left: b.left - content.left, right: b.right - content.left, top: b.top - content.top, bottom: b.bottom - content.top, width: b.width, height: b.height }
        if (ar.bottom <= br.top + 6) return matches(coords, [ar.left + ar.width / 2, ar.bottom, br.left + br.width / 2, br.top - 3])
        const right = ar.right <= br.left
        const from = [right ? ar.right : ar.left, ar.top + ar.height / 2]
        const to = [right ? br.left - 3 : br.right + 3, br.top + Math.min(18, br.height / 2)]
        return matches(coords, [...from, ...to])
      })
      return { dependent: !!dependent, startsAtDependency, lineFollowsHit: line?.matches('.bd-e'), arrowFollowsLine: arrow?.matches('.bd-ea'), samePath: line?.getAttribute('d') === hit.getAttribute('d'), finite: coords.length >= 8 && coords.every(Number.isFinite), distinctEndpoints: coords.length >= 8 && (coords[0] !== coords[6] || coords[1] !== coords[7]) }
    })
  })
  expect(result.length).toBeGreaterThan(0)
  expect(result.every(edge => edge.dependent && edge.startsAtDependency && edge.lineFollowsHit && edge.arrowFollowsLine && edge.samePath && edge.finite && edge.distinctEndpoints)).toBe(true)
})
