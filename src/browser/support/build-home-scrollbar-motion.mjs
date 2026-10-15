// These sequences become product parity gates when C9-T03 draws #bd-content.
export async function scrollbar(page, ctx, action) {
  const samples = []
  const sample = async () => page.evaluate(() => {
    const sb = document.querySelector('#bd-sb'), th = sb.querySelector('i')
    return { classes: [...sb.classList].sort(), height: th.style.height, transform: th.style.transform,
      scrollTop: document.querySelector('#bd-vp').scrollTop }
  })
  if (action === 'scroll-reveal') {
    await page.locator('#bd-vp').evaluate(el => new Promise(resolve => {
      const before = el.scrollTop
      el.addEventListener('scroll', resolve, { once: true }); el.scrollTop += 400
      if (el.scrollTop === before) resolve()
    }))
    let previous = 0
    for (const at of [0, 100, 699, 700, 701]) {
      await page.clock.runFor(at - previous); previous = at; samples.push(await sample())
    }
  } else if (action === 'drag') {
    const box = await page.locator('#bd-sb i').boundingBox()
    await page.mouse.move(box.x + box.width / 2, box.y + 3); await page.mouse.down()
    for (let step = 1; step <= 5; step++) {
      await page.mouse.move(box.x + box.width / 2, box.y + 3 + step * 20); samples.push(await sample())
    }
    await page.mouse.up(); samples.push(await sample())
  } else {
    await page.locator('#bd-sb').evaluate(el => new Promise(resolve => {
      const vp = document.querySelector('#bd-vp'), before = vp.scrollTop
      vp.addEventListener('scroll', resolve, { once: true })
      const r = el.getBoundingClientRect(); el.dispatchEvent(new PointerEvent('pointerdown', { clientY: r.top + r.height * .75 }))
      if (vp.scrollTop === before) resolve()
    }))
    samples.push(await sample())
  }
  return { samples }
}
