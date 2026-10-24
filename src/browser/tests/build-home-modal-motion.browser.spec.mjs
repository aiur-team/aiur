import { test, expect } from '@playwright/test'
import { openProduct, parityContextOptions, PARITY_VIEWPORTS } from '../support/design-parity.mjs'

test.setTimeout(90_000)

test('product modal entrance uses the documented duration and easing, then closes instantly', async ({ browser }) => {
  for (const viewport of PARITY_VIEWPORTS) {
    const cell = { ...viewport, theme: 'dark', palette: 'aiur', dataset: 'offline' }
    const context = await browser.newContext({ ...parityContextOptions(cell), baseURL: test.info().project.use.baseURL })
    try {
      const page = await context.newPage()
      await openProduct(page, cell)
      await page.evaluate(async () => {
        const { ctx } = await import('/build-home/state.js')
        ;(await import('/build-home/modal/frame.js')).openModal(ctx.D.now[0])
        const el = document.querySelector('#tk-modal')
        const animation = el.getAnimations().find(candidate => candidate.animationName === 'tkin')
        if (!animation) throw new Error('product modal entrance animation did not start')
        animation.pause()
        window.modalAnimation = animation
      })
      const timing = await page.locator('#tk-modal').evaluate(el => {
        const animation = window.modalAnimation
        return { duration: animation.effect.getTiming().duration, easing: animation.effect.getKeyframes()[0].easing,
          frames: [0, 120, 240].map(at => {
            animation.currentTime = at
            const style = getComputedStyle(el)
            return { opacity: Number(style.opacity), transform: style.transform }
          }) }
      })
      expect(timing.duration).toBe(240)
      expect(timing.easing).toBe('cubic-bezier(0.22, 1, 0.36, 1)')
      expect(timing.frames[0].opacity).toBeLessThan(timing.frames[2].opacity)
      expect(timing.frames[0].transform).not.toBe(timing.frames[2].transform)
      await page.locator('#bd-tk-close').click()
      await expect(page.locator('#tk-backdrop')).not.toHaveClass(/\bshow\b/)
      await expect(page).not.toHaveURL(/ticket=/)
      expect(await page.evaluate(() => ({ overflow: document.body.style.overflow,
        ticket: new URLSearchParams(location.search).has('ticket'), animations: document.querySelector('#tk-modal').getAnimations().length })))
        .toEqual({ overflow: '', ticket: false, animations: 0 })
    } finally { await context.close() }
  }
})
