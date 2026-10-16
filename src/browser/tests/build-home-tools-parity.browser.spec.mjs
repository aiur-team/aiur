import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { PARITY_VIEWPORTS, openParityPair, expectDesignParity, applyAllowlist } from '../support/design-parity.mjs'
import { assertNoDocumentOverflow, assertControlsRemainReachable, expectAuditClean } from './support/browser-helpers.mjs'

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

// Capture each region at a stable integer origin, independent of full-page viewport resizing.
async function compareRegion(pair, options) {
  await applyAllowlist(pair, pair.cell)
  // View changes recreate the select; the shared allowlist records its first removal only.
  const demo = pair.allowlist.find(entry => entry.id === 'demo-data-select')
  await pair.design.locator(demo.selector).evaluateAll(nodes => nodes.forEach(node => node.remove()))
  const styles = [], chrome = [], backgrounds = [], icons = [], geometry = []
  for (const side of ['design', 'product']) {
    geometry.push(await pair[side].locator(options.region).evaluate(el => {
      const host = el.getBoundingClientRect()
      return [...el.querySelectorAll('svg')].map(svg => { const b = svg.getBoundingClientRect(); return [b.x - host.x, b.y - host.y, b.width, b.height] })
    }))
    await pair[side].evaluate(() => {
      window.scrollTo(0, 0)
      document.getAnimations().forEach(animation => Number.isFinite(animation.effect?.getComputedTiming().endTime) ? animation.finish() : animation.cancel())
    })
    // Sibling header/usage content changes the region's Y and the inherited body gradient.
    // Compare transparent corners against the same canvas without altering the controls.
    backgrounds.push(await pair[side].evaluate(() => {
      const original = document.body.style.background; document.body.style.background = 'var(--bg)'; return original
    }))
    // Fixed shell navigation is outside this ticket and can cover a full-page clip on phones.
    chrome.push(await pair[side].locator('.sidenav, .ax-top').evaluateAll(nodes => nodes.map(el => {
      const visibility = el.style.visibility; el.style.visibility = 'hidden'; return visibility
    })))
    styles.push(await pair[side].locator(options.region).evaluate(el => {
    const original = el.getAttribute('style'), box = el.getBoundingClientRect()
    Object.assign(el.style, { position: 'fixed', left: Math.round(box.x) + 'px', top: '100px',
      width: box.width + 'px', boxSizing: 'border-box', margin: '0', zIndex: '9999',
      background: 'var(--bg)', transform: 'translateZ(0)' })
    return original
    }))
    icons.push(await pair[side].locator(options.region + ' svg').evaluateAll(nodes => nodes.map(el => {
      const original = el.getAttribute('style'), box = el.getBoundingClientRect()
      // Keep equal vector geometry while avoiding device-pixel raster origins between pixels.
      el.style.transform = `translate(${Math.round(box.x) - box.x}px, ${Math.round(box.y) - box.y}px)`
      return original
    })))
    await pair[side].evaluate(async () => {
      document.getAnimations().forEach(animation => Number.isFinite(animation.effect?.getComputedTiming().endTime) ? animation.finish() : animation.cancel())
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
    })
  }
  try { expect(geometry[1]).toEqual(geometry[0]); await expectDesignParity(pair, { ...options, preserveAnimations: true }) }
  finally {
    for (const [index, side] of ['design', 'product'].entries()) await pair[side].locator(options.region).evaluate((el, style) => {
      if (style === null) el.removeAttribute('style'); else el.setAttribute('style', style)
    }, styles[index])
    for (const [index, side] of ['design', 'product'].entries()) await pair[side].locator(options.region + ' svg').evaluateAll((nodes, values) => nodes.forEach((el, i) => {
      if (values[i] === null) el.removeAttribute('style'); else el.setAttribute('style', values[i])
    }), icons[index])
    for (const [index, side] of ['design', 'product'].entries()) await pair[side].evaluate(background => { document.body.style.background = background }, backgrounds[index])
    for (const [index, side] of ['design', 'product'].entries()) await pair[side].locator('.sidenav, .ax-top').evaluateAll((nodes, values) => nodes.forEach((el, i) => { el.style.visibility = values[i] }), chrome[index])
  }
}

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
        if (viewport.viewport.width === 1440) expectAuditClean(await new AxeBuilder({ page: pair.product }).include('.bd-toolbar').include('#bd-status').analyze())
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
