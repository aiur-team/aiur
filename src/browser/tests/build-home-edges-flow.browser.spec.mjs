import { test, expect } from '@playwright/test'
import { openProduct, productContextOptions, PRODUCT_VIEWPORTS } from '../support/build-home-product.mjs'

// #7756: a crowded board falls back to flow layout; its dependency lines must stay visible,
// reach the LIVE band, and keep hover and tree-lock highlighting.
test.setTimeout(120_000)

for (const vp of [PRODUCT_VIEWPORTS[0], PRODUCT_VIEWPORTS[2]]) {
  test(`flow mode keeps dependency lines at ${vp.viewport.width}`, async ({ browser }) => {
    const cell = { dataset: 'crowded', theme: 'dark', palette: 'gruvbox', ...vp }
    const context = await browser.newContext({ ...productContextOptions(cell), baseURL: test.info().project.use.baseURL })
    try {
      const page = await context.newPage(); await openProduct(page, cell)
      await page.evaluate(async () => { window.st = await import('/build-home/state.js') })
      expect(await page.evaluate(() => st.S.flow && st.ctx.content.classList.contains('flow'))).toBe(true)
      const edges = page.locator('#bd-edges')
      await expect.poll(() => edges.evaluate(el => getComputedStyle(el).opacity)).toBe('1')

      // A dependent card whose blocker card is also on the board, and the line drawn between them.
      const pair = await page.evaluate(() => {
        const cards = new Map([...st.ctx.R.values()].filter(el => el.style.opacity !== '0').map(el => [el.dataset.id, el]))
        for (const [id, el] of cards) {
          const did = (st.ctx.D.byId[id]?.deps || []).find(d => d !== id && cards.has(d))
          if (did) return { id, did, w: Math.min(el.getBoundingClientRect().width, cards.get(did).getBoundingClientRect().width) }
        }
        return null
      })
      expect(pair).not.toBeNull()
      expect(pair.w).toBeGreaterThan(0)
      const line = page.locator(`#bd-edges .bd-eh[data-e="${pair.id}"] + .bd-e`).first()
      await expect(line).toHaveCount(1)
      expect(await line.evaluate(p => p.getTotalLength())).toBeGreaterThan(0)

      // A LIVE card's line to its blocker or dependent, drawn behind the LIVE band.
      const live = await page.evaluate(() => {
        const band = st.ctx.L.band.items.filter(it => it.el?.isConnected && it.el.style.opacity !== '0').map(it => it.t.id)
        const on = new Set([...st.ctx.R.values()].filter(el => el.style.opacity !== '0').map(el => el.dataset.id).concat(band))
        for (const id of band) {
          if ((st.ctx.D.byId[id].deps || []).some(d => d !== id && on.has(d))) return id
          const fut = [...on].find(o => o !== id && (st.ctx.D.byId[o]?.deps || []).includes(id))
          if (fut) return fut
        }
        return null
      })
      expect(live).not.toBeNull()
      expect(await page.locator(`#bd-edges .bd-eh[data-e="${live}"] + .bd-e`).count()).toBeGreaterThan(0)
      const nowLine = page.locator('.bd-now > .bd-now-e .bd-e').first()
      await expect(nowLine).toHaveCount(1)
      expect(await nowLine.evaluate(p => p.getTotalLength())).toBeGreaterThan(0)
      expect(Number(await page.locator('.bd-now > .bd-now-e').evaluate(el => getComputedStyle(el).opacity))).toBeGreaterThan(0)

      // Hover and tree lock still highlight in flow mode.
      await page.evaluate(id => st.fx.setHover(id, [...st.ctx.R.values()].find(el => el.dataset.id === id)), pair.id)
      await expect(edges).toHaveClass(/\bhov\b/)
      await expect(line).toHaveClass(/\bhl\b/)
      await page.evaluate(() => st.fx.setHover(null))
      await expect(edges).not.toHaveClass(/\bhov\b/)
      await page.evaluate(id => st.fx.lockTree(id), pair.id)
      await expect(edges).toHaveClass(/\bhov\b/)
      expect(await page.evaluate(() => st.ctx.lockId)).toBe(pair.id)
      expect(await edges.evaluate(el => getComputedStyle(el).opacity)).toBe('1')
    } finally { await context.close() }
  })
}
