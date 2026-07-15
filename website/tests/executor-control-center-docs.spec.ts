import { expect, test } from '@playwright/test'
import { readFile, readdir } from 'node:fs/promises'
import path from 'node:path'

const surfaces = ['analytics-link', 'decision-inbox', 'decision', 'fleet', 'history', 'overview', 'recent-outcomes']
const variants = ['dark', 'light', 'mobile']
const expectedAssets = surfaces.flatMap((surface) => variants.map((variant) => `${surface}-${variant}.png`)).sort()

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
  const naturalDimensions = await page.locator('.vp-doc img').evaluateAll((images) =>
    images.map((image) => ({ width: image.naturalWidth, height: image.naturalHeight }))
  )

  expect(imagePaths).toHaveLength(14)
  expect(darkPaths).toHaveLength(7)
  expect(naturalDimensions).toHaveLength(14)
  expect(naturalDimensions.every(({ width, height }) => width > 0 && height > 0)).toBe(true)
  expect([...imagePaths, ...darkPaths].map((imagePath) => path.basename(imagePath)).sort()).toEqual(expectedAssets)

  for (const imagePath of [...imagePaths, ...darkPaths]) {
    expect(imagePath).toMatch(/^\/docs\/images\/executor-control-center\/[a-z-]+\.png$/)
    const response = await request.get(imagePath)
    expect(response.ok()).toBe(true)
    expect((await response.body()).byteLength).toBeGreaterThan(1_000)
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
  const captureScript = await readFile(path.join(websiteRoot, 'scripts/capture-executor-control-center.mjs'), 'utf8')
  const assetsRoot = path.join(websiteRoot, 'public/images/executor-control-center')
  const assets = (await readdir(assetsRoot)).filter((asset) => asset.endsWith('.png')).sort()

  expect(fixture).toContain('example.test')
  expect(fixture).toContain('EX-142')
  expect(fixture).toContain('kind: memory')
  expect(fixture).toContain('synthetic_workflow')
  expect(fixture).not.toMatch(/\.aiur\/config|github\.com|its-everdred|AIUR-\d+/i)

  expect(captureScript).toContain('allocatePort')
  expect(captureScript).toContain('syntheticMarkerPresent')
  expect(captureScript).toContain('AIUR_DOCS_TMP: docsTmp')
  expect(captureScript).toContain('rm(fixture.docsTmp')
  expect(captureScript).toContain('AIUR_DASHBOARD_USERNAME: ""')
  expect(captureScript).not.toContain('4099')
  expect(assets).toEqual(expectedAssets)

  for (const surface of surfaces) {
    const images = new Map<string, { bytes: Buffer, width: number, height: number }>()

    for (const variant of variants) {
      const bytes = await readFile(path.join(assetsRoot, `${surface}-${variant}.png`))
      const dimensions = pngDimensions(bytes)
      expect(dimensions.width).toBeGreaterThan(0)
      expect(dimensions.height).toBeGreaterThan(0)
      expect(bytes.byteLength).toBeGreaterThan(1_000)
      images.set(variant, { bytes, ...dimensions })
    }

    expect(images.get('light')?.bytes.equals(images.get('dark')!.bytes)).toBe(false)
    expect(images.get('mobile')?.width).toBeLessThanOrEqual(390)
    expect(images.get('mobile')?.width).toBeLessThan(images.get('dark')!.width)
  }
})

function pngDimensions(bytes: Buffer): { width: number, height: number } {
  expect(bytes.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a')
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) }
}
