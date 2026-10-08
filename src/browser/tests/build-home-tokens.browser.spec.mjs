import { test, expect } from '@playwright/test'
import { openDesign, parityContextOptions, applyAllowlist, loadAllowlist, expectDesignParity, FIXTURE_META } from '../support/design-parity.mjs'
import { openVisualRoute } from '../support/visual.mjs'

for (const theme of ['dark', 'light']) for (const palette of ['aiur', 'gruvbox']) {
  test(`tokens, wash and faces match design: ${theme}/${palette}`, async ({ browser }) => {
    const cell = { theme, palette, dataset: 'live', viewport: { width: 1440, height: 900 } }
    const designContext = await browser.newContext(parityContextOptions(cell))
    const productContext = await browser.newContext({ ...parityContextOptions(cell), baseURL: test.info().project.use.baseURL })
    const pair = { design: await designContext.newPage(), product: await productContext.newPage(), cell }
    const resources = []
    pair.product.on('request', request => { if (/\.woff2/.test(request.url())) resources.push(request.url()) })
    try {
      await openDesign(pair.design, cell, { phase: 'shell' })
      await pair.product.clock.setFixedTime(FIXTURE_META.now)
      await openVisualRoute(pair.product, { theme, palette, route: '/palette-probe' })
      pair.allowlist = await loadAllowlist()
      await applyAllowlist(pair, cell)
      const names = await pair.design.evaluate(() => [...new Set([...document.styleSheets].filter(sheet => !sheet.href || new URL(sheet.href).origin === location.origin).flatMap(sheet => [...sheet.cssRules].filter(rule => /^(?:\:root|html(?:\[data-(?:theme|palette)="[^"]+"\])*)$/.test(rule.selectorText ?? '')).flatMap(rule => [...rule.style].filter(name => name.startsWith('--') && name !== '--navw'))))])
      const resolve = names => {
        const probe = document.createElement('span')
        document.body.append(probe)
        const values = Object.fromEntries(names.map(name => {
          const property = name.startsWith('--shadow') ? 'boxShadow' : name.startsWith('--radius') ? 'borderRadius' : 'color'
          probe.style[property] = `var(${name})`
          return [name, getComputedStyle(probe)[property]]
        }))
        probe.remove()
        return values
      }
      expect(await pair.product.evaluate(resolve, names)).toEqual(await pair.design.evaluate(resolve, names))
      const bodyStyle = () => {
        const style = getComputedStyle(document.body)
        return Object.fromEntries(['backgroundImage', 'backgroundColor', 'backgroundAttachment', 'fontFamily', 'lineHeight', 'transition'].map(key => [key, style[key]]))
      }
      expect(await pair.product.evaluate(bodyStyle)).toEqual(await pair.design.evaluate(bodyStyle))
      const faces = () => {
        const span = document.createElement('span')
        span.textContent = 'Aiur token glyph width 0123456789 中文'
        span.style.display = 'inline-block'
        document.body.append(span)
        const result = {}
        for (const family of ['Space Grotesk', 'JetBrains Mono']) {
          result[family] = [400, 500, 550, 600, 650, 700].map(weight => {
            span.style.font = `${weight} 40px "${family}", system-ui, -apple-system, "Segoe UI", sans-serif`
            return span.getBoundingClientRect().width
          })
        }
        span.remove()
        return result
      }
      for (const page of [pair.design, pair.product]) {
        await page.evaluate(async () => {
          for (const family of ['Space Grotesk', 'JetBrains Mono']) for (const weight of [400, 500, 550, 600, 650, 700]) {
            await document.fonts.load(`${weight} 40px "${family}"`)
            if (!document.fonts.check(`${weight} 40px "${family}"`)) throw Error(`missing font ${family}/${weight}`)
          }
        })
      }
      const productFaces = await pair.product.evaluate(faces)
      expect(productFaces).toEqual(await pair.design.evaluate(faces))
      for (const widths of Object.values(productFaces)) {
        expect(widths[2]).toBe(widths[3])
        expect(widths[4]).toBe(widths[5])
      }
      expect(await pair.product.evaluate(() => ['Space Grotesk', 'JetBrains Mono'].every(family => [...document.fonts].some(face => face.family.replace(/["']/g, '') === family && face.status === 'loaded')))).toBe(true)
      expect(resources.some(name => name.includes('space-grotesk'))).toBe(true)
      expect(resources.every(name => new URL(name).origin === new URL(test.info().project.use.baseURL).origin)).toBe(true)
      // C2-T02 owns the design's reserved scrollbar gutter; compare this ticket's wash at equal widths.
      for (const page of [pair.design, pair.product]) await page.addStyleTag({ content: 'html { scrollbar-gutter: auto !important; } body > * { display: none !important; } body { transition: none !important; }' })
      await expectDesignParity(pair, { name: `body-${theme}-${palette}` })
      for (const page of [pair.design, pair.product]) {
        await page.evaluate(() => {
          const specimen = document.createElement('div')
          specimen.id = 'bungee-specimen'
          specimen.style.cssText = 'display:inline-block!important;font:400 40px Bungee;position:fixed;top:0;left:0'
          specimen.textContent = 'aiur'
          document.body.append(specimen)
        })
      }
      await expectDesignParity(pair, { name: `bungee-${theme}-${palette}`, region: '#bungee-specimen' })
    } finally { await designContext.close(); await productContext.close() }
  })
}
