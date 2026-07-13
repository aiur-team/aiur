import { expect, test } from '@playwright/test'

const themes = ['light', 'dark'] as const

test('homepage establishes the canonical default theme', async ({ page }) => {
  await page.goto('/')
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark')
  await expect.poll(() => page.evaluate(() => localStorage.getItem('aiur-theme'))).toBe('dark')
})

test('light preference is applied before docs hydration', async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('aiur-theme', 'light')
    localStorage.setItem('vitepress-theme-appearance', 'dark')
    ;(window as typeof window & { darkThemeObserved?: boolean }).darkThemeObserved = false
    new MutationObserver(() => {
      if (document.documentElement.classList.contains('dark')) {
        ;(window as typeof window & { darkThemeObserved?: boolean }).darkThemeObserved = true
      }
    }).observe(document.documentElement, { attributes: true, attributeFilter: ['class'] })
  })

  await page.goto('/docs/guide/quick-start')
  await expect(page.locator('html')).not.toHaveClass(/dark/)
  expect(await page.evaluate(() => (window as typeof window & { darkThemeObserved?: boolean }).darkThemeObserved)).toBe(false)
  expect(await page.evaluate(() => localStorage.getItem('vitepress-theme-appearance'))).toBe('light')
})

for (const theme of themes) {
  test(`${theme} theme remains accessible across home and docs`, async ({ page }) => {
    await page.addInitScript((savedTheme) => {
      localStorage.setItem('aiur-theme', savedTheme)
    }, theme)

    await page.goto('/')
    await expect(page.locator('html')).toHaveAttribute('data-theme', theme)
    await page.locator('#themeToggle').click()
    await expect.poll(() => page.evaluate(() => localStorage.getItem('aiur-theme'))).toBe(opposite(theme))
    await page.locator('#themeToggle').click()

    await page.getByRole('link', { name: 'Docs' }).first().click()
    await expect(page).toHaveURL(/\/docs\/guide\/quick-start/)
    await expect(page.locator('html')).toHaveClass(theme === 'dark' ? /dark/ : /^(?!.*dark)/)
    expect(localStorageTheme(await page.evaluate(() => localStorage.getItem('aiur-theme')))).toBe(theme)

    const docsThemeToggle = page.locator('.VPSwitchAppearance:visible').first()
    await docsThemeToggle.click()
    await expect.poll(() => page.evaluate(() => localStorage.getItem('aiur-theme'))).toBe(opposite(theme))
    await docsThemeToggle.click()

    const contrast = await page.evaluate(() => {
      const styles = getComputedStyle(document.documentElement)
      return {
        muted: styles.getPropertyValue('--aiur-muted').trim(),
        brandButton: {
          foreground: styles.getPropertyValue('--vp-button-brand-text').trim(),
          background: styles.getPropertyValue('--vp-button-brand-bg').trim()
        },
        backgrounds: [
          styles.getPropertyValue('--aiur-bg').trim(),
          styles.getPropertyValue('--aiur-bg-soft').trim()
        ]
      }
    })
    for (const background of contrast.backgrounds) {
      expect(contrastRatio(contrast.muted, background)).toBeGreaterThanOrEqual(4.5)
    }
    expect(contrastRatio(contrast.brandButton.foreground, contrast.brandButton.background)).toBeGreaterThanOrEqual(4.5)

    const homeLink = page.getByRole('link', { name: 'Home' })
    await expect(homeLink).toHaveAttribute('href', 'https://aiur.team/')
    await page.goto('/')
    await expect(page).toHaveURL('http://127.0.0.1:43127/')
    await expect(page.locator('html')).toHaveAttribute('data-theme', theme)
  })
}

function localStorageTheme(value: string | null): 'light' | 'dark' | null {
  return value === 'light' || value === 'dark' ? value : null
}

function opposite(theme: 'light' | 'dark'): 'light' | 'dark' {
  return theme === 'light' ? 'dark' : 'light'
}

function contrastRatio(foreground: string, background: string): number {
  const luminance = (hex: string) => {
    const channels = hex.match(/[a-f\d]{2}/gi)?.map((value) => Number.parseInt(value, 16) / 255) ?? []
    const linear = channels.map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
  }
  const [lighter, darker] = [luminance(foreground), luminance(background)].sort((a, b) => b - a)
  return (lighter + 0.05) / (darker + 0.05)
}
