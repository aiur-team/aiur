import { expect } from '@playwright/test'

// Audit a settled rendering, not scroll/resize-driven virtualisation during axe.
// Interaction and live-diff specs keep the real lifecycle running.
export async function freezeAuditLayout(page) {
  await page.evaluate(async () => {
    const { ctx, fx, S } = await import('/build-home/state.js')
    await document.fonts.ready
    // Use the same Now anchor on every scan, after fonts have fixed sizing.
    // Bootstrap scroll/resize callbacks can otherwise leave a different history slice.
    if (S.view !== 'list') fx.jumpNow(true)
    const fingerprint = () => JSON.stringify([...ctx.root.querySelectorAll('.bd-card, .bd-lane, .bd-list')]
      .map(el => {
        const r = el.getBoundingClientRect()
        return [el.dataset.id ?? el.title, ...[r.x, r.y, r.width, r.height].map(n => Math.round(n * 100) / 100)]
      }))
    let changedAt = performance.now(), previous = fingerprint()
    const observer = new MutationObserver(() => { changedAt = performance.now() })
    if (ctx.lanesEl) observer.observe(ctx.lanesEl, { childList: true, subtree: true })
    const deadline = performance.now() + 10_000
    try {
      await new Promise((resolve, reject) => {
        const sample = () => {
          const now = performance.now(), next = fingerprint()
          if (next !== previous || ctx.snapping || ctx.content?.classList.contains('scrolling')) changedAt = now
          previous = next
          if (now > deadline) return reject(new Error('Board layout did not become stable before axe'))
          if (now - changedAt >= 600) return resolve()
          requestAnimationFrame(sample)
        }
        sample()
      })
    } finally { observer.disconnect() }
    // In particular, stop the scroll listener, 250ms scroll poll and pending
    // column timers; otherwise they can replace nodes while axe addresses them.
    ctx.life.dispose()
    let domMutations = 0
    const guard = new MutationObserver(records => { domMutations += records.length })
    guard.observe(ctx.content ?? ctx.vp, { childList: true, subtree: true })
    const before = fingerprint()
    window.finishAuditLayout = () => {
      domMutations += guard.takeRecords().length
      guard.disconnect()
      return { domMutations, unchanged: fingerprint() === before }
    }
  })
}

export async function expectAuditLayoutStable(page) {
  expect(await page.evaluate(() => window.finishAuditLayout()), 'Board changed during axe')
    .toEqual({ domMutations: 0, unchanged: true })
}
