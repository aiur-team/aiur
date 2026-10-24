import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { estimatePatch } from '../scripts/build-home-now-patch.mjs'
import { openParityPair, expectDesignParity, waitParityReady, PARITY_VIEWPORTS } from '../support/design-parity.mjs'
import { prepareFilterCapture } from '../support/build-home-filter-parity.mjs'
import { pairedBrowser } from '../support/build-home-feature-parity-source.mjs'
import { FIXTURE_META } from '../support/design-parity-environment.mjs'

const reference = estimatePatch(await readFile(new URL('../../test/fixtures/build_home/design-source/assets/build.js', import.meta.url), 'utf8'))
const anchor = '  window.AiurBuild = {'
expect(reference.split(anchor)).toHaveLength(2)
// Expose only the original renderer, as the existing render-parity fixture does.
const probe = reference.replace(anchor, '  window.__featureRedraw = () => drawEdges(true); window.__featureStop = () => { S.ready = false; snapping = true; };\n' + anchor)
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
  await expect(pair.product.locator('#build-root')).toHaveAttribute('data-bd-paging', 'idle')
  const count = page => page.locator('#bd-sec-hist .bd-sech em').last().textContent()
  const target = await count(pair.product)
  for (let day = 0; await count(pair.design) !== target; day++) {
    if (day > 220) throw new Error('History windows differ: ' + await count(pair.design) + ' vs ' + target)
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
  const pair = await openParityPair(await pairedBrowser(browser), { ...PARITY_VIEWPORTS.find(view => view.viewport.width === cell.width), theme: cell.theme, palette: 'gruvbox', reducedMotion: cell.reduce ? 'reduce' : 'no-preference' }, { dataset: cell.dataset, query, motion: true })
  try {
    await pair.design.route('**/assets/build.js*', route => route.fulfill({ contentType: 'text/javascript', body: probe }))
    const referenceURL = new URL(pair.design.url())
    if (cell.mode === 'compact') referenceURL.searchParams.set('fmode', 'focus')
    await pair.design.goto(referenceURL.href); await waitParityReady(pair.design, 'board', 'design', true)
    if (cell.view !== 'list') await align(pair)
    // Static scene capture: freeze only automatic paging/snap after real span loading.
    // Feature state still comes from the URL and the original mode button.
    await pair.design.evaluate(() => window.__featureStop())
    await pair.product.evaluate(async () => { const { S, ctx } = await import('/build-home/state.js'); S.ready = false; ctx.snapping = true })
    if (cell.mode === 'compact') await pair.design.locator('#bd-fh [data-m=compact]').click()
    await prepareFilterCapture(pair)
    const boxes = await Promise.all([pair.design, pair.product].map(p => p.locator('#build-root').boundingBox()))
    const width = Math.floor(Math.min(...boxes.map(b => b.width)))
    for (const page of [pair.design, pair.product]) {
      await page.locator('#build-root').evaluate((el, width) => { el.style.width = width + 'px' }, width)
      // The reference observes window resize; the product also observes its root.
      // Re-render both after aligning shell widths so their layout uses that width.
      if (page === pair.design) await page.evaluate(() => window.AiurBuild.render())
      else await page.evaluate(async () => (await import('/build-home/state.js')).fx.relayout())
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
    if (cell.view === 'list') for (const page of [pair.design, pair.product]) {
      // Same viewport isolation as list parity: preserve paint and remove shell raster origins.
      const paint = await page.locator('#bd-vp').evaluate(vp => {
        const box = vp.getBoundingClientRect(), root = vp.closest('.bd-root'), top = vp.scrollTop, cs = getComputedStyle(vp)
        const fields = ['backgroundColor', 'backgroundImage', 'backgroundSize', 'fontFamily', 'fontSize', 'lineHeight'], before = fields.map(k => cs[k])
        const host = document.createElement('div'); host.className = root.className
        Object.assign(host.style, { position: 'fixed', top: '0', left: '0', width: box.width + 'px', height: box.height + 'px', background: 'var(--bg)', zIndex: '9999' })
        for (const key of ['--board-bg', '--dot']) host.style.setProperty(key, cs.getPropertyValue(key))
        document.body.append(host); host.append(vp)
        Object.assign(vp.style, { width: box.width + 'px', height: box.height + 'px', minHeight: '0', flex: 'none', margin: '0' }); vp.scrollTop = top
        document.documentElement.style.scrollBehavior = 'auto'; window.scrollTo({ top: 0, behavior: 'instant' })
        return [before, fields.map(k => getComputedStyle(vp)[k])]
      })
      expect(paint[1]).toEqual(paint[0])
    }
    await pair.design.evaluate(() => window.__featureRedraw())
    await pair.product.evaluate(async () => (await import('/build-home/state.js')).fx.drawEdges(true))
    await expectDesignParity(pair, { name: `feature-scene-${Object.values(cell).join('-')}`, region: '#bd-vp', viewportClip: true })
  } finally { await pair.close() }
})
