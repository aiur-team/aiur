import { expect, test } from '@playwright/test'
import { readFile, readdir } from 'node:fs/promises'
import path from 'node:path'

test('Executor Control Center guide publishes every synthetic screenshot surface', async ({ page, request }) => {
  await page.goto('/docs/guide/executor-control-center')

  await expect(page.getByRole('heading', { level: 1, name: 'Executor Control Center' })).toBeVisible()
  await expect(page.getByText('Every screenshot on this page was captured')).toBeVisible()
  await expect(page.locator('.vp-doc')).not.toContainText('Operator Control Center')

  const imagePaths = await page.locator('.vp-doc img').evaluateAll((images) =>
    images.map((image) => image.getAttribute('src')).filter((value): value is string => value !== null)
  )
  const darkPaths = await page.locator('.vp-doc picture source').evaluateAll((sources) =>
    sources.map((source) => source.getAttribute('srcset')).filter((value): value is string => value !== null)
  )

  expect(imagePaths).toHaveLength(14)
  expect(darkPaths).toHaveLength(7)

  for (const imagePath of [...imagePaths, ...darkPaths]) {
    expect(imagePath).toMatch(/^\/docs\/images\/executor-control-center\/[a-z-]+\.png$/)
    expect((await request.get(imagePath)).ok()).toBe(true)
  }
})

test('docs-gap pages are linked and published', async ({ page }) => {
  await page.goto('/docs/guide/quick-start')
  await expect(page.locator('.vp-doc').getByRole('link', { name: 'Executor Control Center', exact: true })).toBeVisible()
  await expect(page.locator('.vp-doc').getByRole('link', { name: 'CLI and control commands', exact: true })).toBeVisible()

  await page.goto('/docs/concepts/coordination')
  await expect(page.getByRole('heading', { level: 1, name: 'Coordination and events' })).toBeVisible()

  await page.goto('/docs/reference/cli')
  await expect(page.getByRole('heading', { level: 1, name: 'CLI and control commands' })).toBeVisible()

  await page.goto('/docs/reference/configuration')
  await expect(page.getByText('lifecycle label slugs').first()).toBeVisible()
})

test('capture inputs and checked-in assets stay example-only', async () => {
  const websiteRoot = path.resolve(import.meta.dirname, '..')
  const fixture = await readFile(
    path.join(websiteRoot, '../src/test/manual/executor_control_center_docs_fixture.exs'),
    'utf8'
  )
  const assets = await readdir(path.join(websiteRoot, 'public/images/executor-control-center'))

  expect(fixture).toContain('example.test')
  expect(fixture).toContain('EX-142')
  expect(fixture).not.toMatch(/github\.com|its-everdred|AIUR-\d+/i)
  expect(assets.filter((asset) => asset.endsWith('.png'))).toHaveLength(21)
})
