import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'

test('the time brush projects a drag and keeps an in-flight selection across hook lifecycle patches', async ({ browser }) => {
  const context = await browser.newContext()
  const page = await context.newPage()

  try {
    await openFixture(page)

    const result = await page.evaluate(() => {
      const host = document.createElement('div')
      const pushed = []

      const buildChart = () => {
        const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
        const target = document.createElementNS('http://www.w3.org/2000/svg', 'rect')

        svg.setAttribute('data-time-brush', 'true')
        svg.setAttribute('data-time-start', '1000')
        svg.setAttribute('data-time-end', '2000')
        target.setAttribute('data-time-brush', 'true')
        target.setAttribute('x', '10')
        target.setAttribute('y', '5')
        target.setAttribute('width', '100')
        target.setAttribute('height', '30')
        svg.appendChild(target)

        svg.createSVGPoint = () => ({
          x: 0,
          y: 0,
          matrixTransform(matrix) {
            return { x: this.x + matrix.offset }
          }
        })
        svg.getScreenCTM = () => ({ inverse: () => ({ offset: 0 }) })
        return { svg, target }
      }

      const first = buildChart()
      host.appendChild(first.svg)
      document.body.appendChild(host)
      host.setPointerCapture = () => {}

      const hook = {
        el: host,
        pushEvent(name, payload) {
          pushed.push({ name, payload })
        }
      }
      const lifecycle = window.AiurTimeBrushHook.createLiveViewHook()
      lifecycle.mounted.call(hook)

      first.target.dispatchEvent(new PointerEvent('pointerdown', { pointerId: 1, button: 0, clientX: 20, bubbles: true, cancelable: true }))
      host.dispatchEvent(new PointerEvent('pointermove', { pointerId: 1, clientX: 80, bubbles: true }))
      const selectionBeforePatch = first.svg.querySelector('.an-time-brush-selection') !== null

      // Simulate a LiveView patch mid-drag: the chart SVG is replaced wholesale.
      const second = buildChart()
      first.svg.remove()
      host.appendChild(second.svg)
      lifecycle.updated.call(hook)

      const selectionAfterPatch = second.svg.querySelector('.an-time-brush-selection') !== null
      host.dispatchEvent(new PointerEvent('pointerup', { pointerId: 1, clientX: 80, bubbles: true }))
      const selectionAfterRelease = second.svg.querySelector('.an-time-brush-selection') !== null

      // An idle patch (no drag in flight) must still clear stale selections.
      lifecycle.updated.call(hook)

      second.target.dispatchEvent(new PointerEvent('pointerdown', { pointerId: 2, button: 0, clientX: 20, bubbles: true, cancelable: true }))
      host.dispatchEvent(new PointerEvent('pointerup', { pointerId: 2, clientX: 80, bubbles: true }))
      lifecycle.destroyed.call(hook)
      second.target.dispatchEvent(new PointerEvent('pointerdown', { pointerId: 3, button: 0, clientX: 20, bubbles: true, cancelable: true }))
      host.dispatchEvent(new PointerEvent('pointerup', { pointerId: 3, clientX: 80, bubbles: true }))
      host.remove()

      return { pushed, selectionBeforePatch, selectionAfterPatch, selectionAfterRelease }
    })

    expect(result.selectionBeforePatch).toBe(true)
    expect(result.selectionAfterPatch).toBe(true)
    expect(result.selectionAfterRelease).toBe(false)
    expect(result.pushed).toEqual([
      { name: 'time-domain', payload: { t0: 1100, t1: 1700 } },
      { name: 'time-domain', payload: { t0: 1100, t1: 1700 } }
    ])
  } finally {
    await context.close()
  }
})
