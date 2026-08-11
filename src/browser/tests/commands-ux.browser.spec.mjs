import { mkdir } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

import { expect, test } from '@playwright/test'

import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

const screenshotDirectory = fileURLToPath(new URL('../../../docs/screenshots/', import.meta.url))

test('Commands active cards and paginated history render at desktop width', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1100 }, reducedMotion: 'reduce' })
  const page = await context.newPage()

  try {
    await openFixture(page)
    await page.context().setHTTPCredentials(dashboardCredentials)
    await page.goto('/decisions')

    await expect(page.getByRole('heading', { name: 'Commands', exact: true })).toBeVisible()
    await expect(page.getByText('2 units awaiting commands')).toBeVisible()
    await expect(page.locator('.decision-card')).toHaveCount(2)
    await expect(page.locator('.decision-card-side .decision-age').first()).toHaveText('2h ago')
    await expect(page.locator('.expand-hint svg').first()).toBeVisible()
    await expect(page.locator('.command-history-table tbody tr')).toHaveCount(10)
    await expect(page.getByRole('button', { name: 'Load more' })).toBeVisible()

    await mkdir(screenshotDirectory, { recursive: true })
    await page.locator('.decision-inbox').screenshot({ path: `${screenshotDirectory}/issue-1786-commands-active.png` })
    await page.locator('.recent-section').screenshot({ path: `${screenshotDirectory}/issue-1786-command-history.png` })

    await page.getByRole('button', { name: 'Load more' }).click()
    await expect(page.locator('.command-history-table tbody tr')).toHaveCount(12)
    await expect(page.getByRole('button', { name: 'Load more' })).toHaveCount(0)
  } finally {
    await context.close()
  }
})
