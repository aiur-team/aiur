export async function resizeTallBand(page, height) {
  await page.locator('#bd-vp').evaluate(async (el, value) => {
    el.style.height = `${value}px`
    el.style.maxHeight = `${value}px`
    // Rebuild geometry now so a later resize frame cannot change the capture.
    if (window.AiurBuild) window.AiurBuild.render()
    else (await import('/build-home/state.js')).fx.relayout()
  }, height)
}
