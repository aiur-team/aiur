// Record the pending Fit operation so a spec can await it.
export async function installFitObserver(page) {
  await page.evaluate(async () => {
    const { fx } = await import('/build-home/state.js')
    const toggle = fx.toggleLock
    fx.toggleLock = button => {
      const result = toggle(button)
      if (button.dataset.lt === 'fit') {
        if (typeof result?.then !== 'function') throw new Error('Fit handler must return its pending operation')
        window.chainParityFit = result
      }
      return result
    }
  })
}
