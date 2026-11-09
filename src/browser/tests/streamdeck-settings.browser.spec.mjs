import { expect, test } from '@playwright/test'
import { anchor, openStreamdeck } from './support/streamdeck-emulator.mjs'

async function holdBack(page) {
  const dial = page.locator('.sd-knob').nth(3)
  await anchor(dial)
  const box = await dial.boundingBox()
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await page.mouse.down()
  await page.waitForTimeout(550)
  await page.mouse.up()
}

test('shared settings keys drill, save brightness and survive browser reconnect', async ({ page }) => {
  await openStreamdeck(page)
  await holdBack(page)
  const device = page.locator('.sd-device')
  await expect(device).toHaveAttribute('data-mode', 'settings')
  const keys = page.locator('#sd-keys button[data-streamdeck-key]')
  await expect(keys).toHaveCount(8)
  await expect(keys.locator('svg')).toHaveCount(8)
  await page.getByRole('button', { name: /^Brightness ·/ }).click()
  await page.getByRole('button', { name: /^30% ·/ }).click()
  await expect(page.getByRole('button', { name: '30% · Selected', exact: true })).toBeVisible()
  await expect(page.locator('[data-mode-view="settings-strip"]')).toContainText('Saved')
  await holdBack(page)
  await expect(page.getByRole('button', { name: 'Brightness · 30%', exact: true })).toBeVisible()
  await holdBack(page)
  await expect(device).toHaveAttribute('data-mode', 'grid')
  await page.reload()
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
  await holdBack(page)
  await expect(page.getByRole('button', { name: 'Brightness · 30%', exact: true })).toBeVisible()
  await page.getByRole('button', { name: /^Mic ·/ }).click()
  await expect(page.locator('[data-mode-view="settings-strip"]')).toContainText('Unavailable')
  await expect(page.locator('#sd-keys button > svg')).toHaveCount(0)
})
