import { test, expect } from '@playwright/test'
import { openVisualRoute } from '../support/visual.mjs'

// Design token and face pixel comparisons were removed with the design-parity suite (#6061).
for (const theme of ['dark', 'light']) for (const palette of ['aiur', 'gruvbox']) {
  test(`fonts load once from aiur-style: ${theme}/${palette}`, async ({ page, baseURL }) => {
    const resources = []
    page.on('request', request => { if (/\.woff2/.test(request.url())) resources.push(request.url()) })
    await openVisualRoute(page, { theme, palette, route: '/palette-probe' })
    await page.evaluate(async () => {
      for (const family of ['Space Grotesk', 'JetBrains Mono']) for (const weight of [400, 500, 550, 600, 650, 700]) {
        await document.fonts.load(`${weight} 40px "${family}"`)
        if (!document.fonts.check(`${weight} 40px "${family}"`)) throw Error(`missing font ${family}/${weight}`)
      }
    })
    // Each family loads once: one face (variable where aiur-style ships one) and one file.
    expect(await page.evaluate(() => [...document.fonts].map(face => `${face.family.replace(/["']/g, '')}:${face.weight}:${face.status}`).sort())).toEqual(['Bungee:400:loaded', 'JetBrains Mono:100 800:loaded', 'Space Grotesk:300 700:loaded'])
    expect([...new Set(resources.map(name => new URL(name).pathname))].sort()).toEqual(['/aiur-style/fonts/Bungee-Regular.woff2', '/aiur-style/fonts/JetBrainsMono-Variable.woff2', '/aiur-style/fonts/SpaceGrotesk-Variable.woff2'])
    expect(resources.every(name => new URL(name).origin === new URL(baseURL).origin)).toBe(true)
  })
}
