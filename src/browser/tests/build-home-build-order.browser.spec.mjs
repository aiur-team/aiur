import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { assertNoDocumentOverflow } from './support/browser-helpers.mjs'

// The Build order view mounts the aiur-build-order package on the document that
// `GET /api/v1/build-order` publishes. The harness projection never loads its
// `pack` source, so every document here reports `unknown`: the review and the
// graph still draw the tickets the document knows about and name the source
// reason instead of showing an empty board or a 0% bar.
test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })

const element = page => page.locator('#bd-bo aiur-build-order')
const review = page => page.locator('#bd-bo .aiur-bo--review')
const banner = page => review(page).locator('[data-section="status-banner"]')

let errors

async function openView(page, query = '') {
  await page.goto('/build-fixture/live?view=build-order' + query)
  await expect(element(page)).toHaveCount(1)
  await expect(element(page)).toHaveAttribute('data-status', 'unknown')
}

test.beforeEach(({ page }) => {
  errors = []
  page.on('pageerror', error => errors.push(error.message))
})

test.afterEach(() => {
  expect(errors).toEqual([])
})

test('the review and the graph are the package rendering the published document', async ({ page }) => {
  await openView(page)

  await expect(page.getByRole('tab', { name: 'Build order' })).toHaveAttribute('aria-selected', 'true')
  await expect(element(page)).toHaveAttribute('src', '/api/v1/build-order')
  await expect(element(page)).toHaveAttribute('view', 'both')

  await expect(review(page)).toHaveCount(1)
  await expect(review(page)).toHaveAttribute('data-contract', 'aiur.build_order')
  await expect(page.locator('#bd-bo svg.aiur-bo-graph')).toHaveCount(1)

  // The board's own geometry does not run in this view: the payload renderer
  // leaves no content column, lane, edge layer or card behind.
  await expect(page.locator('#bd-content')).toHaveCount(0)
  await expect(page.locator('#bd-edges')).toHaveCount(0)
  await expect(page.locator('.bd-card')).toHaveCount(0)
})

test('an unknown source renders its reason and the tickets the document knows about', async ({ page }) => {
  await openView(page)

  await expect(banner(page)).toHaveCount(1)
  await expect(banner(page)).toHaveAttribute('data-status', 'unknown')
  await expect(banner(page)).toContainText('Build order is unknown')
  await expect(banner(page)).toContainText('unknown, not zero')
  await expect(page.locator('#bd-bo')).toHaveAttribute('data-build-order-status', 'unknown')
  await expect(page.locator('#bd-bo')).toHaveAttribute('data-build-order-sources', 'pack')
  await expect(review(page).locator('.aiur-bo-ticket-link').first()).toBeVisible()
})

test('a focused build-order root reads its own document', async ({ page }) => {
  await openView(page, '&feature=bo-43')

  await expect(element(page)).toHaveAttribute('src', '/api/v1/build-order?root=43')
  await expect(page.locator('#bd-bo .aiur-bo-title')).toHaveText('Stale planning lane')
  await expect(page.locator('#bd-bo .aiur-bo-meta')).toContainText('1 tickets')
})

test('phone width keeps the review inside the board scroller', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await openView(page)

  await expect(review(page)).toBeVisible()
  await expect(banner(page)).toBeVisible()
  await assertNoDocumentOverflow(page)
})

test('switching away unmounts the package and switching back reads the document again', async ({ page }) => {
  await openView(page)
  await expect(review(page)).toHaveCount(1)

  await page.getByRole('tab', { name: 'Timeline', exact: true }).click()
  await expect(page.getByRole('tab', { name: 'Timeline', exact: true })).toHaveAttribute('aria-selected', 'true')
  await expect(element(page)).toHaveCount(0)
  await expect(page.locator('#bd-content')).toHaveCount(1)

  await page.getByRole('tab', { name: 'Build order' }).click()
  await expect(element(page)).toHaveCount(1)
  await expect(element(page)).toHaveAttribute('src', '/api/v1/build-order')
  await expect(review(page)).toHaveCount(1)
})
