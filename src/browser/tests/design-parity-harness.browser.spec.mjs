import { test, expect } from '@playwright/test'
import { mkdtemp, cp, appendFile, writeFile, rm, symlink, mkdir } from 'node:fs/promises'
import path from 'node:path'
import { tmpdir } from 'node:os'
import { setTimeout as delay } from 'node:timers/promises'
import { PARITY_VIEWPORTS, DESIGN_ROOT, FIXTURE_META, parityContextOptions, openDesign, openProduct, expectDesignParity, compareParityPixels, assertCellState, waitParityReady, guardNetwork, checkPage, captureStable, loadAllowlist, applyAllowlist, verifyDesignSource } from '../support/design-parity.mjs'
import { resolveDesignPath, routeDesign } from '../support/design-parity-environment.mjs'

const cell = { ...PARITY_VIEWPORTS[0], theme: 'dark', palette: 'gruvbox', dataset: 'live' }
let contexts
let scratch

test.beforeEach(async () => { contexts = []; scratch = await mkdtemp(path.join(tmpdir(), 'parity-3110-')) })
test.afterEach(async () => { for (const context of contexts) await context.close(); await rm(scratch, { recursive: true, force: true }) })
async function pageFor(browser, selected = cell, overrides = {}) {
  const context = await browser.newContext({ ...parityContextOptions(selected), ...overrides })
  contexts.push(context)
  return context.newPage()
}
async function designPair(browser, selected = cell, opts = {}) {
  const design = await pageFor(browser, selected)
  const product = await pageFor(browser, selected)
  await openDesign(design, selected, opts)
  await openDesign(product, selected, opts)
  return { design, product, cell: selected, allowlist: [] }
}
async function pixelFailure(pair, options, compare = expectDesignParity) {
  let error
  try { await compare(pair, options) } catch (e) { error = e }
  if (error && !/pixels.*different/.test(error.message)) throw error
  expect(error?.message).toMatch(/pixels.*different/)
}
async function allowlistFile(entries) {
  const file = path.join(scratch, 'allowlist.json')
  await writeFile(file, JSON.stringify(entries))
  return file
}
const entry = { id: 'demo', kind: 'design-removal', selector: '.bd-exl', reason: 'test difference', approval: { status: 'pending-sign-off', ref: 'test approval' } }

const calibration = PARITY_VIEWPORTS.flatMap(v => ['dark', 'light'].map(theme => ({ ...cell, ...v, theme })))
calibration.push({ ...cell, palette: 'aiur' }, { ...cell, dataset: 'dense' })
for (const selected of calibration) {
  test(`calibration: design equals design ${selected.viewport.width} ${selected.theme} ${selected.palette} ${selected.dataset}`, async ({ browser }) => {
    await expectDesignParity(await designPair(browser, selected), { name: `calibration-${selected.viewport.width}-${selected.theme}-${selected.palette}-${selected.dataset}` })
  })
}
test('calibration: design equals design loading', async ({ browser }) => {
  await expectDesignParity(await designPair(browser, cell, { phase: 'loading' }), { name: 'loading' })
})
for (const region of [undefined, '.bd-now']) {
  test(`mutation: ${region ?? '.bd-card'} catches +1px padding`, async ({ browser }) => {
    const pair = await designPair(browser)
    const selector = region ? '.bd-now .bd-in' : '.bd-card'
    const padding = await pair.product.locator(selector).first().evaluate(e => parseFloat(getComputedStyle(e).paddingLeft))
    await pair.product.addStyleTag({ content: `${selector} { padding-left: ${padding + 1}px !important; }` })
    await pixelFailure(pair, { name: 'padding', region })
  })
}
for (const size of [1, 10]) {
  test(`mutation: catches ${size}x${size} red pixels`, async ({ browser }) => {
    const pair = await designPair(browser)
    await pair.product.evaluate(size => {
      const change = document.createElement('div')
      change.style.cssText = `position:fixed;left:700px;top:450px;width:${size}px;height:${size}px;background:red;z-index:2147483647`
      document.body.append(change)
    }, size)
    await pixelFailure(pair, { name: `red-${size}` })
  })
}
test('mutation: catches changed API count text', async ({ browser }) => {
  const pair = await designPair(browser)
  await pair.product.getByText('2 APIs', { exact: true }).evaluate(e => { e.textContent = '3 APIs' })
  await pixelFailure(pair, { name: 'api-count' })
})
test('mutation: palette swap fails', async ({ browser }) => {
  const other = { ...cell, palette: 'aiur' }
  const pair = { design: await pageFor(browser), product: await pageFor(browser, other), cell, allowlist: [] }
  await openDesign(pair.design, cell)
  await openDesign(pair.product, other)
  // Exercise the pixel comparator independently of the palette guard.
  await pixelFailure(pair, { name: 'palette' }, compareParityPixels)
})
for (const [name, mutate, message] of [
  ['clock guard', async p => p.clock.setFixedTime(FIXTURE_META.now + 1), /clock not frozen/],
  ['theme guard', async p => p.evaluate(() => { document.documentElement.dataset.theme = 'light' }), /theme not applied/],
  ['palette guard', async p => p.evaluate(() => { document.documentElement.dataset.palette = 'aiur' }), /palette not applied/]
]) {
  test(name, async ({ browser }) => {
    const page = await pageFor(browser)
    await openDesign(page, cell)
    await mutate(page)
    await expect(assertCellState(page, cell)).rejects.toThrow(message)
  })
}
test('time zone guard', async ({ browser }) => {
  const page = await pageFor(browser, cell, { timezoneId: 'UTC' })
  await expect(openDesign(page, cell)).rejects.toThrow(/time zone UTC, expected America\/Los_Angeles/)
})
for (const missing of ['font file', 'stylesheet']) {
  test(`font guard: missing ${missing}`, async ({ browser }) => {
    const page = await pageFor(browser)
    await page.route(missing === 'font file' ? '**/SpaceGrotesk-Variable.woff2' : 'https://fonts.googleapis.com/**', route => route.fulfill({ status: missing === 'font file' ? 404 : 200, contentType: 'text/css', body: '' }))
    await expect(openDesign(page, cell)).rejects.toThrow(/font not loaded:/)
  })
}
test('network guard', async ({ browser }) => {
  const page = await pageFor(browser)
  await guardNetwork(page, ['http://design.parity.invalid'])
  await page.setContent('<script src="https://example.com/x.js"></script>')
  expect(() => checkPage(page)).toThrow(/network request refused: https:\/\/example.com\/x.js/)
})
test('product target missing', async ({ browser, baseURL }) => {
  const page = await pageFor(browser, cell, { baseURL })
  await expect(openProduct(page, cell, { dataset: '__missing__' })).rejects.toThrow(/product target unavailable: GET \/build-fixture\/__missing__ → 404/)
})
test('ready guard', async ({ browser }) => {
  const page = await pageFor(browser)
  await openDesign(page, cell, { phase: 'loading' })
  await expect(waitParityReady(page, 'board', 'product')).rejects.toThrow(/product not ready: .bd-loading still present/)
})
for (const marker of ['mounted', 'paging']) {
  test(`product ready guard: ${marker}`, async ({ browser }) => {
    const page = await pageFor(browser)
    await openDesign(page, cell)
    await page.locator('#build-root').evaluate((e, marker) => {
      if (marker === 'mounted') e.dataset.bdPaging = 'idle'
      else { e.dataset.bdMounted = ''; e.dataset.bdPaging = 'busy' }
    }, marker)
    await expect(waitParityReady(page, 'board', 'product')).rejects.toThrow(/product not ready:/)
  })
}
test('design WebSocket guard', async ({ browser }) => {
  const page = await pageFor(browser)
  await routeDesign(page)
  await page.goto('http://design.parity.invalid/blank')
  await page.evaluate(() => { window.paritySocket = new WebSocket('wss://fonts.googleapis.com/parity') })
  await expect.poll(() => {
    try { checkPage(page); return '' } catch (error) { return error.message }
  }).toContain('network request refused: wss://fonts.googleapis.com/parity')
})
test('live-stream ticket refused', async ({ browser }) => {
  const { readFile } = await import('node:fs/promises')
  const fixture = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/live.json', import.meta.url), 'utf8'))
  const ticket = fixture.data.now.find(t => t.agent.state === 'active').id
  await expect(openDesign(await pageFor(browser), cell, { ticket })).rejects.toThrow(`ticket ${ticket} runs the design's mock live stream`)
})
for (const variant of ['duplicate query', 'empty override']) {
  test(`live-stream query refused: ${variant}`, async ({ browser }) => {
    const { readFile } = await import('node:fs/promises')
    const fixture = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/live.json', import.meta.url), 'utf8'))
    const active = fixture.data.now.find(t => t.agent.state === 'active').id
    const inactive = fixture.data.hist[0].id
    const opts = variant === 'duplicate query' ? { query: `?ticket=${inactive}&ticket=${active}` } : { ticket: '', query: `?ticket=${active}` }
    await expect(openDesign(await pageFor(browser), cell, opts)).rejects.toThrow(`ticket ${active} runs the design's mock live stream`)
  })
}
test('loading phase holds the skeleton', async ({ browser }) => {
  const page = await pageFor(browser)
  await openDesign(page, cell, { phase: 'loading' })
  await delay(2000)
  await expect(page.locator('.bd-loading')).toHaveCount(1)
  const a = await page.screenshot({ animations: 'disabled', scale: 'device' })
  await delay(1000)
  expect((await page.screenshot({ animations: 'disabled', scale: 'device' })).equals(a)).toBe(true)
})
test('settle guard', async ({ page }) => {
  await page.setContent('<div style="width:100px;height:100px">changing</div>')
  let n = 0
  // Change between each real capture; this cannot accidentally sample the same timer phase.
  const target = { screenshot: async opts => {
    await page.locator('div').evaluate((e, n) => { e.style.outline = `${n % 2 + 1}px solid red` }, n++)
    return page.screenshot(opts)
  } }
  await expect(captureStable(target, { scale: 'device' })).rejects.toThrow('design did not settle after 10 captures')
})
test('region guard', async ({ browser }) => {
  const pair = await designPair(browser)
  await expect(expectDesignParity(pair, { name: 'missing', region: '.missing' })).rejects.toThrow('region missing on design')
  await expect(expectDesignParity(pair, { name: 'duplicate', region: '.bd-card' })).rejects.toThrow('region not unique on design')
  await pair.product.locator('.bd-now').evaluate(e => e.remove())
  await expect(expectDesignParity(pair, { name: 'product-missing', region: '.bd-now' })).rejects.toThrow('region missing on product')
})
const defects = {
  'no ref': e => { e.approval.ref = '' },
  'unknown kind': e => { e.kind = 'unknown' },
  'duplicate id': e => e,
  'wrong approver': e => { e.approval = { status: 'approved', by: 'Someone', date: '2026-10-08', ref: 'test' } },
  'missing css': e => { e.kind = 'design-style' },
  'unexpected css': e => { e.css = 'html {color:red}' },
  'wrong status spelling': e => { e.approval.status = 'pending-signoff' },
  'missing property': e => { e.kind = 'property' },
  'missing rule': e => { e.kind = 'axe' },
  'missing path': e => { e.kind = 'motion' },
  'approved false': e => { e.approved = false }
}
for (const [name, mutate] of Object.entries(defects)) {
  test(`allowlist validation: ${name}`, async () => {
    const bad = structuredClone(entry); mutate(bad)
    await expect(loadAllowlist(await allowlistFile(name === 'duplicate id' ? [bad, bad] : [bad]))).rejects.toThrow('invalid allowlist entry')
  })
}
test('stale allowlist entry', async ({ browser }) => {
  const pair = await designPair(browser)
  await expect(applyAllowlist(pair, cell, [{ ...entry, selector: '.missing' }])).rejects.toThrow('stale allowlist entry demo')
})
test('allowlist removal applies', async ({ browser }) => {
  const pair = await designPair(browser)
  // The footer is below the viewport; keep its region size fixed after removal.
  for (const page of [pair.design, pair.product]) await page.addStyleTag({ content: '#bd-status { height: 32px; box-sizing: border-box; }' })
  const entries = await loadAllowlist()
  await applyAllowlist(pair, cell, entries)
  await pixelFailure(pair, { name: 'removed', region: '#bd-status' })
  await applyAllowlist({ ...pair, design: pair.product }, cell, entries)
  await expectDesignParity(pair, { name: 'both-removed', region: '#bd-status' })
})
test('design-style entry applies', async ({ browser }) => {
  const pair = await designPair(browser)
  const entries = await loadAllowlist(await allowlistFile([{ ...entry, kind: 'design-style', selector: 'html', css: ':root { --accent: #ff0000 !important; }' }]))
  await applyAllowlist(pair, cell, entries)
  await pixelFailure(pair, { name: 'style', region: '.bd-now' })
  await applyAllowlist({ ...pair, design: pair.product }, cell, entries)
  await expectDesignParity(pair, { name: 'both-styled', region: '.bd-now' })
})
test('pixel-mask applies on both pages', async ({ browser }) => {
  const pair = await designPair(browser)
  await pair.product.locator('#bd-status').evaluate(e => { e.style.background = 'red' })
  await pixelFailure(pair, { name: 'unmasked', region: '#bd-status' })
  pair.allowlist = await loadAllowlist(await allowlistFile([{ ...entry, kind: 'pixel-mask', selector: '#bd-status' }]))
  await expectDesignParity(pair, { name: 'masked', region: '#bd-status' })
  await pair.product.locator('#bd-status').evaluate(e => e.remove())
  await expect(applyAllowlist(pair, cell)).rejects.toThrow('stale allowlist entry demo')
})
test('design symlinks refused', async () => {
  const root = path.join(scratch, 'design')
  await mkdir(root)
  const outside = path.join(scratch, 'outside.txt')
  await writeFile(outside, 'outside reference bytes')
  await symlink(outside, path.join(root, 'logo.svg'))
  expect(resolveDesignPath('logo.svg', root)).toBeNull()
  await expect(verifyDesignSource(root, { design_sha256: {} })).rejects.toThrow('design source contains a symlink')
})
test('design source hash', async () => {
  const root = path.join(scratch, 'design')
  await cp(DESIGN_ROOT, root, { recursive: true })
  await verifyDesignSource(root)
  await appendFile(path.join(root, 'assets/aiur-logo.png'), 'drift')
  await expect(verifyDesignSource(root)).rejects.toThrow('design source changed without re-export')
})
test('design route containment', async ({ browser }) => {
  expect(resolveDesignPath('../../mix.exs')).toBeNull()
  const page = await pageFor(browser)
  await routeDesign(page)
  const response = await page.goto('http://design.parity.invalid/%2e%2e%2fmix.exs')
  expect(response.status()).toBe(404)
})
test('page error guard', async ({ browser }) => {
  const page = await pageFor(browser)
  await openDesign(page, cell)
  const seen = page.waitForEvent('pageerror')
  await page.addScriptTag({ content: 'throw new Error("parity boom")' })
  await seen
  expect(() => checkPage(page)).toThrow('page error: parity boom')
})
test('pending sign-off entries are reported', async () => {
  await loadAllowlist()
  expect(test.info().annotations).toContainEqual({ type: 'pending-sign-off', description: expect.stringContaining('demo-data-select: pending-sign-off') })
})

test('shell phase and query are available to consumers', async ({ browser }) => {
  const page = await pageFor(browser)
  await openDesign(page, cell, { phase: 'shell', query: '?view=list' })
  expect(new URL(page.url()).searchParams.get('view')).toBe('list')
  await page.locator('#build-root').evaluate(e => e.remove())
  await waitParityReady(page, 'shell')
})

test('visual route seeds the optional palette', async ({ page }) => {
  const { openVisualRoute } = await import('../support/visual.mjs')
  await openVisualRoute(page, { theme: 'dark', palette: 'aiur', route: '/build-orders' })
  expect(await page.evaluate(() => localStorage.getItem('aiur-palette'))).toBe('aiur')
})
