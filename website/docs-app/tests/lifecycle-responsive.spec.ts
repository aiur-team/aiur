import { expect, test } from '@playwright/test'

const viewports = [
  { width: 320, height: 568 },
  { width: 390, height: 844 },
  { width: 844, height: 390 },
  { width: 768, height: 1024 },
  { width: 1280, height: 800 },
  { width: 1440, height: 900 },
  { width: 1920, height: 1080 },
  { width: 3440, height: 1440 }
]

for (const viewport of viewports) {
  for (const theme of ['light', 'dark'] as const) {
    test(`lifecycle timeline at ${viewport.width}x${viewport.height} in ${theme} mode`, async ({ page }) => {
      await page.setViewportSize(viewport)
      await page.emulateMedia({ reducedMotion: 'reduce' })
      await page.goto('concepts/lifecycle')
      await page.evaluate((dark) => document.documentElement.classList.toggle('dark', dark), theme === 'dark')
      await expect(page.getByRole('figure', { name: 'Ticket lifecycle timeline' })).toBeVisible()
      await expect(page.locator('.event-card:visible').first()).toBeVisible()

      const horizontal = await page.locator('.horizontal-layout').isVisible()
      const layout = await page.evaluate(() => {
        const figure = document.querySelector<HTMLElement>('figure.lifecycle')!
        const doc = document.querySelector<HTMLElement>('.vp-doc')!
        const labels = [...document.querySelectorAll<HTMLElement>(
          '.event-card, .phase span, .progress-marker, .desktop-marker, .lane-name'
        )].filter((element) => element.getClientRects().length)
        const boxes = labels.map((element) => {
          const rect = element.getBoundingClientRect()
          return { x: rect.x, y: rect.y, right: rect.right, bottom: rect.bottom, label: `${element.className}:${element.textContent?.trim()}` }
        })
        const overlaps: string[] = []
        for (let i = 0; i < boxes.length; i++) {
          for (let j = i + 1; j < boxes.length; j++) {
            const a = boxes[i]!
            const b = boxes[j]!
            if (Math.min(a.right, b.right) - Math.max(a.x, b.x) > 1 && Math.min(a.bottom, b.bottom) - Math.max(a.y, b.y) > 1) {
              overlaps.push(`${a.label}@${a.x},${a.y}:${b.label}@${b.x},${b.y}`)
            }
          }
        }
        const phaseBar = document.querySelector<HTMLElement>('.phase-rail')
        const progressBar = document.querySelector<HTMLElement>('.progress-rail')
        const topActor = document.querySelector<HTMLElement>('.lane-executor')
        const bottomActor = document.querySelector<HTMLElement>('.lane-agent')
        const markers = [...document.querySelectorAll<HTMLElement>('.desktop-marker')]
        const markersConnected = markers.every((marker) =>
          marker.previousElementSibling?.classList.contains('connector') ||
          marker.previousElementSibling?.classList.contains('connector-offset')
        )
        return {
          pageWidth: document.documentElement.scrollWidth,
          viewportWidth: innerWidth,
          figureLeft: figure.getBoundingClientRect().left,
          figureRight: figure.getBoundingClientRect().right,
          docLeft: doc.getBoundingClientRect().left,
          docRight: doc.getBoundingClientRect().right,
          overlaps,
          topAboveBar: !phaseBar || !topActor || topActor.getBoundingClientRect().bottom < phaseBar.getBoundingClientRect().top,
          bottomBelowBar: !progressBar || !bottomActor || bottomActor.getBoundingClientRect().top > progressBar.getBoundingClientRect().bottom,
          markerCount: markers.length,
          connectorCount: document.querySelectorAll('.desktop-overview > .connector').length,
          markersConnected
        }
      })

      expect(layout.pageWidth, `${viewport.width}x${viewport.height} page overflow`).toBeLessThanOrEqual(layout.viewportWidth)
      expect(layout.figureLeft, 'timeline stays inside the doc column').toBeGreaterThanOrEqual(layout.docLeft - 1)
      expect(layout.figureRight, 'timeline stays inside the doc column').toBeLessThanOrEqual(layout.docRight + 1)
      expect(layout.overlaps, `${viewport.width}x${viewport.height} overlapping labels or markers`).toEqual([])
      expect(horizontal, `${viewport.width}x${viewport.height} layout`).toBe(layout.figureRight - layout.figureLeft >= 640)
      if (horizontal) {
        expect(layout.topAboveBar).toBe(true)
        expect(layout.bottomBelowBar).toBe(true)
        expect(layout.markerCount).toBeGreaterThan(0)
        expect(layout.connectorCount).toBe(layout.markerCount)
        expect(layout.markersConnected).toBe(true)
      }
      await expect(page.locator('.rail-labels .time-label')).toHaveCount(0)
      const focused = page.locator('.event-card:visible').first()
      await focused.focus()
      await expect(focused).toBeFocused()
    })
  }
}

test('matching lifecycle emits and consumes share a timeline point', async ({ page }) => {
  await page.goto('concepts/lifecycle')
  const pairedMoments = await page.locator('.vertical-layout .timeline-point').evaluateAll((points) =>
    points.some((point) => {
      const matching = [...point.querySelectorAll<HTMLElement>('.event-card[data-topic]')]
      return matching.some((item) => item.dataset.kind === 'emit' && matching.some((other) => other.dataset.kind === 'consume' && other.dataset.topic === item.dataset.topic))
    })
  )
  expect(pairedMoments).toBe(true)
})
