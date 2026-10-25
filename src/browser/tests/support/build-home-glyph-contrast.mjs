import { expect } from '@playwright/test'
import { contrastRatio } from './build-home-a11y-audit.mjs'

// Measure the existing DOM glyphs, including their opacity/filter and both
// ends of the card's progress wash. Never substitute a token for a missing colour.
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
      let host = glyph, background
      const washes = []
      while (host) {
        const paint = getComputedStyle(host)
        if (paint.backgroundImage !== 'none') {
          if (!paint.backgroundImage.startsWith('linear-gradient(')) throw new Error('Unsupported glyph background: ' + paint.backgroundImage)
          washes.unshift(...paint.backgroundImage.match(/(?:rgba?|oklch|oklab|lab|lch|color)\([^)]*\)|transparent/g))
        }
        context.reset()
        context.fillStyle = paint.backgroundColor
        context.fillRect(0, 0, 1, 1)
        if (pixel()[3] === 255) { background = paint.backgroundColor; break }
        host = host.parentElement
      }
      if (!background) throw new Error('No opaque background for glyph ' + selector)
      const backgrounds = [null, ...washes]
      const pairs = backgrounds.map(wash => {
        context.reset()
        context.fillStyle = background
        context.fillRect(0, 0, 1, 1)
        if (wash) { context.fillStyle = wash; context.fillRect(0, 0, 1, 1) }
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
