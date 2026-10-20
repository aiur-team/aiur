import { fileURLToPath } from 'node:url'
import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { openParityPair, applyAllowlist, waitParityReady, PARITY_VIEWPORTS, PARITY_MATRIX } from '../support/design-parity.mjs'

// Two isolated pages, font loading and six scroll windows exceed a single-page budget.
test.setTimeout(120_000)
const cell = { dataset: 'live', ...PARITY_VIEWPORTS[0], theme: 'dark', palette: 'gruvbox' }

test('edges are decorative for assistive tech', async ({ browser }) => {
  const pair = await openParityPair(browser, cell)
  try {
    expect(await pair.product.evaluate(() => [...document.querySelectorAll('#bd-edges, .bd-now-e')].map(el => el.getAttribute('aria-hidden')))).toEqual(['true', 'true'])
  } finally { await pair.close() }
})

// B9: the design leaves `.hide` on after flow mode; the product removes it.
test('edges return after a flow to wide resize', async ({ browser }) => {
  const pair = await openParityPair(browser, cell)
  try {
    const page = pair.product
    await page.setViewportSize({ width: 390, height: 844 }); await page.waitForTimeout(600)
    await page.setViewportSize({ width: 1440, height: 900 }); await page.waitForTimeout(800)
    const edges = page.locator('#bd-edges')
    await expect(edges).not.toHaveClass(/hide/)
    expect(await edges.evaluate(el => getComputedStyle(el).opacity)).toBe('1')
  } finally { await pair.close() }
})

// Design ids read "AIUR-583", product ids "583"; y is made relative to the history section, whose page offset differs.
const histEdges = page => page.evaluate(() => {
  const cr = document.querySelector('#bd-content').getBoundingClientRect(), top = document.querySelector('#bd-sec-hist').getBoundingClientRect().top - cr.top
  return [...document.querySelectorAll('#bd-edges .bd-eh')]
    .filter(h => document.querySelector(`#bd-sec-hist .bd-card[data-id="${CSS.escape(h.dataset.e)}"]`))
    .map(h => { const n = h.getAttribute('d').match(/-?[\d.]+/g).map((v, i) => +v - (i % 2 ? top : 0))
      // Endpoint pair: the dependent id plus the blocker's offset from it (identical on both sides when the cards match).
      return { k: `${h.dataset.e.replace(/\D/g, '')} ${Math.round(n[0])},${Math.round(n[6])},${Math.round(n[7] - n[1])}`, c: [...h.nextElementSibling.classList].join(' '), n } })
    .sort((a, b) => a.k.localeCompare(b.k) || a.n[1] - b.n[1] || a.n[7] - b.n[7])
})
const toHistory = (page, offset) => page.evaluate(o => { document.querySelector('#bd-vp').scrollTop = document.querySelector('#bd-sec-hist').offsetTop + o }, offset)
// Each side renders its own window around the scroll position, so walk the section and merge what was drawn.
async function walkHistory(page) {
  const seen = []
  for (let offset = 0; offset < 3000; offset += 500) {
    await toHistory(page, offset); await page.waitForTimeout(500)
    // The same edge seen in two windows can differ by sub-pixel layout; y within 2 px is the same edge.
    for (const e of await histEdges(page)) if (!seen.some(o => o.k === e.k && Math.abs(o.n[1] - e.n[1]) < 2 && Math.abs(o.n[7] - e.n[7]) < 2)) seen.push(e)
  }
  return seen.sort((a, b) => a.k.localeCompare(b.k) || a.n[1] - b.n[1] || a.n[7] - b.n[7])
}
const styleOf = page => page.evaluate(() => Object.fromEntries([...new Set([...document.querySelectorAll('#bd-edges .bd-e, #bd-edges .bd-ea')].map(p => p.getAttribute('class').trim()))].map(cls => {
  const cs = getComputedStyle(document.querySelector(`#bd-edges path[class^="${cls}"]`))
  return [cls, ['stroke', 'strokeWidth', 'strokeDasharray', 'opacity', 'fill'].map(k => cs[k]).join('|')]
})))

// B1b/B1c on the history region at matched scroll. Edges that end in the now band wait for C9-T08 (edges-now-band-pending);
// the dense fixture waits on the column gap (edges-dense-columns-pending).
for (const cell of PARITY_MATRIX.filter(c => c.dataset === 'live' && c.viewport.width >= 1024 && !c.reducedMotion)) test(`history edge paths and styles match the design: ${cell.viewport.width} ${cell.theme} ${cell.palette}`, async ({ browser }) => {
  const pair = await openParityPair(browser, cell)
  try {
    await Promise.all([pair.design, pair.product].map(page => waitParityReady(page, 'board', page === pair.design ? 'design' : 'product', true)))
    const design = await walkHistory(pair.design)
    expect(design.length).toBeGreaterThan(0)
    const product = await walkHistory(pair.product)
    // The two sides render slightly different windows; compare the edges both draw.
    const shared = new Set(design.map(e => e.k).filter(k => product.some(e => e.k === k)))
    const [dd, pp] = [design, product].map(list => list.filter(e => shared.has(e.k)))
    expect(shared.size, JSON.stringify({ d: design.map(e => e.k), p: product.map(e => e.k) })).toBeGreaterThanOrEqual(5)
    expect(pp.map(e => e.k)).toEqual(dd.map(e => e.k))
    // The key is the endpoint pair (dependent, blocker x); the class is a value, so a wrong class on a shared pair fails.
    expect(pp.map(e => `${e.k} ${e.c}`)).toEqual(dd.map(e => `${e.k} ${e.c}`))
    // The history section sits at a different page y on each side (band and header work belongs to other tickets),
    // so compare the edge geometry relative to the first shared edge.
    const dy = pp[0].n[1] - dd[0].n[1]
    pp.forEach((e, i) => e.n.forEach((v, j) => expect(Math.abs(v - dd[i].n[j] - (j % 2 ? dy : 0)), `${e.k} #${j}`).toBeLessThan(1.5)))
    await applyAllowlist(pair, cell)
    const [d, p] = [await styleOf(pair.design), await styleOf(pair.product)]
    expect(Object.keys(p).length).toBeGreaterThan(0)
    for (const cls of Object.keys(p)) if (cls in d) expect(p[cls], cls).toBe(d[cls])
  } finally { await pair.close() }
})

test.describe('product edges on live', () => {
  test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })
  const edge = (page, id) => page.locator(`#bd-edges .bd-eh[data-e="${id}"]`).first().evaluate(h => [...(h.nextElementSibling?.classList ?? [])].join(' '))
  async function open(page) {
    await page.route(/\/build-home\/[\w-]+\.js$/, route => route.fulfill({ path: fileURLToPath(new URL('../../priv/static/build-home/' + new URL(route.request().url()).pathname.split('/').at(-1), import.meta.url)), contentType: 'text/javascript' }))
    await page.goto('/build-fixture/live')
    await expect(page.locator('.bd-lane')).not.toHaveCount(0)
    await page.evaluate(async () => { window.st = await import('/build-home/state.js'); st.ctx.vp.scrollTop = st.ctx.secs.plan.el.offsetTop })
    await expect.poll(() => edge(page, '615')).toBe('bd-e bl')
    await page.waitForTimeout(500)
  }
  // B6: a dep_states change alone redraws; the signature must carry ctx.proto.generation.
  test('a state change turns the edge ok', async ({ page }) => {
    await open(page)
    expect(await page.request.get('/build-control/diff?name=edge-state-cleared').then(r => r.status())).toBe(200)
    await expect.poll(() => edge(page, '615')).toBe('bd-e ok')
  })
  test('B6 generation alone invalidates cached edge classes', async ({ page }) => {
    await open(page)
    const diff = await import('../../test/fixtures/build_home/diffs/edge-state-cleared.json', { with: { type: 'json' } })
    expect(await page.evaluate(async diff => {
      const { applyDiff } = await import('/build-home/store.js')
      st.fx.drawEdges(true)
      const before = st.ctx.svg.innerHTML
      const result = applyDiff({ ...diff, epoch: st.ctx.proto.epoch, generation: st.ctx.proto.generation + 1 })
      if (result.error) throw new Error(result.error)
      st.fx.drawEdges(false)
      return { changed: st.ctx.svg.innerHTML !== before, cls: st.ctx.svg.querySelector('.bd-eh[data-e="615"]').nextElementSibling.getAttribute('class').trim() }
    }, diff.default)).toEqual({ changed: true, cls: 'bd-e ok' })
  })
  // B5: unknown stays the base faint solid line.
  test('an unknown state draws the base line', async ({ page }) => {
    await open(page)
    expect(await page.request.get('/build-control/diff?name=edge-unknown').then(r => r.status())).toBe(200)
    await expect.poll(() => edge(page, '615')).toBe('bd-e')
    const { stroke, faint, dash } = await page.locator('#bd-edges .bd-eh[data-e="615"]').first().evaluate(h => {
      const cs = getComputedStyle(h.nextElementSibling), probe = document.createElement('i'); probe.style.color = 'var(--faint)'; document.body.append(probe)
      return { stroke: cs.stroke, faint: getComputedStyle(probe).color, dash: cs.strokeDasharray }
    })
    expect(stroke).toBe(faint); expect(dash).toBe('none')
  })
  // B10: the hit path sits under the pointer, ahead of its line, and is inert while scrolling.
  test('hit path target, order and scrolling', async ({ page }) => {
    await open(page)
    // Neighbouring hit paths overlap; use the first on-screen point where an edge's own hit path is on top.
    const found = await page.evaluate(() => {
      for (const h of document.querySelectorAll('#bd-edges .bd-eh')) {
        const c = h.getScreenCTM(), n = h.getTotalLength()
        for (let i = 1; i < 40; i++) {
          const m = h.getPointAtLength(n * i / 40), x = c.a * m.x + c.e, y = c.d * m.y + c.f
          if (y > 0 && y < innerHeight && x > 0 && x < innerWidth && document.elementFromPoint(x, y) === h) return { x, y, e: h.dataset.e, i: [...document.querySelectorAll('#bd-edges .bd-eh')].indexOf(h) }
        }
      }
      return null
    })
    expect(found).not.toBeNull()
    const { e, i, ...pt } = found
    const hit = page.locator('#bd-edges .bd-eh').nth(i)
    expect(await page.locator('#bd-edges .bd-eh').evaluateAll(hits => hits.every(h =>
      h.nextElementSibling?.matches('.bd-e') && h.nextElementSibling.getAttribute('d') === h.getAttribute('d') &&
      h.nextElementSibling.nextElementSibling?.matches('.bd-ea')))).toBe(true)
    const top = () => page.evaluate(({ x, y }) => { const el = document.elementFromPoint(x, y); return el.matches('.bd-eh') ? el.dataset.e : 'other' }, pt)
    expect(await top()).toBe(e)
    await page.mouse.move(pt.x, pt.y)
    expect(await hit.evaluate(h => getComputedStyle(h.nextElementSibling).strokeWidth)).toBe('2.8px')
    await page.mouse.click(pt.x, pt.y)
    await expect(page.locator('#tk-backdrop.show')).toHaveCount(0)
    await page.evaluate(() => st.ctx.content.classList.add('scrolling'))
    expect(await top()).toBe('other')
  })
})
