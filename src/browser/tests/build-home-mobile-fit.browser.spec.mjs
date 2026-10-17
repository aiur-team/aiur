// #4827: /build on a 390×844 phone must fit horizontally and clear the fixed bottom navigation.
import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, httpCredentials: dashboardCredentials })

async function open(page) {
  await page.goto('/build-fixture/live')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-state', 'ready')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-home-hook', 'mounted')
  await expect(page.locator('#bd-vp .bd-card').first()).toBeVisible()
}

test('no horizontal page scroll and every bottom-nav item is fully visible', async ({ page }) => {
  await open(page)
  const fit = await page.evaluate(() => ({
    innerWidth, scrollWidth: document.documentElement.scrollWidth, clientWidth: document.documentElement.clientWidth,
    items: Array.from(document.querySelectorAll('a.snav'), item => {
      const box = item.getBoundingClientRect(), label = item.querySelector('.snav-label')
      return { text: label.textContent.trim(), left: box.left, right: box.right, clipped: label.scrollWidth > label.clientWidth }
    })
  }))
  expect(fit.scrollWidth).toBeLessThanOrEqual(fit.innerWidth)
  expect(fit.items.length).toBeGreaterThanOrEqual(6)
  for (const item of fit.items) {
    expect(item.left, item.text).toBeGreaterThanOrEqual(0)
    expect(item.right, item.text).toBeLessThanOrEqual(fit.clientWidth)
    expect(item.clipped, item.text).toBe(false)
  }
})

test('the timeline scrolled to its end shows its last card above the bottom nav', async ({ page }) => {
  await open(page)
  await page.evaluate(() => window.scrollTo(0, 0))
  await page.locator('#bd-vp').evaluate(vp => { vp.scrollTop = vp.scrollHeight })
  const navTop = await page.locator('aside.sidenav').evaluate(nav => nav.getBoundingClientRect().top)
  const lastBottom = () => page.locator('#bd-vp').evaluate(vp => Math.max(0, ...Array.from(vp.querySelectorAll('.bd-card'), card => card.getBoundingClientRect().bottom)))
  await expect.poll(lastBottom).toBeGreaterThan(0)
  await expect.poll(lastBottom).toBeLessThanOrEqual(navTop)
})
