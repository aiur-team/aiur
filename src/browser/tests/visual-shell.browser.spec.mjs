import { test, expect } from '@playwright/test'
import { getMaskConfig } from '../support/visual.mjs'

const THEMES = ['light', 'dark']
const VIEWPORTS = [
  { name: '1440×900', width: 1440, height: 900 },
  { name: '1024×768', width: 1024, height: 768 },
  { name: '390×844', width: 390, height: 844 }
]
const ROUTES = ['/', '/build-orders', '/analytics']

/**
 * Helper to seed theme in localStorage and navigate
 */
async function setupThemeAndNavigate(page, theme, route) {
  await page.goto(route, { waitUntil: 'domcontentloaded' })

  // Seed theme via localStorage
  await page.evaluate((t) => {
    localStorage.setItem('aiur-theme', t)
  }, theme)

  // Reload to apply theme from localStorage
  await page.goto(route, { waitUntil: 'networkidle' })

  // Wait for theme to render (LiveView class application, CSS-in-JS)
  await page.waitForTimeout(500)
}

/**
 * Helper to set nav collapse state based on viewport
 */
async function setNavState(page, viewport) {
  const isSmallViewport = viewport.width <= 959

  if (isSmallViewport) {
    // Small viewport defaults to bottom-pill nav (no sidebar)
    await page.evaluate(() => {
      localStorage.setItem('aiur-nav-collapsed', 'true')
    })
    // Trigger restore-nav event for LiveView to pick up the change
    await page.evaluate(() => {
      document.dispatchEvent(new Event('restore-nav'))
    })
  } else {
    // Desktop: test both expanded and collapsed states
    // Start with expanded (default)
    await page.evaluate(() => {
      localStorage.removeItem('aiur-nav-collapsed')
    })
  }

  await page.waitForTimeout(300)
}

/**
 * Full-page and route-specific baseline snapshots
 */
test.describe.each(THEMES)('Visual baseline: %s theme', (theme) => {
  test.describe.each(VIEWPORTS)('%s viewport', ({ name, width, height }) => {
    test.beforeEach(async ({ page }) => {
      await page.setViewportSize({ width, height })
    })

    test.describe.each(ROUTES)('Route: %s', (route) => {
      test('full-page shell baseline', async ({ page }) => {
        await setupThemeAndNavigate(page, theme, route)
        await setNavState(page, { width, height })

        await expect(page).toHaveScreenshot(
          `${theme}-${width}x${height}-${route.replace(/\//g, '')}-shell.png`,
          { mask: getMaskConfig() }
        )
      })

      test('header topbar element', async ({ page }) => {
        await setupThemeAndNavigate(page, theme, route)
        await setNavState(page, { width, height })

        const header = page.locator('header.topbar')
        await expect(header).toBeVisible()
        await expect(header).toHaveScreenshot(
          `${theme}-${width}x${height}-${route.replace(/\//g, '')}-header.png`,
          { mask: getMaskConfig() }
        )
      })

      test('shell sidebar (desktop) or mobile nav', async ({ page }) => {
        await setupThemeAndNavigate(page, theme, route)
        await setNavState(page, { width, height })

        const isSmallViewport = width <= 959
        const navLocator = isSmallViewport
          ? page.locator('.shell-nav-mobile')
          : page.locator('aside.shell-sidebar')

        await expect(navLocator).toBeVisible()
        await expect(navLocator).toHaveScreenshot(
          `${theme}-${width}x${height}-${route.replace(/\//g, '')}-nav.png`,
          { mask: getMaskConfig() }
        )
      })

      test('route context (main content area)', async ({ page }) => {
        await setupThemeAndNavigate(page, theme, route)
        await setNavState(page, { width, height })

        const content = page.locator('.route-context')
        await expect(content).toBeVisible()
        await expect(content).toHaveScreenshot(
          `${theme}-${width}x${height}-${route.replace(/\//g, '')}-content.png`,
          { mask: getMaskConfig() }
        )
      })

      test('primary button element', async ({ page }) => {
        await setupThemeAndNavigate(page, theme, route)
        await setNavState(page, { width, height })

        // Find first regular button
        const btn = page.locator('button.btn:first-of-type')
        if (await btn.isVisible()) {
          await expect(btn).toHaveScreenshot(
            `${theme}-${width}x${height}-${route.replace(/\//g, '')}-btn.png`,
            { mask: getMaskConfig() }
          )
        }
      })

      test('ghost button element', async ({ page }) => {
        await setupThemeAndNavigate(page, theme, route)
        await setNavState(page, { width, height })

        // Find first ghost button
        const ghostBtn = page.locator('button.btn.ghost:first-of-type')
        if (await ghostBtn.isVisible()) {
          await expect(ghostBtn).toHaveScreenshot(
            `${theme}-${width}x${height}-${route.replace(/\//g, '')}-ghost-btn.png`,
            { mask: getMaskConfig() }
          )
        }
      })

      test('tool button element', async ({ page }) => {
        await setupThemeAndNavigate(page, theme, route)
        await setNavState(page, { width, height })

        // Find first tool button
        const toolBtn = page.locator('.tool-btn:first-of-type')
        if (await toolBtn.isVisible()) {
          await expect(toolBtn).toHaveScreenshot(
            `${theme}-${width}x${height}-${route.replace(/\//g, '')}-tool-btn.png`,
            { mask: getMaskConfig() }
          )
        }
      })
    })

    /**
     * Nav state variations: expanded sidebar on desktop
     */
    test('desktop: expanded nav sidebar state', async ({ page }) => {
      if (width <= 959) {
        test.skip()
      }

      await setupThemeAndNavigate(page, theme, '/')

      // Ensure nav is expanded (no localStorage marker)
      await page.evaluate(() => {
        localStorage.removeItem('aiur-nav-collapsed')
      })
      await page.evaluate(() => {
        document.dispatchEvent(new Event('restore-nav'))
      })
      await page.waitForTimeout(300)

      const sidebar = page.locator('aside.shell-sidebar')
      await expect(sidebar).toBeVisible()

      // Check that expanded state is visually different from collapsed
      await expect(sidebar).toHaveScreenshot(
        `${theme}-${width}x${height}-nav-expanded.png`,
        { mask: getMaskConfig() }
      )
    })

    /**
     * Nav state variations: collapsed sidebar on desktop
     */
    test('desktop: collapsed nav sidebar state', async ({ page }) => {
      if (width <= 959) {
        test.skip()
      }

      await setupThemeAndNavigate(page, theme, '/')

      // Collapse nav
      await page.evaluate(() => {
        localStorage.setItem('aiur-nav-collapsed', 'true')
      })
      await page.evaluate(() => {
        document.dispatchEvent(new Event('restore-nav'))
      })
      await page.waitForTimeout(300)

      const sidebar = page.locator('aside.shell-sidebar')
      await expect(sidebar).toBeVisible()

      await expect(sidebar).toHaveScreenshot(
        `${theme}-${width}x${height}-nav-collapsed.png`,
        { mask: getMaskConfig() }
      )
    })
  })
})

/**
 * Keyboard focus baseline: ensure focus ring is visible
 */
test.describe('Keyboard focus states', () => {
  test('first nav item focus ring (desktop)', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 })

    await setupThemeAndNavigate(page, 'light', '/')
    await setNavState(page, { width: 1440, height: 900 })

    // Tab to first nav item
    const firstNavItem = page.locator('.shell-nav-item').first()
    await firstNavItem.focus()

    // Verify focus ring is visible
    await expect(firstNavItem).toBeFocused()

    await expect(firstNavItem).toHaveScreenshot(
      'keyboard-focus-nav-item-light.png',
      { mask: getMaskConfig() }
    )
  })

  test('first nav item focus ring (dark theme)', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 })

    await setupThemeAndNavigate(page, 'dark', '/')
    await setNavState(page, { width: 1440, height: 900 })

    // Tab to first nav item
    const firstNavItem = page.locator('.shell-nav-item').first()
    await firstNavItem.focus()

    // Verify focus ring is visible
    await expect(firstNavItem).toBeFocused()

    await expect(firstNavItem).toHaveScreenshot(
      'keyboard-focus-nav-item-dark.png',
      { mask: getMaskConfig() }
    )
  })
})

/**
 * Proof test: Validate that visual regression detection works
 *
 * This test demonstrates that:
 * 1. The baseline is actually consulted during comparison
 * 2. Real CSS changes are caught (not masked away)
 * 3. Masking doesn't suppress legitimate visual differences
 */
test.describe('Visual regression proof test', () => {
  test('CSS change to nav padding triggers regression detection', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 })
    
    await setupThemeAndNavigate(page, 'light', '/build-orders')
    await setNavState(page, { width: 1440, height: 900 })
    
    // Take baseline screenshot
    await expect(page).toHaveScreenshot('proof-test-baseline.png', {
      mask: getMaskConfig()
    })
    
    // Inject CSS that changes nav item padding
    // This change should be VISIBLE and NOT masked
    await page.addStyleTag({
      content: `.shell-nav-item { padding-left: calc(0.72rem + 2px) !important; }`
    })
    
    await page.waitForTimeout(200)
    
    // Second screenshot with injected CSS should NOT match baseline
    // We expect this to fail the comparison, proving regression detection works
    let comparisonFailed = false
    try {
      await expect(page).toHaveScreenshot('proof-test-baseline.png', {
        mask: getMaskConfig()
      })
    } catch (error) {
      // Expected: comparison should fail because CSS changed the layout
      if (error.message.includes('Screenshot comparison failed')) {
        comparisonFailed = true
      } else {
        throw error
      }
    }
    
    // Assert that the comparison actually failed
    // If this assertion fails, it means the baseline wasn't checked or masking hid the change
    if (!comparisonFailed) {
      throw new Error(
        'Proof test failed: CSS change did not trigger screenshot mismatch. ' +
        'Baseline may not be loaded or masking may be suppressing the change.'
      )
    }
  })
})
