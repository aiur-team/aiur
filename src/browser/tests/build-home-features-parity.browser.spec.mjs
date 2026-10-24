import { test, expect } from '@playwright/test'
import { pairedBrowser } from '../support/build-home-feature-parity-source.mjs'
import { openParityPair, expectDesignParity } from '../support/design-parity.mjs'
for (const feature of ['pag', 'khala']) for (const width of [1440, 1024, 390]) for (const theme of ['dark', 'light']) for (const palette of ['gruvbox', 'aiur']) test(`feature header ${feature} ${width} ${theme} ${palette}`, async ({ browser }) => {
  test.setTimeout(120000)
  const pair = await openParityPair(await pairedBrowser(browser), { viewport: { width, height: 900 }, theme, palette }, { dataset: 'live', query: `feature=${feature}`, motion: true })
  try {
    // Isolate the header at one raster origin and width, outside shell chrome and paging reflow.
    await expect.poll(() => pair.product.evaluate(async () => {
      const { S, ctx } = await import('/build-home/state.js'), { H } = await import('/build-home/history.js')
      return ctx.D.features[S.feature].oldest == null || S.histFrom <= ctx.D.features[S.feature].oldest || !H.more
    })).toBe(true)
    const boxes = await Promise.all([pair.design, pair.product].map(page => page.locator('#bd-fh').boundingBox()))
    const available = Math.floor(Math.min(...boxes.map(box => box.width)))
    await test.info().attach('header-shell-widths', { body: Buffer.from(JSON.stringify({ design: boxes[0], product: boxes[1], available })), contentType: 'application/json' })
    for (const page of [pair.design, pair.product]) await page.locator('#bd-fh').evaluate((host, width) => { Object.assign(host.style, { width: width + 'px', position: 'fixed', top: '100px', left: '19px', zIndex: '9999', background: 'var(--bg)' }) }, available)
    await expect(pair.product.locator('.bd-fh')).toBeVisible()
    const html = page => page.locator('#bd-fh').evaluate(el => el.innerHTML)
    expect(await html(pair.product)).toBe(await html(pair.design))
    await expectDesignParity(pair, { name: `feature-${feature}-${width}-${theme}-${palette}`, region: '#bd-fh' })
    await pair.product.locator('[data-m="compact"]').click()
    await pair.design.locator('[data-m="compact"]').click()
    await pair.product.clock.runFor(400); await pair.design.clock.runFor(400)
    for (const page of [pair.design, pair.product]) await page.clock.setSystemTime(1791408000000)
    expect(await html(pair.product)).toBe(await html(pair.design))
    await expectDesignParity(pair, { name: `feature-compact-${feature}-${width}-${theme}-${palette}`, region: '#bd-fh' })
  } finally { await pair.close() }
})
