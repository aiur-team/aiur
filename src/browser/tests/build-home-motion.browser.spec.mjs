import { test, expect } from '@playwright/test'
import { openDesign, openProduct, parityContextOptions, FIXTURE_META } from '../support/design-parity.mjs'

const cell = { viewport: { width: 1440, height: 900 }, theme: 'dark', palette: 'gruvbox', dataset: 'live' }

test('clock probe: product connects and patches with preinstalled clock', async ({ browser }) => {
  const context = await browser.newContext({ ...parityContextOptions(cell), baseURL: test.info().project.use.baseURL })
  try {
    const page = await context.newPage()
    await page.clock.install({ time: FIXTURE_META.now - 1000 })
    await page.clock.pauseAt(FIXTURE_META.now)
    await openProduct(page, cell, { phase: 'shell', productRoute: '/build-orders' })
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
import { compareRecords, domState, pausedAnimations, scrollFrames } from '../support/build-home-motion.mjs'

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
  expect(compareRecords(record(10), product).map(diff => diff.path)).toEqual(['probe.dom.nodes[0]'])
})

test('harness self-check: path allowlist and stale paths', () => {
  expect(compareRecords(record(10), record(12), [motionEntry])).toEqual([])
  expect(() => compareRecords(record(10), record(10), [motionEntry])).toThrow('stale allowlist entry probe-motion')
  expect(() => compareRecords(record(10), record(12), [{ ...motionEntry, path: 'probe.samples[0].other' }])).toThrow('stale allowlist entry probe-motion')
})

test('harness self-check: DOM records preserve geometry and fixture identity', async ({ page }) => {
  await page.setContent('<div id="bd-vp"><div class="bd-card phx-connected dim" data-id="product-1" style="left:12px;width:25px"></div></div>')
  expect((await domState(page, { 'design-1': 'product-1' })).nodes).toEqual([
    { key: 'design-1', classes: ['bd-card', 'dim'], top: '', left: '12px', width: '25px', height: '' }
  ])
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
