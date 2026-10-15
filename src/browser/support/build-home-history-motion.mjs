import { expect } from '@playwright/test'

export async function historySequence(page, ctx, name) {
  const before = await page.locator('#bd-sec-hist').evaluate(el => el.offsetHeight)
  await page.locator('#bd-vp').evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')) })
  await page.clock.runFor(32)
  await expect.poll(() => page.locator('#bd-sec-hist').evaluate(el => el.offsetHeight)).toBeGreaterThan(before)
  await page.clock.runFor(32)
  if (name === 'window') {
    await page.locator('#bd-vp').evaluate(el => { el.scrollTop = 1000; el.dispatchEvent(new Event('scroll')) })
    await page.clock.runFor(32)
  }
  const sample = await page.evaluate(({ before, name }) => {
    const vp = document.querySelector('#bd-vp'), section = document.querySelector('#bd-sec-hist')
    const cards = Array.from(section.querySelectorAll('.bd-card'))
    return name === 'load-earlier' ? { heightDelta: section.offsetHeight - before, scrollDelta: vp.scrollTop } : {
      cards: cards.map(el => ({ top: el.style.top, height: el.style.height })).sort((a, b) => parseFloat(a.top) - parseFloat(b.top))
    }
  }, { before, name })
  return { samples: [sample] }
}
