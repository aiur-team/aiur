import type { Page } from '@playwright/test'
import { fileURLToPath } from 'node:url'

export async function seedTheme(page: Page, theme: 'light' | 'dark'): Promise<void> {
  await page.addInitScript((theme) => localStorage.setItem('aiur-theme', theme), theme)
}

const families = [
  ['Bungee', 'Bungee-Regular.woff2', '400'],
  ['Space Grotesk', 'SpaceGrotesk-Variable.woff2', '300 700'],
  ['JetBrains Mono', 'JetBrainsMono-Variable.woff2', '100 800']
] as const

export async function routeFonts(page: Page): Promise<void> {
  await page.route('https://fonts.googleapis.com/**', (route) => route.fulfill({
    contentType: 'text/css',
    body: families.map(([family, file, weight]) =>
      `@font-face { font-family: '${family}'; font-style: normal; font-weight: ${weight}; font-display: block; src: url('https://fonts.gstatic.com/visual/${file}') format('woff2'); }`
    ).join('\n')
  }))
  await page.route('https://fonts.gstatic.com/**', async (route) => {
    const file = new URL(route.request().url()).pathname.split('/').pop()
    if (!families.some(([, name]) => name === file)) throw new Error(`Unexpected font: ${file}`)
    await route.fulfill({
      contentType: 'font/woff2',
      path: fileURLToPath(new URL(`../fixtures/fonts/${file}`, import.meta.url))
    })
  })
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
