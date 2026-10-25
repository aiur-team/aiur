// The paused JS clock does not drive Chromium's native scroll phase. Drain the
// app's queued scroll paint before capturing that frame, without ticking its
// animator or changing the reference's drawing code.
export async function installScrollPaint(page) {
  await page.locator('#bd-vp').evaluate(vp => {
    const raf = requestAnimationFrame.bind(window), cancel = cancelAnimationFrame.bind(window)
    const pending = new Map()
    let scrolling = false
    // Capture precedes the app's target listeners; the final target listener
    // closes the phase after they have scheduled their paint callbacks.
    vp.addEventListener('scroll', () => { scrolling = true }, true)
    vp.addEventListener('scroll', () => { scrolling = false })
    window.requestAnimationFrame = callback => {
      const id = raf(time => { pending.delete(id); callback(time) })
      if (scrolling) pending.set(id, callback)
      return id
    }
    window.cancelAnimationFrame = id => { pending.delete(id); cancel(id) }
    window.flushScrollPaint = () => {
      const callbacks = [...pending]
      pending.clear()
      for (const [id, callback] of callbacks) { cancel(id); callback(performance.now()) }
      return callbacks.length
    }
  })
}
export async function flushScrollPaint(page) {
  return page.evaluate(() => window.flushScrollPaint())
}
