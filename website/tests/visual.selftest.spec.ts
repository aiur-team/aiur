import { test, expect } from '@playwright/test'
import { seedTheme, settle } from './support/visual'

/**
 * Self-test: Prove that the snapshot threshold catches visual regressions
 *
 * Injects visible changes (background colors, padding) and verifies that
 * toHaveScreenshot() detects them using strict maxDiffPixelRatio (0.002).
 *
 * Skipped during baseline generation (--update-snapshots) since it tests
 * that visual changes are caught, not that baselines match.
 */

test.describe('Visual regression detection (selftest)', () => {
  test.skip(process.env.PW_TEST_REPORTER_JSON !== undefined, 'Skip during update-snapshots')

  test('detects color change (0.002 ratio threshold)', async ({ page }) => {
    test.fail() // Injected change should cause screenshot to fail

    await seedTheme(page, 'light')
    await page.setViewportSize({ width: 1280, height: 800 })

    await page.goto('/')
    await settle(page)

    // Inject a clearly visible background color change
    await page.evaluate(() => {
      document.documentElement.style.backgroundColor = '#ff00ff'
    })

    // Wait for repaint
    await page.waitForTimeout(50)

    // This should FAIL because the magenta background doesn't match the original
    // test.fail() makes this a pass (failed assertion is expected)
    await expect(page).toHaveScreenshot('landing-top-light-desktop.png')
  })

  test('detects padding change (0.002 ratio threshold)', async ({ page }) => {
    test.fail() // Injected change should cause screenshot to fail

    await seedTheme(page, 'light')
    await page.setViewportSize({ width: 1280, height: 800 })

    await page.goto('/')
    await settle(page)

    // Inject a large padding change on the install box
    await page.evaluate(() => {
      const box = document.querySelector('.install-box') as HTMLElement
      if (box) {
        box.style.padding = '50px'
        box.style.backgroundColor = '#ff00ff'
      }
    })

    // Wait for repaint
    await page.waitForTimeout(50)

    // This should FAIL because the padding/color changed
    // test.fail() makes this a pass (failed assertion is expected)
    await expect(page).toHaveScreenshot('landing-top-light-desktop.png')
  })
})
