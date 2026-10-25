import { expect } from '@playwright/test'
import { applyAllowlist, expectDesignParity } from './design-parity.mjs'

// Capture each region at a stable integer origin, independent of full-page viewport resizing.
export async function compareRegion(pair, options) {
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
    const canvas = document.createElement('div'); canvas.dataset.parityCanvas = ''
    Object.assign(canvas.style, { position: 'fixed', left: Math.round(box.x) + 'px', top: '100px',
      width: box.width + 'px', height: box.height + 'px', background: 'var(--bg)', zIndex: '9998' })
    document.body.appendChild(canvas)
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
      document.querySelector('[data-parity-canvas]')?.remove()
    }, styles[index])
    for (const [index, side] of ['design', 'product'].entries()) await pair[side].locator(options.region + ' svg').evaluateAll((nodes, values) => nodes.forEach((el, i) => {
      if (values[i] === null) el.removeAttribute('style'); else el.setAttribute('style', values[i])
    }), icons[index])
    for (const [index, side] of ['design', 'product'].entries()) await pair[side].evaluate(background => { document.body.style.background = background }, backgrounds[index])
    for (const [index, side] of ['design', 'product'].entries()) await pair[side].locator('.sidenav, .ax-top').evaluateAll((nodes, values) => nodes.forEach((el, i) => { el.style.visibility = values[i] }), chrome[index])
  }
}
