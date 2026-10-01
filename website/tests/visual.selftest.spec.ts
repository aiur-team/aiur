import { test, expect } from '@playwright/test'
import { seedTheme, settle } from './support/visual'

/**
 * Self-test: Prove that the snapshot threshold catches visual regressions
 *
 * These tests are intentionally expected to fail. They inject small visual changes
 * (1-unit color change, 2px padding) and verify that toHaveScreenshot() detects them.
 *
 * If these tests pass (snapshot matches despite the injected changes), it means
 * the threshold is too loose and will miss real regressions.
 *
 * These tests should be run with test.fail() so they pass when the snapshot DOESN'T match.
 */

test.describe('Visual regression detection (selftest)', () => {
  test('detects 1-unit color change (accent variable)', async ({ page }) => {
    test.fail() // This test is expected to fail (snapshot mismatch is the desired outcome)

    await seedTheme(page, 'light')
    await page.setViewportSize({ width: 1280, height: 800 })

    await page.goto('/')

    // Inject a 1-unit color change
    await page.evaluate(() => {
      document.documentElement.style.setProperty('--accent', '#2f86fe')
    })

    await settle(page)

    // This snapshot comparison should FAIL because the color changed
    await expect(page).toHaveScreenshot('landing-top-light-desktop.png')
  })

  test('detects 2px padding change on install-box', async ({ page }) => {
    test.fail() // This test is expected to fail (snapshot mismatch is the desired outcome)

    await seedTheme(page, 'light')
    await page.setViewportSize({ width: 1280, height: 800 })

    await page.goto('/')

    // Inject a 2px padding change
    await page.evaluate(() => {
      const installBox = document.querySelector('.install-box')
      if (installBox) {
        const current = window.getComputedStyle(installBox).padding
        ;(installBox as HTMLElement).style.padding = 'calc(' + current + ' + 2px)'
      }
    })

    await settle(page)

    // This snapshot comparison should FAIL because padding changed
    await expect(page).toHaveScreenshot('landing-top-light-desktop.png')
  })
})
