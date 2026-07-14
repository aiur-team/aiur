import { expect, test } from '@playwright/test'

test('intentional failure produces browser evidence', async ({ page }) => {
  await page.goto('/auth/read_only')
  await expect(page.locator('[data-fixture-ready="true"]')).toBeVisible()
  await expect(page.locator('#fixture-status')).toHaveText('this assertion intentionally fails')
})
