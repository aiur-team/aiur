import { captureStable } from './design-parity.mjs'

export async function captureStaticGrain(page, target, options) {
  await page.evaluate(() => {
    window.grainAmbientAnimations = document.getAnimations().filter(animation =>
      animation.playState === 'running' && animation.effect?.getTiming().iterations === Infinity
    )
    window.grainAmbientAnimations.forEach(animation => { animation.pause(); animation.currentTime = 0 })
  })
  try { return await captureStable(target, options, page) }
  finally {
    if (!page.isClosed()) await page.evaluate(() => window.grainAmbientAnimations?.forEach(animation => animation.play()))
  }
}
