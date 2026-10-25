import { expect } from '@playwright/test'
import { contrastRatio } from './build-home-a11y-audit.mjs'

// Measure the existing DOM glyphs, including their opacity/filter and both
// ends of progress washes, stripes and the grid. Never substitute a token for a missing colour.
export async function measureGlyphContrast(page, selectors) {
  const measurements = await page.evaluate(selectors => {
    const canvas = document.createElement('canvas')
    canvas.width = canvas.height = 1
    const context = canvas.getContext('2d', { willReadFrequently: true })
    const pixel = () => [...context.getImageData(0, 0, 1, 1).data]
    const hex = rgb => '#' + rgb.slice(0, 3).map(n => n.toString(16).padStart(2, '0')).join('')
    return selectors.map(selector => {
      const glyph = document.querySelector(selector)
      if (!glyph?.matches('.bd-cx')) throw new Error('Expected a rendered complexity glyph: ' + selector)
      const style = getComputedStyle(glyph)
      let host = glyph
      const layers = []
      while (host) {
        const paint = getComputedStyle(host)
        let stops = [null]
        if (paint.backgroundImage !== 'none') {
          if (!/^(repeating-)?(linear|radial)-gradient\(/.test(paint.backgroundImage)) throw new Error('Unsupported glyph background: ' + paint.backgroundImage)
          stops.push(...paint.backgroundImage.match(/(?:rgba?|oklch|oklab|lab|lch|color)\([^)]*\)|transparent/g))
        }
        layers.unshift({ color: paint.backgroundColor, stops })
        context.reset()
        context.fillStyle = paint.backgroundColor
        context.fillRect(0, 0, 1, 1)
        if (pixel()[3] === 255) break
        host = host.parentElement
      }
      if (!host) throw new Error('No opaque background for glyph ' + selector)
      let backgrounds = ['#000000']
      for (const layer of layers) {
        backgrounds = [...new Set(backgrounds.flatMap(background => layer.stops.map(stop => {
          context.reset()
          context.fillStyle = background; context.fillRect(0, 0, 1, 1)
          context.fillStyle = layer.color; context.fillRect(0, 0, 1, 1)
          if (stop) { context.fillStyle = stop; context.fillRect(0, 0, 1, 1) }
          return hex(pixel())
        }))) ]
      }
      const pairs = backgrounds.map(background => {
        context.reset()
        context.fillStyle = background
        context.fillRect(0, 0, 1, 1)
        const bg = hex(pixel())
        context.filter = style.filter
        context.globalAlpha = Number(style.opacity)
        context.fillStyle = style.color
        context.fillRect(0, 0, 1, 1)
        return { foreground: hex(pixel()), background: bg }
      })
      const size = parseFloat(style.fontSize), bold = Number(style.fontWeight) >= 700
      return { selector, text: glyph.textContent, size, weight: style.fontWeight,
        minimum: size >= 24 || (bold && size >= 18.6667) ? 3 : 4.5, pairs }
    })
  }, selectors)
  return measurements.map(measurement => ({
    ...measurement,
    ratio: Math.min(...measurement.pairs.map(pair => contrastRatio(pair.foreground, pair.background)))
  }))
}

export function expectGlyphContrast(measurements) {
  for (const measurement of measurements) {
    expect(measurement.ratio, JSON.stringify(measurement)).toBeGreaterThanOrEqual(measurement.minimum)
  }
}
