import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertControlsRemainReachable, assertFixtureAccessDenied, assertNoDocumentOverflow, captureConfiguredScreenshot, openFixture, reconnectLiveView } from './support/browser-helpers.mjs'
import { assertMeasurementBudget, measureBrowserWork } from './support/measurements.mjs'

test('synthetic LiveView requires authentication and covers navigation, modes, hooks, inputs, and updates', async ({ page }, testInfo) => {
  await assertFixtureAccessDenied(page)
  await openFixture(page, 'read_only')
  await expect(page.locator('#mode-status')).toHaveText('read_only')

  await page.getByRole('button', { name: 'Details' }).click()
  await expect(page).toHaveURL(/\?view=details/)

  await page.mouse.click(0, 0)
  await page.getByRole('button', { name: 'Pointer input' }).click()
  await expect(page.locator('#fixture-status')).toHaveText('pointer input received')

  await page.getByRole('button', { name: 'Keyboard input' }).focus()
  await page.keyboard.press('Enter')
  await expect(page.locator('#fixture-status')).toHaveText('keyboard input received')

  await page.getByRole('button', { name: 'Dark theme' }).click()
  await expect(page.locator('#fixture-root')).toHaveAttribute('data-theme', 'dark')

  await page.getByRole('button', { name: 'Apply synthetic update' }).click()
  await expect(page.locator('#fixture-counts')).toHaveText('nodes: 50, edges: 48, roots: 2')
  await captureConfiguredScreenshot(page, testInfo)
})

test('synthetic fixture supports touch, reduced motion, zoom, and focus', async ({ browser }) => {
  const context = await browser.newContext({
    viewport: { width: 320, height: 720 },
    hasTouch: true,
    isMobile: true,
    reducedMotion: 'reduce'
  })
  const page = await context.newPage()

  try {
    await openFixture(page)
    await page.getByRole('button', { name: 'Touch input' }).tap()
    await expect(page.locator('#fixture-status')).toHaveText('touch input received')

    await page.locator('#keyboard-input').focus()
    await expect(page.locator('#keyboard-input')).toBeFocused()
    await expect(page.locator('#graph-viewport')).toHaveAttribute('data-reduced-motion', 'true')

    await page.evaluate(() => { document.documentElement.style.fontSize = '200%' })
    await assertNoDocumentOverflow(page)
    await assertControlsRemainReachable(page)
  } finally {
    await context.close()
  }
})

test('synthetic fixture reconnects LiveView and passes automated accessibility checks', async ({ page }) => {
  await openFixture(page, 'writable')
  await reconnectLiveView(page)

  const accessibility = await new AxeBuilder({ page }).analyze()
  expect(accessibility.violations).toEqual([])
})

test('browser measurements use monotonic samples after warmup', async ({ page }) => {
  await openFixture(page)
  await page.evaluate(() => {
    const target = document.querySelector('#graph-content')

    window.__aiurBrowserHarnessOperations = {
      redraw(index) {
        target.dataset.revision = String(index)
        target.textContent = `Synthetic redraw ${index}`
        target.style.transform = `translateX(${index % 2}px)`
      },
      slow() {
        const until = performance.now() + 25

        while (performance.now() < until) {}
      },
      long() {
        const until = performance.now() + 60

        while (performance.now() < until) {}
      }
    }
  })

  const measurement = await measureBrowserWork(page, { operation: 'redraw', warmups: 2, repetitions: 4 })

  expect(measurement.warmups).toBe(2)
  expect(measurement.samples).toHaveLength(4)
  expect(measurement.samples.every((sample) => sample.layoutLatencyMs >= 0 && sample.mainThreadMs >= 0)).toBe(true)
  expect(Array.isArray(measurement.longTasks)).toBe(true)
  // This validates the measurement primitive, not BO-014's product budget.
  assertMeasurementBudget(measurement, { maxLayoutLatencyMs: 1_000, maxMainThreadMs: 1_000, maxCoalescedUpdates: 10, maxLongTaskMs: 1_000 })

  const slowMeasurement = await measureBrowserWork(page, { operation: 'slow', warmups: 0, repetitions: 1 })
  expect(() => assertMeasurementBudget(slowMeasurement, { maxMainThreadMs: 5 })).toThrow(/main-thread work/)

  const longMeasurement = await measureBrowserWork(page, { operation: 'long', warmups: 0, repetitions: 1 })
  expect(() => assertMeasurementBudget(longMeasurement, { maxMainThreadMs: 5 })).toThrow(/main-thread work/)
})
