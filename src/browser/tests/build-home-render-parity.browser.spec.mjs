import { readFile } from 'node:fs/promises'
import { test, expect } from '@playwright/test'
import { openParityPair, expectDesignParity, applyAllowlist, FIXTURE_META, waitParityReady } from '../support/design-parity.mjs'
import { runOn, compareRecords } from '../support/build-home-motion.mjs'

// Two page openings plus three windows in each section; this is not a perf budget.
test.setTimeout(120_000)

const source = await readFile(new URL('../../test/fixtures/build_home/design-source/assets/build.js', import.meta.url), 'utf8')
const anchor = '  window.AiurBuild = {'
expect(source.split(anchor)).toHaveLength(2)
// Expose the original update; disable automatic paging only for static component captures.
const probe = source.replace(anchor, `window.__E8Render = { stop: () => { S.ready = false; snapping = true; }, scroll(sec, offset) {
  vp.scrollTop = secs[sec].el.offsetTop + offset; update();
} };\n${anchor}`)

for (const width of [1440, 390]) for (const theme of ['light', 'dark']) for (const dataset of ['live', 'dense', 'newrepo', 'noqueue']) test(`section headers and vertical geometry match the design: ${dataset} ${width} ${theme}`, async ({ browser }) => {
  const cell = { viewport: { width, height: width === 390 ? 844 : 900 }, theme, palette: 'aiur', dataset, ...(width === 390 ? { deviceScaleFactor: 3, isMobile: true, hasTouch: true } : {}) }
  const pair = await openParityPair(browser, cell, { motion: true })
  try {
    await pair.design.route('**/assets/build.js*', route => route.fulfill({ contentType: 'text/javascript', body: probe }))
    await pair.design.reload()
    await waitParityReady(pair.design, 'board', 'design', true)
    await pair.design.evaluate(() => window.__E8Render.stop())
    // Collapse the separately owned sticky Now band through its actual UI, so
    // it cannot cover section headers while their natural pixels are captured.
    for (const page of [pair.design, pair.product]) {
      await page.locator('[data-min]').evaluate(button => button.click())
      await expect(page.locator('#bd-now')).toHaveClass(/min/)
    }
    await pair.product.evaluate(async () => { const { S, ctx } = await import('/build-home/state.js'); S.ready = false; ctx.snapping = true })
    // The fixture's initial zoom updates --dot and transitions background-size
    // for 400ms. Read it only after both pages finish that real transition;
    // otherwise their computed values can differ by a fraction of a pixel.
    await Promise.all([pair.design, pair.product].map(page => page.locator('#bd-vp').evaluate(vp => {
      const transition = vp.getAnimations().find(animation => animation.transitionProperty === 'background-size')
      if (transition) transition.finish()
    })))
    // Preserve the harness's existing AA palette exceptions; add no local masks/styles.
    await applyAllowlist(pair, pair.cell)
    const read = page => page.evaluate(() => ['hist', 'plan', 'nq'].map(sec => ({
      sec, h: document.querySelector('#bd-sec-' + sec).style.height,
      contentWidth: document.querySelector('#bd-content').style.width, dot: getComputedStyle(document.querySelector('#bd-vp')).backgroundSize,
      head: document.querySelector('#bd-sec-' + sec + ' .bd-sech').innerHTML,
      typography: Array.from(document.querySelectorAll('#bd-sec-' + sec + ' .bd-sech, #bd-sec-' + sec + ' .bd-sech em'), el => {
        const style = getComputedStyle(el)
        return Object.fromEntries(['font', 'color', 'letterSpacing', 'textTransform', 'whiteSpace'].map(key => [key, style[key]]))
      }),
      cards: Array.from(document.querySelectorAll('#bd-sec-' + sec + ' .bd-card'), el => ({ id: el.dataset.id.replace('AIUR-', ''), top: parseFloat(el.style.top), height: parseFloat(el.style.height) })).sort((a, b) => a.id.localeCompare(b.id)),
      marks: Array.from(document.querySelectorAll('#bd-sec-' + sec + ' .bd-mk, #bd-sec-' + sec + ' .bd-lbl, #bd-sec-' + sec + ' .bd-dl'), el => ({
        cls: el.className, text: el.textContent, ...Object.fromEntries(['top', 'height', 'left', 'width'].map(key => [key, parseFloat(getComputedStyle(el)[key])]))
      }))
    })))
    const design = await read(pair.design), product = await read(pair.product)
    // Section-relative inputs isolate virtualization and card geometry. The
    // Now-band suite covers composed mobile headers at matching global scroll.
    // Compare every owned card/mark, with exact identity (never an intersection).
    for (let i = 0; i < design.length; i++) {
      expect(product[i].h).toBe(design[i].h); expect(product[i].head).toBe(design[i].head)
      expect(product[i].typography).toEqual(design[i].typography)
      expect(product[i].contentWidth).toBe(design[i].contentWidth); expect(product[i].dot).toBe(design[i].dot)
      const h = parseFloat(design[i].h)
      for (const offset of [Math.max(0, h - 46), Math.max(0, h - 2046), 0]) {
        await pair.design.evaluate(({ sec, offset }) => window.__E8Render.scroll(sec, offset), { sec: design[i].sec, offset })
        await pair.product.evaluate(async ({ sec, offset }) => {
          const { ctx, fx } = await import('/build-home/state.js')
          ctx.vp.scrollTop = ctx.secs[sec].el.offsetTop + offset; fx.update()
        }, { sec: design[i].sec, offset })
        const dc = (await read(pair.design))[i], pc = (await read(pair.product))[i]
        expect(pc.cards.map(card => card.id)).toEqual(dc.cards.map(card => card.id))
        for (let j = 0; j < dc.cards.length; j++) for (const key of ['top', 'height']) expect(Math.abs(pc.cards[j][key] - dc.cards[j][key])).toBeLessThanOrEqual(1)
        expect(pc.marks.map(mark => [mark.cls, mark.text])).toEqual(dc.marks.map(mark => [mark.cls, mark.text]))
        for (let j = 0; j < dc.marks.length; j++) for (const key of ['top', 'height', 'left', 'width']) expect(Math.abs(pc.marks[j][key] - dc.marks[j][key])).toBeLessThanOrEqual(1)
      }
      for (const page of [pair.design, pair.product]) {
        await page.clock.setSystemTime(FIXTURE_META.now)
        await page.locator('#bd-vp').evaluate((vp, sec) => { vp.scrollIntoView({ block: 'start' }); vp.scrollTop = document.querySelector('#bd-sec-' + sec).offsetTop - 160 }, design[i].sec)
      }
      // Accepted scope decision dec_2043ed93d73bbe63: mobile uses exact DOM,
      // geometry and typography. C9-T08 owns composed mobile header pixels,
      // without masks. Retain the existing unmodified desktop element capture.
      if (width === 1440 && design[i].sec === 'hist') await expectDesignParity(pair, {
        name: `header-hist-${dataset}-${width}-${theme}`, region: '#bd-sec-hist .bd-sech em:first-child'
      })
    }
  } finally { await pair.close() }
})

for (const name of ['history.load-earlier', 'history.window']) test(`history sequence parity: ${name}`, async ({ browser }) => {
  const pair = await openParityPair(browser, { viewport: { width: 1440, height: 900 }, theme: 'dark', palette: 'gruvbox', dataset: name === 'history.window' ? 'dense' : 'live' }, { motion: true })
  try {
    const [design, product] = await Promise.all([runOn(pair.design, name), runOn(pair.product, name)])
    expect(compareRecords(design, product)).toEqual([])
  } finally { await pair.close() }
})
