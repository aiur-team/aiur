import { expect, test } from '@playwright/test'

const intersects = (a, b) => a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5

for (const [width, height] of [[1440, 900], [390, 844]]) {
  test(`Units API and Models labels fit without overlap at ${width}x${height}`, async ({ browser }) => {
    const context = await browser.newContext({ viewport: { width, height }, reducedMotion: 'reduce' })
    const page = await context.newPage()

    try {
      await page.goto('/auth/read_only')
      await page.goto('/units-fixture?provider_layout=1')
      await expect(page.locator('[data-units-fixture="true"]')).toBeVisible()
      await expect(page.locator('#units-title')).toHaveText('Units')
      const apis = page.locator('.github-quota-card')
      const models = page.locator('.rs-models')
      await expect(apis).toBeVisible()
      await expect(models).toBeVisible()

      const apiCells = await apis.evaluate((card) => {
        const selectors = ['.rs-head .rs-logo', '.rs-head .rs-auth-mode', '.rs-limit-label', '.rs-limit-meta:not(.rs-limit-meta-wide[style*="display: none"])']
        return selectors.flatMap((selector) => Array.from(card.querySelectorAll(selector)).filter((element) => {
          const style = getComputedStyle(element)
          return style.display !== 'none' && element.getBoundingClientRect().width > 0
        }).map((element) => {
          const box = element.getBoundingClientRect()
          return { selector, text: element.textContent.trim(), left: box.left, right: box.right, top: box.top, bottom: box.bottom, width: box.width }
        }))
      })

      expect(apiCells.some(({ selector }) => selector.includes('rs-logo'))).toBe(true)
      await expect(apis.locator('.rs-auth-mode')).toHaveText('PAT')
      const labels = apiCells.filter(({ selector }) => selector === '.rs-limit-label').map(({ text }) => text.toLowerCase())
      for (const expected of ['core', 'graphql', 'credits']) expect(labels.some((label) => label.includes(expected))).toBe(true)
      for (const expected of ['4906/5000', '4794/5000']) expect(apiCells.some(({ text }) => text.includes(expected))).toBe(true)
      for (let i = 0; i < apiCells.length; i++) {
        for (let j = i + 1; j < apiCells.length; j++) {
          const [a, b] = [apiCells[i], apiCells[j]]
          expect(intersects(a, b), `${a.selector} "${a.text}" ${JSON.stringify(a)} overlaps ${b.selector} "${b.text}" ${JSON.stringify(b)} at ${width}px`).toBe(false)
        }
      }

      const modelCells = await models.locator('.rs-ln > span, .rs-ln .rs-rs > span').evaluateAll((cells) => cells.map((cell) => {
        const style = getComputedStyle(cell)
        const line = cell.closest('.rs-ln')
        return {
          text: cell.textContent.trim(),
          overflows: style.display !== 'none' && cell.scrollWidth > cell.clientWidth,
          textOverflow: style.textOverflow,
          cellTitle: cell.getAttribute('title') || '',
          lineTitle: line?.getAttribute('title') || ''
        }
      }))
      for (const cell of modelCells.filter(({ overflows }) => overflows)) {
        expect(cell.textOverflow, `"${cell.text}" is clipped without an ellipsis at ${width}px`).toBe('ellipsis')
        expect(`${cell.cellTitle} ${cell.lineTitle}`).toContain(cell.text)
      }

      const session = models.locator('.rs-ln').filter({ hasText: 'session' })
      await expect(session.locator('.rs-tg')).toHaveText('session')
      await expect(session).toHaveAttribute('title', /Session.*left/i)

      const headroomNote = models.locator('.rs-no').filter({ hasText: '32% left' })
      await expect(headroomNote).toHaveText('32% left · 1s old')
      await expect(headroomNote).toHaveAttribute('title', '32% left · 1s old')
    } finally {
      await context.close()
    }
  })
}
