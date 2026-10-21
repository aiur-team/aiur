import { expect, test } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

for (const width of [320, 390, 720]) {
  test(`bottom navigation keeps every link reachable without page overflow at 200% text zoom (${width}px)`, async ({ browser }) => {
    test.setTimeout(10_000)
    const context = await browser.newContext({
      viewport: { width, height: 900 },
      deviceScaleFactor: 2,
      reducedMotion: 'reduce',
      httpCredentials: dashboardCredentials
    })
    const page = await context.newPage()

    try {
      await openFixture(page)
      await page.goto('/')
      await page.evaluate(() => { document.documentElement.style.fontSize = '200%' })

      const navigation = page.locator('.sidenav-nav')
      await expect(navigation.locator('a.snav')).toHaveCount(6)
      await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
      await expect.poll(() => navigation.evaluate(node => getComputedStyle(node).overflowX)).toBe('auto')

      await page.locator('#ax-cog').click()
      const settings = page.locator('#ax-menu')
      await expect(settings).toBeVisible()
      const settingsBounds = await settings.evaluate(node => {
        const rect = node.getBoundingClientRect()
        return { left: rect.left, right: rect.right }
      })
      expect(settingsBounds.left).toBeGreaterThanOrEqual(0)
      expect(settingsBounds.right).toBeLessThanOrEqual(width)
      for (const item of await settings.locator('.ax-mi').all()) {
        const itemBounds = await item.evaluate(node => {
          const menu = node.closest('.ax-menu').getBoundingClientRect()
          const rect = node.getBoundingClientRect()
          return { left: rect.left, right: rect.right, menuLeft: menu.left, menuRight: menu.right }
        })
        expect(itemBounds.left).toBeGreaterThanOrEqual(itemBounds.menuLeft)
        expect(itemBounds.right).toBeLessThanOrEqual(itemBounds.menuRight)
        await expect(item).toBeVisible()
        if (width <= 480) {
          const labelBounds = await item.evaluate(node => {
            const label = node.querySelector('span:not(.toggle-icon)')
            const toggle = node.querySelector('.ax-sw')
            const labelRect = label.getBoundingClientRect()
            const rowRect = node.getBoundingClientRect()
            const toggleRect = toggle?.getBoundingClientRect()
            return {
              labelRight: labelRect.right,
              rowRight: rowRect.right,
              labelScrollWidth: label.scrollWidth,
              labelClientWidth: label.clientWidth,
              overlapsToggle: toggleRect && labelRect.right > toggleRect.left
            }
          })
          expect(labelBounds.labelRight).toBeLessThanOrEqual(labelBounds.rowRight)
          expect(labelBounds.labelScrollWidth).toBeLessThanOrEqual(labelBounds.labelClientWidth)
          expect(labelBounds.overlapsToggle).toBeFalsy()
        }
      }

      for (const link of await navigation.locator('a.snav').all()) {
        await link.evaluate(node => node.scrollIntoView({ block: 'nearest', inline: 'center' }))
        const bounds = await link.evaluate(node => {
          const nav = node.closest('.sidenav-nav').getBoundingClientRect()
          const rect = node.getBoundingClientRect()
          return { left: rect.left, right: rect.right, navLeft: nav.left, navRight: nav.right }
        })
        expect(bounds.left).toBeGreaterThanOrEqual(bounds.navLeft - 1)
        expect(bounds.right).toBeLessThanOrEqual(bounds.navRight + 1)
        const label = link.locator('.snav-label')
        expect(await label.evaluate(node => node.scrollWidth <= node.clientWidth)).toBe(true)
        await expect(link).toBeVisible()
      }
    } finally {
      await context.close()
    }
  })

  test(`Tab keeps each bottom navigation link fully visible at 200% text zoom (${width}px)`, async ({ browser }) => {
    test.setTimeout(10_000)
    const context = await browser.newContext({
      viewport: { width, height: 900 },
      deviceScaleFactor: 2,
      reducedMotion: 'reduce',
      httpCredentials: dashboardCredentials
    })
    const page = await context.newPage()

    try {
      await openFixture(page)
      await page.goto('/')
      await page.evaluate(() => { document.documentElement.style.fontSize = '200%' })

      const navigation = page.locator('.sidenav-nav')
      const links = navigation.locator('a.snav')
      await expect(links).toHaveCount(6)
      // The settings cog is display:none below 961px. Starting keyboard
      // navigation from it leaves focus on a 0x0 target and Tab can stall at
      // mobile widths. Start from the visible first nav link instead.
      const firstLink = links.first()
      await expect(firstLink).toBeVisible()
      await firstLink.focus()

      for (let index = 1; index < 6; index += 1) {
        await page.keyboard.press('Tab')
        const link = links.nth(index)
        await expect(link).toBeFocused()
        await expect.poll(() => link.evaluate(node => {
          const nav = node.closest('.sidenav-nav').getBoundingClientRect()
          const rect = node.getBoundingClientRect()
          return rect.left >= nav.left - 1 && rect.right <= nav.right + 1
        })).toBe(true)
      }
    } finally {
      await context.close()
    }
  })
}
