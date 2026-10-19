import { readFile } from 'node:fs/promises'
import { expect } from '@playwright/test'
import { alignBoard, alignEtaMask, primeBoardPaint } from './build-home-band-canvas.mjs'
import { installScrollPaint, flushScrollPaint } from './build-home-scroll-paint.mjs'
import { waitParityReady, FIXTURE_META } from './design-parity.mjs'

const source = await readFile(new URL('../../test/fixtures/build_home/design-source/assets/build.js', import.meta.url), 'utf8')
const anchor = '  window.AiurBuild = {'
expect(source.split(anchor)).toHaveLength(2)
const probe = source.replace(anchor, `window.__ganttComposition = {
  geometry() { return { state: { view:S.view, span:S.span, flow:S.flow, K:S.K, histFrom:S.histFrom }, dims: { w:vp.clientWidth,h:vp.clientHeight }, rows:{hist:D.hist,now:D.now,plan:D.plan}, order:D.order, layout:L, offsets:Object.fromEntries(['hist','plan'].map(k=>[k,{top:secs[k].el.offsetTop,height:secs[k].el.offsetHeight}])) }; },
  stop() { S.ready = false; snapping = true; },
  allHistory() { S.histFrom = 0; relayout(); update(); },
  targets() {
    const hs = L.secs.hist, pick = pred => hs.items.filter(pred).sort((a,b) => a.h - b.h)[0];
    const overlap = n => pick(it => it.lanes === n && new Set(hs.items.filter(other => other.key === it.key && other.lanes === n && other.y < it.y + it.h && other.y + other.h > it.y).map(other => other.lane)).size === n);
    const item = it => it && ({ id: it.t.id.replace('AIUR-', ''), y: it.y, h: it.h, lanes: it.lanes });
    const mark = pred => { const m = hs.marks.find(pred); return m && { y: m.y, h: m.h }; };
    const tick = hs.labels.find(l => l.tick), line = hs.labels.find(l => l.line);
    return { full: item(pick(it => cardDetail(it) === 'full')), two: item(overlap(2)), three: item(overlap(3)),
      labelled: mark(m => m.kind === 'brk' && m.label), empty: mark(m => m.kind === 'brk' && !m.label),
      tick: tick && { y: tick.y }, line: line && { y: line.y - 6 } };
  },
  scroll(top) { vp.scrollTop = top; update(); },
  positions() { return { now: Math.max(0, secs.hist.el.offsetTop + secs.hist.el.offsetHeight - 46), hist: 0, plan: secs.plan.el.offsetTop }; }
};\n${anchor}`)

export async function freezeGanttComposition(pair) {
  // Freeze before the first scroll can page history, preserving the same loaded rows.
  const hook = await readFile(new URL('../../priv/static/build-home/hook.js', import.meta.url), 'utf8')
  expect(hook.split('S.ready = true;')).toHaveLength(2)
  await pair.product.route('**/build-home/hook.js', route => route.fulfill({ contentType: 'text/javascript', body: hook.replace('S.ready = true;', 'S.ready = false;') }))
  await pair.product.reload(); await waitParityReady(pair.product, 'board', 'product', true)
  await pair.design.route('**/assets/build.js*', route => route.fulfill({ contentType: 'text/javascript', body: probe }))
  await pair.design.reload(); await waitParityReady(pair.design, 'board', 'design', true)
  await pair.design.evaluate(() => __ganttComposition.stop())
  await pair.product.evaluate(async () => {
    const { S, ctx } = await import('/build-home/state.js'); S.ready = false; ctx.snapping = true
  })
  // Compare the same loaded history window. The dense reference initially
  // includes the previous day; the server snapshot can begin with today only.
  const from = await pair.design.evaluate(() => __ganttComposition.geometry().state.histFrom)
  const loaded = await pair.product.evaluate(async from => {
    const { ensureFrom } = await import('/build-home/history.js')
    const { S } = await import('/build-home/state.js')
    await ensureFrom(from)
    return S.histFrom
  }, from)
  expect(loaded, 'matching history window before Gantt comparison').toBe(from)
  await alignBoard(pair)
  // The reference toolbar can overflow the phone page and expand its layout
  // viewport to 435px despite a 390px visual viewport. Clip the exterior page,
  // preserving every board pixel, so both SVGs paint in the same viewport.
  for (const page of [pair.design, pair.product]) {
    const before = await page.locator('#bd-vp').boundingBox()
    await page.evaluate(() => { document.documentElement.style.overflowX = 'clip'; document.body.style.overflowX = 'clip' })
    expect(await page.locator('#bd-vp').boundingBox()).toEqual(before)
    await expect.poll(() => page.evaluate(() => ({ width: innerWidth, height: innerHeight }))).toEqual(page.viewportSize())
  }
  for (const page of [pair.design, pair.product]) await page.locator('#bd-vp').evaluate(el => {
    document.body.style.minHeight = Math.ceil(el.getBoundingClientRect().bottom + scrollY) + 'px'
  })
  // Existing C9-T08 exception only: C7-T03 owns ETA copy. Do not mask cards, edges or band geometry.
  pair.allowlist = pair.allowlist.map(entry => entry.id === 'now-band-eta-pending' ? { ...entry, kind: 'pixel-mask', selector: '.bd-now-eta' } : entry)
  await alignEtaMask(pair)
  await Promise.all([pair.design, pair.product].map(async page => {
    await page.clock.setSystemTime(FIXTURE_META.now)
    await installScrollPaint(page)
  }))
}

export async function scrollGanttComposition(pair, top) {
  // Restore isolated static cards before the render window can recycle them.
  for (const page of [pair.design, pair.product]) await page.evaluate(() => window.restoreGanttCards?.())
  // A paused JS clock also pauses Phoenix's heartbeat timer. Keep the actual
  // transport alive during long capture batches without changing app state/time.
  await pair.product.evaluate(() => {
    const socket = window.liveSocket.getSocket()
    if (!socket.isConnected()) throw new Error('Gantt capture lost its live transport')
    socket.sendHeartbeat()
  })
  await pair.design.evaluate(top => __ganttComposition.scroll(top), top)
  await pair.product.evaluate(async top => {
    const { ctx, fx } = await import('/build-home/state.js'); ctx.vp.scrollTop = top; fx.update()
  }, top)
  // Native scroll dispatch is not driven by the paused JS clock. Flush its queued paint,
  // then re-prime the sticky canvas using the same path as the Now-band parity suite.
  await Promise.all([pair.design, pair.product].map(async page => {
    await page.locator('#bd-vp').evaluate(vp => vp.dispatchEvent(new Event('scroll')))
    await flushScrollPaint(page)
  }))
  await primeBoardPaint(pair)
  const positions = await Promise.all([pair.design, pair.product].map(page => page.locator('#bd-vp').evaluate(vp => vp.scrollTop)))
  expect(positions[1]).toBe(positions[0])
}

export async function attachGanttRasterDiagnostics(pair, info) {
  const records = {}
  for (const side of ['design', 'product']) records[side] = await pair[side].evaluate(() => {
    const rect = el => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height } }
    const styles = el => {
      const cs = getComputedStyle(el)
      return { ...Object.fromEntries(['color', 'stroke', 'strokeWidth', 'fill', 'fillOpacity', 'strokeOpacity', 'filter', 'opacity', 'shapeRendering', 'transform'].map(key => [key, cs[key]])),
        computed: Object.fromEntries([...cs].filter(key => !key.startsWith('--')).map(key => [key, cs.getPropertyValue(key)])),
        vars: Object.fromEntries(['--ec', '--h', '--fg', '--muted', '--faint'].map(key => [key, cs.getPropertyValue(key)])) }
    }
    const parents = el => {
      const list = []
      for (let node = el.parentElement; node; node = node.parentElement) {
        list.push({ tag: node.tagName, cls: node.getAttribute('class'), id: node.id, box: rect(node), styles: styles(node) })
        if (node.id === 'build-root') break
      }
      return list
    }
    const card = [...document.querySelectorAll('.bd-card')].find(el => el.dataset.id.replace('AIUR-', '') === '604')
    return { dpr: devicePixelRatio, viewport: { width: innerWidth, height: innerHeight, scale: visualViewport.scale, visualWidth: visualViewport.width, visualHeight: visualViewport.height, documentWidth: document.documentElement.scrollWidth }, fonts: document.fonts.status, scroll: { x: scrollX, y: scrollY, top: document.querySelector('#bd-vp').scrollTop },
      boxes: Object.fromEntries(['#build-root', '#bd-vp', '#bd-content', '#bd-now'].map(selector => [selector, rect(document.querySelector(selector))])),
      card: card && { box: rect(card), styles: styles(card), parents: parents(card), icons: [...card.querySelectorAll('svg')].map(el => ({ box: rect(el), html: el.outerHTML, styles: styles(el), parents: parents(el), paths: [...el.querySelectorAll('path,rect,circle')].map(path => ({ tag: path.tagName, styles: styles(path) })) })) } }
  })
  await info.attach('gantt-raster-origins', { body: Buffer.from(JSON.stringify(records, null, 2)), contentType: 'application/json' })
}

export async function compareRenderedGanttEdges(pair) {
  const records = []
  for (const page of [pair.design, pair.product]) records.push(await page.evaluate(() => {
    const numbers = path => (path.getAttribute('d').match(/-?\d*\.?\d+(?:e[-+]?\d+)?/gi) ?? []).map(Number)
    const classes = el => [...el.classList].sort().join(' ')
    const counts = new Map()
    const main = [...document.querySelectorAll('#bd-edges > .bd-e')].map(line => {
      const hit = line.previousElementSibling
      if (!hit?.matches('.bd-eh')) throw new Error('rendered main edge has no dependent identity')
      const id = hit.dataset.e.replace('AIUR-', ''), n = counts.get(id) ?? 0
      counts.set(id, n + 1)
      const arrow = line.nextElementSibling
      if (!arrow?.matches('.bd-ea')) throw new Error('rendered main edge has no arrow')
      return { id: `${id}:${n}`, cls: classes(line), arrowClass: classes(arrow), coords: numbers(line), arrow: numbers(arrow), path: line.getAttribute('d') }
    })
    const band = [...document.querySelectorAll('.bd-now-e .bd-e')].map(line => {
      const source = main.find(edge => edge.path === line.getAttribute('d') && edge.cls === classes(line))
      if (!source) throw new Error('rendered band edge has no corresponding main edge')
      return { id: source.id, cls: classes(line), arrowClass: classes(line.nextElementSibling), coords: numbers(line), arrow: numbers(line.nextElementSibling) }
    })
    return [...main.map(({ path, ...edge }) => ({ layer: 'main', ...edge })), ...band.map(edge => ({ layer: 'band', ...edge }))]
      .sort((a, b) => a.layer.localeCompare(b.layer) || a.id.localeCompare(b.id))
  }))
  const [expected, actual] = records
  expect(actual.map(({ coords, arrow, ...identity }) => identity)).toEqual(expected.map(({ coords, arrow, ...identity }) => identity))
  actual.forEach((edge, n) => {
    for (const field of ['coords', 'arrow']) {
      expect(edge[field].length).toBe(expected[n][field].length)
      edge[field].forEach((value, i) => expect(Math.abs(value - expected[n][field][i]), `${edge.layer} ${edge.id} ${field}[${i}]`).toBeLessThanOrEqual(0.5))
    }
  })
}

export async function attachGanttGeometryDiagnostics(pair, info) {
  const design = await pair.design.evaluate(() => {
    const data = __ganttComposition.geometry()
    return JSON.parse(JSON.stringify(data, (key, value) => key === 'el' || key === '_it' ? undefined : value))
  })
  const product = await pair.product.evaluate(async () => {
    const { ctx, S } = await import('/build-home/state.js')
    return JSON.parse(JSON.stringify({ state: { view:S.view, span:S.span, flow:S.flow, K:S.K, histFrom:S.histFrom }, dims:{w:ctx.vp.clientWidth,h:ctx.vp.clientHeight}, rows:{hist:ctx.D.hist,now:ctx.D.now,plan:ctx.D.plan}, order:ctx.D.order, layout:ctx.L, offsets:Object.fromEntries(['hist','plan'].map(k=>[k,{top:ctx.secs[k].el.offsetTop,height:ctx.secs[k].el.offsetHeight}])) }, (key, value) => key === 'el' || key === '_it' ? undefined : value))
  })
  await info.attach('gantt-layout-diagnostics', { body: Buffer.from(JSON.stringify({design,product})), contentType:'application/json' })
}
