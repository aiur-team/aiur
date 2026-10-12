import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'

// The operator's MODELS panel (#3751): DeepSeek credits, Claude with two named
// accounts, Codex, and a Muse placeholder with no configured account.
async function openModelsPanel(page) {
  await page.goto('/auth/read_only')
  await page.goto('/models-panel')
  await expect(page.locator('[data-models-panel-fixture="true"] .rs-models')).toBeVisible()
}

// Every text cell of every line, with its box and whether its text overflows
// the box. Runs in the browser, so it cannot use this module's scope.
function lineCells(panel) {
  return Array.from(panel.querySelectorAll('.rs-ln')).map((line) => ({
    title: line.getAttribute('title'),
    cells: Array.from(line.children).map((cell) => {
      const box = cell.getBoundingClientRect()
      return {
        className: cell.className.baseVal ?? cell.className,
        text: cell.textContent.trim(),
        left: box.left,
        right: box.right,
        top: box.top,
        bottom: box.bottom,
        overflow: cell.scrollWidth - cell.clientWidth
      }
    })
  }))
}

const intersects = (a, b) => a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5

for (const width of [1440, 390]) {
  test(`models panel labels and values never overlap at ${width}px`, async ({ browser }, testInfo) => {
    const context = await browser.newContext({ viewport: { width, height: 900 }, reducedMotion: 'reduce' })
    const page = await context.newPage()

    try {
      await openModelsPanel(page)
      const panel = page.locator('.rs-models')

      // Only real allocations: the Muse placeholder, the LIMITS filler row and
      // the "worst of N accounts" summary are gone.
      await expect(panel.locator('.rs-model')).toHaveCount(3)
      await expect(panel.locator('.rs-model[data-provider="muse"]')).toHaveCount(0)
      await expect(panel).not.toContainText(/Muse/)
      await expect(panel).not.toContainText(/Limits/i)
      await expect(panel).not.toContainText(/Not observed/i)
      await expect(panel).not.toContainText(/worst of/i)
      await expect(panel.locator('.rs-group-count')).toHaveText('3 models')

      // Reset times are the recycle icon and the time, never "resets in".
      await expect(panel).not.toContainText(/resets in/i)
      await expect(panel).not.toContainText(/s old|fresh/)
      const codex = panel.locator('.rs-model[data-provider="codex"]')
      await expect(codex.locator('.rs-ln')).toHaveCount(1)
      await expect(codex.locator('.rs-rs')).toHaveText('5d 4h/7d')
      await expect(codex.locator('.rs-rs svg')).toHaveCount(1)

      // Each Claude account keeps its own named line (no split bar).
      const claude = panel.locator('.rs-model[data-provider="claude"]')
      await expect(claude.locator('.rs-x')).toHaveText('×2')
      await expect(claude.locator('.rs-ln[data-account="default"] .rs-tg')).toHaveText('default')
      await expect(claude.locator('.rs-ln[data-account="everdred"] .rs-tg')).toHaveText('everdred')
      await expect(claude.locator('.rs-ln[data-account="everdred"] .rs-pc')).toHaveText('12%')
      await expect(claude.locator('.rs-ln .rs-tg')).toHaveText(['default', 'everdred', 'session'])
      await expect(claude.locator('.rs-ln .rs-rs svg')).toHaveCount(3)

      const deepseek = panel.locator('.rs-model[data-provider="deepseek"]')
      await expect(deepseek.locator('.rs-pc')).toHaveText('2%')
      await expect(deepseek.locator('.rs-usd')).toHaveText('$10.40')

      // No cell overlaps another, and no cell's text spills out of its box.
      const lines = await panel.evaluate(lineCells)
      expect(lines.length).toBe(5)
      for (const line of lines) {
        for (const cell of line.cells) {
          expect(cell.overflow, `${line.title}: "${cell.text}" overflows its cell at ${width}px`).toBeLessThanOrEqual(0)
        }
        for (let i = 0; i < line.cells.length; i++) {
          for (let j = i + 1; j < line.cells.length; j++) {
            const [a, b] = [line.cells[i], line.cells[j]]
            expect(intersects(a, b), `${line.title}: "${a.text}" overlaps "${b.text}" at ${width}px`).toBe(false)
          }
        }
      }

      await assertNoDocumentOverflow(page)

      if (process.env.AIUR_BROWSER_SCREENSHOTS === '1') {
        const destination = testInfo.outputPath(`models-panel-${width}.png`)
        await panel.screenshot({ path: destination })
        await testInfo.attach(`models panel at ${width}px`, { path: destination, contentType: 'image/png' })
      }
    } finally {
      await context.close()
    }
  })
}
