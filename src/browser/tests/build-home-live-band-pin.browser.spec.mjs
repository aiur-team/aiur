import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles' })

// #7758: LIVE scrolls with the board but pins under the header (top) or to the bottom edge instead of leaving view.
async function open(page, viewport, view) {
  page.on('pageerror', error => { throw error })
  await page.setViewportSize(viewport)
  await page.clock.install({ time: 1791407999000 }); await page.clock.pauseAt(1791408000000)
  await page.goto('/build-fixture/live' + (view ? '?view=' + view : ''))
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/, { timeout: 10000 })
  await page.evaluate(async () => { window.m = await import('/build-home/state.js'); await import('/build-home/band.js') })
  await page.clock.runFor(2000)
}

// Scroll the board to a named position derived from the band's natural geometry and report where the band renders.
const place = (page, sel, st) => page.evaluate(({ sel, st }) => {
  const vp = m.ctx.vp, band = vp.querySelector(sel), box = vp.querySelector('.bd-content, .bd-list')
  const head = vp.querySelector('.bd-lanes, .lr-h').getBoundingClientRect().height
  // Natural top in content coordinates, read from the next sibling so a pinned band cannot skew it.
  const nat = band.nextElementSibling.getBoundingClientRect().top - box.getBoundingClientRect().top - band.offsetHeight
  const h = band.offsetHeight, viewH = vp.clientHeight
  const want = { mid: nat - head - Math.max(0, viewH - head - h) / 2, above: nat + h + 200, below: nat + h - 100 - viewH }[st]
  vp.scrollTop = Math.max(0, Math.min(want, vp.scrollHeight - viewH))
  vp.dispatchEvent(new Event('scroll'))
  const v = vp.getBoundingClientRect(), r = band.getBoundingClientRect(), c = box.getBoundingClientRect()
  return { st: vp.scrollTop, nat, h, viewH, head, top: r.top - v.top - vp.clientTop, bottom: v.top + vp.clientTop + viewH - r.bottom, offset: r.top - c.top }
}, { sel, st })

for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
  for (const [view, sel] of [['', '#bd-now'], ['gantt', '#bd-now'], ['list', '.lr-live']]) {
    test(`live band pins in ${view || 'graph'} view at ${viewport.width}`, async ({ page }) => {
      await open(page, viewport, view)

      // Room to spare: the band sits inline at its natural place.
      const mid = await place(page, sel, 'mid')
      expect(mid.h).toBeLessThanOrEqual(mid.viewH - mid.head)
      expect(Math.abs(mid.offset - mid.nat)).toBeLessThanOrEqual(1)

      // Natural place well above the viewport: pinned to the top, under the sticky header.
      const above = await place(page, sel, 'above')
      expect(above.nat - above.st).toBeLessThan(above.head - 100)
      expect(Math.abs(above.top - above.head)).toBeLessThanOrEqual(1)
      expect(above.bottom).toBeGreaterThanOrEqual(-1)

      // List puts Live first, so its natural place can never fall below the viewport.
      if (view === 'list') return
      // Natural place running off the bottom: pinned to the bottom edge, fully in view.
      const below = await place(page, sel, 'below')
      expect(below.nat + below.h - below.st).toBeGreaterThan(below.viewH + 50)
      expect(Math.abs(below.bottom)).toBeLessThanOrEqual(1)
      expect(below.offset).toBeLessThan(below.nat - 50)
      expect(below.top).toBeGreaterThanOrEqual(below.head - 1)
    })
  }

  test(`pinned live band keeps edges and hover aligned at ${viewport.width}`, async ({ page }) => {
    await open(page, viewport, '')
    const pinned = await place(page, '#bd-now', 'above')
    expect(Math.abs(pinned.top - pinned.head)).toBeLessThanOrEqual(1)
    await page.evaluate(() => m.fx.drawEdges(true)); await page.clock.runFor(500)
    const card = page.locator('#bd-now .bd-card').first()
    await expect(card).toBeInViewport()
    // The live-edge overlay is translated by the pinned band's real offset, so its paths stay on the cards.
    const shift = await page.evaluate(() => {
      const band = m.ctx.bandEl, g = band.querySelector('.bd-now-e g'), c = m.ctx.content.getBoundingClientRect(), b = band.getBoundingClientRect()
      return { drawn: g.getAttribute('transform'), want: `translate(${c.left - b.left},${c.top - b.top})` }
    })
    expect(shift.drawn).toBe(shift.want)
    // Nothing covers the pinned card: the point under its centre is the card itself, so hover reaches it.
    const box = await card.boundingBox()
    const hit = await page.evaluate(({ x, y }) => document.elementFromPoint(x, y)?.closest('.bd-card')?.dataset.id ?? null, { x: box.x + box.width / 2, y: box.y + box.height / 2 })
    expect(hit).toBe(await card.getAttribute('data-id'))
  })
}
