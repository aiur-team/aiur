import { readFile } from 'node:fs/promises'
import { expect } from '@playwright/test'
import { scrollGanttComposition } from './build-home-gantt-parity.mjs'
import { primeBoardPaint } from './build-home-band-canvas.mjs'

export async function loadGanttRegionHistory(pair, dataset) {
  const snapshot = JSON.parse(await readFile(new URL(`../../test/fixtures/build_home/${dataset}.json`, import.meta.url), 'utf8'))
  await pair.design.evaluate(() => __ganttComposition.allHistory())
  await pair.product.evaluate(async snapshot => {
    const { ctx, S } = await import('/build-home/state.js'), { receive } = await import('/build-home/hook.js')
    S.ready = false
    receive({ ...ctx.snap, kind: 'snapshot', generation: ctx.proto.generation + 1,
      sections: { ...ctx.snap.sections, hist: snapshot.sections.hist }, history: { ...snapshot.history, from: 0, more: false } })
    ctx.snapping = true
  }, snapshot)
  const targets = await pair.design.evaluate(() => __ganttComposition.targets())
  for (const name of ['full', 'two', 'three', 'labelled', 'empty', 'tick', 'line']) expect(targets[name], `fixture missing ${name} Gantt region`).toBeTruthy()
  return targets
}

export async function markGanttRegion(pair, name, target, width) {
  await restoreCards(pair)
  await scrollGanttComposition(pair, Math.max(0, target.y - 100))
  const records = []
  for (const page of [pair.design, pair.product]) records.push(await page.evaluate(({ name, target, width }) => {
    document.querySelector('[data-gantt-clip]')?.remove()
    document.querySelectorAll('[data-gantt-region]').forEach(el => el.removeAttribute('data-gantt-region'))
    const hist = document.querySelector('#bd-sec-hist')
    let el
    if (target.id) el = [...hist.querySelectorAll('.bd-card')].find(el => el.dataset.id.replace('AIUR-', '') === target.id)
    else {
      const selector = name === 'tick' ? '.bd-lbl.tick' : name === 'line' ? '.bd-dl' : '.bd-mk.brk'
      el = [...hist.querySelectorAll(selector)].find(el => Math.abs(parseFloat(el.style.top) - target.y) < 0.01)
    }
    if (!el) throw new Error(`missing rendered ${name} Gantt region`)
    if (width) el.style.width = width + 'px'
    if (name === 'two' || name === 'three') {
      const selected = el._it
      const cluster = [...hist.querySelectorAll('.bd-card')].filter(card => card._it.key === selected.key && card._it.lanes === selected.lanes && card._it.y < selected.y + selected.h && card._it.y + card._it.h > selected.y)
      if (new Set(cluster.map(card => card._it.lane)).size !== target.lanes) throw new Error('render window misses an overlap lane')
      const boxes = cluster.map(card => card.getBoundingClientRect()), x = Math.min(...boxes.map(b => b.x)), y = Math.min(...boxes.map(b => b.y))
      const clip = document.createElement('div'); clip.dataset.ganttClip = ''
      Object.assign(clip.style, { position: 'fixed', left: x + 'px', top: y + 'px', width: Math.max(...boxes.map(b => b.right)) - x + 'px', height: Math.max(...boxes.map(b => b.bottom)) - y + 'px', pointerEvents: 'none' })
      clip._ganttCards = cluster
      document.body.appendChild(clip); el = clip
    }
    el.dataset.ganttRegion = name
    const rect = el.getBoundingClientRect(), time = el.querySelector('.bd-time'), badge = el.querySelector('.bd-badges span')
    return { width: rect.width, height: rect.height, time: time ? getComputedStyle(time).display : null, badgeFont: badge ? getComputedStyle(badge).fontSize : null,
      icons: [...el.querySelectorAll('svg')].map(svg => { const b = svg.getBoundingClientRect(); return [b.x - rect.x, b.y - rect.y, b.width, b.height] }) }
  }, { name, target, width }))
  expect(records[1]).toEqual(records[0])
  if (width) {
    expect(records[1].time).toBe(width <= 150 ? 'none' : 'block')
    expect(parseFloat(records[1].badgeFont)).toBeCloseTo(13 * (width <= 150 ? 0.62 : 0.7), 2)
  }
  if (['full', 'two', 'three'].includes(name)) await isolateCards(pair, name)
  await primeBoardPaint(pair)
  return `[data-gantt-region="${name}"]`
}

export async function markFixedGanttRegion(pair, selector, name) {
  await restoreCards(pair)
  const records = []
  for (const page of [pair.design, pair.product]) records.push(await page.locator(selector).first().evaluate((el, name) => {
    document.querySelectorAll('[data-gantt-region]').forEach(node => node.removeAttribute('data-gantt-region'))
    el.dataset.ganttRegion = name
    const box = el.getBoundingClientRect()
    // Fix the external toolbar legend in place. Static cards use the canvas
    // below; the sticky band retains its real composed background.
    if (name === 'legend') Object.assign(el.style, { position: 'fixed', left: '100px', top: '100px', width: box.width + 'px', height: box.height + 'px', boxSizing: 'border-box', margin: '0', zIndex: '10000', background: 'var(--bg)' })
    const origin = el.getBoundingClientRect()
    return { width: origin.width, height: origin.height, icons: [...el.querySelectorAll('svg')].map(svg => {
      const b = svg.getBoundingClientRect(); return [b.x - origin.x, b.y - origin.y, b.width, b.height]
    }) }
  }, name))
  expect(records[1]).toEqual(records[0])
  if (name === 'planned') await isolateCards(pair, name)
  await primeBoardPaint(pair)
  return `[data-gantt-region="${name}"]`
}

async function restoreCards(pair) {
  for (const page of [pair.design, pair.product]) await page.evaluate(() => window.restoreGanttCards?.())
}

async function isolateCards(pair, name) {
  for (const page of [pair.design, pair.product]) await page.evaluate(name => {
    const target = document.querySelector(`[data-gantt-region="${name}"]`)
    const cards = target._ganttCards ?? [target], box = target.getBoundingClientRect()
    const records = cards.map(card => {
      const rect = card.getBoundingClientRect(), anchor = document.createComment('Gantt card origin')
      card.before(anchor)
      return { card, anchor, style: card.getAttribute('style'), rect, fontSize: getComputedStyle(card).fontSize }
    })
    // Use the card suite's integer-origin canvas for static detail captures.
    // Preserve every card dimension and relative lane position; the B1 viewport
    // matrix separately checks the real sticky composition without this canvas.
    const holder = document.createElement('div'); holder.className = 'bd-root'
    Object.assign(holder.style, { position: 'fixed', left: '0', top: '100px', width: Math.ceil(box.width + 16) + 'px', height: Math.ceil(box.height + 16) + 'px', background: 'var(--bg)', zIndex: '99999', display: 'block', margin: '0', padding: '0', minHeight: '0', overflow: 'visible' })
    document.body.append(holder)
    target.removeAttribute('data-gantt-region'); holder.dataset.ganttRegion = name
    for (const { card, rect, fontSize } of records) {
      holder.append(card)
      Object.assign(card.style, { position: 'absolute', left: 8 + rect.x - box.x + 'px', top: 8 + rect.y - box.y + 'px', width: rect.width + 'px', height: rect.height + 'px', fontSize, transition: 'none' })
    }
    window.restoreGanttCards = () => {
      for (const { card, anchor, style } of records) {
        anchor.replaceWith(card)
        if (style === null) card.removeAttribute('style'); else card.setAttribute('style', style)
      }
      holder.remove(); delete window.restoreGanttCards
    }
  }, name)
}
