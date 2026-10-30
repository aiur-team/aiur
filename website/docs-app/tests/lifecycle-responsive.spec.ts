import { expect, test } from '@playwright/test'

const viewports = [
  { width: 320, height: 568 },
  { width: 390, height: 844 },
  { width: 844, height: 390 },
  { width: 768, height: 1024 },
  { width: 1280, height: 800 },
  { width: 1920, height: 1080 },
  { width: 3440, height: 1440 }
]

test('lifecycle timeline fits every viewport and theme', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.goto('concepts/lifecycle')
  await expect(page.getByRole('figure', { name: 'Ticket lifecycle timeline' })).toBeVisible()

  for (const viewport of viewports) {
    await page.setViewportSize(viewport)
    for (const theme of ['light', 'dark'] as const) {
      await page.evaluate((dark) => document.documentElement.classList.toggle('dark', dark), theme === 'dark')
      await expect(page.locator('.event-card:visible').first()).toBeVisible()
      const horizontal = await page.locator('.horizontal-layout').isVisible()
      const chartWidth = await page.locator('figure.lifecycle').evaluate((element) => element.clientWidth)
      expect(horizontal, `${viewport.width}x${viewport.height} horizontal layout`).toBe(chartWidth >= 720)
      await expect(page.locator('.vertical-layout')).toBeVisible()

      const layout = await page.evaluate(() => {
        const visible = [...document.querySelectorAll<HTMLElement>('.event-card')].filter((el) => el.getClientRects().length)
        const labels = [...document.querySelectorAll<HTMLElement>('.event-card, .phase span, .progress-marker')].filter((el) => el.getClientRects().length)
        const boxes = labels.map((el) => {
          const rect = el.getBoundingClientRect()
          return { x: rect.x, y: rect.y, right: rect.right, bottom: rect.bottom }
        })
        const overlaps: string[] = []
        for (let i = 0; i < boxes.length; i++) {
          for (let j = i + 1; j < boxes.length; j++) {
            const a = boxes[i]!
            const b = boxes[j]!
            if (Math.min(a.right, b.right) - Math.max(a.x, b.x) > 1 && Math.min(a.bottom, b.bottom) - Math.max(a.y, b.y) > 1) overlaps.push(`${labels[i]!.textContent?.trim()}:${labels[j]!.textContent?.trim()}`)
          }
        }
        return { viewport: innerWidth, page: document.documentElement.scrollWidth, overlaps }
      })
      expect(layout.page, `${viewport.width}x${viewport.height} ${theme} page overflow`).toBeLessThanOrEqual(layout.viewport)
      expect(layout.overlaps, `${viewport.width}x${viewport.height} ${theme} overlapping labels`).toEqual([])

      const focused = page.locator('.event-card:visible').first()
      await focused.focus()
      await expect(focused).toBeFocused()
    }
  }

  const pairedMoments = await page.locator('.vertical-layout .timeline-point').evaluateAll((points) =>
    points.some((point) => {
      const matching = [...point.querySelectorAll<HTMLElement>('.event-card[data-topic]')]
      return matching.some((item) => item.dataset.kind === 'emit' && matching.some((other) => other.dataset.kind === 'consume' && other.dataset.topic === item.dataset.topic))
    })
  )
  expect(pairedMoments).toBe(true)
})
