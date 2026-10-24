import { fileURLToPath } from 'node:url'
import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { openProduct, parityContextOptions, PARITY_VIEWPORTS } from '../support/design-parity.mjs'

// Two isolated pages, font loading and six scroll windows exceed a single-page budget.
test.setTimeout(120_000)
const cell = { dataset: 'live', ...PARITY_VIEWPORTS[0], theme: 'dark', palette: 'gruvbox' }

test('edges are decorative for assistive tech', async ({ browser }) => {
  const context = await browser.newContext({ ...parityContextOptions(cell), baseURL: test.info().project.use.baseURL })
  try {
    const page = await context.newPage(); await openProduct(page, cell)
    expect(await page.evaluate(() => [...document.querySelectorAll('#bd-edges, .bd-now-e')].map(el => el.getAttribute('aria-hidden')))).toEqual(['true', 'true'])
  } finally { await context.close() }
})

// B9: the design leaves `.hide` on after flow mode; the product removes it.
test('edges return after a flow to wide resize', async ({ browser }) => {
  const context = await browser.newContext({ ...parityContextOptions(cell), baseURL: test.info().project.use.baseURL })
  try {
    const page = await context.newPage(); await openProduct(page, cell)
    await page.setViewportSize({ width: 390, height: 844 }); await page.waitForTimeout(600)
    await page.setViewportSize({ width: 1440, height: 900 }); await page.waitForTimeout(800)
    const edges = page.locator('#bd-edges')
    await expect(edges).not.toHaveClass(/hide/)
    expect(await edges.evaluate(el => getComputedStyle(el).opacity)).toBe('1')
  } finally { await context.close() }
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
