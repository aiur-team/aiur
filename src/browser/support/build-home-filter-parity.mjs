import { expect } from '@playwright/test'
import { FIXTURE_META } from './design-parity-environment.mjs'

export async function prepareFilterCapture(pair) {
  await pair.product.evaluate(async now => {
    const { setNow } = await import('/build-home/clock.js'), { fx } = await import('/build-home/state.js')
    setNow(now); fx.renderUsage()
  }, FIXTURE_META.now)
  // Kevin's dec_0744a774b38194aa excludes navigation, including its mobile overlay.
  // Hide only exterior paint; keep every build pixel and its original geometry.
  for (const page of [pair.design, pair.product]) {
    const nav = page.locator('.sidenav')
    await expect(nav).toHaveCount(1)
    expect(await nav.evaluate(el => {
      const build = document.querySelector('#build-root')
      return el.contains(build) || build.contains(el)
    })).toBe(false)
    const selectors = ['#build-root', '#bd-usage', '.bd-toolbar', '#bd-vp']
    const before = await Promise.all(selectors.map(selector => page.locator(selector).boundingBox()))
    expect(before.every(Boolean)).toBe(true)
    // The stylesheet survives LiveView URL patches; exterior clipping also keeps
    // the mobile layout viewport at its declared width (the Gantt harness uses this rule).
    const viewport = page.viewportSize()
    await page.addStyleTag({ content: '.sidenav, .sidenav * { visibility: hidden !important } html, body { overflow-x: clip !important }' })
    expect(await page.evaluate(() => ({ width: innerWidth, height: innerHeight }))).toEqual(viewport)
    // Keep the usage raster's decode cache separate from smaller card logos.
    // The server returns the identical PNG bytes for this query-only cache key.
    await page.locator('#bd-usage img[src*="deepseek-logo.png"]').evaluateAll(images => Promise.all(images.map(async image => {
      const url = new URL(image.currentSrc || image.src)
      url.searchParams.set('parity-surface', 'usage')
      image.src = url.href
      await image.decode()
    })))
    expect(await Promise.all(selectors.map(selector => page.locator(selector).boundingBox()))).toEqual(before)
  }
}

export async function attachFilterRasterDiagnostics(pair, info) {
  const records = {}
  for (const side of ['design', 'product']) records[side] = await pair[side].evaluate(() => {
    const rect = el => {
      const { x, y, width, height } = el.getBoundingClientRect()
      return { x, y, width, height }
    }
    return {
      viewport: { width: innerWidth, height: innerHeight, scale: visualViewport.scale, dpr: devicePixelRatio },
      images: [...document.querySelectorAll('#bd-usage img')].map(el => {
        const parents = []
        for (let node = el; node; node = node.parentElement) {
          const cs = getComputedStyle(node)
          parents.push({ tag: node.tagName, cls: node.className, box: rect(node),
            styles: Object.fromEntries([...cs].filter(key => !key.startsWith('--')).map(key => [key, cs.getPropertyValue(key)])) })
        }
        return { src: el.currentSrc, naturalWidth: el.naturalWidth, naturalHeight: el.naturalHeight, complete: el.complete, parents }
      })
    }
  })
  await info.attach('filter-raster-origins', { body: Buffer.from(JSON.stringify(records, null, 2)), contentType: 'application/json' })
}
