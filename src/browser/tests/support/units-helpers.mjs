import { expect } from '@playwright/test'

export async function openUnits(page, path = '/units') {
  await page.goto('/auth/read_only')
  await page.goto('/streamdeck-control/read_only')
  await page.goto(path)
  await expect(page.locator('[data-units-fixture="true"]')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  // `isConnected()` reports the socket, not the view: the root still carries
  // `phx-loading` until the first connected render is applied, and a click
  // dispatched in that window lands on dead-render DOM that LiveView is about
  // to replace, so its binding never reaches the server. Wait for the swap.
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
}

export async function openWritableUnits(page) {
  await page.goto('/auth/writable')
  await page.goto('/streamdeck-control/writable')
  await page.goto('/units')
  await expect(page.locator('[data-units-fixture="true"]')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
}
