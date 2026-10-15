import { expect } from '@playwright/test'
import { FIXTURE_META } from './design-parity-environment.mjs'

async function scroll(page, top) {
  await page.locator('#bd-vp').evaluate((el, top) => {
    el.scrollTop = top
    el.dispatchEvent(new Event('scroll'))
  }, top)
  await page.clock.runFor(48)
  await expect.poll(async () => {
    await page.clock.runFor(16)
    const paging = await page.locator('#build-root').getAttribute('data-bd-paging')
    return paging === null || paging === 'idle'
  }).toBe(true)
  await page.clock.runFor(32)
}

async function sample(page, ids) {
  return page.evaluate(ids => {
    const reverse = Object.fromEntries(Object.entries(ids).map(([design, product]) => [product, design]))
    const sections = ['hist', 'plan', 'nq']
    // L.band is deferred to C9-T08: at a shared global scrollTop its missing
    // height changes plan/nq windows. Their exact sets use section-relative
    // offsets in the geometry parity test; history has the same global origin.
    const cards = ['hist'].flatMap(section => [...document.querySelectorAll('#bd-sec-' + section + ' .bd-card[data-id]')].map(el => ({
      section, id: reverse[el.dataset.id] ?? el.dataset.id,
      top: parseFloat(el.style.top), height: parseFloat(el.style.height)
    }))).sort((a, b) => a.section.localeCompare(b.section) || a.id.localeCompare(b.id))
    const transitions = sections.flatMap(section => [...document.querySelectorAll('#bd-sec-' + section + ' .bd-card')].flatMap(el => el.getAnimations()))
    return {
      // The design keeps histFrom private; its first header em reports that boundary.
      histFrom: document.querySelector('#bd-sec-hist .bd-sech em')?.textContent ?? '',
      header: document.querySelector('#bd-sec-hist .bd-sech').textContent,
      scrollTop: document.querySelector('#bd-vp').scrollTop,
      cards, transitions: transitions.map(animation => animation.transitionProperty ?? animation.animationName)
    }
  }, ids)
}

export async function historySequence(page, ctx, name) {
  const ids = ctx.ids ?? FIXTURE_META.ids
  if (name === 'load-earlier') {
    // Settle cards just outside the paging trigger before moving to 200. Cards
    // created by that same scroll still have noanim and cannot expose a slide.
    await scroll(page, 260)
    const thumb = await page.locator('#bd-sb i').boundingBox()
    await page.mouse.move(thumb.x + thumb.width / 2, thumb.y + 3)
    await page.mouse.down()
    try {
      await page.clock.runFor(80)
      await page.locator('.bd-card').evaluateAll(cards => cards.forEach(card => getComputedStyle(card).top))
      const before = await page.locator('#bd-sec-hist').evaluate(el => el.offsetHeight)
      await scroll(page, 200)
      await expect.poll(async () => {
        await page.clock.runFor(16)
        return page.locator('#bd-sec-hist').evaluate(el => el.offsetHeight)
      }).toBeGreaterThan(before)
      await page.clock.runFor(48)
      const state = await sample(page, ids)
      expect(state.transitions, 'paging must not animate history cards').toEqual([])
      return { samples: [state] }
    } finally { await page.mouse.up() }
  }
  const band = await page.locator('#bd-sec-hist').evaluate(el => el.offsetTop + el.offsetHeight)
  const positions = []
  for (let top = band; top > 0; top -= 300) positions.push(top)
  positions.push(0)
  const samples = []
  // Hold the scrollbar as a user does while inspecting history. This invokes
  // the design's drag guard so the separately owned live snap cannot page it.
  await scroll(page, band)
  const thumb = await page.locator('#bd-sb i').boundingBox()
  await page.mouse.move(thumb.x + thumb.width / 2, thumb.y + 3)
  await page.mouse.down()
  try {
    for (const top of positions) {
      await scroll(page, top)
      samples.push(await sample(page, ids))
    }
    return { samples }
  } finally { await page.mouse.up() }
}
