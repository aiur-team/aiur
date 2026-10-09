import { test, expect } from '@playwright/test'
import { getMaskConfig, openVisualRoute } from '../support/visual.mjs'

test.use({ reducedMotion: 'reduce' })

const THEMES = ['light', 'dark']
const VIEWPORTS = [
  { width: 1440, height: 900 },
  { width: 1024, height: 768 },
  { width: 390, height: 844 }
]
const ROUTES = ['/', '/build-orders', '/analytics']

for (const theme of THEMES) {
  for (const viewport of VIEWPORTS) {
    const size = `${viewport.width}x${viewport.height}`
    const states = viewport.width > 959 ? ['expanded', 'collapsed'] : ['mobile']
    test.describe(`${theme} ${size}`, () => {
      const mobile = viewport.width <= 959
      test.use({ viewport, deviceScaleFactor: mobile ? 3 : 1, isMobile: mobile, hasTouch: mobile })
      for (const route of ROUTES) {
        for (const state of states) {
          test(`shell ${route} ${state}`, async ({ page }) => {
            await openVisualRoute(page, { theme, route, collapsed: state === 'collapsed' })
            const prefix = `${theme}-${size}-${route === '/' ? 'units' : route.slice(1)}-${state}`
            const mask = getMaskConfig(page)
            await expect(page).toHaveScreenshot(`${prefix}-shell.png`, { mask })
            for (const [name, selector] of [
              ['header', 'header.topbar'],
              ['nav', state === 'mobile' ? '.shell-nav-mobile' : state === 'collapsed' ? '#nav-toggle' : 'aside.shell-sidebar'],
              ['context', '.route-context']
            ]) {
              const element = page.locator(selector)
              await expect(element).toBeVisible()
              await expect(element).toHaveScreenshot(`${prefix}-${name}.png`, { mask })
            }
            if (state === 'collapsed') {
              await expect(page.locator('.shell-nav-sidebar')).not.toBeVisible()
              await expect(page.locator('#nav-toggle')).toBeVisible()
            }
          })
        }
      }

      test('button elements', async ({ page }) => {
        await openVisualRoute(page, { theme, route: '/', mode: 'writable' })
        await page.goto('/units')
        await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
        await expect(page.locator('html')).toHaveAttribute('data-theme', theme)
        // Units exposes the primary and ghost controls together in the real
        // admission modal. No route-dependent optional screenshot branches.
        await page.getByRole('button', { name: 'Add an agent to ticket 2101', exact: true }).click()
        const modal = page.locator('#add-agent-modal')
        await expect(modal).toBeVisible()
        const tool = modal.locator('.tool-btn')
        await expect(tool).toBeVisible()
        for (const selector of ['.btn:not(.ghost)', '.btn.ghost']) {
          await expect(modal.locator(selector)).toBeVisible()
        }
        await expect(tool).toHaveScreenshot(`${theme}-${size}-tool-btn.png`)
        for (const [name, selector] of [['btn', '.btn:not(.ghost)'], ['ghost-btn', '.btn.ghost']]) {
          const button = modal.locator(selector)
          await expect(button).toBeVisible()
          await expect(button).toHaveScreenshot(`${theme}-${size}-${name}.png`)
        }
      })
    })
  }
  test(`keyboard focus ${theme}`, async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 })
    await openVisualRoute(page, { theme, route: '/' })
    const item = page.locator('.shell-nav-sidebar .shell-nav-item').first()
    // Traverse the actual tab order so :focus-visible is exercised.
    for (let attempt = 0; attempt < 20; attempt += 1) {
      await page.keyboard.press('Tab')
      if (await item.evaluate((node) => node === document.activeElement)) break
    }
    await expect(item).toBeFocused()
    expect(await item.evaluate((node) => node.matches(':focus-visible'))).toBe(true)
    const bounds = await item.boundingBox()
    // Locator screenshots clip outside outlines. Include the surrounding gap
    // so the keyboard focus ring itself is constrained by the baseline.
    await expect(page).toHaveScreenshot(`keyboard-focus-${theme}.png`, {
      clip: { x: Math.max(0, bounds.x - 8), y: Math.max(0, bounds.y - 8), width: bounds.width + 16, height: bounds.height + 16 }
    })
  })
}

test('CSS nav padding mutation fails sidebar screenshot comparison', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await openVisualRoute(page, { theme: 'light', route: '/build-orders' })
  const sidebar = page.locator('aside.shell-sidebar')
  const navItem = sidebar.locator('.shell-nav-item').first()
  await expect(sidebar).toBeVisible()
  await expect(sidebar).toHaveScreenshot('proof-sidebar.png', { maxDiffPixels: 0, maxDiffPixelRatio: 0 })
  // Refresh only the unmodified baseline; otherwise update mode records the intentional mutation.
  if (test.info().config.updateSnapshots !== 'none') return
  const before = await navItem.evaluate((node) => parseFloat(getComputedStyle(node).paddingLeft))
  await page.addStyleTag({ content: '.shell-nav-item{padding-left:calc(0.72rem + 2px)!important}' })
  const after = await navItem.evaluate((node) => parseFloat(getComputedStyle(node).paddingLeft))
  expect(after - before).toBeCloseTo(2, 1)
  let mismatch
  try {
    await expect(sidebar).toHaveScreenshot('proof-sidebar.png', { timeout: 2000, maxDiffPixels: 0, maxDiffPixelRatio: 0 })
  } catch (error) {
    // Missing baselines, closed pages and capture failures must not count as
    // proof. Only the screenshot matcher's actual pixel difference qualifies.
    if (error.matcherResult?.name !== 'toHaveScreenshot' || !/pixels.*different/.test(error.message)) throw error
    mismatch = error
  }
  expect(mismatch, 'the +2px padding mutation must fail the baseline comparison').toBeDefined()
})
