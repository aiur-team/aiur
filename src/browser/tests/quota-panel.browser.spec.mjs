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

  // The leader is measured in points, not calls, and carries its own share.
  const top = panel.locator('.github-quota-attribution')
  await expect(top).toContainText('ticket:1790')
  await expect(top).toContainText('338 points')
  await expect(top).toContainText('of window spend')

  // And the panel never presents that leader as the whole picture.
  const coverage = panel.locator('.github-quota-coverage')
  await expect(coverage).toContainText('Attributed')
  await expect(coverage).toContainText('spent this window')
  await expect(coverage).toContainText('observed')

  await assertNoDocumentOverflow(page)
})
