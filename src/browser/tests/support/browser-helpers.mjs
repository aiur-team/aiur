import { expect } from '@playwright/test'

export async function openFixture(page, mode = 'read_only') {
  await page.goto('/')
  await expect(page.locator('[data-fixture-ready="true"]')).toBeVisible()
  await expect(page.locator('#worker-status')).toHaveAttribute('data-worker-ready', 'true')

  if (mode === 'writable') {
    await page.getByRole('button', { name: 'Writable' }).click()
    await expect(page.locator('#mode-status')).toHaveText('writable')
  }
}

export async function assertNoDocumentOverflow(page) {
  const dimensions = await page.evaluate(() => ({ width: window.innerWidth, scrollWidth: document.documentElement.scrollWidth }))
  expect(dimensions.scrollWidth).toBeLessThanOrEqual(dimensions.width)
}

export async function assertControlsRemainReachable(page) {
  const { controls, width } = await page.evaluate(() => ({
    controls: Array.from(document.querySelectorAll('button')).map((button) => button.getBoundingClientRect().right),
    width: window.innerWidth
  }))
  expect(controls.every((right) => right <= width)).toBe(true)
}

export async function reconnectLiveView(page) {
  await page.evaluate(() => window.liveSocket.disconnect())
  await expect(page.locator('#worker-status')).toHaveAttribute('data-live-status', 'disconnected')
  await page.evaluate(() => window.liveSocket.connect())
  await expect(page.locator('#worker-status')).toHaveAttribute('data-live-status', 'reconnected')
}

export async function captureConfiguredScreenshot(page, testInfo) {
  if (process.env.AIUR_BROWSER_SCREENSHOTS !== '1') return null

  const destination = testInfo.outputPath('fixture.png')
  await page.screenshot({ path: destination, fullPage: true })
  await testInfo.attach('fixture screenshot', { path: destination, contentType: 'image/png' })
  return destination
}
