import { test, expect, devices } from '@playwright/test'
import { seedTheme, settle } from './support/visual'

// Define the test matrix: themes, viewports, and states
const themes = ['light', 'dark'] as const
const viewports = [
  { name: 'desktop', width: 1280, height: 800 },
  { name: 'mobile', width: 390, height: 844, deviceScaleFactor: 3 },
  { name: 'mobile-landscape', width: 844, height: 390 }
]

test.describe.configure({ mode: 'parallel' })

// Landing page tests
test.describe('Landing page (/)', () => {
  for (const theme of themes) {
    test.describe(`${theme} theme`, () => {
      for (const viewport of viewports) {
        test.describe(`${viewport.name} viewport`, () => {
          test('state (a): top of page', async ({ page }) => {
            await seedTheme(page, theme)
            if (viewport.deviceScaleFactor) {
              await page.setViewportSize({ width: viewport.width, height: viewport.height })
            } else {
              await page.setViewportSize({ width: viewport.width, height: viewport.height })
            }

            await page.goto('/')
            await settle(page)
            await expect(page).toHaveScreenshot(`landing-top-${theme}-${viewport.name}.png`)
          })

          test('state (b): scrolled 900px (brand section revealed)', async ({ page }) => {
            await seedTheme(page, theme)
            if (viewport.deviceScaleFactor) {
              await page.setViewportSize({ width: viewport.width, height: viewport.height })
            } else {
              await page.setViewportSize({ width: viewport.width, height: viewport.height })
            }

            await page.goto('/')
            await page.evaluate(() => window.scrollBy(0, 900))
            await settle(page)
            await expect(page).toHaveScreenshot(`landing-scrolled-${theme}-${viewport.name}.png`)
          })

          test('state (c): banner dismissed', async ({ page }) => {
            await seedTheme(page, theme)
            if (viewport.deviceScaleFactor) {
              await page.setViewportSize({ width: viewport.width, height: viewport.height })
            } else {
              await page.setViewportSize({ width: viewport.width, height: viewport.height })
            }

            await page.context().addCookies([
              {
                name: 'aiur-archon-banner',
                value: 'dismissed',
                url: 'http://127.0.0.1:43127'
              }
            ])

            await page.goto('/')
            await settle(page)
            await expect(page).toHaveScreenshot(`landing-banner-dismissed-${theme}-${viewport.name}.png`)
          })

          const tabs = ['Prompt', 'npm', 'bun', 'pnpm', 'yarn']
          for (const tab of tabs) {
            test(`state (d): ${tab} tab selected`, async ({ page }) => {
              await seedTheme(page, theme)
              if (viewport.deviceScaleFactor) {
                await page.setViewportSize({ width: viewport.width, height: viewport.height })
              } else {
                await page.setViewportSize({ width: viewport.width, height: viewport.height })
              }

              await page.goto('/')

              // Click the tab button
              const tabButton = page.locator(`button:has-text("${tab}"):visible`).first()
              await tabButton.click({ force: true })

              await settle(page)
              await expect(page).toHaveScreenshot(`landing-tab-${tab.toLowerCase()}-${theme}-${viewport.name}.png`)
            })
          }

          test('state (e): npm tab + copy clicked', async ({ page }) => {
            await seedTheme(page, theme)
            if (viewport.deviceScaleFactor) {
              await page.setViewportSize({ width: viewport.width, height: viewport.height })
            } else {
              await page.setViewportSize({ width: viewport.width, height: viewport.height })
            }

            // Grant clipboard permissions
            await page.context().grantPermissions(['clipboard-read', 'clipboard-write'])

            await page.goto('/')

            // Click npm tab
            const npmTab = page.locator('button:has-text("npm"):visible').first()
            await npmTab.click({ force: true })

            // Click copy button
            const copyBtn = page.locator('button:has-text("Copy"):visible').first()
            if (await copyBtn.isVisible()) {
              await copyBtn.click({ force: true })
            }

            await settle(page)
            await expect(page).toHaveScreenshot(`landing-npm-copy-${theme}-${viewport.name}.png`)
          })
        })
      }
    })
  }
})

// Documentation pages tests
test.describe('Documentation pages', () => {
  const docPages = [
    { path: '/docs/', name: 'docs-index' },
    { path: '/docs/guide/quick-start', name: 'docs-quick-start' }
  ]

  for (const theme of themes) {
    test.describe(`${theme} theme`, () => {
      for (const { path, name } of docPages) {
        test(`${name}`, async ({ page }) => {
          await seedTheme(page, theme)
          await page.setViewportSize({ width: 1280, height: 800 })

          await page.goto(path)
          await settle(page)
          await expect(page).toHaveScreenshot(`${name}-${theme}.png`)
        })
      }

      test('product switcher open', async ({ page }) => {
        await seedTheme(page, theme)
        await page.setViewportSize({ width: 1280, height: 800 })

        await page.goto('/docs/')

        // Open product switcher
        const switcher = page.locator('[data-test="product-switcher"]').first()
        if (await switcher.isVisible()) {
          await switcher.click()
        }

        await settle(page)
        await expect(page).toHaveScreenshot(`docs-switcher-open-${theme}.png`)
      })
    })
  }
})

// Element-level snapshots for key sections
test.describe('Element snapshots', () => {
  const elements = [
    { selector: '.announce', name: 'announce' },
    { selector: '.topbar', name: 'topbar' },
    { selector: '.install-box', name: 'install-box' },
    { selector: '.features', name: 'features' },
    { selector: '.site-foot', name: 'site-foot' },
    { selector: '.VPNav', name: 'vpnav' }
  ]

  for (const theme of ['light', 'dark']) {
    test.describe(`${theme} theme`, () => {
      for (const { selector, name } of elements) {
        test(`${name} element`, async ({ page }) => {
          await seedTheme(page, theme)
          await page.setViewportSize({ width: 1280, height: 800 })

          await page.goto('/')

          const element = page.locator(selector).first()
          if (await element.isVisible()) {
            await element.scrollIntoViewIfNeeded()
            await settle(page)
            await expect(element).toHaveScreenshot(`element-${name}-${theme}.png`)
          }
        })
      }
    })
  }
})

// Self-test: Prove that the snapshot threshold catches visual regressions
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
