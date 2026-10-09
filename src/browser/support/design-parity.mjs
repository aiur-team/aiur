/**
 * Openers and captures share one clock, matrix, and allowlist contract.
 * Visual consumers: openParityPair(browser, cell, { dataset }), then
 * expectDesignParity(pair, { name, region: '.bd-now' }); always close the pair.
 * Both references render live; use playwright.design-parity.config.mjs.
 * Approved differences require Kevin's written approval in the shared allowlist.
 * Pending entries are reported, not signed off; C12-T08 owns the sign-off gate.
 */
import { expect, test } from '@playwright/test'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { openVisualRoute } from './visual.mjs'
import { dashboardCredentials } from '../tests/support/layout-worker.mjs'
import { DESIGN_ROOT, DESIGN_ORIGIN, FIXTURE_META, verifyDesignSource, routeDesign, guardNetwork, seedRandom, waitParityReady, assertCellState, checkPage } from './design-parity-environment.mjs'
import { loadAllowlist, applyAllowlist } from './design-parity-allowlist.mjs'
export { DESIGN_ROOT, FIXTURE_META, verifyDesignSource, routeDesign, guardNetwork, seedRandom, waitParityReady, assertCellState, checkPage, loadAllowlist, applyAllowlist }

// CI run 37775013284: identical logo renders differ by up to 8/255 per channel.
// Every pixel above that colour threshold must match.
export const PARITY_FLOOR = 0
export const PARITY_THRESHOLD = 0.04
export const PARITY_VIEWPORTS = [
  { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 },
  { viewport: { width: 1024, height: 768 }, deviceScaleFactor: 1 },
  { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true }
]
export const PARITY_MATRIX = FIXTURE_META.datasets.flatMap(dataset => PARITY_VIEWPORTS.flatMap(viewport => ['dark', 'light'].flatMap(theme => ['gruvbox', 'aiur'].map(palette => ({ ...viewport, theme, palette, dataset })))))
PARITY_MATRIX.push({ ...PARITY_VIEWPORTS[0], theme: 'dark', palette: 'gruvbox', dataset: 'live', reducedMotion: 'reduce' })

export function parityContextOptions(cell) {
  const { viewport, deviceScaleFactor = 1, isMobile = false, hasTouch = false } = cell
  return { viewport, deviceScaleFactor, isMobile, hasTouch, timezoneId: FIXTURE_META.tz, locale: 'en-US', colorScheme: cell.theme, reducedMotion: cell.reducedMotion ?? 'no-preference', serviceWorkers: 'block' }
}

function routeQuery(route, { query = '', ticket }, dataset) {
  const url = new URL(route, DESIGN_ORIGIN)
  for (const [key, value] of new URLSearchParams(query.replace(/^\?/, ''))) url.searchParams.set(key, value)
  if (dataset) url.searchParams.set('example', dataset)
  if (ticket) url.searchParams.set('ticket', ticket)
  return `${url.pathname}${url.search}`
}

async function prepare(page, phase, side, motion = false, pauseAtSelector) {
  if (motion || (phase === 'loading' && side === 'design')) {
    await page.clock.install({ time: FIXTURE_META.now - 1000 })
    await page.clock.pauseAt(FIXTURE_META.now)
  }
  if (!motion) await page.clock.setFixedTime(FIXTURE_META.now)
  await seedRandom(page)
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

async function refuseLiveTicket(dataset, ticket) {
  if (!ticket || dataset === 'offline') return
  const fixture = JSON.parse(await readFile(new URL(`../../test/fixtures/build_home/${dataset}.json`, import.meta.url), 'utf8'))
  if (fixture.data.now.some(t => t.id === ticket && t.agent?.state === 'active')) throw new Error(`ticket ${ticket} runs the design's mock live stream`)
}

export async function openDesign(page, cell, opts = {}) {
  await page.bringToFront()
  const { dataset = cell.dataset ?? 'live', phase = 'board' } = opts
  if (!FIXTURE_META.datasets.includes(dataset)) throw new Error(`unknown design dataset ${dataset}`)
  if (!['board', 'loading', 'shell'].includes(phase)) throw new Error(`unknown parity phase ${phase}`)
  await verifyDesignSource()
  const route = routeQuery('/Aiur%20Dashboard.html', opts, dataset)
  await refuseLiveTicket(dataset, new URL(route, DESIGN_ORIGIN).searchParams.get('ticket'))
  await prepare(page, phase, 'design', opts.motion, opts.pauseAtSelector)
  await routeDesign(page)
  await page.goto(`${DESIGN_ORIGIN}/blank`)
  await page.evaluate(({ theme, palette }) => {
    localStorage.setItem('aiur-theme', theme)
    localStorage.setItem('aiur-palette', palette)
    localStorage.setItem('aiur-nav-collapsed', '0')
  }, cell)
  await page.goto(`${DESIGN_ORIGIN}${route}`)
  if (!await page.locator('.panel[data-panel="build"].is-active').count()) await page.evaluate(() => window.AiurHost.switchTab('build'))
  await waitParityReady(page, phase, 'design', opts.motion, opts.pauseAtSelector)
  if (opts.motion) {
    const phase = await page.evaluate(() => performance.now() % 16)
    if (phase) await page.clock.runFor(16 - phase)
    await page.clock.setSystemTime(FIXTURE_META.now)
  }
  await assertCellState(page, cell)
  return page
}

// This is the sole owner of C3-T01's dataset-switch URL.
export function productUrl(dataset) { return `/build-fixture/${encodeURIComponent(dataset)}` }
export async function selectProductDataset(page, dataset) {
  await page.context().setHTTPCredentials(dashboardCredentials)
  const response = await page.request.get(productUrl(dataset))
  if (response.status() !== 200) throw new Error(`product target unavailable: GET ${productUrl(dataset)} → ${response.status()}`)
}

export async function openProduct(page, cell, opts = {}) {
  const { dataset = cell.dataset ?? 'live', phase = 'board', productRoute = '/build' } = opts
  if (!['board', 'loading', 'shell'].includes(phase)) throw new Error(`unknown parity phase ${phase}`)
  await prepare(page, phase, 'product', opts.motion, opts.pauseAtSelector)
  const origin = new URL(test.info().project.use.baseURL).origin
  await guardNetwork(page, [origin])
  await selectProductDataset(page, phase === 'loading' ? 'hold' : dataset)
  const route = new URL(routeQuery(productRoute, opts), DESIGN_ORIGIN)
  const designTicket = route.searchParams.get('ticket')
  if (designTicket) route.searchParams.set('ticket', FIXTURE_META.ids?.[designTicket] ?? designTicket)
  try { await openVisualRoute(page, { theme: cell.theme, palette: cell.palette, route: `${route.pathname}${route.search}`, mode: 'writable' }) }
  catch (error) { checkPage(page); throw new Error(`product target unavailable: socket not connected or route unavailable: ${error.message}`) }
  if (opts.productPending || (opts.productAnchor && !await page.locator(opts.productAnchor).count())) { checkPage(page); return page }
  await waitParityReady(page, phase, 'product', opts.motion, opts.pauseAtSelector)
  if (opts.motion) {
    const phase = await page.evaluate(() => performance.now() % 16)
    if (phase) await page.clock.runFor(16 - phase)
    await page.clock.setSystemTime(FIXTURE_META.now)
  }
  await assertCellState(page, cell)
  return page
}

export async function openParityPair(browser, cell, opts = {}) {
  const options = parityContextOptions(cell)
  const designContext = await browser.newContext(options)
  const productContext = await browser.newContext({ ...options, baseURL: test.info().project.use.baseURL })
  const pair = { design: await designContext.newPage(), product: await productContext.newPage(), cell: { ...cell, dataset: opts.dataset ?? cell.dataset ?? 'live' },
    close: async () => { await designContext.close(); await productContext.close() } }
  try {
    pair.allowlist = await loadAllowlist()
    await openDesign(pair.design, pair.cell, opts)
    await openProduct(pair.product, pair.cell, opts)
    return pair
  } catch (error) {
    // Retain honest evidence even when the product route is not yet implemented.
    try { await capturePairEvidence(pair) }
    catch (evidenceError) { throw new AggregateError([error, evidenceError], error.message) }
    finally { await pair.close() }
    throw error
  }
}

export async function captureStable(target, opts, page) {
  let previous
  for (let attempt = 0; attempt < 10; attempt++) {
    // Locator screenshots scroll into view, disturbing motion under measurement.
    let png
    if (page) {
      const box = await target.boundingBox()
      if (!box) throw new Error('unreachable screenshot region')
      const offset = await page.evaluate(() => ({ x: scrollX, y: scrollY }))
      png = await page.screenshot({ ...opts, fullPage: true, clip: { ...box, x: box.x + offset.x, y: box.y + offset.y } })
    } else png = await target.screenshot(opts)
    if (previous?.equals(png)) return png
    previous = png
    await delay(100)
  }
  throw new Error('design did not settle after 10 captures')
}

async function one(page, region, side) {
  const target = page.locator(region)
  const count = await target.count()
  if (count !== 1) throw new Error(`region ${count ? 'not unique' : 'missing'} on ${side}: ${region}`)
  return target
}

export async function capturePairEvidence(pair) {
  for (const side of ['design', 'product']) {
    if (!pair[side].isClosed()) await pair[side].screenshot({ path: test.info().outputPath(`${side}.png`), animations: 'disabled', caret: 'hide', scale: 'device' })
  }
}

export async function expectDesignParity(pair, { name, region, fullPage = false, preserveAnimations = false }) {
  const time = preserveAnimations ? await pair.design.evaluate(() => Date.now()) : FIXTURE_META.now
  await assertCellState(pair.design, pair.cell, time)
  await assertCellState(pair.product, pair.cell, time)
  await compareParityPixels(pair, { name, region, fullPage, preserveAnimations })
}

export async function compareParityPixels(pair, { name, region, fullPage = false, preserveAnimations = false }) {
  const { designMask, productMask } = await applyAllowlist(pair, pair.cell)
  // Hold screenshot animation state once, avoiding cancel/resume repaint drift.
  if (!preserveAnimations) for (const page of [pair.design, pair.product]) await page.evaluate(() => document.getAnimations().forEach(a => Number.isFinite(a.effect?.getComputedTiming().endTime) ? a.finish() : a.cancel()))
  const design = region ? await one(pair.design, region, 'design') : pair.design
  const product = region ? await one(pair.product, region, 'product') : pair.product
  const opts = { animations: preserveAnimations ? 'allow' : 'disabled', caret: 'hide', scale: 'device', maskColor: '#ff00ff', ...(region ? {} : { fullPage }) }
  await pair.design.bringToFront()
  const png = await captureStable(design, { ...opts, mask: designMask }, preserveAnimations && region ? pair.design : undefined)
  await pair.product.bringToFront()
  checkPage(pair.design)
  checkPage(pair.product)
  const file = test.info().snapshotPath(`${name}.png`, { kind: 'screenshot' })
  await mkdir(path.dirname(file), { recursive: true })
  await writeFile(file, png)
  if (preserveAnimations && region) {
    const actual = await captureStable(product, { ...opts, mask: productMask }, pair.product)
    expect(actual).toMatchSnapshot(`${name}.png`, { threshold: PARITY_THRESHOLD, maxDiffPixels: PARITY_FLOOR })
  } else await expect(product).toHaveScreenshot(`${name}.png`, { ...opts, mask: productMask, threshold: PARITY_THRESHOLD, maxDiffPixels: PARITY_FLOOR })
  checkPage(pair.design)
  checkPage(pair.product)
}
