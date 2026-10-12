import { expect, test } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

async function open(page, dataset = 'live') {
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.setViewportSize({ width: 1440, height: 900 })
  await page.goto(`/build-fixture/${dataset}`)
  await expect.poll(() => page.evaluate(() => window.liveSocket?.isConnected())).toBe(true)
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-state', dataset === 'unavailable' ? 'unavailable' : 'ready')
}

async function patch(page) {
  const toggle = page.locator('#ax-drag')
  const previous = await toggle.getAttribute('data-nav-collapsed')
  await toggle.click()
  await expect(toggle).toHaveAttribute('data-nav-collapsed', previous === 'true' ? 'false' : 'true')
}

test('hook-owned DOM survives a server patch', async ({ page }) => {
  await open(page)
  await page.locator('#build-root').evaluate(root => root.append(Object.assign(document.createElement('b'), { id: 'probe' })))
  await patch(page)
  await expect(page.locator('#probe')).toHaveCount(1)
})

test('an open modal survives a server patch', async ({ page }) => {
  await open(page)
  await page.evaluate(() => {
    document.querySelector('#tk-backdrop').classList.add('show')
    document.querySelector('#tk-body').append(Object.assign(document.createElement('b'), { id: 'mprobe' }))
  })
  // The modal deliberately overlays navigation once its styles have landed.
  await page.locator('#ax-drag').evaluate(handle => handle.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true })))
  await expect(page.locator('#ax-drag')).toHaveAttribute('data-nav-collapsed', 'true')
  await expect(page.locator('#tk-backdrop')).toHaveClass(/\bshow\b/)
  await expect(page.locator('#mprobe')).toHaveCount(1)
})

test('server state reaches the ignored root', async ({ page }) => {
  await open(page)
  await expect(page.locator('#build-root')).not.toHaveAttribute('data-build-reason')
  await open(page, 'unavailable')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-reason', 'unknown')
})

test('fixture endpoint picks only known datasets and carries query strings', async ({ request }) => {
  for (const dataset of ['live', 'dense', 'newrepo', 'noqueue', 'offline', 'hold', 'unavailable']) {
    const response = await request.get(`/build-fixture/${dataset}?ticket=12`, { maxRedirects: 0 })
    expect(response.status()).toBe(302)
    expect(response.headers().location).toBe('/build?ticket=12')
  }
  for (const dataset of ['manifest', 'usage-sets', 'nope', '..%2Flive']) {
    expect((await request.get(`/build-fixture/${dataset}`, { maxRedirects: 0 })).status()).toBe(404)
  }
})

test('future regression guard: hook-written data attributes are removed but classes survive', async ({ page }) => {
  await open(page)
  await page.locator('#build-root').evaluate(root => { root.dataset.probe = '1'; root.classList.add('probe') })
  await patch(page)
  await expect(page.locator('#build-root')).not.toHaveAttribute('data-probe')
  await expect(page.locator('#build-root')).toHaveClass(/\bprobe\b/)
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-state', 'ready')
})
