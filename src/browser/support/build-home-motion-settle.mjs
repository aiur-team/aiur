export async function settleScrollPosition(page) {
  let previous = null
  let stableFrames = 0

  for (let frame = 0; frame < 90; frame++) {
    await page.clock.runFor(16)
    const scrollTop = await page.locator('#bd-vp').evaluate(el => el.scrollTop)
    stableFrames = scrollTop === previous ? stableFrames + 1 : 0
    if (stableFrames === 2) return
    previous = scrollTop
  }

  throw new Error('snap scroll did not settle within 90 frames')
}
