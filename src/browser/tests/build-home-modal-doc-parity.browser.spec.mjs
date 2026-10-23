import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { DESIGN_ROOT, PARITY_VIEWPORTS } from '../support/design-parity.mjs'
import { openModalPair } from '../support/build-home-modal-pair.mjs'
import { compareRegion } from '../support/build-home-region-parity.mjs'

test.setTimeout(180_000)
for (const viewport of PARITY_VIEWPORTS.filter(v => v.viewport.width !== 1024)) for (const theme of ['dark', 'light']) {
  test(`issue document parity ${viewport.viewport.width} ${theme}`, async ({ browser }) => {
    const pair = await openModalPair(browser, { ...viewport, theme, palette: 'aiur', dataset: 'offline' }, { productPending: true })
    try {
      await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
      // The frozen generator clears failed cues and has no wait+override/NQ-dependency rows.
      // Supply those acceptance inputs to both datasets without changing either renderer.
      const js = await readFile(DESIGN_ROOT + '/assets/build.js', 'utf8')
      await pair.design.route('**/assets/build.js', route => route.fulfill({ contentType: 'text/javascript', body: js.replace('const children = {}; all.forEach', `
        plan[1].cue.failed = {by: 7, blocks: [plan[1].id, plan[2].id, plan[3].id]};
        plan.find(t => t.cue.wait).override = {hours: 4, reason: "Operator priority"};
        nq[0].deps = [plan[0].id];
        const children = {}; all.forEach`) }))
      await pair.design.reload()
      await expect(pair.design.locator('#bd-content')).toHaveCount(1)
      const rows = await pair.product.evaluate(async () => {
        const { ctx } = await import('/build-home/state.js')
        const held = ctx.D.plan.find(t => t.cue?.held)
        const failed = { ...ctx.D.plan[1], cue: { ...ctx.D.plan[1].cue, failed: { by: 7, blocks: [ctx.D.plan[1].id, ctx.D.plan[2].id, ctx.D.plan[3].id] } } }
        const waiting = { ...ctx.D.plan.find(t => t.cue?.wait), override: { hours: 4, reason: 'Operator priority' } }
        const nq = { ...ctx.D.nq[0], deps: [ctx.D.plan[0].id] }
        return [held, failed, waiting, nq, nq, nq]
      })
      for (const [index, t] of rows.entries()) {
        expect(t).toBeTruthy()
        await pair.design.evaluate(id => window.AiurBuild.open('AIUR-' + id), t.id)
        await pair.product.evaluate(async t => (await import('/build-home/modal/frame.js')).openModal(t), t)
        await expect(pair.product.locator('.bm-body h4').first()).toHaveText('Scope')
        // C7-T03 owns estimate values; this ticket explicitly renders unknown. Apply that
        // same written rule to reference facts, including a queue position if unknown.
        await pair.design.locator('.bm-facts > div').evaluateAll((facts, row) => {
          for (const fact of facts) {
            const label = fact.querySelector('small').textContent
            if (label === 'Estimate' || (label === 'Queue' && row.sec === 'plan' && row.qpos == null)) fact.querySelector('b').textContent = '—'
          }
        }, t)
        for (const side of ['design', 'product']) {
          await pair[side].locator('#tk-modal').evaluate(el => el.getAnimations().forEach(a => a.finish()))
          if (index === 4) await pair[side].locator('.bm-dep').first().hover()
          if (index === 5) await pair[side].locator('.bm-side .btn').hover()
        }
        await compareRegion(pair, { name: `modal.doc.${viewport.viewport.width}.${theme}.${index}`, region: '#tk-modal' })
      }
    } finally { await pair.close() }
  })
}
