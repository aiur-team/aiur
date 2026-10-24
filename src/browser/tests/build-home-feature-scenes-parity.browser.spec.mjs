import { test, expect } from '@playwright/test'
import { openParityPair, expectDesignParity } from '../support/design-parity.mjs'
import { prepareFilterCapture } from '../support/build-home-filter-parity.mjs'
import { pairedBrowser } from '../support/build-home-feature-parity-source.mjs'
import { FIXTURE_META } from '../support/design-parity-environment.mjs'

const cells = [
  ...['live', 'dense'].flatMap(dataset => [1440, 1024].flatMap(width => ['dark', 'light'].map(theme => ({ dataset, width, theme, mode: 'focus', section: 'now' })))),
  ...['dark', 'light'].map(theme => ({ dataset: 'live', width: 1440, theme, mode: 'compact', section: 'hist', feature: 'khala' })),
  ...['focus', 'compact'].flatMap(mode => [false, true].map(reduce => ({ dataset: 'live', width: 1440, theme: 'dark', mode, section: mode === 'compact' ? 'hist' : 'now', view: 'gantt', feature: mode === 'compact' ? 'khala' : 'pag', reduce }))),
  ...['live', 'noqueue'].map(dataset => ({ dataset, width: 1440, theme: 'dark', mode: 'compact', section: 'plan' })),
  ...[1440, 390].map(width => ({ dataset: 'live', width, theme: 'dark', mode: 'focus', section: 'list', view: 'list' })),
]
async function align(pair) {
  await expect.poll(() => pair.product.evaluate(async () => {
    const { S, ctx } = await import('/build-home/state.js'), { H } = await import('/build-home/history.js')
    const oldest = ctx.D.features[S.feature]?.oldest
    return oldest == null || S.histFrom <= oldest || !H.more
  })).toBe(true)
  const count = page => page.locator('#bd-sec-hist .bd-sech em').last().textContent()
  const target = await count(pair.product)
  for (let day = 0; await count(pair.design) !== target; day++) {
    if (day > 220) throw new Error('History windows differ')
    await pair.design.locator('#bd-vp').evaluate(vp => { vp.scrollTop = 0; vp.dispatchEvent(new Event('scroll')) })
    await pair.design.clock.runFor(32)
  }
}
const state = page => page.evaluate(() => ({
  cards: [...document.querySelectorAll('.bd-card')].map(el => ({ id: el.dataset.id.replace(/^AIUR-/, ''), classes: ['dim', 'also', 'feat-on', 'ghost'].filter(c => el.classList.contains(c)) })).sort((a, b) => a.id.localeCompare(b.id)),
  gaps: [...document.querySelectorAll('.bd-mk.gap')].map(el => ({ top: el.style.top, height: el.style.height, text: el.textContent })),
  header: document.querySelector('#bd-fh').innerHTML.replace(/\s+/g, ' '),
}))
for (const cell of cells) test(`feature scene ${Object.values(cell).join(' ')}`, async ({ browser }) => {
  test.setTimeout(180000)
  const query = `feature=${cell.feature || 'pag'}&fmode=${cell.mode}&view=${cell.view || 'graph'}`
  const pair = await openParityPair(await pairedBrowser(browser), { viewport: { width: cell.width, height: 900 }, theme: cell.theme, palette: 'gruvbox', reducedMotion: cell.reduce ? 'reduce' : 'no-preference' }, { dataset: cell.dataset, query, motion: true })
  try {
    if (cell.view !== 'list') await align(pair)
    await prepareFilterCapture(pair)
    const boxes = await Promise.all([pair.design, pair.product].map(p => p.locator('#build-root').boundingBox()))
    const width = Math.floor(Math.min(...boxes.map(b => b.width)))
    for (const page of [pair.design, pair.product]) {
      await page.locator('#build-root').evaluate((el, width) => { el.style.width = width + 'px' }, width)
      await page.clock.runFor(800)
      if (cell.section === 'now') { await page.locator('#bd-nowbtn').click(); await page.clock.runFor(800) }
      else await page.locator('#bd-vp').evaluate((vp, sec) => new Promise(resolve => {
        const el = document.querySelector(sec === 'list' ? '.bd-list' : sec === 'now' ? '#bd-now' : '#bd-sec-' + sec)
        const top = sec === 'hist' || sec === 'list' ? 0 : vp.scrollTop + el.getBoundingClientRect().top - vp.getBoundingClientRect().top
        if (vp.scrollTop === top) return resolve()
        vp.addEventListener('scroll', resolve, { once: true }); vp.scrollTop = top
      }), cell.section)
      await page.clock.runFor(800)
      await page.clock.setSystemTime(FIXTURE_META.now)
      await page.evaluate(() => document.getAnimations().forEach(a => { if (Number.isFinite(a.effect?.getComputedTiming().endTime)) a.finish() }))
    }
    expect(await state(pair.product)).toEqual(await state(pair.design))
    // Settle through the actual delegated hover handlers before capturing.
    for (const page of [pair.design, pair.product]) {
      await page.locator('#bd-vp').evaluate(vp => vp.dispatchEvent(new Event('scroll')))
      await page.clock.runFor(800)
      await page.clock.setSystemTime(FIXTURE_META.now)
      const visible = await page.locator('.bd-card').evaluateAll(cards => {
        const vp = document.querySelector('#bd-vp').getBoundingClientRect()
        return cards.find(el => { const r = el.getBoundingClientRect(), x = r.x + r.width / 2, y = r.y + r.height / 2; return y >= vp.top + 50 && y < Math.min(vp.bottom, innerHeight) && x >= vp.left && x < vp.right && document.elementFromPoint(x, y)?.closest('.bd-card') === el })?.dataset.id
      })
      if (visible) { await page.locator(`.bd-card[data-id="${visible}"]`).hover({ timeout: 5000 }); await page.mouse.move(0, 0); await page.clock.runFor(800) }
      await page.clock.setSystemTime(FIXTURE_META.now)
      await page.screenshot({ animations: 'allow' })
    }
    for (const side of ['design', 'product']) await test.info().attach(side + '-edge-diagnostics', { body: Buffer.from(JSON.stringify(await pair[side].evaluate(() => [...document.querySelectorAll('svg.bd-edges path')].map(el => ({ d: el.getAttribute('d'), cls: el.getAttribute('class'), style: Object.fromEntries(['stroke', 'strokeWidth', 'strokeDasharray', 'strokeDashoffset', 'filter', 'opacity', 'transform', 'animation'].map(k => [k, getComputedStyle(el)[k]])), svg: el.ownerSVGElement.getBoundingClientRect().toJSON() }))))), contentType: 'application/json' })
    await expectDesignParity(pair, { name: `feature-scene-${Object.values(cell).join('-')}`, region: '#bd-vp', viewportClip: true })
  } finally { await pair.close() }
})
