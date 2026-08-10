import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'

async function openMeterRow(page) {
  await page.goto('/auth/read_only')
  await page.goto('/meter-row')
  await expect(page.locator('[data-meter-row-fixture="true"]')).toBeVisible()
}

// The fixture carries five panes' worth of providers — the GitHub pane plus
// four model providers — which is the first configuration that collapses the
// row into a single grouped table.
test('the compressed meter row groups providers, keeps every freshness state, and fits without scrolling', async ({ browser }) => {
  test.setTimeout(60_000)

  for (const width of [1440, 1280, 960, 768, 390]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, reducedMotion: 'reduce' })
    const page = await context.newPage()

    try {
      await openMeterRow(page)

      // One pane, not five.
      await expect(page.locator('.run-summary.is-compressed')).toHaveCount(1)
      await expect(page.locator('.rs-block')).toHaveCount(1)

      // The grouping is rendered rather than implied by ordering.
      const groups = page.locator('.rs-group')
      await expect(groups).toHaveCount(2)
      await expect(groups.nth(0).locator('.rs-group-title')).toHaveText('Agent APIs')
      await expect(groups.nth(1).locator('.rs-group-title')).toHaveText('Other')
      await expect(groups.nth(0).locator('.rs-row')).toHaveCount(4)
      await expect(groups.nth(1).locator('.rs-row')).toHaveCount(1)
      await expect(groups.nth(1)).toContainText('GitHub API')

      // Identity, remaining/limit and reset survive the compression.
      const codex = groups.nth(0).locator('.rs-row').filter({ hasText: 'Codex' })
      await expect(codex.locator('.rs-logo')).toHaveCount(1)
      await expect(codex).toContainText('3000/5000 left')
      await expect(codex).toContainText('resets in')

      // So does the freshness distinction: a stale reading, a fresh zero, and a
      // provider that reported nothing are three visibly different rows.
      await expect(groups.nth(0).locator('.rs-row').filter({ hasText: 'Claude' }).locator('.rs-state.is-stale')).toHaveText('Stale')
      await expect(groups.nth(0).locator('.rs-row').filter({ hasText: 'DeepSeek' }).locator('.rs-state.is-healthy')).toHaveText('Healthy')
      await expect(groups.nth(0).locator('.rs-row').filter({ hasText: 'Kimi' }).locator('.rs-state.is-unavailable')).toHaveText('Unavailable')

      // Neither the row nor the page body scrolls horizontally.
      await assertNoDocumentOverflow(page)

      const rowOverflow = await page.locator('.run-summary.is-compressed').evaluate((row) => row.scrollWidth - row.clientWidth)
      expect(rowOverflow).toBeLessThanOrEqual(0)
    } finally {
      await context.close()
    }
  }
})
