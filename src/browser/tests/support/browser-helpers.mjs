import { expect } from '@playwright/test'

const fixtureAccessModes = new Set(['read_only', 'writable'])

export async function assertFixtureAccessDenied(page) {
  const response = await page.goto('/fixture')

  expect(response?.status()).toBe(401)
  await expect(page.getByText('synthetic fixture authentication required')).toBeVisible()
}

export async function openFixture(page, mode = 'read_only') {
  if (!fixtureAccessModes.has(mode)) throw new Error(`unsupported synthetic fixture access mode: ${mode}`)

  await page.goto(`/auth/${mode}`)
  await expect(page).toHaveURL(/\/fixture$/)
  await expect(page.locator('[data-fixture-ready="true"]')).toBeVisible()
  await expect(page.locator('#worker-status')).toHaveAttribute('data-worker-ready', 'true')
  await expect(page.locator('#mode-status')).toHaveText(mode)

  const session = (await page.context().cookies()).find((cookie) => cookie.name === '_aiur_browser_harness')

  expect(session).toMatchObject({ httpOnly: true, sameSite: 'Lax' })
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
