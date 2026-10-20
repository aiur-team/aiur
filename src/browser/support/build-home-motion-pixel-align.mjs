export async function alignCardIconToDevicePixel(page) {
  return page.locator('#bd-vp').evaluate(vp => {
    const viewport = vp.getBoundingClientRect()
    const card = [...vp.querySelectorAll('.bd-card')].find(el => el.dataset.id?.replace(/^AIUR-/, '') === '604')
    const icon = card?.querySelector('.bd-ic svg')
    const rect = icon?.getBoundingClientRect()
    if (!icon || rect.bottom <= viewport.top || rect.top >= viewport.bottom) throw new Error('snap viewport has no visible #604 card icon')

    const dpr = window.devicePixelRatio
    const top = rect.top
    let bestOffset = 0
    let bestDistance = Infinity
    // Chromium keeps scrollTop integral here, so pin the screenshot layer instead.
    for (let step = -32; step <= 32; step++) {
      const offset = step / 64
      const deviceTop = (top - offset) * dpr
      const distance = Math.abs(deviceTop - Math.round(deviceTop))
      if (distance < bestDistance) {
        bestDistance = distance
        bestOffset = offset
      }
    }
    const layer = card.closest('.bd-layer')
    if (!layer) throw new Error('snap #604 card has no layer')
    const previousTranslate = layer.style.translate
    layer.style.translate = `0 ${-bestOffset}px`
    return { previousTranslate }
  })
}

export async function restoreCardIconAlignment(page, alignment) {
  await page.locator('#bd-vp').evaluate((vp, previousTranslate) => {
    const card = [...vp.querySelectorAll('.bd-card')].find(el => el.dataset.id?.replace(/^AIUR-/, '') === '604')
    const layer = card?.closest('.bd-layer')
    if (!layer) throw new Error('snap #604 card has no layer')
    layer.style.translate = previousTranslate
  }, alignment.previousTranslate)
}
