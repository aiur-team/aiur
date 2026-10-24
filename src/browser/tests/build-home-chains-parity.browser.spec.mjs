import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { openParityPair, expectDesignParity, PARITY_VIEWPORTS } from '../support/design-parity.mjs'
import { settleAnimations } from './support/browser-helpers.mjs'
import { prepareChainCanvas, prepareChainParity, largestRoot, hoverRoot, assertChainPaint, fitState, installFitObserver, waitForFit, treeRecord } from './support/build-home-chains-parity.mjs'

test.setTimeout(120_000)
const full = process.env.AIUR_PARITY_FULL === '1'
const cells = PARITY_VIEWPORTS.filter(v => full || v.viewport.width === 1440).flatMap(v => ['dark', 'light'].flatMap(theme => ['gruvbox', 'aiur'].map(palette => ({ dataset: 'live', ...v, theme, palette }))))

async function loadHistory(pair) {
  const snapshot = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/' + pair.cell.dataset + '.json', import.meta.url), 'utf8'))
  const expected = snapshot.sections.hist.map(ticket => ticket.id).sort()
  for (const page of [pair.design, pair.product]) {
    await page.bringToFront()
    await page.locator('[data-span="30"]').click()
    const header = page.locator('#bd-sec-hist .bd-sech'), viewport = page.locator('#bd-vp')
    // The mock unlocks on every history relayout. Compare identical loaded data;
    // B6 separately exercises Fit while real history pages are still arriving.
    for (let pages = 0; pages < 100; pages++) {
      const before = await header.textContent()
      if (/\ball [\d,]+ from\b/.test(before)) break
      await viewport.evaluate(el => { el.scrollTop = 0 })
      await expect.poll(() => header.textContent()).not.toBe(before)
    }
    await expect(header).toContainText('all ' + expected.length.toLocaleString('en-US') + ' from ')
    await page.locator('[data-span="1"]').click()
    await expect(page.locator('.bd-zv')).toHaveText('100%')
    if (page === pair.product) {
      await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'idle')
      expect(await page.evaluate(async () => (await import('/build-home/state.js')).ctx.D.hist.map(ticket => ticket.id).sort())).toEqual(expected)
    }
  }
}

async function installReferenceFit(page) {
  await page.evaluate(() => {
    const frame = window.requestAnimationFrame
    let complete
    window.referenceFitDone = new Promise(resolve => { complete = resolve })
    window.referenceFitObserved = false
    window.referenceFitRestore = () => { window.requestAnimationFrame = frame }
    window.requestAnimationFrame = callback => frame(now => {
      // Observe the original callback at its native frame; never delay or replay it.
      const fit = callback.toString().includes('lockTree(id)') && !callback.toString().includes('requestAnimationFrame')
      callback(now)
      if (fit) { window.referenceFitObserved = true; complete() }
    })
  })
}

for (const cell of cells) test(`P1–P4 chain pixel parity ${cell.viewport.width} ${cell.theme} ${cell.palette}`, {
  tag: ['@full-parity', ...(cell.viewport.width === 1440 ? ['@routine-parity'] : [])],
}, async ({ browser }) => {
  test.setTimeout(cell.viewport.width === 390 ? 240_000 : 120_000)
  const failures = []
  // Keep independent captures when one phase differs, then fail with every actual discrepancy.
  const check = async (name, action) => { try { await test.step(name, action) } catch (error) { failures.push(error) } }
  const pixels = (pair, name, region) => check(name, async () => {
    await prepareChainParity(pair) // Fit replaces the band's ETA element.
    await expectDesignParity(pair, { name, region, preserveAnimations: pair.cell.viewport.width === 390, viewportClip: true })
  })
  const pair = await openParityPair(browser, cell, { query: '?trees=1' })
  const root = await largestRoot(pair.product, 'live')
  try {
    await loadHistory(pair)
    await prepareChainCanvas(pair)
    await prepareChainParity(pair)
    for (const page of [pair.design, pair.product]) await hoverRoot(page, root, page === pair.product)
    await check('P1 hover classes and tab position', () => assertChainPaint(pair, root, false))
    await pixels(pair, 'P1-chain-hover', '#bd-vp')
    for (const page of [pair.design, pair.product]) await page.locator('[data-lt="lock"]').click()
    await check('P2 lock classes and tab position', () => assertChainPaint(pair, root, true))
    await pixels(pair, 'P2-chain-tab', '.bd-lt')
    await pixels(pair, 'P2-chain-lock', '#bd-vp')
    for (const page of [pair.design, pair.product]) await expect(page.locator('.bd-lt.locked.show')).toHaveCount(1)
    // P4 starts from the locked P2 state; Fit must not change its backdrop inputs.
    for (const page of [pair.design, pair.product]) {
      await page.locator('[data-lt="tree"]').click()
      await settleAnimations(page, '#bd-tree')
    }
    await check('P4 node positions and scale', async () => expect(await treeRecord(pair.product)).toEqual(await treeRecord(pair.design)))
    await pixels(pair, 'P4-whole-tree', '#bd-tree')
    await expect(pair.product.getByRole('dialog', { name: 'Dependency tree' })).toBeVisible()
    for (const page of [pair.design, pair.product]) {
      await page.keyboard.press('Escape')
      await expect(page.locator('#bd-tree')).toBeHidden()
    }
    await installReferenceFit(pair.design)
    await installFitObserver(pair.product)
    for (const page of [pair.design, pair.product]) {
      await page.bringToFront()
      await page.locator('[data-lt="fit"]').click()
      if (page === pair.design) {
        await expect.poll(() => page.evaluate(() => window.referenceFitObserved), 'observe the original reference Fit callback').toBe(true)
        await page.evaluate(() => window.referenceFitDone)
        await expect(page).toHaveURL(/[?&]span=/)
        await expect(page.locator('.bd-lt.locked.show'), 'reference Fit completes after history relayouts').toHaveCount(1, { timeout: 30_000 })
      } else await waitForFit(page)
      await expect(page.locator('.bd-lt.locked.show'), `P3 ${page === pair.design ? 'design' : 'product'} Fit retains its locked tab`).toHaveCount(1)
    }
    await prepareChainParity(pair) // Observe Fit geometry after both native scroll sequences settle.
    await expect(pair.design.locator('.bd-lt.locked.show')).toHaveCount(1)
    const [designFit, productFit] = await Promise.all([fitState(pair.design), fitState(pair.product)])
    await check('P3 Fit URL', async () => expect(productFit.url).toEqual(designFit.url))
    await check('P3 zoom label', async () => { expect(productFit.zoom).toBeTruthy(); expect(productFit.zoom).toEqual(designFit.zoom) })
    await check('P3 scroll', async () => expect(Math.abs(productFit.scroll - designFit.scroll)).toBeLessThanOrEqual(1))
    // Kevin approved settled arrows and the 1440 tab x (#3152, 2026-10-21).
    // Keep native design execution and compare every tab pixel at a common x.
    const fitStyles = []
    if (cell.viewport.width === 1440) {
      const entry = pair.allowlist.find(entry => entry.id === 'chain-fit-settled')
      expect(entry.approval.status).toBe('approved')
      expect(entry.spec).toBe('build-home-chains-parity.browser.spec.mjs')
      const positioned = await pair.product.evaluate(id => {
        const card = document.querySelector(`.bd-card[data-id="${id}"]`).getBoundingClientRect()
        const content = document.querySelector('#bd-content').getBoundingClientRect()
        return { actual: parseFloat(document.querySelector('.bd-lt').style.left), expected: card.right - content.left - 1 }
      }, root.id)
      expect(positioned.actual).toBeCloseTo(positioned.expected, 1)
      const left = await pair.design.locator('.bd-lt').evaluate(el => el.style.left)
      fitStyles.push(await pair.product.addStyleTag({ content: `.bd-lt { left: ${left} !important; }` }))
    }
    if (cell.viewport.width > 390) {
      expect(pair.allowlist.find(entry => entry.id === 'chain-fit-settled').approval.status).toBe('approved')
      // Capture-only approved paint exclusion: never reorder/replay reference code.
      for (const page of [pair.design, pair.product]) fitStyles.push(await page.addStyleTag({
        content: '.bd-edges .bd-e, .bd-edges .bd-ea { visibility: hidden !important; }',
      }))
    }
    try { await pixels(pair, 'P3-chain-fit', '.bd-vpw') }
    finally { for (const style of fitStyles) await style.evaluate(el => el.remove()) }
  } finally {
    if (!pair.design.isClosed()) await pair.design.evaluate(() => window.referenceFitRestore?.())
    await pair.close()
  }
  // One narrow-cell case proves continuation-row wrapping; P1–P4 above cover every cell.
  if (cell.viewport.width === 390 && cell.theme === 'dark' && cell.palette === 'gruvbox') {
    const dense = await openParityPair(browser, { ...cell, dataset: 'dense' }, { query: '?trees=1' })
    const denseRoot = await largestRoot(dense.product, 'dense', 'plan')
    try {
      await loadHistory(dense)
      await prepareChainCanvas(dense)
      await prepareChainParity(dense)
      for (const page of [dense.design, dense.product]) {
        await hoverRoot(page, denseRoot, page === dense.product)
        await page.locator('[data-lt="lock"]').click()
        await page.locator('[data-lt="tree"]').click()
        await settleAnimations(page, '#bd-tree')
      }
      await check('P4 dense wrap rows and scale', async () => {
        const design = await treeRecord(dense.design), product = await treeRecord(dense.product)
        expect(product).toEqual(design)
        const levels = Number(design.header.match(/· (\d+) levels/)[1])
        expect(new Set(design.nodes.map(node => node.pos[1])).size).toBeGreaterThan(levels)
      })
      await pixels(dense, 'P4-dense-wrap', '#bd-tree')
    } finally { await dense.close() }
  }
  if (failures.length) throw new AggregateError(failures, failures.map(error => error.message).join('\n'))
})
