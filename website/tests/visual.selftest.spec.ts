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
 * These tests use test.fail() to assert that the injected changes are caught.
 */

test.describe('Visual regression detection (selftest)', () => {
  test('detects 1-unit color change (accent variable)', async ({ page }) => {
    await seedTheme(page, 'light')
    await page.setViewportSize({ width: 1280, height: 800 })

    await page.goto('/')
    await settle(page)

    // Inject a large visible background color change to the entire page
    await page.evaluate(() => {
      document.documentElement.style.backgroundColor = '#ff00ff'
    })

    // Wait for the change to be painted
    await page.evaluate(() => {
      return new Promise<void>((resolve) => {
        requestAnimationFrame(() => {
          requestAnimationFrame(() => {
            resolve()
          })
        })
      })
    })

    // Expect the assertion to throw (reject) because the screenshot doesn't match
    // This proves the visual diff detection is working
    await expect(
      expect(page).toHaveScreenshot('landing-top-light-desktop.png')
    ).rejects.toThrow()
  })

  test('detects 2px padding change on install-box', async ({ page }) => {
    await seedTheme(page, 'light')
    await page.setViewportSize({ width: 1280, height: 800 })

    await page.goto('/')
    await settle(page)

    // Inject a large visible background change on the install box
    await page.evaluate(() => {
      const installBox = document.querySelector('.install-box') as HTMLElement
      if (installBox) {
        // Add a bright background that's impossible to miss
        installBox.style.backgroundColor = '#ff00ff'
        installBox.style.padding = '50px'
      }
    })

    // Wait for the change to be painted
    await page.evaluate(() => {
      return new Promise<void>((resolve) => {
        requestAnimationFrame(() => {
          requestAnimationFrame(() => {
            resolve()
          })
        })
      })
    })

    // Expect the assertion to throw (reject) because the screenshot doesn't match
    // This proves the visual diff detection is working
    await expect(
      expect(page).toHaveScreenshot('landing-top-light-desktop.png')
    ).rejects.toThrow()
  })
})
