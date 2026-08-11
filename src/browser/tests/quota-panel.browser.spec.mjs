import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'

// The panel that answers "what is burning the GitHub budget". It was reporting
// a leader with two requests against 5,000 consumed (#1805): a ranking in the
// wrong unit, drawn from a fraction of the spend it never disclosed.
test('the GitHub quota panel ranks the heaviest consumer and states the share of spend it covers', async ({ page }) => {
  await page.goto('/auth/read_only')
  await page.goto('/quota-panel')

  const panel = page.locator('.github-quota-card')
  await expect(panel).toBeVisible()

  // Both budgets exhausted — the state the bug was reported in.
  await expect(panel).toContainText('0/5000 left')

  // The leader is measured in the unit of the budget it burned, not in calls,
  // and its share is of that budget: 312 of GraphQL's 5,000 points is 6.2%.
  const top = panel.locator('.github-quota-attribution')
  await expect(top).toContainText('ticket:1790')
  await expect(top).toContainText('GraphQL 312 points (6.2%)')
  await expect(top).toContainText('Core 26 requests (0.52%)')

  // And the panel never presents that leader as the whole picture. Coverage is
  // one line per budget, each against its own window — core and GraphQL reset
  // seven minutes apart here, so there is no shared "this window" to divide by.
  const coverage = panel.locator('.github-quota-coverage')
  await expect(coverage).toHaveCount(2)
  await expect(coverage.nth(0)).toContainText('Attributed Core')
  await expect(coverage.nth(0)).toContainText('1.5% of 5000 spent this window')
  await expect(coverage.nth(0)).toContainText('1.5% observed')
  await expect(coverage.nth(1)).toContainText('Attributed GraphQL')
  await expect(coverage.nth(1)).toContainText('6.2% of 5000 spent this window')
  await expect(coverage.nth(1)).toContainText('6.7% observed')
  await expect(coverage.nth(1)).toContainText('cost partly estimated')

  // The combined denominator the panel used to print (5,000 + 5,000) is a
  // quantity of nothing: requests added to points across two windows.
  await expect(panel).not.toContainText('10000')

  await assertNoDocumentOverflow(page)
})
