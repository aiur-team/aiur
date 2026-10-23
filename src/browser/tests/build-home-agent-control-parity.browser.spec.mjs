import { test, expect } from '@playwright/test'
import { hideDesignChat, openModalPair } from '../support/build-home-modal-pair.mjs'
import { compareRegion } from '../support/build-home-region-parity.mjs'

test.setTimeout(180_000)
for (const width of [1440, 390]) for (const theme of ['dark', 'light']) {
  test(`agent controls ${width} ${theme}`, async ({ browser }) => {
    const pair = await openModalPair(browser, { viewport: { width, height: 1000 }, theme, palette: 'aiur', dataset: 'offline' }, { productPending: true })
    try {
      await hideDesignChat(pair)
      await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
      const rows = await pair.product.evaluate(async () => {
        const { ctx } = await import('/build-home/state.js')
        return ['active', 'paused'].map(state => ctx.D.now.find(t => t.agent?.state === state))
      })
      for (const row of rows) {
        await pair.design.evaluate(id => window.AiurBuild.open('AIUR-' + id), row.id)
        await pair.product.evaluate(async id => (await import('/build-home/modal/frame.js')).openById(id), row.id)
        await expect(pair.product.locator('.bm-agent')).toHaveAttribute('data-control', 'ready')
        await expect(pair.product.locator('[data-a="pause"]')).not.toHaveAttribute('aria-disabled')
        await compareRegion(pair, { name: `modal.controls.${row.agent.state}.${width}.${theme}`, region: '#tk-head .bm-act' })
        if (width === 1440 && theme === 'dark' && row.agent.state === 'active') {
          for (const side of ['design', 'product']) await pair[side].locator('#tk-head [data-a="pause"]').hover()
          await compareRegion(pair, { name: 'modal.controls.hover.1440.dark', region: '#tk-head .bm-act' })
        }
      }
    } finally { await pair.close() }
  })
}
