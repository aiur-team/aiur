import { test, expect } from '@playwright/test'
import { open, lock } from './support/build-home-chains.mjs'
import { settleAnimations } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

// The design export stops arrow tips 2 px short of the target card; edge parity holds the product to it.
const TIP_GAP = 2

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })

for (const width of [1440, 1024]) test(`Fit redraws dependency arrows on settled cards at ${width}px`, async ({ page }) => {
  await page.setViewportSize({ width, height: 900 })
  await open(page)
  await lock(page, '9012')
  const beforeFit = await page.locator('#bd-edges .bd-ea').evaluateAll(paths => paths.map(path => path.getAttribute('d')))
  await page.locator('[data-lt="fit"]').click()
  await expect.poll(() => page.evaluate(() => st.ctx.fitHistory === null && !st.ctx.isScrolling() && !st.ctx.snapping)).toBe(true)
  await settleAnimations(page, '.bd-content')

  const endpointErrors = await page.evaluate(() => {
    const svg = st.ctx.svg
    const point = (d, index) => d.match(/-?[\d.]+/g).map(Number).slice(index, index + 2)
    const screen = ([x, y]) => {
      const m = svg.getScreenCTM()
      return [m.a * x + m.c * y + m.e, m.b * x + m.d * y + m.f]
    }
    const edgeDistance = (p, r) => {
      const dx = Math.max(r.left - p[0], 0, p[0] - r.right)
      const dy = Math.max(r.top - p[1], 0, p[1] - r.bottom)
      if (dx || dy) return Math.hypot(dx, dy)
      return Math.min(p[0] - r.left, r.right - p[0], p[1] - r.top, r.bottom - p[1])
    }
    const edgeIndex = new Map()
    return [...svg.querySelectorAll('.bd-eh')].map(hit => {
      const line = hit.nextElementSibling
      const arrow = line.nextElementSibling
      const target = document.querySelector(`.bd-card[data-id="${CSS.escape(hit.dataset.e)}"]`)
      const sources = [...new Set(st.ctx.D.byId[hit.dataset.e].deps)].map(id => document.querySelector(`.bd-card[data-id="${CSS.escape(id)}"]`)).filter(candidate => candidate && candidate.style.opacity !== '0')
      const index = edgeIndex.get(hit.dataset.e) ?? 0
      edgeIndex.set(hit.dataset.e, index + 1)
      const source = sources[index]
      if (!source || !target || !arrow) throw new Error(`Missing visible endpoint for ${hit.dataset.e} dependency ${index}`)
      const start = screen(point(line.getAttribute('d'), 0))
      const tip = screen(point(arrow.getAttribute('d'), 2))
      return {
        id: hit.dataset.e,
        source: edgeDistance(start, source.getBoundingClientRect()),
        target: edgeDistance(tip, target.getBoundingClientRect()),
      }
    })
  })

  expect(endpointErrors.length).toBeGreaterThan(0)
  const afterFit = await page.locator('#bd-edges .bd-ea').evaluateAll(paths => paths.map(path => path.getAttribute('d')))
  expect(afterFit).not.toEqual(beforeFit)
  for (const edge of endpointErrors) {
    expect(edge.source, `${edge.id} source endpoint`).toBeLessThanOrEqual(1)
    expect(Math.abs(edge.target - TIP_GAP), `${edge.id} arrow tip`).toBeLessThanOrEqual(1)
  }
})
