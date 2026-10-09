import { test, expect } from '@playwright/test'
import { openFixture, assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

async function openProbe(page, { palette, theme, blocked = false } = {}) {
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.evaluate(({ palette, theme }) => {
    localStorage.clear()
    if (palette !== undefined) localStorage.setItem('aiur-palette', palette)
    if (theme !== undefined) localStorage.setItem('aiur-theme', theme)
  }, { palette, theme })
  await page.addInitScript(blocked => {
    if (blocked) Storage.prototype.getItem = () => { throw Error('blocked') }
    requestAnimationFrame(() => {
      window.firstPaletteFrame = { ...document.documentElement.dataset, bg: getComputedStyle(document.documentElement).getPropertyValue('--bg').trim() }
    })
  }, blocked)
  await page.goto('/palette-probe')
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
}

for (const palette of [undefined, 'solarized', '', 'GRUVBOX']) {
  test(`default is gruvbox for ${JSON.stringify(palette)}`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'dark' })
    await openProbe(page, { palette })
    await expect(page.locator('html')).toHaveAttribute('data-palette', 'gruvbox')
    expect(await page.evaluate(() => window.firstPaletteFrame)).toMatchObject({ palette: 'gruvbox', bg: '#18191a' })
  })
}

test('stored aiur restores before first frame, persists and survives patch', async ({ page }) => {
  await openProbe(page, { palette: 'aiur', theme: 'dark' })
  expect(await page.evaluate(() => window.firstPaletteFrame)).toMatchObject({ palette: 'aiur', bg: '#16171a' })
  await page.locator('#ax-cog').click()
  const button = page.locator('#ax-palette')
  await expect(button).toHaveAttribute('aria-checked', 'false')
  await button.click()
  await expect(button).toHaveAttribute('aria-checked', 'true')
  await button.click()
  await page.locator('#ax-drag').click()
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'true')
  await expect(button).toHaveAttribute('aria-checked', 'false')
  await expect(page.locator('#probe-palette-button')).toHaveAttribute('data-probe-patch', 'true')
  await expect(page.locator('#probe-palette-button')).toHaveAttribute('aria-pressed', 'false')
  await expect(page.locator('#probe-palette-item')).toHaveAttribute('aria-checked', 'false')
  expect(await page.evaluate(() => localStorage.getItem('aiur-palette'))).toBe('aiur')
  await page.reload()
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'true')
  await page.locator('#ax-drag').focus()
  await page.keyboard.press('ArrowRight')
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'false')
  await page.locator('#ax-cog').click()
  await expect(button).toHaveAttribute('aria-checked', 'false')
})

for (const theme of [undefined, 'blue', 'dark']) {
  test(`theme follows OS unless stored choice is valid: ${theme}`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'light' })
    await openProbe(page, { theme })
    const expected = theme === 'dark' ? 'dark' : 'light'
    expect(await page.evaluate(() => window.firstPaletteFrame.theme)).toBe(expected)
    await expect(page.locator('html')).toHaveAttribute('data-theme', expected)
  })
}

test('blocked storage still follows OS and toggles, menu role uses aria-checked', async ({ page }) => {
  const errors = []
  page.on('pageerror', e => errors.push(e.message))
  await page.emulateMedia({ colorScheme: 'light' })
  await openProbe(page, { blocked: true })
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light')
  await expect(page.locator('html')).toHaveAttribute('data-palette', 'gruvbox')
  await page.evaluate(() => { Storage.prototype.setItem = () => { throw Error('blocked') } })
  await page.locator('#ax-cog').click()
  await page.locator('#ax-palette').click()
  await expect(page.locator('#ax-palette')).toHaveAttribute('aria-checked', 'false')
  const item = page.locator('#probe-palette-item')
  await item.click()
  await expect(item).toHaveAttribute('aria-checked', 'true')
  expect(await item.getAttribute('aria-pressed')).toBeNull()
  expect(errors).toEqual([])
})

test('390px palette control causes no horizontal scroll', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await openProbe(page)
  await assertNoDocumentOverflow(page)
  await page.locator('#ax-cog').click()
  await expect(page.locator('#ax-palette')).toBeInViewport()
})
