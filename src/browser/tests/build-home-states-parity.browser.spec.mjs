import { test, expect } from '@playwright/test'
import { openParityPair, expectDesignParity, PARITY_VIEWPORTS, applyAllowlist } from '../support/design-parity.mjs'

test.setTimeout(90000)
for (const viewport of PARITY_VIEWPORTS) for (const theme of ['light', 'dark']) for (const palette of ['aiur', 'gruvbox']) {
  for (const [dataset, sec] of [['newrepo', 'hist'], ['noqueue', 'plan']]) test(`empty marker parity ${dataset} ${viewport.viewport.width} ${theme} ${palette}`, async ({ browser }) => {
    const pair = await openParityPair(browser, { ...viewport, theme, palette, dataset })
    try {
      for (const page of [pair.design, pair.product]) await page.locator('#bd-vp').evaluate((vp, sec) => { vp.scrollTop = document.querySelector('#bd-sec-' + sec).offsetTop - 160 }, sec)
      await applyAllowlist(pair, pair.cell)
      const region = '#bd-sec-' + sec + ' .bd-mk.empty'
      await expect(pair.product.locator(region)).toHaveText(await pair.design.locator(region).textContent())
      await expectDesignParity(pair, { name: `empty-${dataset}-${viewport.viewport.width}-${theme}-${palette}`, region })
    } finally { await pair.close() }
  })
  test(`offline banner parity ${viewport.viewport.width} ${theme} ${palette}`, async ({ browser }) => {
    const pair = await openParityPair(browser, { ...viewport, theme, palette, dataset: 'offline' })
    try { await expectDesignParity(pair, { name: `offline-${viewport.viewport.width}-${theme}-${palette}`, region: '#bd-offline' }) }
    finally { await pair.close() }
  })
}
for (const width of [1440, 390]) test(`degraded marker retains design geometry ${width}`, async ({ browser }) => {
  const pair = await openParityPair(browser, { viewport: { width, height: 900 }, theme: 'dark', palette: 'aiur', dataset: 'newrepo' })
  try {
    await pair.product.goto(new URL('/build-fixture/degraded', pair.product.url()).href)
    await expect(pair.product.locator('#bd-content')).toHaveCount(1)
    for (const page of [pair.design, pair.product]) await page.locator('#bd-vp').evaluate(vp => { vp.scrollTop = document.querySelector('#bd-sec-hist').offsetTop - 160 })
    const read = page => page.locator('#bd-sec-hist .bd-mk.empty').evaluate(el => {
      const s = getComputedStyle(el), props = ['top', 'left', 'width', 'height']
      return { box: props.map(k => s[k]), text: ['b', 'p'].map(sel => { const st = getComputedStyle(el.querySelector(sel)); return ['font', 'color', 'maxWidth'].map(k => st[k]) }) }
    })
    expect(await read(pair.product)).toEqual(await read(pair.design))
    if (width === 390) expect(await pair.product.locator('#bd-vp').evaluate(el => el.scrollWidth === el.clientWidth)).toBe(true)
  } finally { await pair.close() }
})
