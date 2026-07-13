import { expect, test } from '@playwright/test'

const themes = ['light', 'dark'] as const

test('homepage establishes the canonical default theme', async ({ page }) => {
  await page.goto('/')
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark')
  await expect.poll(() => page.evaluate(() => localStorage.getItem('aiur-theme'))).toBe('dark')
})

test('light homepage preference is applied before module hydration', async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('aiur-theme', 'light')
    ;(window as typeof window & { darkHomepageObserved?: boolean }).darkHomepageObserved = false
    new MutationObserver(() => {
      if (document.documentElement.getAttribute('data-theme') === 'dark') {
        ;(window as typeof window & { darkHomepageObserved?: boolean }).darkHomepageObserved = true
      }
    }).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] })
  })

  await page.goto('/')
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
  expect(await page.evaluate(() => (window as typeof window & { darkHomepageObserved?: boolean }).darkHomepageObserved)).toBe(false)
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

    const codeLanguageLabel = page.locator('.lang').first()
    expect(contrastRatio(...await renderedColors(codeLanguageLabel))).toBeGreaterThanOrEqual(4.5)

    const homeLink = page.getByRole('link', { name: 'Home' })
    await expect(homeLink).toHaveAttribute('href', 'https://aiur.team/')
    await expect(homeLink).toHaveAttribute('target', '_self')
    await page.route('https://aiur.team/', (route) => route.fulfill({
      contentType: 'text/html',
      body: '<!doctype html><title>Aiur home</title><h1>Aiur</h1>'
    }))
    const pageCount = page.context().pages().length
    await homeLink.click()
    await expect(page).toHaveURL('https://aiur.team/')
    expect(page.context().pages()).toHaveLength(pageCount)
  })
}

test('dark brand CTA interaction states meet contrast requirements', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('aiur-theme', 'dark'))
  await page.goto('/docs/')
  const cta = page.locator('.VPButton.brand').first()

  await cta.hover()
  expect(contrastRatio(...await colors(cta))).toBeGreaterThanOrEqual(4.5)

  await page.mouse.move(0, 0)
  await cta.focus()
  expect(contrastRatio(...await colors(cta))).toBeGreaterThanOrEqual(4.5)
})

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

async function colors(locator: import('@playwright/test').Locator): Promise<[string, string]> {
  return locator.evaluate((element) => {
    const styles = getComputedStyle(element)
    const toHex = (color: string) => {
      const channels = color.match(/\d+/g)?.slice(0, 3).map(Number) ?? []
      return `#${channels.map((channel) => channel.toString(16).padStart(2, '0')).join('')}`
    }
    return [toHex(styles.color), toHex(styles.backgroundColor)]
  })
}

async function renderedColors(locator: import('@playwright/test').Locator): Promise<[string, string]> {
  return locator.evaluate((element) => {
    const toHex = (color: string) => {
      const channels = color.match(/\d+/g)?.slice(0, 3).map(Number) ?? []
      return `#${channels.map((channel) => channel.toString(16).padStart(2, '0')).join('')}`
    }
    const foreground = getComputedStyle(element).color
    let backgroundElement: Element | null = element
    let background = 'rgba(0, 0, 0, 0)'
    while (backgroundElement && /rgba?\([^)]*,\s*0\)/.test(background)) {
      background = getComputedStyle(backgroundElement).backgroundColor
      backgroundElement = backgroundElement.parentElement
    }
    return [toHex(foreground), toHex(background)]
  })
}
