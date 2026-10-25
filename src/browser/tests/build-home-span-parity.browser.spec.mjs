import { test, expect } from '@playwright/test'
import { PARITY_VIEWPORTS, openParityPair } from '../support/design-parity.mjs'
import { compareRegion } from '../support/build-home-region-parity.mjs'
import { runOn, compareRecords } from '../support/build-home-motion.mjs'

test.setTimeout(120_000)
const cells = [
  { ...PARITY_VIEWPORTS[0], theme: 'dark', palette: 'gruvbox' },
  { ...PARITY_VIEWPORTS[1], theme: 'light', palette: 'aiur' },
  { ...PARITY_VIEWPORTS[2], theme: 'dark', palette: 'gruvbox' },
]
for (const cell of cells) for (const span of [1, 2, 7, 30]) test(`range and zoom parity ${cell.viewport.width} span ${span}`, async ({ browser }) => {
  const pair = await openParityPair(browser, { ...cell, dataset: 'live' }, { query: `span=${span}` })
  try {
    // Fixture HTTP nesting drops queries; a server patch consumes the canonical URL.
    await pair.product.evaluate(span => window.liveSocket.main.pushLinkPatch(new Event('click'), `/build?span=${span}`, null), span)
    await expect(pair.product.locator('.bd-zv')).toHaveText(`${Math.round(100 / span)}%`)
    for (const region of ['.bd-cal', '.bd-zoom']) await compareRegion(pair, { name: `${region.slice(1)}-${span}-${cell.viewport.width}`, region })
    for (const side of ['design', 'product']) {
      const sizes = await pair[side].locator('[data-span], [data-z]').evaluateAll(nodes => nodes.map(el => { const r = el.getBoundingClientRect(); return [r.width, r.height] }))
      for (const [w, h] of sizes) { expect(w).toBeGreaterThanOrEqual(30); expect(h).toBeGreaterThanOrEqual(28) }
    }
  } finally { await pair.close() }
})
for (const theme of ['dark', 'light']) test(`dot grid style parity ${theme}`, async ({ browser }) => {
  const pair = await openParityPair(browser, { ...cells[0], theme, dataset: 'live' })
  try {
    for (const span of [1, 2, 3, 30]) {
      await pair.product.evaluate(async span => (await import('/build-home/span.js')).setSpan(span), span)
      // Native controls keep the design's real relayout and grid transition.
      await pair.design.locator('[data-span="1"]').evaluate(el => el.click())
      if (span === 30) await pair.design.locator('[data-span="30"]').evaluate(el => el.click())
      else for (let i = 1; i < span; i++) await pair.design.locator('[data-z="1"]').evaluate(el => el.click())
      const styles = []
      for (const side of ['design', 'product']) styles.push(await pair[side].locator('#bd-vp').evaluate(el => {
        el.getAnimations().forEach(a => a.finish())
        const s = getComputedStyle(el)
        return [s.backgroundSize, s.backgroundImage, s.transition]
      }))
      expect(styles[1]).toEqual(styles[0])
    }
  } finally { await pair.close() }
})
test('view.span product sequence reaches both zoom ends', async ({ browser }) => {
  const pair = await openParityPair(browser, { ...cells[0], dataset: 'live' }, { motion: true })
  try {
    const design = await runOn(pair.design, 'view.span'), product = await runOn(pair.product, 'view.span')
    expect(compareRecords(design, product)).toEqual([])
    expect(product.samples.some(sample => sample.span === '30' && sample.disabled)).toBe(true)
    expect(product.samples.at(-1)).toMatchObject({ span: '1', disabled: true })
  } finally { await pair.close() }
})
