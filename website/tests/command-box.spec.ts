import { test, expect } from '@playwright/test'
import { routeFonts, settle } from './support/visual'

test.use({ viewport: { width: 1280, height: 800 } })
test.beforeEach(async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await routeFonts(page)
})

test('command box and canvas keepout follow every selected tab', async ({ page }, testInfo) => {
  await page.route('http://127.0.0.1:43127/', async (route) => {
    const response = await route.fetch()
    await route.fulfill({ response, body: (await response.text()).replace('<html', '<html data-field-debug') })
  })
  await page.goto('/')
  await settle(page)
  expect(await page.evaluate(() => matchMedia('(prefers-reduced-motion: reduce)').matches)).toBe(true)
  let promptWidth = 0
  for (const tab of ['Prompt', 'npm', 'bun', 'pnpm', 'yarn', 'Prompt']) {
    await page.getByRole('tab', { name: tab, exact: true }).click()
    await settle(page)
    const geometry = await page.evaluate(() => {
      const rect = document.querySelector('.aiur-command')!.getBoundingClientRect()
      const canvas = document.querySelector<HTMLCanvasElement>('#field')!
      const canvasRect = canvas.getBoundingClientRect()
      const style = getComputedStyle(document.querySelector('.aiur-command')!)
      const field = (window as unknown as {
        __field: { debugObstacles: () => { cx: number; cy: number; hx: number; hy: number }[] }
      }).__field
      const obstacle = field.debugObstacles().find((ob) =>
        Math.abs(ob.cx - (rect.left - canvasRect.left + rect.width / 2)) < 1 &&
        Math.abs(ob.cy - (rect.top - canvasRect.top + rect.height / 2)) < 1)
      const left = Math.ceil(rect.left - canvasRect.left)
      const top = Math.ceil(rect.top - canvasRect.top)
      const width = Math.floor(rect.width) - 2
      const height = Math.floor(rect.height) - 2
      const pixels = (x: number, y: number, w: number, h: number) => {
        const data = canvas.getContext('2d')!.getImageData(x, y, w, h).data
        let count = 0
        for (let i = 3; i < data.length; i += 4) if (data[i]) count++
        return count
      }
      const nearEdge = (x: number, side: -1 | 1) => {
        const data = canvas.getContext('2d')!.getImageData(x + (side < 0 ? -20 : 0), top - 20, 20, height + 40).data
        let nearest = Infinity
        for (let i = 3; i < data.length; i += 4) {
          if (!data[i]) continue
          const pixel = (i - 3) / 4
          const dx = pixel % 20 + (side < 0 ? -20 : 0)
          const y = Math.floor(pixel / 20) - 20
          nearest = Math.min(nearest, Math.hypot(dx, y - Math.max(0, Math.min(height, y))))
        }
        return nearest
      }
      return {
        width: rect.width, height: rect.height, obstacle,
        border: parseFloat(style.borderLeftWidth) + parseFloat(style.borderRightWidth),
        contentWidth: Math.max(document.querySelector('.aiur-tabs')!.scrollWidth,
          document.querySelector('#installRow')!.scrollWidth),
        inside: pixels(left + 1, top + 1, width, height),
        leftEdge: nearEdge(left, -1),
        rightEdge: nearEdge(Math.floor(rect.right - canvasRect.left), 1)
      }
    })
    await testInfo.attach(`${tab}-hero`, { body: await page.locator('.hero').screenshot(), contentType: 'image/png' })
    expect(geometry.obstacle, `${tab} current obstacle`).toBeDefined()
    expect(Math.abs(geometry.obstacle!.hx * 2 - geometry.width - 18), `${tab} horizontal keepout`).toBeLessThanOrEqual(1)
    expect(Math.abs(geometry.obstacle!.hy * 2 - geometry.height - 12), `${tab} vertical keepout`).toBeLessThanOrEqual(1)
    // scrollWidth excludes the panel's two 1px borders.
    expect(Math.abs(geometry.width - geometry.border - geometry.contentWidth)).toBeLessThanOrEqual(1)
    if (tab === 'Prompt') promptWidth = geometry.width
    if (tab === 'npm') expect(geometry.width).toBeLessThan(promptWidth - 40)
    expect(geometry.inside, `${tab} no canvas pixels inside box`).toBe(0)
    expect(geometry.leftEdge, `${tab} left clearance <= GAP + padX + 2`).toBeLessThanOrEqual(20)
    expect(geometry.rightEdge, `${tab} right clearance <= GAP + padX + 2`).toBeLessThanOrEqual(20)
  }
})

test('hero resizing updates the canvas without a window resize', async ({ page }) => {
  await page.goto('/')
  await settle(page)
  const before = await page.locator('#field').evaluate((canvas) => (canvas as HTMLCanvasElement).height)
  await page.locator('.hero').evaluate((hero) => {
    (hero as HTMLElement).style.height = `${hero.clientHeight + 100}px`
  })
  await settle(page)
  expect(await page.locator('#field').evaluate((canvas) => (canvas as HTMLCanvasElement).height)).toBe(before + 100)
})

test('browsers without ResizeObserver retain window resize support', async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(window, 'ResizeObserver', { value: undefined, configurable: true })
  })
  const errors: string[] = []
  page.on('pageerror', (error) => errors.push(error.message))
  await page.goto('/')
  await settle(page)
  await page.getByRole('tab', { name: 'npm', exact: true }).click()
  await expect(page.locator('#installCmd')).toHaveText('npm i -g aiur-cli')
  await page.setViewportSize({ width: 1100, height: 800 })
  await expect.poll(() => page.locator('#field').evaluate((canvas) => (canvas as HTMLCanvasElement).width)).toBe(1100)
  expect(errors).toEqual([])
  expect(await page.evaluate(() => '__field' in window)).toBe(false)
})
