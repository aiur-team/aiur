import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { expectSpanAuditClean } from './support/build-home-span-audit.mjs'
import { PARITY_VIEWPORTS, openParityPair } from '../support/design-parity.mjs'
import { assertNoDocumentOverflow, assertControlsRemainReachable } from './support/browser-helpers.mjs'

test.setTimeout(90_000)

async function isolateBoard(pair) {
  await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
  await pair.product.evaluate(async () => {
    const { fx } = await import('/build-home/state.js')
    // Keep real toolbar state and URL writes; board providers such as C9-T09's
    // Gantt layout are outside toolbar parity, as in the functional tools fixture.
    for (const name of ['viewport', 'relayout', 'update', 'jumpNow']) fx[name] = () => {}
  })
}

import { compareRegion } from '../support/build-home-region-parity.mjs'

for (const viewport of PARITY_VIEWPORTS) for (const theme of ['dark', 'light']) for (const palette of ['gruvbox', 'aiur']) {
  const name = `${viewport.viewport.width}-${theme}-${palette}`
  test(`toolbar and status parity ${name}`, async ({ browser }) => {
    const pair = await openParityPair(browser, { ...viewport, theme, palette, dataset: 'live' }, { productPending: true })
    try {
      await isolateBoard(pair)
      expect(await pair.product.locator('#bd-tools-l .bd-seg.vw').count()).toBe(1)
      for (const view of ['graph', 'gantt', 'list']) {
        for (const side of ['design', 'product']) {
          await pair[side].evaluate(() => window.scrollTo(0, 0))
          await pair[side].locator(`[data-v="${view}"]`).click()
          await pair[side].evaluate(() => document.fonts.ready)
        }
        await compareRegion(pair, { name: `tabs-${view}-${name}`, region: '#bd-tools-l' })
        await compareRegion(pair, { name: `status-${view}-${name}`, region: '#bd-status' })
        if (viewport.viewport.width === 1440) expectSpanAuditClean(await new AxeBuilder({ page: pair.product }).include('.bd-toolbar').include('#bd-status').analyze())
      }
      if (viewport.viewport.width <= 1180) {
        const boxes = []
        for (const side of ['design', 'product']) boxes.push(await pair[side].evaluate(() => {
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
    await isolateBoard(pair)
    expect(await pair.product.locator('#bd-tools-l .bd-seg.vw').count()).toBe(1)
    await compareRegion(pair, { name: `tabs-${dataset}`, region: '#bd-tools-l' })
    if (dataset === 'offline') await compareRegion(pair, { name: `status-${dataset}`, region: '#bd-status' })
  } finally { await pair.close() }
})
test('toolbar breakpoint and reduced motion guards preserve existing stylesheet behavior', async ({ browser }) => {
  const pair = await openParityPair(browser, { ...PARITY_VIEWPORTS[0], theme: 'dark', palette: 'aiur', dataset: 'live' }, { productPending: true })
  try {
    await isolateBoard(pair)
    for (const width of [1181, 1180, 721, 720]) {
      await pair.product.setViewportSize({ width, height: 900 })
      const boxes = await pair.product.evaluate(() => ['bd-filters', 'bd-tools-l', 'bd-tools'].map(id => { const r = document.getElementById(id).getBoundingClientRect(); return { top: r.top, bottom: r.bottom, width: r.width } }))
      if (width > 1180) { expect(boxes[0].top).toBeGreaterThanOrEqual(boxes[1].top); expect(boxes[0].top).toBeLessThanOrEqual(boxes[1].bottom) }
      else { expect(boxes[0].top).toBeGreaterThanOrEqual(boxes[1].bottom); expect(boxes[0].width).toBeGreaterThan(boxes[1].width) }
    }
    await expect(pair.product.locator('.bd-live i')).toHaveCSS('animation-name', 'bdPulse')
    await pair.product.emulateMedia({ reducedMotion: 'reduce' })
    await expect(pair.product.locator('.bd-live i')).toHaveCSS('animation-name', 'none')
    expect(parseFloat(await pair.product.locator('.bd-live').evaluate(el => getComputedStyle(el).transitionDuration))).toBeLessThanOrEqual(0.00001)
  } finally { await pair.close() }
})
