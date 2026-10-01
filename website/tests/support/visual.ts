import { Page } from '@playwright/test'

/**
 * Seed the theme in localStorage before page load
 * @param page Playwright page instance
 * @param theme 'light' or 'dark'
 */
export async function seedTheme(page: Page, theme: 'light' | 'dark'): Promise<void> {
  await page.addInitScript(({ theme }) => {
    localStorage.setItem('aiur-theme', theme)
  }, { theme })
}

/**
 * Route Google Fonts requests to local fixture copies
 * Eliminates network dependency and ensures font availability
 * @param page Playwright page instance
 */
export async function routeFonts(page: Page): Promise<void> {
  const fixtureRoot = 'file:///' + __dirname.replace(/\\/g, '/').replace('/tests/support', '') + '/fixtures/fonts'

  await page.route('**/fonts.googleapis.com/**', async (route) => {
    // Return a local CSS that imports vendored fonts
    await route.abort()
  })

  await page.route('**/fonts.gstatic.com/**', async (route) => {
    const url = route.request().url()
    // Extract font file name from URL
    const match = url.match(/fonts\.gstatic\.com\/s\/([^/?]+)\//)
    if (match) {
      // Attempt to serve from local fixtures; if not found, abort
      const fontPath = `${fixtureRoot}/${match[1]}.woff2`
      await route.fetch({ url: fontPath }).catch(() => route.abort())
    } else {
      await route.abort()
    }
  })
}

/**
 * Settle the page: wait for fonts to load and animations to stabilize
 * Ensures deterministic visual rendering by waiting for:
 * - Font loading completion (document.fonts.ready)
 * - Paint cycles (2x requestAnimationFrame)
 * @param page Playwright page instance
 */
export async function settle(page: Page): Promise<void> {
  // Wait for all fonts to load
  await page.evaluate(() => document.fonts.ready)

  // Wait 2x requestAnimationFrame to let paint cycles settle
  await page.evaluate(() => {
    return new Promise<void>((resolve) => {
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          resolve()
        })
      })
    })
  })
}
