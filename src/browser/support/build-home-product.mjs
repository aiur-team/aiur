/** Shared setup for Build home browser behavior and rendering checks. */
import { test } from '@playwright/test'
import { setTimeout as delay } from 'node:timers/promises'
import { openVisualRoute } from './visual.mjs'
import { dashboardCredentials } from '../tests/support/layout-worker.mjs'
import { BUILD_FIXTURE_META, guardNetwork, seedProductRandom, waitProductReady, assertProductEnvironment, checkProductPage } from './build-home-test-environment.mjs'
export { BUILD_FIXTURE_META }

export const PRODUCT_VIEWPORTS = [
  { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 },
  { viewport: { width: 1024, height: 768 }, deviceScaleFactor: 1 },
  { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true }
]

export function productContextOptions(cell) {
  const { viewport, deviceScaleFactor = 1, isMobile = false, hasTouch = false } = cell
  return { viewport, deviceScaleFactor, isMobile, hasTouch, timezoneId: BUILD_FIXTURE_META.tz, locale: 'en-US', colorScheme: cell.theme, reducedMotion: cell.reducedMotion ?? 'no-preference', serviceWorkers: 'block' }
}

function routeQuery(route, { query = '', ticket }) {
  const url = new URL(route, 'http://fixture.invalid')
  for (const [key, value] of new URLSearchParams(query.replace(/^\?/, ''))) url.searchParams.set(key, value)
  if (ticket) url.searchParams.set('ticket', ticket)
  return `${url.pathname}${url.search}`
}

async function prepare(page, phase, motion = false, pauseAtSelector) {
  if (motion) {
    await page.clock.install({ time: BUILD_FIXTURE_META.now - 1000 })
    await page.clock.pauseAt(BUILD_FIXTURE_META.now)
  }
  if (!motion) await page.clock.setFixedTime(BUILD_FIXTURE_META.now)
  await seedProductRandom(page)
  if (pauseAtSelector) await page.addInitScript(selector => {
    // URL-opened modals can finish while readiness waits; pause at their first style flush.
    const observer = new MutationObserver(() => {
      const root = document.querySelector(selector)
      if (!root) return
      getComputedStyle(root).opacity
      const animations = root.getAnimations({ subtree: true })
      if (!animations.length) return
      animations.forEach(animation => { animation.pause(); animation.currentTime = 0 })
      observer.disconnect()
    })
    observer.observe(document, { childList: true, subtree: true, attributes: true })
  }, pauseAtSelector)
}

// This is the sole owner of C3-T01's dataset-switch URL.
export function productUrl(dataset) { return `/build-fixture/${encodeURIComponent(dataset)}` }
export async function selectProductDataset(page, dataset) {
  await page.context().setHTTPCredentials(dashboardCredentials)
  const response = await page.request.get(productUrl(dataset))
  if (response.status() !== 200) throw new Error(`product target unavailable: GET ${productUrl(dataset)} → ${response.status()}`)
}

export async function openProduct(page, cell, opts = {}) {
  const { dataset = cell.dataset ?? 'live', phase = 'board', productRoute = '/' } = opts
  if (!['board', 'loading', 'shell'].includes(phase)) throw new Error(`unknown product phase ${phase}`)
  await prepare(page, phase, opts.motion, opts.pauseAtSelector)
  const origin = new URL(test.info().project.use.baseURL).origin
  await guardNetwork(page, [origin])
  await selectProductDataset(page, phase === 'loading' ? 'hold' : dataset)
  const route = new URL(routeQuery(productRoute, opts), 'http://fixture.invalid')
  const ticket = route.searchParams.get('ticket')
  if (ticket) route.searchParams.set('ticket', BUILD_FIXTURE_META.ids?.[ticket] ?? ticket)
  try { await openVisualRoute(page, { theme: cell.theme, palette: cell.palette, route: `${route.pathname}${route.search}`, mode: 'writable' }) }
  catch (error) { checkProductPage(page); throw new Error(`product target unavailable: socket not connected or route unavailable: ${error.message}`) }
  if (opts.productPending || (opts.productAnchor && !await page.locator(opts.productAnchor).count())) { checkProductPage(page); return page }
  await waitProductReady(page, phase, opts.motion)
  if (opts.motion) {
    const phase = await page.evaluate(() => performance.now() % 16)
    if (phase) await page.clock.runFor(16 - phase)
    await page.clock.setSystemTime(BUILD_FIXTURE_META.now)
  }
  await assertProductEnvironment(page, cell)
  return page
}

export async function productScreenshot(target, opts, page, viewportClip = false) {
  let previous
  const screenshotOptions = {
    ...opts,
    // Keep the native track and its layout width, but remove the thumb's
    // scroll-position-dependent paint from consecutive captures.
    style: `${opts.style ?? ''}\n* { scrollbar-color: transparent transparent !important; }\n*::-webkit-scrollbar-thumb { background: transparent !important; }`
  }
  for (let attempt = 0; attempt < 10; attempt++) {
    // Locator screenshots scroll into view, disturbing motion under measurement.
    const shoot = async () => {
      if (!page) return target.screenshot(screenshotOptions)
      const box = await target.boundingBox()
      if (!box) throw new Error('unreachable screenshot region')
      const offset = await page.evaluate(() => ({ x: scrollX, y: scrollY }))
      const viewport = viewportClip ? page.viewportSize() : null
      // Expanding an already-visible clip fires responsive relayouts and clears locks.
      const visible = viewport && !offset.x && !offset.y && box.x >= 0 && box.y >= 0
        && box.x + box.width <= viewport.width && box.y + box.height <= viewport.height
      return page.screenshot({ ...screenshotOptions, fullPage: viewportClip ? !visible : true, clip: { ...box, x: box.x + offset.x, y: box.y + offset.y } })
    }
    let png
    try { png = await shoot() }
    catch (error) {
      if (!error.message.includes('Protocol error (Page.captureScreenshot): Unable to capture screenshot')) throw error
      // Chromium can briefly refuse a capture during layout; retry once without spending a settle sample.
      console.warn(`productScreenshot: retrying capture attempt ${attempt + 1} of 10: ${error.message}`)
      await delay(100)
      png = await shoot()
    }
    if (previous?.equals(png)) return png
    previous = png
    await delay(100)
  }
  throw new Error('product capture did not settle after 10 attempts')
}
