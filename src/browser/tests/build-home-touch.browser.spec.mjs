import { fileURLToPath } from 'node:url'
import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

// #7686: on a phone one finger over the board scrolls the page, two fingers pan the board,
// a pinch changes the same zoom percent the +/- control shows, and the section fits the screen.
test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } })

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

for (const [width, height] of [[390, 844], [360, 780], [430, 932], [844, 390]]) {
  test(`the section fills the space between header and bottom nav at ${width}x${height}`, async ({ page }) => {
    await page.setViewportSize({ width, height })
    await page.evaluate(() => document.querySelector('#build-root .bd-board').scrollIntoView({ behavior: 'instant' }))
    const m = await page.evaluate(() => {
      const r = document.querySelector('#build-root .bd-board').getBoundingClientRect()
      const vp = document.querySelector('#bd-vp').getBoundingClientRect()
      const nav = document.querySelector('.sidenav')
      const navTop = nav && getComputedStyle(nav).position === 'fixed' ? nav.getBoundingClientRect().top : innerHeight
      const live = document.querySelector('#bd-vp .bd-live')?.getBoundingClientRect()
      return { top: r.top, bottom: r.bottom, headerBottom: document.querySelector('.ax-top').getBoundingClientRect().bottom, navTop,
        vp: vp.height, inner: innerHeight, live: live && { top: live.top, vpTop: vp.top }, overflow: document.documentElement.scrollWidth > innerWidth }
    })
    expect(Math.abs(m.top - m.headerBottom)).toBeLessThanOrEqual(2)
    expect(Math.abs(m.bottom - m.navTop)).toBeLessThanOrEqual(2)
    if (height > width) expect(m.vp).toBeGreaterThanOrEqual(m.inner * 0.55)
    if (m.live) expect(m.live.top).toBeGreaterThanOrEqual(m.live.vpTop - 1)
    expect(m.overflow).toBe(false)
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

// #7774's fixed Executor footer bar sits over the page bottom above the phone nav; the board must leave room for it.
// Height, not position: the fixture page's end clamps the scroll a few px short of aligning the board top.
test('the section height leaves room for a fixed Executor footer bar', async ({ page }) => {
  const h = await page.evaluate(() => {
    const nav = document.querySelector('.sidenav').getBoundingClientRect().height
    const top = document.querySelector('.topnav, header, .app-header')?.getBoundingClientRect().height ?? 56
    document.body.insertAdjacentHTML('beforeend', `<aside class="executor-footer" style="position:fixed;left:0;right:0;bottom:${nav}px"><div class="executor-footer__bar" style="height:44px"></div></aside>`)
    window.dispatchEvent(new Event('resize'))
    return { board: document.querySelector('#build-root .bd-board').getBoundingClientRect().height, want: innerHeight - parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--app-top')) - nav - 44 }
  })
  expect(Math.abs(h.board - h.want)).toBeLessThanOrEqual(1)
})
