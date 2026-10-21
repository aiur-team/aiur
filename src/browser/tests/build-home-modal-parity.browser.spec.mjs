import { test, expect } from '@playwright/test'
import { PARITY_VIEWPORTS } from '../support/design-parity.mjs'
import { openModalPair } from '../support/build-home-modal-pair.mjs'
import { compareRegion } from '../support/build-home-region-parity.mjs'

// Offline reuses the live rows but prevents the design's mock conversation timer changing progress.
test.setTimeout(180_000)
// Each matrix cell exercises seven state headers against the frozen design.
for (const viewport of PARITY_VIEWPORTS) for (const theme of ['dark', 'light']) for (const palette of ['aiur', 'gruvbox']) {
  test(`modal headers and frame ${viewport.viewport.width} ${theme} ${palette}`, async ({ browser }) => {
    const pair = await openModalPair(browser, { ...viewport, theme, palette, dataset: 'offline' }, { productPending: true })
    for (const side of ['design', 'product']) pair[side].on('pageerror', error =>
      console.error(`[modal parity ${side}] ${pair[side].url()}\n${error.stack}`))
    try {
      // The body is excluded from this comparison. Prevent its reference-only mock log
      // from queuing scroll callbacks that run after another ticket replaces the body.
      await pair.design.addStyleTag({ content: '#tk-body #cv-log { overflow: clip !important; }' })
      await expect(pair.product.locator("#build-root")).toHaveAttribute("data-build-generation", /\d+/)
      const rows = await pair.product.evaluate(async () => {
        const { ctx } = await import('/build-home/state.js')
        return ['active', 'paused', 'command'].map(state => ctx.D.now.find(t => t.agent.state === state))
          .concat(['done', 'failed'].map(status => ctx.D.hist.find(t => t.status === status)), ctx.D.plan.find(t => t.wave < 5), ctx.D.nq[0])
      })
      for (const t of rows) {
        expect(t).toBeTruthy()
        await pair.design.evaluate(id => window.AiurBuild.open('AIUR-' + id), t.id)
        await pair.product.evaluate(async id => (await import('/build-home/modal/frame.js')).openById(id), t.id)
        // Only the frame/header belongs to this ticket; body ports have their own successors.
        for (const side of ['design', 'product']) await pair[side].locator('#tk-body').evaluate(el => { el.style.visibility = 'hidden' })
        for (const side of ['design', 'product']) await pair[side].locator('#tk-modal').evaluate(el => el.getAnimations().forEach(a => a.finish()))
        const geometry = []
        for (const side of ['design', 'product']) geometry.push(await pair[side].locator('#tk-modal').evaluate(el => {
          const b = el.getBoundingClientRect(), css = getComputedStyle(el)
          return { width: b.width, height: b.height, border: css.border, radius: css.borderRadius, shadow: css.boxShadow }
        }))
        expect(geometry[1]).toEqual(geometry[0])
        // Capture the real headers together so every state shares one stable pixel comparison.
        for (const side of ['design', 'product']) await pair[side].locator('#tk-head').evaluate(el => {
          let matrix = document.querySelector('#modal-header-matrix')
          if (!matrix) {
            matrix = document.createElement('div'); matrix.id = 'modal-header-matrix'; matrix.className = 'tk-modal bdm'
            matrix.style.cssText = 'position:absolute;top:0;height:auto;max-height:none;border:0;border-radius:0;box-shadow:none;animation:none;overflow:visible'
            matrix.style.width = el.parentElement.getBoundingClientRect().width + 'px'; document.body.append(matrix)
          }
          const copy = el.cloneNode(true)
          for (const node of [copy, ...copy.querySelectorAll('[id]')]) node.removeAttribute('id')
          matrix.append(copy)
        })
      }
      await compareRegion(pair, { name: `modal.head.offline.${viewport.viewport.width}.${theme}.${palette}`, region: '#modal-header-matrix' })
    } finally { await pair.close() }
  })
}
