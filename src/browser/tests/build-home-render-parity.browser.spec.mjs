import { test, expect } from '@playwright/test'
import { openParityPair, expectDesignParity, FIXTURE_META } from '../support/design-parity.mjs'
import { runOn, compareRecords } from '../support/build-home-motion.mjs'

for (const dataset of ['live', 'dense', 'newrepo', 'noqueue']) test(`section headers and vertical geometry match the design: ${dataset}`, async ({ browser }) => {
  const cell = { viewport: { width: 1440, height: 900 }, theme: 'light', palette: 'aiur', dataset }
  const pair = await openParityPair(browser, cell, { motion: true })
  try {
    // Band rendering belongs to C9-T08; align both viewports to the history top.
    for (const page of [pair.design, pair.product]) await page.locator('#bd-vp').evaluate(el => { el.scrollTop = 400; el.dispatchEvent(new Event('scroll')) })
    for (const page of [pair.design, pair.product]) await page.clock.runFor(32)
    const read = page => page.evaluate(() => ['hist', 'plan', 'nq'].map(sec => ({
      sec, h: document.querySelector('#bd-sec-' + sec).style.height,
      head: document.querySelector('#bd-sec-' + sec + ' .bd-sech').innerHTML,
      cards: Array.from(document.querySelectorAll('#bd-sec-' + sec + ' .bd-card'), el => ({ id: el.dataset.id, top: el.style.top, height: el.style.height })).sort((a, b) => a.id.localeCompare(b.id))
    })))
    const design = await read(pair.design), product = await read(pair.product)
    // Virtual windows depend on the Now band, which has not landed; compare shared card geometry.
    for (let i = 0; i < design.length; i++) {
      expect(product[i].h, JSON.stringify({ sec: product[i].sec, product: product[i].head, design: design[i].head })).toBe(design[i].h); expect(product[i].head).toBe(design[i].head)
      for (const page of [pair.design, pair.product]) {
        await page.evaluate(sec => { const vp = document.querySelector('#bd-vp'); vp.scrollTop = document.querySelector('#bd-sec-' + sec).offsetTop + (sec === 'hist' ? 400 : 50); vp.dispatchEvent(new Event('scroll')) }, product[i].sec)
        await page.clock.runFor(32)
      }
      const dc = (await read(pair.design))[i].cards, pc = (await read(pair.product))[i].cards
      const byId = new Map(dc.map(card => [card.id.replace('AIUR-', ''), { ...card, id: card.id.replace('AIUR-', '') }]))
      const common = pc.filter(card => byId.has(card.id))
      if (pc.length) expect(common.length).toBeGreaterThan(0)
      for (const card of common) expect(card).toEqual(byId.get(card.id))
    }
    // Isolate the transparent header from unowned dot/edge backdrops (C9-T07/T10).
    for (const page of [pair.design, pair.product]) await page.addStyleTag({ content: '#bd-sec-hist .bd-sech { width: 1000px; background: var(--bg) }' })
    for (const page of [pair.design, pair.product]) await page.clock.setSystemTime(FIXTURE_META.now)
    await expectDesignParity(pair, { name: 'history-header-' + dataset, region: '#bd-sec-hist .bd-sech' })
  } finally { await pair.close() }
})

for (const name of ['history.load-earlier', 'history.window']) test(`history sequence parity: ${name}`, async ({ browser }) => {
  const pair = await openParityPair(browser, { viewport: { width: 1440, height: 900 }, theme: 'dark', palette: 'gruvbox', dataset: 'live' }, { motion: true })
  try {
    const [design, product] = await Promise.all([runOn(pair.design, name), runOn(pair.product, name)])
    expect(compareRecords(design, product)).toEqual([])
  } finally { await pair.close() }
})
