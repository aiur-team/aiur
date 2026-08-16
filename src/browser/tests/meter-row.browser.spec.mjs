import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'

async function openMeterRow(page) {
  await page.goto('/auth/read_only')
  await page.goto('/meter-row')
  await expect(page.locator('[data-meter-row-fixture="true"]')).toBeVisible()
}

// The strip keeps the GitHub API card in its own pane and combines every model
// provider into a single second pane, so the model count no longer changes the
// pane count or trips a compressed form. The fixture carries four model
// providers (plus the GitHub pane) to exercise that combined pane.
test('the model pane groups providers, keeps every freshness state, and fits without scrolling', async ({ browser }) => {
  test.setTimeout(60_000)

  for (const width of [1440, 1280, 960, 768, 390]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, reducedMotion: 'reduce' })
    const page = await context.newPage()

    try {
      await openMeterRow(page)

      // Two panes regardless of model count: the GitHub card, then one models pane.
      await expect(page.locator('.run-summary')).toHaveCount(1)
      await expect(page.locator('.rs-block')).toHaveCount(2)
      await expect(page.locator('.rs-block.rs-models')).toHaveCount(1)

      // All four model providers render inside the one combined pane.
      const models = page.locator('.rs-models .rs-model')
      await expect(models).toHaveCount(4)

      // Identity survives the grouping: one logo per row, and it leads the row.
      const codex = page.locator('.rs-model').filter({ hasText: 'Codex' })
      await expect(codex.locator('.rs-logo')).toHaveCount(1)

      for (const name of ['Codex', 'Claude', 'DeepSeek', 'Kimi']) {
        const row = page.locator('.rs-model').filter({ hasText: name })
        await expect(row.locator('.rs-head > :first-child')).toHaveClass(/rs-logo/)
      }

      // Only Claude and Codex carry a second, right-hand token glyph.
      await expect(page.locator('.rs-model').filter({ hasText: 'Codex' }).locator('.rs-token-ic')).toHaveCount(1)
      await expect(page.locator('.rs-model').filter({ hasText: 'Claude' }).locator('.rs-token-ic')).toHaveCount(1)
      await expect(page.locator('.rs-model').filter({ hasText: 'DeepSeek' }).locator('.rs-token-ic, .rs-token-na')).toHaveCount(0)
      await expect(page.locator('.rs-model').filter({ hasText: 'Kimi' }).locator('.rs-token-ic, .rs-token-na')).toHaveCount(0)

      // Every freshness state stays distinguishable on the meter's own meta
      // line, now that the head-row chip is gone.
      await expect(page.locator('.rs-state')).toHaveCount(0)
      await expect(page.locator('.rs-model').filter({ hasText: 'Claude' }).locator('.rs-limit-meta')).toContainText('(stale)')
      await expect(page.locator('.rs-model').filter({ hasText: 'DeepSeek' }).locator('.rs-limit-meta')).toContainText('0% · resets in')
      await expect(page.locator('.rs-model').filter({ hasText: 'Kimi' }).locator('.rs-limit-meta')).toHaveText('Unavailable')

      // Neither the row nor the page body scrolls horizontally.
      await assertNoDocumentOverflow(page)

      const rowOverflow = await page.locator('.run-summary').evaluate((row) => row.scrollWidth - row.clientWidth)
      expect(rowOverflow).toBeLessThanOrEqual(0)
    } finally {
      await context.close()
    }
  }
})
