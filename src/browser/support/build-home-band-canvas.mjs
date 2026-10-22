// Keep the entire composed viewport, including sticky layers and scrollbars, at
// the same raster origin. Header/usage height differs outside this ticket.
export async function alignBoard(pair) {
  for (const page of [pair.design, pair.product]) await page.evaluate(() => {
    window.scrollTo(0, 0)
    // External panels sit behind the fixed reference board's rounded corners.
    document.querySelectorAll('#bd-usage, #bd-offline').forEach(el => { el.style.visibility = 'hidden' })
    const vp = document.querySelector('#bd-vp'), host = vp.parentElement, box = host.getBoundingClientRect()
    Object.assign(host.style, { position: 'fixed', left: Math.round(box.x) + 'px', top: '100px', width: box.width + 'px', zIndex: '9999' })
  })
}
export async function alignEtaMask(pair) {
  const widths = await Promise.all([pair.design, pair.product].map(page => page.locator('.bd-now-eta').evaluate(el => el.getBoundingClientRect().width)))
  for (const page of [pair.design, pair.product]) await page.locator('.bd-now-eta').evaluate((el, width) => { el.style.minWidth = width + 'px' }, Math.max(...widths))
}

// Force a fresh paint after relocating the fixture's sticky viewport. A warm
// screenshot alone does not reconcile its glyph raster. Use between paused
// JS-clock scroll samples; no pixels are masked or final styles changed.
export async function primeBoardPaint(pair, region = '#bd-vp') {
  for (const page of [pair.design, pair.product]) {
    const vp = page.locator('#bd-vp'), target = page.locator(region), focused = await page.evaluateHandle(() => document.activeElement)
    const original = await target.evaluate(el => ({ value: el.style.visibility, priority: el.style.getPropertyPriority('visibility') }))
    original.scroll = await vp.evaluate(el => el.scrollTop)
    try {
      await target.evaluate(el => { el.style.visibility = 'hidden' })
      await page.screenshot({ animations: 'allow' })
    } finally {
      await target.evaluate((el, old) => { el.style.setProperty('visibility', old.value, old.priority) }, original)
      const sameFocus = await focused.evaluate(el => el === document.activeElement)
      await focused.dispose()
      if (!sameFocus || await vp.evaluate(el => el.scrollTop) !== original.scroll) throw new Error('Canvas repaint changed focus or scroll position')
    }
  }
}
