import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { openVisualRoute } from '../support/visual.mjs'

for (const theme of ['dark', 'light']) for (const palette of ['aiur', 'gruvbox']) {
  const guard = theme === 'dark' ? 'future regression guard: ' : ''
  test(`${guard}History outcomes retain readable contrast in ${theme} ${palette}`, async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 844 })
    await openVisualRoute(page, { theme, palette, route: '/commands/decision-123' })
    await page.addStyleTag({ content: 'html { font-size: 200% !important; }' })
    await expect(page.locator('.chip.good').filter({ hasText: 'Answered' }).first()).toBeVisible()
    const audit = await new AxeBuilder({ page }).include('.chip.good').withRules(['color-contrast']).analyze()
    expect(audit.violations).toEqual([])
    expect(audit.passes.some(result => result.id === 'color-contrast')).toBe(true)
  })
}
