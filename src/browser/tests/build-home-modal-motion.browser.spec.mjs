import { test, expect } from '@playwright/test'
import { PARITY_VIEWPORTS } from '../support/design-parity.mjs'
import { openModalPair } from '../support/build-home-modal-pair.mjs'

test.setTimeout(90_000)
for (const viewport of PARITY_VIEWPORTS) test(`modal tkin samples and instant close ${viewport.viewport.width}`, async ({ browser }) => {
  const pair = await openModalPair(browser, { ...viewport, theme: 'dark', palette: 'aiur', dataset: 'offline' }, { productPending: true })
  try {
    await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
    const id = await pair.product.evaluate(async () => (await import('/build-home/state.js')).ctx.D.now[0].id)
    const samples = []
    for (const side of ['design', 'product']) {
      await pair[side].evaluate(async ({ id, side }) => {
        if (side === 'design') window.AiurBuild.open('AIUR-' + id)
        else (await import('/build-home/modal/frame.js')).openModal((await import('/build-home/state.js')).ctx.D.byId[id])
        const el = document.querySelector('#tk-modal')
        const animation = el.getAnimations().find(a => a.animationName === 'tkin')
        if (!animation) throw new Error('tkin did not start')
        animation.pause(); window.modalAnimation = animation
      }, { id, side })
      samples.push(await pair[side].evaluate(() => {
        const a = window.modalAnimation, timing = a.effect.getTiming()
        const frames = [0, 60, 120, 180, 240].map(at => {
          a.currentTime = at
          const style = getComputedStyle(document.querySelector('#tk-modal'))
          return { at, transform: style.transform, opacity: style.opacity }
        })
        return { duration: timing.duration, easing: a.effect.getKeyframes()[0].easing, frames }
      }))
    }
    expect(samples[1]).toEqual(samples[0])
    expect(samples[1].duration).toBe(240)
    expect(samples[1].easing).toBe('cubic-bezier(0.22, 1, 0.36, 1)')
    for (const side of ['design', 'product']) {
      await pair[side].locator('#bd-tk-close').click()
      await expect(pair[side].locator('#tk-backdrop')).not.toHaveClass(/\bshow\b/)
      await expect(pair[side]).not.toHaveURL(/ticket=/)
      expect(await pair[side].evaluate(() => ({ overflow: document.body.style.overflow,
        ticket: new URLSearchParams(location.search).has('ticket'), animations: document.querySelector('#tk-modal').getAnimations().length })))
        .toEqual({ overflow: '', ticket: false, animations: 0 })
    }
  } finally { await pair.close() }
})

test('reduced motion keeps the product modal static under the recorded S-18 default', async ({ browser }) => {
  const pair = await openModalPair(browser, { ...PARITY_VIEWPORTS[0], theme: 'dark', palette: 'aiur', dataset: 'offline', reducedMotion: 'reduce' }, { productPending: true })
  try {
    await expect(pair.product.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
    await pair.product.evaluate(async () => {
      const { ctx } = await import('/build-home/state.js')
      ;(await import('/build-home/modal/frame.js')).openModal(ctx.D.now[0])
    })
    expect(await pair.product.locator('#tk-modal').evaluate(el => parseFloat(getComputedStyle(el).animationDuration) * 1000)).toBeLessThanOrEqual(.01)
    await expect(pair.product.locator('#bm-title')).toBeFocused()
    expect(await pair.product.locator('#tk-modal').evaluate(el => getComputedStyle(el).opacity)).toBe('1')
  } finally { await pair.close() }
})
