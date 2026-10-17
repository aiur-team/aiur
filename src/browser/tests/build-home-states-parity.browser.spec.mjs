import { test, expect } from '@playwright/test'
import { openParityPair, expectDesignParity, PARITY_VIEWPORTS, applyAllowlist } from '../support/design-parity.mjs'

// Port guards preserve existing healthy markers and offline styling; degraded states are new coverage.
test.setTimeout(90000)
for (const viewport of PARITY_VIEWPORTS) for (const theme of ['light', 'dark']) for (const palette of ['aiur', 'gruvbox']) {
  for (const [dataset, sec] of [['newrepo', 'hist'], ['noqueue', 'plan']]) test(`empty marker parity ${dataset} ${viewport.viewport.width} ${theme} ${palette}`, async ({ browser }) => {
    const pair = await openParityPair(browser, { ...viewport, theme, palette, dataset })
    try {
      for (const page of [pair.design, pair.product]) await page.locator('#bd-vp').evaluate((vp, sec) => { vp.scrollTop = document.querySelector('#bd-sec-' + sec).offsetTop - 160 }, sec)
      await applyAllowlist(pair, pair.cell)
      const region = '#bd-sec-' + sec + ' .bd-mk.empty'
      await expect(pair.product.locator(region)).toHaveText(await pair.design.locator(region).textContent())
      const read = page => page.locator(region).evaluate(el => {
        const s = getComputedStyle(el)
        return ['top', 'left', 'width', 'height', 'display', 'gap'].map(key => s[key])
      })
      expect(await read(pair.product)).toEqual(await read(pair.design))
      // Isolate the owned marker from the adjacent Now band's shadow, retaining
      // its real size, CSS, typography and viewport background on both sides.
      for (const page of [pair.design, pair.product]) await page.locator(region).evaluate(el => {
        const vp = document.querySelector('#bd-vp'), bg = getComputedStyle(vp), box = el.getBoundingClientRect()
        const host = document.createElement('div'); host.className = 'bd-root'; host.id = 'marker-capture'
        Object.assign(host.style, { position: 'fixed', top: '0', left: '0', zIndex: '2147483647',
          width: box.width + 'px', height: box.height + 'px', background: bg.background, backgroundSize: bg.backgroundSize })
        document.body.append(host); host.append(el)
        Object.assign(el.style, { top: '0', left: '0', width: box.width + 'px' })
      })
      await expectDesignParity(pair, { name: `empty-${dataset}-${viewport.viewport.width}-${theme}-${palette}`, region: '#marker-capture' })
    } finally { await pair.close() }
  })
  test(`offline banner parity ${viewport.viewport.width} ${theme} ${palette}`, async ({ browser }) => {
    const pair = await openParityPair(browser, { ...viewport, theme, palette, dataset: 'offline' })
    try {
      for (const page of [pair.design, pair.product]) await page.locator('#bd-offline').evaluate(el => {
        const box = el.getBoundingClientRect()
        let parent = el.parentElement, color = 'rgba(0, 0, 0, 0)'
        while (parent && color === 'rgba(0, 0, 0, 0)') { color = getComputedStyle(parent).backgroundColor; parent = parent.parentElement }
        const host = document.createElement('div'); host.className = 'bd-root'; host.id = 'offline-capture'
        // Preserve the translucent banner over its actual ancestor background,
        // isolated from unowned mobile chrome beneath the fixed capture origin.
        Object.assign(host.style, { position: 'fixed', top: '0', left: '0', width: box.width + 'px',
          height: box.height + 'px', zIndex: '2147483647', backgroundColor: color })
        document.body.append(host); host.append(el)
      })
      await expectDesignParity(pair, { name: `offline-${viewport.viewport.width}-${theme}-${palette}`, region: '#offline-capture' })
    }
    finally { await pair.close() }
  })
}
for (const width of [1440, 390]) test(`degraded marker retains design geometry ${width}`, async ({ browser }) => {
  // The design is specified at 390 with phone (overlay) scrollbars, as in PARITY_VIEWPORTS (#4885).
  const pair = await openParityPair(browser, { ...PARITY_VIEWPORTS.find(v => v.viewport.width === width), viewport: { width, height: 900 }, theme: 'dark', palette: 'aiur', dataset: 'newrepo' })
  try {
    await pair.product.goto(new URL('/build-fixture/degraded', pair.product.url()).href)
    await expect(pair.product.locator('#bd-content')).toHaveCount(1)
    for (const page of [pair.design, pair.product]) await page.locator('#bd-vp').evaluate(vp => { vp.scrollTop = document.querySelector('#bd-sec-hist').offsetTop - 160 })
    const read = page => page.locator('#bd-sec-hist .bd-mk.empty').evaluate(el => {
      const s = getComputedStyle(el), props = ['top', 'left', 'width', 'height']
      return { box: props.map(k => s[k]), text: ['b', 'p'].map(sel => { const st = getComputedStyle(el.querySelector(sel)); return ['font', 'color', 'maxWidth'].map(k => st[k]) }) }
    })
    expect(await read(pair.product)).toEqual(await read(pair.design))
    await expect(pair.product.locator('#bd-sec-nq .bd-sech')).toContainText('stale, read 3 h ago (11:20)')
    if (width === 390) expect(await pair.product.locator('#bd-vp').evaluate(el => el.scrollWidth === el.clientWidth)).toBe(true)
  } finally { await pair.close() }
})
