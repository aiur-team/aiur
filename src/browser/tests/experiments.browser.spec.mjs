import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

async function openExperiments(page, scenario = 'mixed') {
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.goto(`/experiments-control/${scenario}`)
  await expect(page.locator('#experiments-page')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  await expect(page.locator("[data-phx-main].phx-connected")).toHaveCount(1)
}

function indexLinks(page) {
  return page.getByRole('navigation', { name: 'Experiment index', exact: true }).getByRole('link')
}

async function assertTouchTarget(link) {
  const box = await link.boundingBox()
  expect(box).not.toBeNull()
  expect(box.width).toBeGreaterThanOrEqual(44)
  expect(box.height).toBeGreaterThanOrEqual(44)
}

test('desktop experiment index selects and navigates between registered experiments', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await openExperiments(page)
  const labels = await page.locator('.sidenav-nav .snav-label').allTextContents()
  expect(labels.indexOf('Experiments')).toBe(labels.indexOf('Analytics') + 1)
  const links = indexLinks(page)
  await expect(links).toHaveCount(2)
  await expect(links.first()).toHaveAttribute('aria-current', 'page')
  await expect(page.locator('#exp-detail h2')).toHaveText('Release delivery speed')
  await expect(links.first()).toContainText('Before/after')
  await expect(links.nth(1)).toContainText('A/B')
  await links.nth(1).click()
  await expect(page).toHaveURL(/\/experiments\/cohort-speed$/)
  await expect(page.locator('#exp-detail h2')).toHaveText('Cohort delivery speed')
  await expect(page.locator('#exp-detail')).toContainText('Control · Test')
  await expect(links.nth(1)).toHaveAttribute('aria-current', 'page')
  await page.goBack()
  await expect(page.locator('#exp-detail h2')).toHaveText('Release delivery speed')
  await assertNoDocumentOverflow(page)
})

test('stored evidence shows guarded samples and analyst attribution', async ({ page }) => {
  await openExperiments(page)
  await expect(indexLinks(page).first()).toContainText('n 4/10')
  await expect(indexLinks(page).first()).toContainText('not enough data')
  await expect(indexLinks(page).first()).toContainText('analyst: confounded')
  await expect(page.getByRole('table', { name: 'Metric evidence' })).toContainText('not enough data (n 4 of 10)')
})

test('phone experiment list and detail keep touch targets reachable without overflow', async ({ browser }) => {
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true,
    httpCredentials: dashboardCredentials, reducedMotion: 'reduce'
  })
  const page = await context.newPage()
  try {
    await openExperiments(page)
    await expect(page.locator('.exp-index')).toBeVisible()
    await expect(page.locator('.exp-detail')).toBeHidden()
    for (const link of await indexLinks(page).all()) await assertTouchTarget(link)
    await assertNoDocumentOverflow(page)
    await indexLinks(page).nth(1).tap()
    await expect(page).toHaveURL(/\/experiments\/cohort-speed$/)
    await expect(page.locator('.exp-index')).toBeHidden()
    await expect(page.locator('#exp-detail h2')).toHaveText('Cohort delivery speed')
    const back = page.getByRole('link', { name: '← All experiments', exact: true })
    await assertTouchTarget(back)
    await assertNoDocumentOverflow(page)
    await back.tap()
    await expect(page).toHaveURL(/\/experiments$/)
    await expect(page.locator('.exp-index')).toBeVisible()
    await expect(page.locator('.exp-detail')).toBeHidden()
    await assertNoDocumentOverflow(page)
  } finally {
    await context.close()
  }
})

test('experiment links support keyboard traversal, visible focus and Enter', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await openExperiments(page)
  const links = indexLinks(page)
  await links.first().focus()
  await page.keyboard.press('Tab')
  await expect(links.nth(1)).toBeFocused()
  expect(await links.nth(1).evaluate(element => {
    const style = getComputedStyle(element)
    return element.matches(':focus-visible') && style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) > 0
  })).toBe(true)
  await page.keyboard.press('Enter')
  await expect(page).toHaveURL(/\/experiments\/cohort-speed$/)
  await expect(page.locator('#exp-detail h2')).toHaveText('Cohort delivery speed')
})

for (const theme of ['dark', 'light']) {
  test(`experiment detail is accessible in ${theme} theme`, async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' })
    await openExperiments(page)
    await indexLinks(page).nth(1).click()
    await page.evaluate(value => {
      localStorage.setItem('aiur-theme', value)
      document.documentElement.dataset.theme = value
    }, theme)
    await expect(page.locator('html')).toHaveAttribute('data-theme', theme)
    const audit = await new AxeBuilder({ page }).analyze()
    expect(audit.violations).toEqual([])
  })
}

test('empty experiment store loads without HTTP or console errors', async ({ page }) => {
  const failures = []
  page.on('response', response => { if (response.status() === 404) failures.push(response.url()) })
  page.on('console', message => { if (message.type() === 'error') failures.push(message.text()) })
  page.on('pageerror', error => failures.push(error.message))
  await openExperiments(page, 'empty')
  await expect(page.locator('[data-empty-reason="no_experiments"]')).toContainText('No experiments yet.')
  await expect(indexLinks(page)).toHaveCount(0)
  await expect(page.locator('#exp-detail')).toHaveCount(0)
  await assertNoDocumentOverflow(page)
  expect(failures).toEqual([])
})

test('consumer metric pack supplies labels and units through the real facade', async ({ page }) => {
  await openExperiments(page, 'custom-pack')
  await expect(page.locator('#exp-detail')).toContainText('Application latency')
  const metric = page.getByRole('row').filter({ hasText: 'Request latency' })
  await expect(metric).toBeVisible()
  await expect(metric.getByRole('cell', { name: 'ms', exact: true })).toBeVisible()
  await expect(metric.getByRole('cell', { name: 'decrease', exact: true })).toBeVisible()
  await expect(metric).not.toContainText('delivery-speed')
})

test('unknown experiment URL stays distinct from an empty index', async ({ page }) => {
  await openExperiments(page, 'empty')
  await page.goto('/experiments/missing')
  await expect(page.locator('[data-empty-reason="not_found"]')).toContainText('Experiment not found')
  await expect(page.locator('[data-empty-reason="no_experiments"]')).toHaveCount(0)
})
