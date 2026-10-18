import { test, expect } from '@playwright/test'
import { openParityPair, PARITY_MATRIX, waitParityReady, applyAllowlist } from '../support/design-parity.mjs'

// Two isolated pages, font loading and six scroll windows exceed a single-page budget.
test.setTimeout(120_000)
// Full regions retain the two upstream gaps recorded in the shared allowlist.
// Save both unmasked regions for sign-off; do not turn the product into its own oracle.
for (const cell of PARITY_MATRIX.filter(c => ['live', 'dense'].includes(c.dataset) && c.viewport.width >= 1024 && !c.reducedMotion)) {
  test(`B1 edge region evidence: ${cell.dataset} ${cell.viewport.width} ${cell.theme} ${cell.palette}`, async ({ browser }, info) => {
    const pair = await openParityPair(browser, cell)
    try {
      await Promise.all([pair.design, pair.product].map(page => waitParityReady(page, 'board', page === pair.design ? 'design' : 'product', true)))
      await applyAllowlist(pair, cell)
      info.annotations.push({ type: 'pending-sign-off', description: cell.dataset === 'dense' ? 'edges-dense-columns-pending / C9-T04' : 'edges-now-band-pending / C9-T08' })
      for (const [side, page] of [['design', pair.design], ['product', pair.product]]) {
        await page.locator('#bd-vp').evaluate(vp => { vp.scrollTop = document.querySelector('#bd-sec-hist').offsetTop })
        await page.waitForTimeout(500)
        // Clip at the viewport: a whole virtual content SVG can be tens of thousands of pixels tall.
        const box = await page.locator('#bd-vp').boundingBox()
        expect(box.width).toBeGreaterThan(0)
        await info.attach(`${side}-edges-content`, { body: await page.screenshot({ clip: box, animations: 'disabled' }), contentType: 'image/png' })
        await info.attach(`${side}-edges-band`, { body: await page.locator('#bd-now').screenshot({ animations: 'disabled' }), contentType: 'image/png' })
      }
    } finally { await pair.close() }
  })
}
