import { expect } from '@playwright/test'
import { captureStaticGrain } from '../../support/build-home-grain-capture.mjs'

export async function assertStaticGrainCapture(browser) {
  const page = await browser.newPage()
  try {
    await page.setContent('<style>@keyframes bleed { 50% { background: white } } #grain { position: absolute; top: 20px; left: 20px; width: 120px; height: 46px } #grain::after { content: ""; position: absolute; inset: 0; background: black; animation: bleed 1s steps(2, end) infinite }</style><div id="grain"></div>')
    const screenshot = page.screenshot.bind(page), states = [], target = page.locator('#grain')
    page.screenshot = async (...args) => {
      states.push(await page.evaluate(() => document.getAnimations()[0].playState))
      return screenshot(...args)
    }
    const png = await captureStaticGrain(page, target, { animations: 'allow', style: '#grain::after { visibility: visible !important }' })
    expect(png.length).toBeGreaterThan(100)
    expect(states.length).toBeGreaterThan(1)
    expect(states).toEqual(states.map(() => 'paused'))
    expect(await page.evaluate(() => document.getAnimations()[0].playState)).toBe('running')
  } finally { await page.close() }
}
