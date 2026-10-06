import { test, expect } from '@playwright/test'
import { seedTheme, settle, routeFonts } from './support/visual'

test.use({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1, isMobile: false })

test('visual selftest detects 2px install-box padding drift', async ({ page }, testInfo) => {
  await routeFonts(page)
  await seedTheme(page, 'light')
  await page.goto('/')
  await settle(page)
  const box = page.locator('.install-box')
  await expect(box).toBeVisible()
  // This baseline is owned by the selftest and always depicts the unmodified element.
  const baseline = 'selftest-install-box-padding.png'
  await expect(box).toHaveScreenshot(baseline)
  test.skip(testInfo.config.updateSnapshots !== 'none', 'Only capture the unmodified baseline during snapshot updates')

  await box.evaluate(element => {
    const padding = parseFloat(getComputedStyle(element).paddingTop)
    ;(element as HTMLElement).style.paddingTop = `${padding + 2}px`
  })
  await settle(page)
  await expect(expect(box).toHaveScreenshot(baseline, { timeout: 1000 })).rejects.toThrow(/Expected an image|pixels .* are different/)
})
