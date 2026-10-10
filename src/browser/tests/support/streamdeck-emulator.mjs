import { expect } from '@playwright/test'
import { dashboardCredentials } from './layout-worker.mjs'

// The fixture dashboard is read-only by default, and the command keys are gated
// on that. Set the mode explicitly rather than relying on the default, so a test
// that opts into `writable` cannot leak into whichever test runs after it.
export async function openStreamdeck(page, mode = 'read_only') {
  await page.goto('/auth/read_only')
  await page.goto('/')
  await page.context().setHTTPCredentials(dashboardCredentials)
  const control = await page.goto(`/streamdeck-control/${mode}`)
  expect(control.status()).toBe(200)
  await page.goto('/streamdeck')
  await expect(page.locator('#streamdeck-page')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
  await anchor(page.locator('.sd-device'))
}

// `page.mouse` takes viewport coordinates and does no scrolling of its own,
// unlike `hover()`/`click()`. The deck sits below the route heading, so a
// gesture read from an unanchored bounding box lands off-screen. Playwright's
// own scroll is used rather than a raw `scrollIntoView`, because it waits for
// the element to settle first — a box read mid-scroll aims the drag at stale
// coordinates. It scrolls minimally, so clear the sticky topbar afterwards or
// the gesture lands on the topbar instead of the dial.
export async function anchor(locator) {
  await locator.scrollIntoViewIfNeeded()
  await locator.evaluate((element) => {
    const topbar = document.querySelector('header.ax-top')
    if (!topbar) return

    const overlap = topbar.getBoundingClientRect().bottom - element.getBoundingClientRect().top
    if (overlap > 0) window.scrollBy(0, -overlap - 8)
  })
}

export async function openUnits(page, path = '/units') {
  await page.goto('/auth/read_only')
  await page.goto(path)
  await expect(page.locator('[data-units-fixture="true"]')).toBeVisible()
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected() === true)).toBe(true)
}

export async function dragDialThroughAngles(page, dial, angles) {
  // Re-anchor before every drag: a mode change re-lays the deck out.
  await anchor(dial)

  const box = await dial.boundingBox()
  const cx = box.x + box.width / 2
  const cy = box.y + box.height / 2
  const point = (degrees) => {
    const radians = (degrees * Math.PI) / 180
    return { x: cx + Math.cos(radians) * 30, y: cy + Math.sin(radians) * 30 }
  }

  await page.mouse.move(...Object.values(point(angles[0])))
  await page.mouse.down()
  for (const degrees of angles.slice(1)) {
    await page.mouse.move(...Object.values(point(degrees)))
  }
  await page.mouse.up()
}
