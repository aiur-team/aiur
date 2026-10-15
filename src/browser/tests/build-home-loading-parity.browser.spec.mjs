import { test, expect } from '@playwright/test'
import { PARITY_VIEWPORTS, openParityPair, expectDesignParity } from '../support/design-parity.mjs'

for (const viewport of PARITY_VIEWPORTS) {
  for (const theme of ['dark', 'light']) for (const palette of ['gruvbox', 'aiur']) {
    const name = `loading-${viewport.viewport.width}-${theme}-${palette}`
    test(`gate: ${name}`, async ({ browser }) => {
      const cell = { ...viewport, theme, palette, dataset: 'live' }
      const pair = await openParityPair(browser, cell, { phase: 'loading' })
      try {
        await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-state', 'loading')
        // Keep the real, connected loading frame after the bounded server read expires.
        await pair.product.evaluate(() => window.liveSocket.disconnect())
        for (const side of ['design', 'product']) {
          await pair[side].evaluate(() => document.fonts.ready)
          // Stop CSS motion before layout/capture, rather than cancelling and resuming
          // animations around each screenshot (which retains timing-dependent paint).
          await pair[side].addStyleTag({ content: `
            .bd-vpw, .bd-vpw *, .bd-vpw::before, .bd-vpw::after,
            .bd-vpw *::before, .bd-vpw *::after {
              animation: none !important; transition: none !important;
            }
          ` })
        }
        // Isolate the measured host from unrelated sticky chrome and align its raster origin.
        // Preserve the real host width, viewport height, contents and production styles.
        for (const side of ['design', 'product']) {
          await pair[side].locator('.bd-vpw').evaluate(el => {
            const width = el.getBoundingClientRect().width
            Object.assign(el.style, { position: 'fixed', top: '0', left: '0', zIndex: '2147483647', width: width + 'px' })
          })
        }
        for (const side of ['design', 'product']) await expect(pair[side].locator('#bd-sb')).toHaveClass(/\boff\b/)
        // Flush layout and paint after freezing styles and aligning the raster origin.
        for (const side of ['design', 'product']) {
          const frames = pair[side].evaluate(() => new Promise(resolve =>
            requestAnimationFrame(() => requestAnimationFrame(resolve))))
          if (side === 'design') await pair[side].clock.runFor(40)
          await frames
        }
        // Both sides use stable captures of the already-frozen state.
        await expectDesignParity(pair, { name: `c9t01-sb-off-${name}`, region: '.bd-vpw', preserveAnimations: true })
        await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-state', 'loading')
      } finally { await pair.close() }
    })
    for (const dataset of ['live', 'dense']) for (const state of ['top', 'act', 'hover', 'drag']) {
      test(`c9t01-sb-${state}-${dataset}-${name}`, () => {
        test.fixme(true, 'awaiting MP-E8-C9-T03: board content determines scrollbar geometry')
      })
    }
  }
}
