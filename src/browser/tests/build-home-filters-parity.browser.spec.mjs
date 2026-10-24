import { readFile } from 'node:fs/promises'
import assert from 'node:assert/strict'
import { test, expect } from '@playwright/test'
import { openParityPair, expectDesignParity, PARITY_VIEWPORTS, DESIGN_ROOT } from '../support/design-parity.mjs'
import { estimatePatch } from '../scripts/build-home-now-patch.mjs'
import { prepareFilterCapture, attachFilterRasterDiagnostics } from '../support/build-home-filter-parity.mjs'

const allCells = ['live', 'dense'].flatMap(dataset => PARITY_VIEWPORTS.flatMap(size => ['dark', 'light'].flatMap(theme => ['gruvbox', 'aiur'].map(palette => ({ dataset, ...size, theme, palette })))))
// Routine CI covers every breakpoint and palette; manual sign-off runs the full matrix.
const full = process.env.AIUR_PARITY_FULL === '1'
const cells = full ? allCells : allCells.filter(c =>
  c.dataset === 'live' && (c.viewport.width === 1440 && c.theme === 'dark' && c.palette === 'gruvbox' || c.viewport.width === 1024 && c.theme === 'light' && c.palette === 'aiur' || c.viewport.width === 390 && c.theme === 'dark' && c.palette === 'aiur') ||
  c.dataset === 'dense' && (c.viewport.width === 1440 && c.theme === 'light' && c.palette === 'gruvbox' || c.viewport.width === 390 && c.theme === 'dark' && c.palette === 'gruvbox'))
async function openFiltersPair(browser, cell, options) {
  const root = test.info().project.metadata.filtersRoot
  const source = { newContext: async opts => {
    const context = await browser.newContext(opts), newPage = context.newPage.bind(context)
    context.newPage = async () => {
      const page = await newPage(), goto = page.goto.bind(page)
      page.goto = async (...args) => {
        if (root) await page.route('**/build-home/*.js', async route => route.fulfill({ contentType: 'text/javascript', body: await readFile(root + '/src/priv/static/build-home/' + new URL(route.request().url()).pathname.split('/').at(-1), 'utf8') }))
        await page.route('**/assets/build.js', async route => {
          // Kevin approved Retrying on dec_d92d050693d7f45c; retain the frozen import.
          const reference = estimatePatch(await readFile(DESIGN_ROOT + '/assets/build.js', 'utf8'))
          const anchor = '    command: { label: "Awaiting command", cls: "stuck" }, paused:'
          assert.equal(reference.split(anchor).length, 2)
          const withRetry = reference.replace(anchor, '    retrying: { label: "Retrying", cls: "queued" },\n' + anchor)
          // Main's #5890 and #5856 preserve runtime labels and distinct agent causes.
          const parked = 'parked: { label: "Parked", cls: "idle" },'
          assert.equal(withRetry.split(parked).length, 2)
          const causes = ' "merge-queued": { label: "agent:merge-queued", cls: "queued" }, "ci-red": { label: "agent:ci-red", cls: "stuck" },' +
            ' "body-fix": { label: "agent:body-fix", cls: "stuck" }, "paused-usage-limit": { label: "agent:paused-usage-limit", cls: "idle" },' +
            ' "paused-decision": { label: "agent:paused-decision", cls: "idle" }, "paused-agent": { label: "agent:paused-agent", cls: "idle" },' +
            ' blocked: { label: "agent:blocked", cls: "queued" }, "handed-off": { label: "agent:handed-off", cls: "idle" },' +
            ' usage_limited: { label: "Paused · usage limit", cls: "idle" }, ci_wait: { label: "Waiting for CI", cls: "idle" },'
          await route.fulfill({ contentType: 'text/javascript', body: withRetry.replace(parked, parked + causes) })
        })
        return goto(...args)
      }
      return page
    }
    return context
  } }
  const pair = await openParityPair(source, cell, { ...options, motion: true })
  await prepareFilterCapture(pair)
  return pair
}
async function normalize(page) {
  return page.locator('#bd-filters').evaluate(el => {
    const copy = el.cloneNode(true)
    for (const node of [copy, ...copy.querySelectorAll('*')]) {
      for (const attr of [...node.attributes]) if (attr.name.startsWith('aria-') || attr.name === 'role') node.removeAttribute(attr.name)
      if (node.tagName === 'IMG') node.setAttribute('src', node.getAttribute('src').split('/').at(-1))
    }
    return copy.outerHTML
  })
}
for (const cell of cells) test(`filter parity ${cell.dataset} ${cell.viewport.width} ${cell.theme} ${cell.palette}`, async ({ browser }) => {
  test.setTimeout(180000)
  const pair = await openFiltersPair(browser, cell)
  try {
    const groups = cell.viewport.width === 1024 ? [] : cell.dataset === 'live' ? ['epic', 'feature', 'model', 'tstate', 'astate'] : ['feature']
    for (const key of [null, ...groups]) {
      // The paused clock stops Phoenix's heartbeat; retain the real healthy transport.
      await pair.product.evaluate(() => {
        const socket = window.liveSocket.getSocket()
        if (!socket.isConnected()) throw new Error('Frozen-clock filter parity lost its live transport')
        socket.sendHeartbeat()
      })
      if (key) for (const page of [pair.design, pair.product]) await page.locator(`[data-g="${key}"]`).dispatchEvent('click')
      expect(await normalize(pair.product)).toBe(await normalize(pair.design))
      await expectDesignParity(pair, { name: `toolbar-${key ?? 'closed'}-${cell.dataset}-${cell.viewport.width}-${cell.theme}-${cell.palette}`, region: '.bd-toolbar', preserveAnimations: true })
      if (key) await expectDesignParity(pair, { name: `popover-${key}-${cell.dataset}-${cell.viewport.width}-${cell.theme}-${cell.palette}`, region: '#bd-pop', preserveAnimations: true })
    }
  } finally { await pair.close() }
})

for (const cell of (full ? allCells.filter(c => c.dataset === 'live') : cells.filter(c => c.dataset === 'live' && c.viewport.width === 1440))) for (const query of ['model=claude&tstate=merged,failed&astate=active', 'epic=docs']) test(`selected viewport ${cell.viewport.width} ${cell.theme} ${cell.palette} ${query}`, async ({ browser }) => {
  test.setTimeout(180000)
  const pair = await openFiltersPair(browser, cell, { query })
  try {
    for (const page of [pair.design, pair.product]) {
      await expect(page.locator('.bd-fg')).toHaveCount(5)
      if (query.startsWith('model=')) await page.locator('[data-g="tstate"]').dispatchEvent('click')
    }
    expect(await normalize(pair.product)).toBe(await normalize(pair.design))
    expect(await pair.product.locator('#bd-usage .ax-rs').allTextContents()).toEqual(await pair.design.locator('#bd-usage .ax-rs').allTextContents())
    await expectDesignParity(pair, { name: `viewport-${cell.viewport.width}-${cell.theme}-${cell.palette}-${query.split('=')[0]}`, region: '#build-root', preserveAnimations: true })
  } catch (error) {
    await attachFilterRasterDiagnostics(pair, test.info())
    throw error
  } finally { await pair.close() }
})
