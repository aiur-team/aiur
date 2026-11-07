import { fileURLToPath } from 'node:url'
import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

// #7686: on a phone one finger over the board scrolls the page, two fingers pan the board,
// a pinch changes the same zoom percent the +/- control shows, and the section fits the screen.
test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } })

const HEADER = 56
const percent = page => page.locator('#bd-tools .bd-zv').innerText()

test.beforeEach(async ({ page }) => {
  // Serve this checkout's build-home files even when the fixture runs a shared compiled release.
  await page.route(/\/build-home\/.+\.(js|css)$/, route => {
    const rel = new URL(route.request().url()).pathname.split('/build-home/')[1]
    return route.fulfill({ path: fileURLToPath(new URL('../../priv/static/build-home/' + rel, import.meta.url)), contentType: rel.endsWith('css') ? 'text/css' : 'text/javascript' })
  })
  await page.goto('/build-fixture/live')
  await expect(page.locator('#bd-vp .bd-card').first()).toBeVisible()
})

async function touch(page, type, points) {
  const cdp = page.cdp ??= await page.context().newCDPSession(page)
  await cdp.send('Input.dispatchTouchEvent', { type, touchPoints: points.map(([x, y], id) => ({ x, y, id })) })
}

async function drag(page, from, to, steps = 8) {
  await touch(page, 'touchStart', from)
  for (let i = 1; i <= steps; i++) {
    await touch(page, 'touchMove', from.map(([x, y], n) => [x + (to[n][0] - x) * i / steps, y + (to[n][1] - y) * i / steps]))
  }
  await touch(page, 'touchEnd', [])
}

// A point over the board that really is inside it: bring the board into view, then take the middle
// of its visible part (the fixed bottom nav is excluded) and prove the point hits the board.
async function boardPoint(page) {
  await page.locator('#bd-vp').scrollIntoViewIfNeeded()
  const p = await page.evaluate(() => {
    const r = document.querySelector('#bd-vp').getBoundingClientRect()
    const nav = document.querySelector('.sidenav')
    const bottom = Math.min(r.bottom, nav && getComputedStyle(nav).position === 'fixed' ? nav.getBoundingClientRect().top : innerHeight)
    const top = Math.max(r.top, 56)
    const x = r.left + r.width / 2, y = (top + bottom) / 2
    return { x, y, hit: !!document.elementFromPoint(x, y)?.closest('#bd-vp') }
  })
  expect(p.hit).toBe(true)
  return p
}

const state = page => page.evaluate(() => ({ board: document.querySelector('#bd-vp').scrollTop, page: window.scrollY }))

for (const [width, height] of [[390, 844], [360, 780], [844, 390]]) {
  test(`the section fits below the header at ${width}x${height}`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    const box = await page.locator('#build-root').boundingBox()
    expect(box.height).toBeLessThanOrEqual(height - HEADER + 1)
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  })
}

test('one finger inside the board scrolls the page, not the board', async ({ page }) => {
  const { x, y } = await boardPoint(page)
  const before = await state(page)
  await drag(page, [[x, y]], [[x, y - 200]])
  await expect.poll(async () => (await state(page)).page).toBeGreaterThan(before.page)
  expect((await state(page)).board).toBe(before.board)
})

test('two fingers pan the board and leave the page where it was', async ({ page }) => {
  const { x, y } = await boardPoint(page)
  const before = await state(page)
  await drag(page, [[x - 40, y + 100], [x + 40, y + 100]], [[x - 40, y - 60], [x + 40, y - 60]])
  expect((await state(page)).board).not.toBe(before.board)
  expect((await state(page)).page).toBe(before.page)
})

test('pinching in lowers the zoom percent and pinching out raises it', async ({ page }) => {
  const { x, y } = await boardPoint(page)
  const start = parseInt(await percent(page)) // the board opens at its closest zoom
  await drag(page, [[x - 90, y], [x + 90, y]], [[x - 20, y], [x + 20, y]])
  const lowered = parseInt(await percent(page))
  expect(lowered).toBeLessThan(start)
  await drag(page, [[x - 20, y], [x + 20, y]], [[x - 90, y], [x + 90, y]])
  expect(parseInt(await percent(page))).toBeGreaterThan(lowered)
})
