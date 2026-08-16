import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'

// The GitHub quota card shows each budget's remaining/limit against its own
// reset window. The former "top consumer" ranking and "attributed/observed"
// coverage lines were removed as unhelpful context.
test('the GitHub quota card shows each budget window and fits without scrolling', async ({ page }) => {
  await page.goto('/auth/read_only')
  await page.goto('/quota-panel')

  const panel = page.locator('.github-quota-card')
  await expect(panel).toBeVisible()

  // Both budgets exhausted — the state the bug was reported in.
  await expect(panel).toContainText('0/5000 left')

  // No top-consumer ranking or attributed/observed coverage context is shown.
  await expect(panel.locator('.github-quota-attribution')).toHaveCount(0)
  await expect(panel.locator('.github-quota-coverage')).toHaveCount(0)

  // The combined denominator the panel used to print (5,000 + 5,000) is a
  // quantity of nothing: requests added to points across two windows.
  await expect(panel).not.toContainText('10000')

  await assertNoDocumentOverflow(page)
})
