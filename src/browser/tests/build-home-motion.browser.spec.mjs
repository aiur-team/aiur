// One spec keeps the required mutations, sequence contracts, and sign-off gate collected together.
import { openVisualRoute } from '../support/visual.mjs'
import { test, expect } from '@playwright/test'
import { openDesign, openProduct, selectProductDataset, guardNetwork, parityContextOptions, FIXTURE_META } from '../support/design-parity.mjs'

// Per-action DOM traces dominate the frame sampler; failures retain numeric diffs and screenshots.
test.use({ trace: 'off' })

const cell = { viewport: { width: 1440, height: 900 }, theme: 'dark', palette: 'gruvbox', dataset: 'live' }

test('clock probe: product connects and patches with preinstalled clock', async ({ browser }) => {
  const context = await browser.newContext({ ...parityContextOptions(cell), baseURL: test.info().project.use.baseURL })
  try {
    const page = await context.newPage()
    await page.clock.install({ time: FIXTURE_META.now - 1000 })
    await page.clock.pauseAt(FIXTURE_META.now)
    await guardNetwork(page, [new URL(test.info().project.use.baseURL).origin])
    await selectProductDataset(page, 'live')
    await openVisualRoute(page, { theme: cell.theme, palette: cell.palette, route: '/build', mode: 'writable' })
    await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
    await page.locator('[phx-click="toggle-nav"]').evaluate(el => el.click())
    await page.clock.runFor(16)
    await expect(page.locator('.dashboard-shell')).toHaveAttribute('data-nav-collapsed', 'true')
  } finally { await context.close() }
})

// Future regression guard for the installed Clock API and unchanged design scroll curve.
test('clock probe: design scroll advances one frame', async ({ browser }) => {
  const context = await browser.newContext(parityContextOptions(cell))
  try {
    const page = await context.newPage()
    await openDesign(page, cell, { phase: 'loading' })
    await page.clock.runFor(640)
    await expect(page.locator('#bd-content')).toHaveCount(1)
    const before = await page.locator('#bd-vp').evaluate(el => el.scrollTop)
    const input = await page.locator('#bd-vp').evaluate(el => new Promise(resolve => {
      el.addEventListener('scroll', () => resolve({ from: el.scrollTop, at: performance.now() }), { once: true })
      el.scrollTop -= 20
    }))
    await page.clock.runFor(200)
    await page.evaluate(() => { window.probeFrames = []; requestAnimationFrame(now => window.probeFrames.push(now)) })
    await page.clock.runFor(16)
    const { after, frames } = await page.evaluate(() => ({ after: document.querySelector('#bd-vp').scrollTop, frames: window.probeFrames }))
    expect(frames).toHaveLength(1)
    const k = (frames[0] - input.at - 200) / 420
    expect(k).toBeGreaterThan(0)
    expect(k).toBeLessThan(1)
    expect(Math.abs(after - (input.from + (before - input.from) * (1 - (1 - k) ** 3)))).toBeLessThanOrEqual(1)
  } finally { await context.close() }
})

// Independent checks remain runnable while #3116 supplies the product fixture route.
import { motionPathMatches, compareRecords, domState, pausedAnimations, scrollFrames } from '../support/build-home-motion.mjs'

const record = value => ({ name: 'probe', samples: [{ scrollTop: value }], dom: { nodes: [] } })
const motionEntry = { id: 'probe-motion', kind: 'motion', path: 'probe.samples[*].scrollTop', approval: { status: 'pending-sign-off' } }

test('harness self-check: empty measurements are unreachable', () => {
  expect(compareRecords(record(10), { ...record(10), samples: [] })).toEqual([{ path: 'probe', reason: 'unreachable' }])
  expect(compareRecords({ ...record(10), samples: [] }, { ...record(10), samples: [] })).toEqual([{ path: 'probe', reason: 'unreachable' }])
})

test('harness self-check: measured position tolerance and missing nodes', () => {
  expect(compareRecords(record(10), record(10.9))).toEqual([])
  expect(compareRecords(record(10), record(11.1))).toEqual([{ path: 'probe.samples[0].scrollTop', design: 10, product: 11.1 }])
  const product = record(10); product.dom.nodes.push({ key: 'extra-card' })
  expect(compareRecords(record(10), product).map(diff => diff.path)).toEqual(['probe.dom.nodes[0].key'])
})

test('harness self-check: column timers allow one frame without losing states', () => {
  const columns = (at, state = 'present') => ({ name: 'columns.probe', samples: Array.from({ length: 8 }, (_, index) => ({ lane: index < at ? 'leave' : state })), applyAt: 220, removeAt: at * 16 })
  expect(compareRecords(columns(3), columns(4))).toEqual([])
  expect(compareRecords(columns(3), columns(5)).map(diff => diff.path)).toEqual(['columns.probe.samples[1].at', 'columns.probe.removeAt'])
  expect(compareRecords(columns(3), columns(4, 'wrong')).map(diff => diff.path)).toEqual(['columns.probe.samples[1].state.lane'])
})

test('harness self-check: path allowlist and stale paths', () => {
  expect(compareRecords(record(10), record(12), [motionEntry])).toEqual([])
  expect(() => compareRecords(record(10), record(10), [motionEntry])).toThrow('stale allowlist entry probe-motion')
  expect(() => compareRecords(record(10), record(12), [{ ...motionEntry, path: 'probe.samples[0].other' }])).toThrow('stale allowlist entry probe-motion')
})

test('harness self-check: DOM records preserve geometry and fixture identity', async ({ page }) => {
  await page.setContent('<div id="bd-vp"><div class="bd-card phx-connected dim" data-id="product-1" style="left:12px;width:25px"></div></div>')
  expect((await domState(page, { 'design-1': 'product-1' })).nodes).toEqual({
    'card:design-1': { key: 'card:design-1', classes: ['bd-card', 'dim'], top: '', left: '12px', width: '25px', height: '' }
  })
})

async function cssProbe(page, duration, reducedMotion) {
  await page.setContent(`<style>@keyframes probeFade {from {opacity:.4;transform:translateY(14px) scale(.99)} to {opacity:1;transform:none}}
    .on {animation:probeFade ${duration}ms cubic-bezier(.22,1,.36,1) both}</style>
    <button onclick="document.querySelector('#motion').className='on'">open</button><div id="motion">motion</div>`)
  return pausedAnimations(page, '#motion', { trigger: 'button', reducedMotion })
}

test('harness self-check: CSS timing and frames detect a planted duration', async ({ page }) => {
  const animations = await cssProbe(page, 240, false)
  expect(animations).toHaveLength(1)
  expect(animations[0].timing.duration).toBe(240)
  expect(animations[0].samples[0].opacity).toBeCloseTo(.4, 3)
  expect(animations[0].samples[4].opacity).toBeCloseTo(1, 3)
  const changed = await cssProbe(page, 300, false)
  expect(compareRecords({ name: 'probe', samples: animations }, { name: 'probe', samples: changed })).toContainEqual(
    { path: 'probe.samples[0].timing.duration', design: 240, product: 300 }
  )
})

test('harness self-check: reduce normalisation only removes near-zero motion', async ({ page }) => {
  expect(await cssProbe(page, .01, true)).toEqual([])
  expect(await cssProbe(page, .01, false)).toHaveLength(1)
  expect(await cssProbe(page, 50, true)).toHaveLength(1)
})

test('harness self-check: missing input and measurement fail', async ({ page }) => {
  await page.setContent('<div id="motion"></div>')
  await expect(pausedAnimations(page, '#motion', { trigger: '.bd-zb' })).rejects.toThrow('unreachable input: .bd-zb')
  await expect(pausedAnimations(page, '.missing')).rejects.toThrow('unreachable measurement: .missing')
})


test('harness self-check: scroll frames advance timers and measure each position', async ({ page }) => {
  await page.clock.install({ time: FIXTURE_META.now - 1000 })
  await page.clock.pauseAt(FIXTURE_META.now)
  await page.setContent('<div id="bd-vp" style="height:20px;overflow:auto"><div style="height:1000px"></div></div>')
  await page.evaluate(() => setInterval(() => document.querySelector('#bd-vp').scrollTop++, 16))
  expect(await scrollFrames(page, { from: 50, frames: 2 })).toEqual([{ scrollTop: 51 }, { scrollTop: 52 }])
})

import { SEQUENCES, OWNER, runOn } from '../support/build-home-motion.mjs'

for (const name of Object.keys(SEQUENCES)) for (const reduce of [false, true]) {
  test(`design determinism: ${name} ${reduce ? 'reduce' : 'normal'}`, async ({ browser }) => {
    test.setTimeout(240_000)
    let reference
    for (let run = 0; run < 3; run++) {
      const record = await designRecord(browser, name, { reduce })
      expect(record.reason, JSON.stringify(record)).toBeUndefined()
      expect(record.samples.length).toBeGreaterThan(0)
      if (name.startsWith('snap.') && name !== 'snap.scrollbar-drag') expect(record.frame).toHaveLength(name === 'snap.scroll-curve' ? 27 : 41)
      if (name === 'snap.scroll-curve' && !reduce) for (const frame of record.frame) {
        const k = Math.min(1, frame.elapsed / 420), expected = record.input.from + (record.input.to - record.input.from) * (1 - (1 - k) ** 3)
        expect(Math.abs(frame.scrollTop - expected), `scroll curve at ${frame.elapsed}ms`).toBeLessThanOrEqual(1)
      }
      if (reference) expect(compareRecords(reference, record), `run ${run + 1}`).toEqual([])
      else reference = record
    }
  })
}

import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { DESIGN_ROOT, loadAllowlist, expectDesignParity, openParityPair, PARITY_MATRIX, waitParityReady, compareParityPixels, applyAllowlist } from '../support/design-parity.mjs'

const plants = [
  ['scroll duration', 'snap.scroll-curve', 'assets/build.js', 'dur = 420', 'dur = 400', /\.frame\[\d+\]\.scrollTop$/],
  ['column debounce', 'columns.enter-leave', 'assets/build.js', 'force ? 0 : 220', 'force ? 0 : 150', /\.applyAt$/],
  ['column removal', 'columns.enter-leave', 'assets/build.js', '}, 300);', '}, 200);', /\.removeAt$/],
  ['reduced snap guard', 'snap.reduce', 'assets/build.js', 'rmOn() === "x"', 'rmOn()', /\.frame\[\d+\]\.scrollTop$/],
  ['modal duration', 'modal.open', 'Aiur Dashboard.html', 'tkin 0.24s', 'tkin 0.3s', /\.animation\.tkin\.duration$/],
  ['tree duration', 'tree.overlay', 'assets/build.css', 'bdTreeIn .22s', 'bdTreeIn .3s', /\.animation\.bdTreeIn\.duration$/],
  ['grain opacity', 'grain.static', 'assets/build.css', 'opacity: .09;', 'opacity: .12;', /\.bd-now\.after\.opacity$/],
  ['reduced tree', 'tree.reduce', 'assets/build.css', '.bd-root.rm .bd-tree, .bd-root.rm .bd-lt { animation: none; transition: none; }', '', /\.animation\.bdTreeIn\./],
  ['reduced loading spinner', 'loading.spin', 'assets/build.css', 'animation-duration: 3s', 'animation-duration: 1s', /\.animation\.khSpin\.duration$/]
]

async function sequenceOptions(name, selectedCell) {
  const opts = { motion: true, phase: name === 'loading.spin' ? 'loading' : 'board', query: name.startsWith('columns.') || name === 'snap.scroll-curve' ? '?trees=1&span=30' : '?trees=1' }
  if (name === 'modal.url') {
    const fixture = JSON.parse(await readFile(new URL(`../../test/fixtures/build_home/${selectedCell.dataset}.json`, import.meta.url), 'utf8'))
    const ticket = fixture.data.now.find(t => t.agent?.state !== 'active') ?? fixture.data.hist[0]
    if (!ticket) throw new Error('unreachable URL modal fixture ticket')
    Object.assign(opts, { ticket: ticket.id, pauseAtSelector: '#tk-modal' })
  }
  return opts
}

async function designRecord(browser, name, { plant, selectedCell = cell, ...ctx } = {}) {
  const context = await browser.newContext(parityContextOptions({ ...selectedCell, reducedMotion: ctx.reduce ? 'reduce' : 'no-preference' }))
  try {
    const page = await context.newPage()
    if (plant) {
      const [, , file, before, after] = plant, original = await readFile(`${DESIGN_ROOT}/${file}`, 'utf8')
      expect(original).toContain(before)
      await page.route(`**/${file.replace(/ /g, '%20')}*`, route => route.fulfill({ body: original.replace(before, after), contentType: file.endsWith('.js') ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : 'text/html' }))
    }
    await openDesign(page, selectedCell, await sequenceOptions(name, selectedCell))
    return await runOn(page, name, ctx)
  } finally { await context.close() }
}

for (const plant of plants) test(`harness self-check: planted ${plant[0]}`, async ({ browser }) => {
  test.setTimeout(90_000)
  const reduce = plant[1].includes('reduce') || plant[0] === 'reduced loading spinner'
  const design = await designRecord(browser, plant[1], { reduce })
  const changed = await designRecord(browser, plant[1], { reduce, plant })
  expect(design.samples.length, design.reason).toBeGreaterThan(0)
  expect(changed.samples.length, changed.reason).toBeGreaterThan(0)
  expect(compareRecords(design, changed).filter(diff => plant[5].test(diff.path)), JSON.stringify({ design: { applyAt: design.applyAt, removeAt: design.removeAt }, changed: { applyAt: changed.applyAt, removeAt: changed.removeAt } })).not.toEqual([])
})

test('harness self-check: missing span selector is unreachable', async ({ browser }) => {
  const record = await designRecord(browser, 'view.span', { inputSelector: '.bd-zb' })
  expect(record.reason).toBe('unreachable input: .bd-zb')
  expect(compareRecords(record, record)).toEqual([{ path: 'view.span', reason: 'unreachable' }])
})

test('harness self-check: shared loader accepts path globs and rejects misplaced paths', async () => {
  const entry = { ...motionEntry, selector: '#tk-modal', reason: 'self-check', approval: { status: 'pending-sign-off', ref: 'self-check' } }
  const file = test.info().outputPath('allowlist.json')
  await mkdir(test.info().outputDir, { recursive: true })
  await writeFile(file, JSON.stringify([entry]))
  expect(await loadAllowlist(file)).toEqual([entry])
  for (const bad of [{ ...entry, path: undefined }, { ...entry, kind: 'pixel-mask' }, { ...entry, path: 'probe.?' }]) {
    await writeFile(file, JSON.stringify([bad]))
    await expect(loadAllowlist(file)).rejects.toThrow('invalid allowlist entry')
  }
})

// C1-T03: all interactions use the narrowed cells; inventory/grain use every colour cell.
const full = process.env.AIUR_PARITY_FULL === '1'
const colourCells = PARITY_MATRIX.filter(c => !c.reducedMotion).flatMap(c => ['no-preference', 'reduce'].map(reducedMotion => ({ ...c, reducedMotion })))
const interactionCells = full ? colourCells : [
  { ...cell, reducedMotion: 'no-preference' }, { ...cell, reducedMotion: 'reduce' },
  { ...cell, viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, reducedMotion: 'no-preference' }
]
const missingPorts = new Set(), matchedAllowlist = new Set()

function ownerFor(name) { return OWNER[name] ?? OWNER[name.split('.')[0]] }
function scopedEntries(entries, selectedCell) {
  return entries.filter(entry => Object.entries(entry.cells ?? {}).every(([key, value]) => (key === 'viewport' ? `${selectedCell.viewport.width}x${selectedCell.viewport.height}` : selectedCell[key]) === value))
}
function collectAllowlist(design, product, entries) {
  const raw = compareRecords(design, product)
  for (const entry of entries.filter(e => e.kind === 'motion')) {
    if (raw.some(diff => motionPathMatches(entry.path, diff.path))) matchedAllowlist.add(entry.id)
  }
  expect(compareRecords(design, product, entries)).toEqual([])
}

// Barrier keeps both pages on each chosen frame while the shared screenshot helper runs.
function frameBarrier(pair, name, reduce) {
  let count = 0, resolve, pending, aborted = false
  const frame = async (fraction, region) => {
    if (aborted) return
    if (reduce && ['modal.open', 'modal.reduce', 'modal.url', 'modal.close'].includes(name)) return // S-18 records the admitted tkin difference numerically.
    if (count++ % 2 === 0) { pending = new Promise(done => { resolve = done }); return pending }
    try { await expectDesignParity(pair, { name: `${name}-${fraction}`, region, preserveAnimations: true }) }
    finally { resolve() }
  }
  return { frame, abort() { aborted = true; resolve?.() } }
}

for (const selectedCell of interactionCells) test.describe(`product interactions ${selectedCell.dataset} ${selectedCell.viewport.width} ${selectedCell.theme} ${selectedCell.palette} ${selectedCell.reducedMotion}`, () => {
  for (const name of Object.keys(SEQUENCES).filter(n => !['inventory', 'grain.static'].includes(n))) test(name, async ({ browser }) => {
    test.setTimeout(120_000)
    const owner = ownerFor(name), reduce = selectedCell.reducedMotion === 'reduce'
    const pair = await openParityPair(browser, selectedCell, { ...await sequenceOptions(name, selectedCell), productAnchor: owner.anchor, productPending: owner.pending })
    try {
      const absent = owner.pending || (owner.anchor && !await pair.product.locator(owner.anchor).count()) || ((name.startsWith('columns.') || name === 'snap.scroll-curve') && !await pair.product.locator('.bd-cal [data-span="7"]').count())
      if (absent) missingPorts.add(`${name}: ${owner.owners.join(', ')}`)
      test.fixme(absent, `awaiting ${owner.owners.join(', ')}`)
      const entries = scopedEntries(pair.allowlist, selectedCell), barrier = frameBarrier(pair, name, reduce)
      const [design, product] = await Promise.all([runOn(pair.design, name, { reduce, onFrame: barrier.frame }).finally(barrier.abort), runOn(pair.product, name, { reduce, onFrame: barrier.frame, ids: FIXTURE_META.ids }).finally(barrier.abort)])
      collectAllowlist(design, product, entries)
    } finally { await pair.close() }
  })
})

for (const selectedCell of colourCells) test.describe(`product inventory/grain ${selectedCell.dataset} ${selectedCell.viewport.width} ${selectedCell.theme} ${selectedCell.palette} ${selectedCell.reducedMotion}`, () => {
  let pair
  test.beforeAll(async ({ browser }) => {
    test.setTimeout(120_000)
    pair = await openParityPair(browser, selectedCell, { motion: true, productPending: true })
    for (const name of ['inventory', 'grain.static']) {
      const reference = await runOn(pair.design, name, { reduce: selectedCell.reducedMotion === 'reduce' })
      expect(reference.samples.length, reference.reason).toBeGreaterThan(0)
    }
  })
  test.afterAll(async () => { await pair?.close() })
  test('inventory #build-root', async () => {
    const owners = Object.values(OWNER.inventory.per)
    const absent = OWNER['loading.spin'].pending || !await pair.product.locator('.bd-content .bd-lanes').count()
    if (absent) missingPorts.add(`inventory #build-root: ${owners.join(', ')}`)
    test.fixme(absent, `awaiting ${owners.join(', ')}`)
    const reduce = selectedCell.reducedMotion === 'reduce'
    const design = await runOn(pair.design, 'inventory', { reduce })
    const product = await runOn(pair.product, 'inventory', { reduce })
    collectAllowlist(design, product, scopedEntries(pair.allowlist, selectedCell))
  })
  for (const name of ['inventory', 'grain.static']) for (const [selector, owner] of Object.entries(OWNER[name].per)) test(`${name} ${selector}`, async () => {
    const loading = selector === '.bd-skel i'
    if (loading && !OWNER['loading.spin'].pending) await openProduct(pair.product, selectedCell, { motion: true, phase: 'loading', productPending: true })
    const absent = !await pair.product.locator(selector).count() || (loading && OWNER['loading.spin'].pending)
    if (absent) missingPorts.add(`${name} ${selector}: ${owner}`)
    test.fixme(absent, `awaiting ${owner}`)
    const phase = selector === '.bd-skel i' ? 'loading' : 'board'
    await openDesign(pair.design, selectedCell, { motion: true, phase })
    await openProduct(pair.product, selectedCell, { motion: true, phase })
    const reduce = selectedCell.reducedMotion === 'reduce'
    const barrier = frameBarrier(pair, name, reduce)
    const [design, product] = await Promise.all([runOn(pair.design, name, { reduce, selector, onFrame: barrier.frame }).finally(barrier.abort), runOn(pair.product, name, { reduce, selector, onFrame: barrier.frame, ids: FIXTURE_META.ids }).finally(barrier.abort)])
    collectAllowlist(design, product, scopedEntries(pair.allowlist, selectedCell))
    if (loading) await openProduct(pair.product, selectedCell, { motion: true, productPending: true })
  })
})

test('full sign-off: no missing ports or stale motion entries', async () => {
  test.skip(!full, 'C12-T08 full matrix gate')
  expect([...missingPorts], 'Full sign-off cannot accept fixme owner gates').toEqual([])
  const entries = await loadAllowlist()
  expect(entries.filter(entry => entry.kind === 'motion' && !matchedAllowlist.has(entry.id)).map(entry => entry.id), 'stale motion paths').toEqual([])
})

test('harness self-check: full matrix flag reaches the Playwright child', async () => {
  const { browserChildEnvironment } = await import('../scripts/artifact-sanitizer.mjs')
  const child = browserChildEnvironment({ AIUR_PARITY_FULL: '1', GITHUB_TOKEN: 'must-not-leak' })
  expect(child.AIUR_PARITY_FULL).toBe('1')
  expect(child.GITHUB_TOKEN).toBeUndefined()
})


test('harness self-check: pixel frames retain paused CSS animation time', async ({ browser }) => {
  const context = await browser.newContext({ viewport: cell.viewport })
  try {
    const pages = await Promise.all([context.newPage(), context.newPage()])
    for (const page of pages) {
      await page.setContent('<style>@keyframes probe { from { opacity: .2 } to { opacity: 1 } } #probe { width: 40px; height: 40px; background: red; animation: probe 1s linear both }</style><div id="probe"></div>')
      await page.evaluate(() => { const animation = document.querySelector('#probe').getAnimations()[0]; animation.pause(); animation.currentTime = 500 })
    }
    const pair = { design: pages[0], product: pages[1], cell, allowlist: [] }
    await compareParityPixels(pair, { name: 'paused-probe', region: '#probe', preserveAnimations: true })
    for (const page of pages) expect(await page.evaluate(() => {
      const animation = document.querySelector('#probe').getAnimations()[0]
      return { time: animation.currentTime, state: animation.playState, opacity: getComputedStyle(document.querySelector('#probe')).opacity }
    })).toEqual({ time: 500, state: 'paused', opacity: '0.6' })
  } finally { await context.close() }
})

test('harness self-check: screenshot allowlists ignore motion paths', async ({ browser }) => {
  const context = await browser.newContext()
  try {
    const design = await context.newPage(), product = await context.newPage()
    await design.setContent('<div>design</div>'); await product.setContent('<div>product</div>')
    const pair = { design, product, cell }
    expect(await applyAllowlist(pair, cell, [{ ...motionEntry, selector: '.missing' }])).toEqual({ designMask: [], productMask: [] })
  } finally { await context.close() }
})


test('harness self-check: composed animations share each sampled fraction', async ({ page }) => {
  await page.setContent('<style>@keyframes probeLeft {from {left:0} to {left:100px}} @keyframes probeWidth {from {width:100px} to {width:200px}} #probe {position:relative;height:20px} .on {animation:probeLeft 1s linear both,probeWidth 1s linear both}</style><button onclick="document.querySelector(\'#probe\').classList.add(\'on\')">start</button><div id="probe"></div>')
  const animations = await pausedAnimations(page, '#probe', { trigger: 'button' })
  for (const animation of animations) expect(animation.samples.map(sample => sample.width)).toEqual(['100px', '125px', '150px', '175px', '200px'])
})

// Future regression guard for the existing sampler; paired root coverage awaits its ports.
test('harness self-check: complete inventory detects an unexpected animation', async ({ browser }) => {
  const context = await browser.newContext()
  try {
    const design = await context.newPage(), product = await context.newPage()
    for (const page of [design, product]) await page.setContent('<div id="build-root"><span class="outside-owners">unexpected</span></div>')
    await product.addStyleTag({ content: '@keyframes unexpected {from {opacity:0} to {opacity:1}} .outside-owners {animation:unexpected 1s infinite}' })
    const reference = await runOn(design, 'inventory'), changed = await runOn(product, 'inventory')
    expect(compareRecords(reference, changed).some(diff => diff.path === 'inventory.animation.unexpected.duration')).toBe(true)
  } finally { await context.close() }
})

for (const name of ['modal.url', 'reduce.live-toggle']) test(`harness self-check: admitted tkin only on ${name}`, async ({ browser }) => {
  const design = await designRecord(browser, name, { reduce: name === 'modal.url' })
  expect(design.animation.tkin.duration).toBe(240)
  const product = structuredClone(design)
  delete product.animation.tkin
  const entries = (await loadAllowlist()).filter(entry => entry.id === 'tkin-reduced-motion')
  expect(compareRecords(design, product, entries)).toEqual([])
  product.samples.push({ unexpected: true })
  expect(compareRecords(design, product, entries)).not.toEqual([])
})

test('harness self-check: scroll curve requests three visual frames', async ({ browser }) => {
  const frames = []
  const record = await designRecord(browser, 'snap.scroll-curve', { onFrame: (fraction, region) => frames.push([fraction, region]) })
  expect(record.samples.length, record.reason).toBeGreaterThan(0)
  expect(frames).toEqual([[0, '#bd-vp'], [.5, '#bd-vp'], [1, '#bd-vp']])
})
