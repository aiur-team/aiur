import { test, expect } from '@playwright/test'
import { writeFile } from 'node:fs/promises'
import { PARITY_VIEWPORTS, FIXTURE_META, parityContextOptions, openDesign, productUrl, guardNetwork, compareParityPixels } from '../support/design-parity.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

// C9-T01 makes this a pixel gate after the loading styles and drawing hook land.
for (const viewport of [PARITY_VIEWPORTS[0], PARITY_VIEWPORTS[2]]) {
  for (const theme of ['dark', 'light']) for (const palette of ['gruvbox', 'aiur']) {
    const name = `loading-${viewport.viewport.width}-${theme}-${palette}`
    test(`report: ${name}`, async ({ browser }, testInfo) => {
      const cell = { ...viewport, theme, palette, dataset: 'live' }
      const designContext = await browser.newContext(parityContextOptions(cell))
      const productContext = await browser.newContext({ ...parityContextOptions(cell), baseURL: testInfo.project.use.baseURL, httpCredentials: dashboardCredentials })
      const pair = { design: await designContext.newPage(), product: await productContext.newPage(), cell }
      try {
        await openDesign(pair.design, cell, { phase: 'loading' })
        // Report the actual product, including fonts/styles not shipped by this ticket.
        await guardNetwork(pair.product, [new URL(testInfo.project.use.baseURL).origin])
        await pair.product.clock.setFixedTime(FIXTURE_META.now)
        await pair.product.addInitScript(({ theme, palette }) => {
          localStorage.setItem('aiur-theme', theme)
          localStorage.setItem('aiur-palette', palette)
          localStorage.setItem('aiur-nav-collapsed', '0')
        }, cell)
        await pair.product.bringToFront()
        await pair.product.goto(productUrl('hold'))
        await expect(pair.product.locator('.phx-connected')).toBeVisible()
        await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-state', 'loading')
        const observed = await pair.product.evaluate(() => ({ theme: document.documentElement.dataset.theme, palette: document.documentElement.dataset.palette ?? 'unavailable', now: Date.now() }))
        expect(observed.now).toBe(FIXTURE_META.now)
        let difference = 'matched'
        try { await compareParityPixels(pair, { name, region: '#bd-vp' }) }
        catch (error) {
          if (!/pixels.*different|Expected.*(?:px|width|height)|Screenshot comparison failed|Expected an image/s.test(error.message)) throw error
          difference = error.message
          testInfo.annotations.push({ type: 'pixel-report', description: 'Pending C9-T01 gate; see loading report' })
        }
        await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-state', 'loading')
        await writeFile(testInfo.outputPath('loading-report.txt'), JSON.stringify({ requested: { theme, palette }, observed, difference }, null, 2))
        await testInfo.attach('loading-report', { path: testInfo.outputPath('loading-report.txt'), contentType: 'text/plain' })
        const images = []
        for (const side of ['design', 'product']) {
          const image = await pair[side].locator('#bd-vp').screenshot({ animations: 'disabled' })
          await testInfo.attach(`${side}-loading`, { body: image, contentType: 'image/png' })
          images.push(`<figure><figcaption>${side}</figcaption><img src="data:image/png;base64,${image.toString('base64')}"></figure>`)
        }
        const html = `<div style="display:flex;gap:16px">${images.join('')}</div><style>figure{margin:0;width:50%}img{width:100%}</style>`
        await writeFile(testInfo.outputPath('side-by-side.html'), html)
        const report = await productContext.newPage()
        await report.setViewportSize({ width: 1600, height: 1000 })
        await report.setContent(html)
        await report.screenshot({ path: testInfo.outputPath('side-by-side.png'), fullPage: true })
        await testInfo.attach('side-by-side-image', { path: testInfo.outputPath('side-by-side.png'), contentType: 'image/png' })
        await testInfo.attach('side-by-side', { path: testInfo.outputPath('side-by-side.html'), contentType: 'text/html' })
      } finally { await designContext.close(); await productContext.close() }
    })
  }
}
