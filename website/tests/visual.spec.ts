import { test, expect } from '@playwright/test'
import { seedTheme, settle, routeFonts, screenshotMask } from './support/visual'

const themes = ['light', 'dark'] as const
const viewports = [
  { name: 'desktop', width: 1280, height: 800, deviceScaleFactor: 1, isMobile: false },
  { name: 'mobile', width: 390, height: 844, deviceScaleFactor: 3, isMobile: true },
  { name: 'mobile-landscape', width: 844, height: 390, deviceScaleFactor: 1, isMobile: false }
]

test.describe.configure({ mode: 'parallel' })
test.beforeEach(async ({ page }) => {
  await routeFonts(page)
})

for (const theme of themes) {
  for (const viewport of viewports) {
    test.describe(`${theme} ${viewport.name}`, () => {
      test.use({
        viewport: { width: viewport.width, height: viewport.height },
        deviceScaleFactor: viewport.deviceScaleFactor,
        isMobile: viewport.isMobile
      })
      test.beforeEach(async ({ page }) => {
        await seedTheme(page, theme)
      })
      const suffix = `${theme}-${viewport.name}`

      test('landing top', async ({ page }) => {
        await page.goto('/')
        await settle(page)
        await expect(page).toHaveScreenshot(`landing-top-${suffix}.png`, { mask: screenshotMask(page) })
      })

      test('landing scrolled 900px', async ({ page }) => {
        await page.goto('/')
        await page.evaluate(() => window.scrollTo(0, 900))
        await settle(page)
        await expect(page).toHaveScreenshot(`landing-scrolled-${suffix}.png`, { mask: screenshotMask(page) })
      })

      test('landing banner dismissed', async ({ page }) => {
        await page.addInitScript(() => localStorage.setItem('aiur-archon-banner', 'dismissed'))
        await page.goto('/')
        await expect(page.locator('.announce')).toBeHidden()
        await settle(page)
        await expect(page).toHaveScreenshot(`landing-banner-dismissed-${suffix}.png`, { mask: screenshotMask(page) })
      })

      for (const tab of ['Prompt', 'npm', 'bun', 'pnpm', 'yarn']) {
        test(`landing ${tab} tab selected`, async ({ page }) => {
          await page.goto('/')
          const button = page.getByRole('tab', { name: tab, exact: true })
          await button.click()
          await expect(button).toHaveAttribute('aria-selected', 'true')
          await settle(page)
          await expect(page).toHaveScreenshot(`landing-tab-${tab.toLowerCase()}-${suffix}.png`, { mask: screenshotMask(page) })
          await expect(page.locator('.hero')).toHaveScreenshot(`hero-tab-${tab.toLowerCase()}-${suffix}.png`, { mask: screenshotMask(page) })
          await expect(page.locator('#installWrap')).toHaveScreenshot(`install-wrap-tab-${tab.toLowerCase()}-${suffix}.png`)
        })
      }

      test('landing npm copy opens next steps', async ({ page }) => {
        await page.context().grantPermissions(['clipboard-read', 'clipboard-write'])
        await page.goto('/')
        await page.getByRole('tab', { name: 'npm', exact: true }).click()
        await page.locator('#copyBtn').click()
        await expect(page.locator('#nextSteps')).toHaveAttribute('aria-hidden', 'false')
        // The transient copied icon resets after 1.3 seconds.
        await expect(page.locator('#copyBtn')).not.toHaveClass(/copied/)
        await settle(page)
        await expect(page).toHaveScreenshot(`landing-npm-copy-${suffix}.png`, { mask: screenshotMask(page) })
      })

      for (const { path, name } of [
        { path: '/docs/', name: 'docs-index' },
        { path: '/docs/guide/quick-start', name: 'docs-quick-start' }
      ]) {
        test(name, async ({ page }) => {
          await page.goto(path)
          await settle(page)
          await expect(page).toHaveScreenshot(`${name}-${suffix}.png`, { mask: screenshotMask(page) })
        })
      }

      test('docs product switcher open', async ({ page }) => {
        await page.goto('/docs/')
        const button = page.locator('#product-switcher-button')
        await expect(button).toBeVisible()
        await button.click()
        const menu = page.locator('#product-switcher-menu')
        await expect(menu).toBeVisible()
        await settle(page)
        await expect(page).toHaveScreenshot(`docs-switcher-open-${suffix}.png`, { mask: screenshotMask(page) })
        await expect(menu).toHaveScreenshot(`docs-switcher-menu-${suffix}.png`)
      })

      for (const { selector, name, path } of [
        { selector: '.announce', name: 'announce', path: '/' },
        { selector: '.topbar', name: 'topbar', path: '/' },
        { selector: '.install-box', name: 'install-box', path: '/' },
        { selector: '.features', name: 'features', path: '/' },
        { selector: '.site-foot', name: 'site-foot', path: '/' },
        { selector: '.VPNav', name: 'vpnav', path: '/docs/' }
      ]) {
        test(`${name} element`, async ({ page }) => {
          await page.goto(path)
          const element = page.locator(selector).first()
          await expect(element).toBeVisible()
          await element.scrollIntoViewIfNeeded()
          await settle(page)
          // Fixed navigation overlaps tall element clips at scroll-dependent offsets.
          if (name === 'features') await page.addStyleTag({ content: '.topbar { visibility: hidden !important; }' })
          await expect(element).toHaveScreenshot(`element-${name}-${suffix}.png`, { mask: screenshotMask(page) })
          if (name === 'features' && viewport.name === 'mobile') {
            await page.evaluate(() => window.scrollBy(0, 40))
            await settle(page)
            await expect(element).toHaveScreenshot(`element-${name}-${suffix}.png`, { mask: screenshotMask(page), maxDiffPixelRatio: 0, maxDiffPixels: 0 })
          }
        })
      }
    })
  }
}
