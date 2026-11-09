import type { Page } from '@playwright/test'

export async function seedTheme(page: Page, theme: 'light' | 'dark'): Promise<void> {
  await page.addInitScript((theme) => localStorage.setItem('aiur-theme', theme), theme)
}

export function screenshotMask(page: Page) {
  return [page.locator('#termScreen')]
}

export async function settle(page: Page): Promise<void> {
  await page.evaluate(() => document.fonts.ready)
  await page.evaluate(() => new Promise<void>((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
  }))
}
