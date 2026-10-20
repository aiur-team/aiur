import { test, expect } from '@playwright/test'
import { PARITY_VIEWPORTS, openParityPair, expectDesignParity } from '../support/design-parity.mjs'

test.setTimeout(90_000)

// The board and shell are still being ported; compare the complete usage region.
for (const viewport of PARITY_VIEWPORTS) for (const theme of ['dark','light']) for (const palette of ['aiur','gruvbox']) for (const count of [2,4,7]) {
  test(`usage ${viewport.viewport.width} ${theme} ${palette} n${count}`, async ({ browser }) => {
    const pair = await openParityPair(browser, { ...viewport, theme, palette, dataset:'live' }, { productPending:true, motion:true, query:`models=${count}` })
    try {
      await expect(pair.product.locator('.ax-usage')).toBeVisible()
      if (count !== 4) expect((await pair.product.request.get(`/build-control/usage?name=n${count}`)).status()).toBe(200)
      await expect(pair.product.locator('.ax-usage')).toHaveClass(new RegExp(`n${count} `))
      const widths = {}
      for (const side of ['design','product']) widths[side] = await pair[side].locator('#build-root').evaluate(el => ({
        width: el.getBoundingClientRect().width,
        containerName: getComputedStyle(el).containerName
      }))
      await test.info().attach('usage-container-widths', { body: JSON.stringify({ viewport: viewport.viewport.width, ...widths }), contentType: 'application/json' })
      if (theme === 'dark' && palette === 'aiur' && count === 2) console.info('usage bd container widths', JSON.stringify({ viewport: viewport.viewport.width, ...widths }))
      for (const side of ['design','product']) expect(widths[side].containerName).toBe('bd')
      expect(widths.product.width).toBe(widths.design.width)
      if (viewport.viewport.width === 1024) for (const side of ['design','product']) {
        expect(widths[side].width).toBeGreaterThan(460)
        expect(widths[side].width).toBeLessThanOrEqual(820)
      }
      await expectDesignParity(pair,{name:`usage-n${count}`,region:'#bd-usage'})
    } finally { await pair.close() }
  })
}

import { pausedAnimations, compareRecords, runOn } from '../support/build-home-motion.mjs'
for (const theme of ['dark','light']) for (const selector of ['.mdl .ax-ln', '.api .ax-ln:nth-child(2)']) test(`usage popover and grain ${theme} ${selector}`, async ({ browser }) => {
  const pair = await openParityPair(browser, { ...PARITY_VIEWPORTS[0], theme, palette:'aiur', dataset:'live' }, { productPending:true, motion:true })
  try {
    const records=[]
    for (const side of ['design','product']) {
      await pair[side].locator('body > .ax-pop').evaluate(el => getComputedStyle(el).opacity)
      await pair[side].locator(selector).first().dispatchEvent('mouseover')
      const animations=await pausedAnimations(pair[side],'body > .ax-pop')
      expect(animations.map(a => a.name).sort(),side).toEqual(['opacity','transform'])
      records.push({name:'usage.popover',samples:animations})
    }
    expect(compareRecords(records[0],records[1])).toEqual([])
    for (const side of ['design','product']) await pair[side].evaluate(() => window.motionAnimations.forEach(a => { a.currentTime=Number(a.effect.getTiming().duration) }))
    await expectDesignParity(pair,{preserveAnimations:true,name:`popover-${selector.startsWith('.mdl') ? 'model' : 'gql'}-${theme}`,region:'body > .ax-pop.show'})
    const design=await runOn(pair.design,'grain.static',{selector:'.ax-uc'})
    const product=await runOn(pair.product,'grain.static',{selector:'.ax-uc'})
    expect(compareRecords(design,product)).toEqual([])
    expect(product['ax-uc'].after.display).toBe(theme === 'light' ? 'none' : 'block')
  } finally { await pair.close() }
})
