// MP-E8-C12-T04: the Build home inside a phone WebView. The phone app opens this page in a
// WebView, so at 360/390/430 px it must never scroll sideways, keep the fixed bottom nav off the
// last control, answer taps where the desktop uses hover, and keep the design's phone geometry.
// Full-page pixels are not compared here: mobile parity is DOM, geometry and typography
// (accepted scope decision dec_2043ed93d73bbe63, see build-home-render-parity).
import { expect, test } from '@playwright/test'
import { openParityPair } from '../support/design-parity.mjs'
import { PHONE_CELLS, PHONE_DATASETS, geom, openPhoneProduct, phoneCell } from '../support/build-home-phone.mjs'

test.setTimeout(180_000)

// The product's own flow rule (J:646-650, J:781): no lanes or edges, epic colouring, K slots.
function expectFlowLayout(g) {
  expect(g.lanes).toBe(0)
  expect(g.laneG).toBe('Colour = epic')
  expect(g.edgesHidden).toBe(true)
  expect(g.histLefts.length).toBeLessThanOrEqual(Math.max(2, Math.floor((g.vpW - 46 - 14) / 140)))
}

// The centre of the first card the finger would actually hit, or null while the board scrolls.
const tappablePoint = (page, selector) => page.evaluate(selector => {
  if (document.querySelector('#bd-content').classList.contains('scrolling')) return null
  for (const card of document.querySelectorAll(selector)) {
    const r = card.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + Math.min(r.height / 2, 20)
    if (y > 0 && y < innerHeight && document.elementFromPoint(x, y)?.closest('.bd-card') === card) return { x, y }
  }
  return null
}, selector)

async function shoot(page, name) {
  await page.screenshot({ path: test.info().outputPath(`${name}.png`), animations: 'disabled', caret: 'hide', scale: 'device' })
}

// Decision 5: compare with the cell width, not innerWidth. With isMobile a too-wide page zooms
// out and innerWidth grows with it (the design reports 435 px), so innerWidth would hide the bug.
// Every dataset at the two narrow cells; 430 px is the widest, so live alone keeps CI time down.
for (const name of Object.keys(PHONE_CELLS)) test(`phone guard: no page scroll sideways and the nav clears the last control at ${name}`, async ({ browser }) => {
  const { width } = PHONE_CELLS[name]
  for (const dataset of name === 'p430' ? ['live'] : PHONE_DATASETS) {
    const { page, close } = await openPhoneProduct(browser, phoneCell(name, dataset))
    try {
      expect(await page.evaluate(() => document.documentElement.scrollWidth), `${dataset} page width`).toBeLessThanOrEqual(width)
      // N13 (#4846): scrolled to the end, the board's last row sits above the fixed bottom nav.
      await page.evaluate(() => scrollTo(0, document.documentElement.scrollHeight))
      await expect.poll(() => page.evaluate(() => {
        const status = document.querySelector('#bd-status').getBoundingClientRect(), nav = document.querySelector('.sidenav').getBoundingClientRect()
        return status.height > 0 && status.bottom <= nav.top
      }), `${dataset} #bd-status above .sidenav`).toBe(true)
    } finally { await close() }
  }
})

for (const name of ['p390', 'p430']) test(`phone guard: board geometry matches the design at ${name}`, async ({ browser }) => {
  const pair = await openParityPair(browser, phoneCell(name))
  try {
    const design = await geom(pair.design), product = await geom(pair.product)
    await shoot(pair.design, `phone-${name}-live-dark-gruvbox-design`)
    await shoot(pair.product, `phone-${name}-live-dark-gruvbox`)
    for (const key of ['rootW', 'vpW', 'vpH']) expect(product[key], key).toBe(design[key])
    // Gutter (J:541): 46 px below a 640 px root; cards never cross vpW - 14.
    for (const g of [design, product]) {
      expect(g.histLefts[0]).toBe(46)
      expect(g.maxRight).toBeLessThanOrEqual(g.vpW - 14)
    }
    // Band stack (J:491): one column on a phone, the same on both pages.
    expect(design.bandCards, 'band check needs ≥ 2 band items').toBeGreaterThanOrEqual(2)
    expect(product.bandLefts).toEqual(design.bandLefts)
    expectFlowLayout(product)
    if (name === 'p390') {
      // Both pages flow at 390 px: the design's own rule (avail / nEst < 62) turns it on.
      expect(design.flow).toBe(true)
      expect(product.flow).toBe(true)
      expectFlowLayout(design)
      expect(product.histLefts).toEqual(design.histLefts)
    } else {
      // At 430 px the design keeps 5 lanes of ~60 px cards; the product flows instead because
      // the packed lanes would be slivers (#4769, render.js `crowded`). The design state is
      // recorded so a design change shows up here.
      expect(design.flow).toBe(false)
      expect(product.flow).toBe(true)
    }
    // S-45.7 census: buttons under 44 × 44 px (C:89, C:118, C:121, C:152), recorded, not gated.
    const small = page => page.evaluate(() => [...document.querySelectorAll('#build-root button')].filter(b => {
      const r = b.getBoundingClientRect(); return r.width && (r.width < 44 || r.height < 44)
    }).length)
    test.info().annotations.push({ type: 'S-45.7', description: `buttons < 44 px at ${name}: design ${await small(pair.design)}, product ${await small(pair.product)}` })
  } finally { await pair.close() }
})

// Design gap S-45.8: the band header row (C:393) is wider than a ≤ 390 px board, so the Minimize
// live button sits at x 370-394 on both pages and .bd-vp clips it. Fixing it needs a phone layout,
// which this ticket may not add; the marker fails loudly once the button fits.
for (const name of ['p360', 'p390']) test(`S-45.8 phone guard: band header controls stay inside the board at ${name}`, async ({ browser }) => {
  test.fail(true, 'S-45.8: the design clips the band Minimize button at this width')
  const { page, close } = await openPhoneProduct(browser, phoneCell(name))
  try {
    const out = await page.evaluate(() => {
      const vp = document.querySelector('#bd-vp').getBoundingClientRect()
      return [...document.querySelectorAll('.bd-now-h button')].filter(b => b.getBoundingClientRect().right > vp.right).map(b => b.className)
    })
    expect(out).toEqual([])
  } finally { await close() }
})

// N4 / C:604-609: at ≤ 720 px the modal fills the backdrop and drops the agent name, the extra
// meta spans (C11-T10 Decision 3) and keeps the 56 px minimap. .bm-doc (C:604) is not ported yet.
test('phone guard: modal at ≤ 720 px', async ({ browser }) => {
  const pair = await openParityPair(browser, phoneCell('p390'))
  try {
    // A finished history conversation avoids the design's mock live stream.
    const ticket = await pair.product.evaluate(async () => {
      const { ctx } = await import('/build-home/state.js')
      return ctx.D.hist.find(t => t.status === 'done').id
    })
    await pair.design.evaluate(id => window.AiurBuild.open('AIUR-' + id), ticket)
    await pair.product.evaluate(async id => (await import('/build-home/modal/frame.js')).openById(id), ticket)
    await expect(pair.product.locator('#cv-map')).toHaveCount(1)
    const read = page => page.evaluate(() => {
      const modal = document.querySelector('#tk-modal')
      modal.getAnimations({ subtree: true }).forEach(a => a.finish())
      const hidden = el => getComputedStyle(el).display === 'none'
      return {
        width: modal.getBoundingClientRect().width,
        mapWidth: document.querySelector('.cv-map').getBoundingClientRect().width,
        agentNameHidden: [...document.querySelectorAll('.bm-agent > span:not(.sr-only)')].every(hidden),
        metaHidden: [...document.querySelectorAll('.bm-tt .bm-meta span:not(.bm-st)')].every(hidden),
      }
    })
    const design = await read(pair.design), product = await read(pair.product)
    expect(design).toEqual({ width: expect.closeTo(390 - 2 * 19.2, 0), mapWidth: 56, agentNameHidden: true, metaHidden: true })
    expect(product).toEqual(design)
  } finally { await pair.close() }
})

test('phone guard: offline age stays visible on a phone', async ({ browser }) => {
  const pair = await openParityPair(browser, phoneCell('p390', 'offline'))
  try {
    for (const page of [pair.design, pair.product]) {
      await expect(page.locator('#bd-offline .bd-offline')).toBeVisible()
      await expect(page.locator('#bd-offline .bd-offline')).toContainText(/\d+ min ago/)
      // C:393: the band's cached time is hidden on a phone; the banner keeps the age.
      await expect(page.locator('.bd-now-h time')).toBeHidden()
    }
    const text = page => page.locator('#bd-offline .bd-offline').innerText()
    expect(await text(pair.product)).toBe(await text(pair.design))
  } finally { await pair.close() }
})

// EC-27 phone half: the ±700 px DOM window (J:706) holds the same cards as the design at each stop.
test('phone guard: DOM window at phone width', async ({ browser }) => {
  const pair = await openParityPair(browser, phoneCell('p390', 'dense'))
  try {
    const settle = page => expect.poll(() => page.evaluate(() => !document.querySelector('#bd-content').classList.contains('scrolling') && !document.querySelector('#bd-content').classList.contains('snapping')), { timeout: 5000 }).toBe(true)
    for (const fraction of [0, 0.25, 0.5, 0.75, 1]) {
      const stops = []
      for (const page of [pair.design, pair.product]) {
        await page.locator('#bd-vp').evaluate((vp, f) => { vp.scrollTop = f * (vp.scrollHeight - vp.clientHeight) }, fraction)
        await settle(page)
        await page.waitForTimeout(700)
        stops.push(await page.evaluate(() => ({ top: document.querySelector('#bd-vp').scrollTop, cards: document.querySelectorAll('#bd-content .bd-card').length })))
      }
      expect(stops[1], `stop ${fraction}`).toEqual(stops[0])
    }
  } finally { await pair.close() }
})

test('phone guard: tap opens the modal', async ({ browser }) => {
  const { page, close } = await openPhoneProduct(browser, phoneCell('p390'))
  try {
    const card = page.locator('#bd-now .bd-layer > .bd-card').first()
    const id = await card.getAttribute('data-id')
    await card.tap()
    await expect(page.locator('#tk-backdrop')).toHaveClass(/\bshow\b/)
    await expect(page.locator('#tk-head')).toContainText('#' + id.replace(/^\D+/, ''))
  } finally { await close() }
})

// Product only (C9-T11 §7): the design listens to mouseover and keeps the chain after a tap.
test('phone guard: a tap leaves no chain hover', async ({ browser }) => {
  // The fake clock keeps the live snap from gliding the board back to the band.
  const { page, close } = await openPhoneProduct(browser, phoneCell('p390'), { query: '?trees=1', motion: true })
  try {
    // Band cards never start a chain (trees.js onHover); a history card does on a mouse. The
    // sticky band covers a whole phone board, so collapse it first; its button is clipped at
    // this width (S-45.8), hence the programmatic click.
    await page.locator('[data-min]').evaluate(button => button.click())
    await expect(page.locator('#bd-now')).toHaveClass(/\bmin\b/)
    await page.locator('#bd-vp').evaluate(vp => new Promise(resolve => {
      const cards = document.querySelectorAll('#bd-sec-hist .bd-layer > .bd-card'), card = cards[Math.floor(cards.length / 2)]
      vp.addEventListener('scroll', resolve, { once: true })
      // Board at the top of the window, card just under the sticky lanes.
      vp.scrollIntoView({ block: 'start' })
      vp.scrollTop += card.getBoundingClientRect().top - vp.getBoundingClientRect().top - 60
    }))
    // Let the browser deliver the scroll before advancing its 200 ms guard and potential
    // 420 ms snap glide; set scrollTop otherwise races the fake clock in repeated runs.
    await page.waitForTimeout(0)
    await page.clock.runFor(704)
    let point
    await expect.poll(async () => {
      point = await tappablePoint(page, '#bd-sec-hist .bd-layer > .bd-card')
      await page.clock.runFor(16)
      return point != null
    }).toBe(true)
    expect(point, 'a tappable history card').not.toBeNull()
    await page.touchscreen.tap(point.x, point.y)
    await expect.poll(async () => { await page.clock.runFor(16); return page.locator('#tk-backdrop').evaluate(el => el.classList.contains('show')) }).toBe(true)
    expect(await page.evaluate(() => ({
      marked: document.querySelectorAll('.hl, .hdim').length,
      hovering: document.querySelector('#bd-content').classList.contains('hovering'),
    }))).toEqual({ marked: 0, hovering: false })
  } finally { await close() }
})

// C:353/C:888: a tap within 200 ms of the last scroll hits nothing; 250 ms later it opens the card.
// Coordinate taps under the fake clock, after a 1 px pinned scroll that starts no snap glide.
test('phone guard: no tap during the scroll freeze', async ({ browser }) => {
  const pair = await openParityPair(browser, phoneCell('p390'), { motion: true })
  try {
    for (const page of [pair.design, pair.product]) {
      // Wait for the native scroll event, so the freeze timer starts before the clock moves.
      const scrollTo = top => page.locator('#bd-vp').evaluate((vp, top) => new Promise(resolve => {
        const before = vp.scrollTop
        vp.addEventListener('scroll', resolve, { once: true })
        vp.scrollTop = top
        if (vp.scrollTop === before) resolve()
      }), top)
      const top = await page.evaluate(() => { const h = document.querySelector('#bd-sec-hist'); return h.offsetTop + h.offsetHeight - 46 })
      await scrollTo(top)
      await page.clock.runFor(704)
      const point = await page.evaluate(() => {
        for (const card of document.querySelectorAll('#bd-now .bd-layer > .bd-card')) {
          const r = card.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + Math.min(r.height / 2, 20)
          if (document.elementFromPoint(x, y)?.closest('.bd-card') === card) return { x, y }
        }
        return null
      })
      expect(point, 'a tappable band card').not.toBeNull()
      const shown = () => page.locator('#tk-backdrop').evaluate(el => el.classList.contains('show'))
      await scrollTo(await page.locator('#bd-vp').evaluate(vp => vp.scrollTop) - 1)
      await page.clock.runFor(100)
      await page.touchscreen.tap(point.x, point.y)
      // The product loads its modal module on demand: give a stray open real time to land
      // while the fake clock stays inside the 200 ms freeze.
      await page.waitForTimeout(500)
      await page.clock.runFor(16)
      expect(await shown(), 'tap at +100 ms').toBe(false)
      await page.clock.runFor(150)
      await page.touchscreen.tap(point.x, point.y)
      await expect.poll(async () => { await page.clock.runFor(16); return shown() }, { message: `${page === pair.design ? 'design' : 'product'} tap at +266 ms` }).toBe(true)
    }
  } finally { await pair.close() }
})

// J:572: a rotation relayouts after 140 ms and keeps scrollTop / scrollHeight.
test('phone guard: rotation keeps the scroll fraction', async ({ browser }) => {
  const pair = await openParityPair(browser, phoneCell('p390'), { motion: true })
  try {
    const flows = []
    for (const page of [pair.design, pair.product]) {
      const fraction = () => page.locator('#bd-vp').evaluate(vp => vp.scrollTop / vp.scrollHeight)
      const settledFlow = async () => {
        // setViewportSize returns before the browser delivers the resize event. Let that event
        // queue the 140 ms relayout, then prove two post-relayout frames agree before reading it.
        await page.waitForTimeout(0)
        await page.clock.runFor(1_000)
        let previous
        await expect.poll(async () => {
          const state = await page.evaluate(() => {
            const content = document.querySelector('#bd-content')
            return {
              flow: content.classList.contains('flow'),
              moving: content.classList.contains('scrolling') || content.classList.contains('snapping'),
            }
          })
          const settled = !state.moving && state.flow === previous?.flow && !previous?.moving
          previous = state
          await page.clock.runFor(16)
          return settled
        }, { timeout: 5_000 }).toBe(true)
        return previous.flow
      }
      await page.locator('#bd-vp').evaluate(vp => new Promise(resolve => {
        vp.addEventListener('scroll', resolve, { once: true })
        vp.scrollTop = vp.scrollHeight * 0.3
      }))
      await page.clock.runFor(1000)
      const before = await fraction(), seen = []
      for (const viewport of [{ width: 844, height: 390 }, PHONE_CELLS.p390]) {
        await page.setViewportSize(viewport)
        seen.push(await settledFlow())
        expect(Math.abs(await fraction() - before), `${viewport.width} px`).toBeLessThanOrEqual(0.01)
      }
      flows.push(seen)
    }
    expect(await pair.product.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
    expect(flows[1]).toEqual(flows[0])
  } finally { await pair.close() }
})

// Design gap S-45.9: at 200 % root text (the text-zoom stand-in of build-order-responsive) the
// toolbar row (#bd-tools, Live), the band header and the shell's bottom nav keep their one-row
// layout and run to ~512 px, as the design's fixed rows do. No phone layout is added here.
test('S-45.9 phone guard: 200% text has no page scroll sideways', async ({ browser }) => {
  test.fail(true, 'S-45.9: the design rows do not wrap at 200 % text')
  const { page, close } = await openPhoneProduct(browser, phoneCell('p390'))
  try {
    await page.evaluate(() => { document.documentElement.style.fontSize = '200%' })
    await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth), { timeout: 3000 }).toBeLessThanOrEqual(390)
  } finally { await close() }
})

// Product only (C9-T05): the design has no unknown values. A narrow phone card keeps the marker.
test('phone guard: unknown is not zero on a narrow card', async ({ browser }) => {
  const { page, close } = await openPhoneProduct(browser, phoneCell('p390', 'unknowns'))
  try {
    const card = page.locator('#bd-now .bd-card[data-id$="9001"]')
    await expect(card.locator('[data-unknown="pct"]')).toHaveText('—')
    await expect(card.locator('.bd-bar')).toHaveCount(0)
    await expect(card).not.toContainText('0%')
  } finally { await close() }
})
