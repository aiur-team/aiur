import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { PARITY_VIEWPORTS, openParityPair, expectDesignParity } from '../support/design-parity.mjs'
import { assertNoDocumentOverflow, assertControlsRemainReachable, expectAuditClean } from './support/browser-helpers.mjs'

for (const viewport of PARITY_VIEWPORTS) for (const theme of ['dark', 'light']) for (const palette of ['gruvbox', 'aiur']) {
  const name = `${viewport.viewport.width}-${theme}-${palette}`
  test(`toolbar and status parity ${name}`, async ({ browser }) => {
    const pair = await openParityPair(browser, { ...viewport, theme, palette, dataset: 'live' }, { productPending: true })
    try {
      await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
      for (const view of ['graph', 'gantt', 'list']) {
        for (const side of ['design', 'product']) {
          await pair[side].locator(`[data-v="${view}"]`).click()
          await pair[side].evaluate(() => document.fonts.ready)
        }
        // Align raster origins; sibling filters/span controls are not populated yet.
        for (const side of ['design', 'product']) await pair[side].evaluate(() => {
          for (const id of ['bd-tools-l', 'bd-status']) {
            const el = document.getElementById(id); el.style.transform = ''; const r = el.getBoundingClientRect()
            el.style.transform = `translate(${Math.round(r.x) - r.x}px, ${Math.round(r.y) - r.y}px)`
          }
        })
        await expectDesignParity(pair, { name: `tabs-${view}-${name}`, region: '#bd-tools-l' })
        await expectDesignParity(pair, { name: `status-${view}-${name}`, region: '#bd-status' })
        if (viewport.viewport.width === 1440) expectAuditClean(await new AxeBuilder({ page: pair.product }).include('.bd-toolbar').include('#bd-status').analyze())
      }
      if (viewport.viewport.width <= 1180) {
        const boxes = []
        for (const side of ['design', 'product']) boxes.push(await pair[side].evaluate(() => {
          document.querySelector('#bd-tools-l').style.transform = ''
          const l = document.querySelector('#bd-tools-l').getBoundingClientRect(), r = document.querySelector('#bd-tools').getBoundingClientRect(), toolbar = document.querySelector('.bd-toolbar').getBoundingClientRect()
          return [l.x, l.y - toolbar.y, l.width, l.height, r.right]
        }))
        expect(boxes[1]).toEqual(boxes[0])
      }
      if (viewport.hasTouch) {
        await pair.product.tap('[data-v="gantt"]')
        await expect(pair.product.locator('[data-v="gantt"]')).toHaveAttribute('aria-selected', 'true')
        await assertNoDocumentOverflow(pair.product)
        await assertControlsRemainReachable(pair.product)
      }
      await pair.product.screenshot({ path: test.info().outputPath(`toolbar-${name}.png`), animations: 'disabled' })
    } finally { await pair.close() }
  })
}
for (const dataset of ['offline', 'noqueue']) test(`toolbar status dataset ${dataset}`, async ({ browser }) => {
  const pair = await openParityPair(browser, { ...PARITY_VIEWPORTS[0], theme: 'dark', palette: 'aiur', dataset }, { productPending: true })
  try {
    await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
    await expectDesignParity(pair, { name: `tabs-${dataset}`, region: '#bd-tools-l' })
    if (dataset === 'offline') await expectDesignParity(pair, { name: `status-${dataset}`, region: '#bd-status' })
  } finally { await pair.close() }
})
test('toolbar breakpoint and reduced motion guards preserve existing stylesheet behavior', async ({ browser }) => {
  const pair = await openParityPair(browser, { ...PARITY_VIEWPORTS[0], theme: 'dark', palette: 'aiur', dataset: 'live' }, { productPending: true })
  try {
    for (const width of [1181, 1180, 721, 720]) {
      await pair.product.setViewportSize({ width, height: 900 })
      const boxes = await pair.product.evaluate(() => ['bd-filters', 'bd-tools-l', 'bd-tools'].map(id => { const r = document.getElementById(id).getBoundingClientRect(); return { top: r.top, bottom: r.bottom, width: r.width } }))
      if (width > 1180) { expect(boxes[0].top).toBeGreaterThanOrEqual(boxes[1].top); expect(boxes[0].top).toBeLessThanOrEqual(boxes[1].bottom) }
      else { expect(boxes[0].top).toBeGreaterThanOrEqual(boxes[1].bottom); expect(boxes[0].width).toBeGreaterThan(boxes[1].width) }
    }
    await expect(pair.product.locator('.bd-live i')).toHaveCSS('animation-name', 'bdPulse')
    await pair.product.emulateMedia({ reducedMotion: 'reduce' })
    await expect(pair.product.locator('.bd-live i')).toHaveCSS('animation-name', 'none')
    await expect(pair.product.locator('.bd-live')).toHaveCSS('transition-duration', '0s')
  } finally { await pair.close() }
})
