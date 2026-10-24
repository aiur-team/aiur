import { test, expect } from '@playwright/test'
import { openVisualRoute } from '../support/visual.mjs'
import { selectProductDataset } from '../support/design-parity.mjs'

test('harness self-check: live ticket shimmer keeps its phase across a live diff', async ({ page }) => {
  await openVisualRoute(page, { theme: 'dark', palette: 'gruvbox', route: '/build', mode: 'writable' })
  await selectProductDataset(page, 'live')
  const card = page.locator('.bd-card.ag-active').first()
  await expect(card).toBeVisible()
  const id = await card.getAttribute('data-id')
  await expect(card.locator('.bd-glow')).toHaveCount(1)
  const before = await card.locator('.bd-glow').evaluate(el => {
    const timeline = document.timeline.currentTime
    const angle = Number.parseFloat(getComputedStyle(el).getPropertyValue('--bd-a'))
    const expected = ((timeline % 9000) * 360 / 9000) % 360
    const delta = ((angle - expected + 540) % 360) - 180
    return { angle, expected, delta }
  })
  expect(Math.abs(before.delta)).toBeLessThanOrEqual(5)
  await page.evaluate(async id => {
    const { ctx } = await import('/build-home/state.js')
    const { refreshTicket } = await import('/build-home/cards.js')
    const it = ctx.L.band.items.find(item => item.t.id === id)
    if (!it) throw new Error(`live band item is unreachable: ${id}`)
    ctx.bandMap[it.key] = { x: it.x ?? 120, w: it.w ?? 260 }
    refreshTicket(id)
  }, id)
  const replacement = page.locator(`.bd-card.ag-active[data-id="${id}"]`)
  await expect(replacement).toHaveCount(1)
  await expect(replacement.locator('.bd-glow')).toHaveCount(1)
  const after = await replacement.locator('.bd-glow').evaluate(el => {
    const timeline = document.timeline.currentTime
    const angle = Number.parseFloat(getComputedStyle(el).getPropertyValue('--bd-a'))
    const expected = ((timeline % 9000) * 360 / 9000) % 360
    const delta = ((angle - expected + 540) % 360) - 180
    return { angle, expected, delta }
  })
  expect(Math.abs(after.delta)).toBeLessThanOrEqual(5)
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await expect(page.locator('#build-root')).toHaveClass(/\brm\b/)
  expect(await replacement.locator('.bd-glow').evaluate(el => getComputedStyle(el).animationName)).toBe('none')
  expect(await replacement.locator('.bd-glow').evaluate(el => getComputedStyle(el).backgroundImage)).toBe('none')
})
