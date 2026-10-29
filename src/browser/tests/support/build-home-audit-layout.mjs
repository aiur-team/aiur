import { expect } from '@playwright/test'

// Audit a settled rendering, not scroll/resize-driven virtualisation during axe.
// Interaction and live-diff specs keep the real lifecycle running.
export async function freezeAuditLayout(page) {
  await page.evaluate(async () => {
    const { ctx, fx, S } = await import('/build-home/state.js')
    await document.fonts.ready
    // Lifecycle disposal stops local timers, not inbound LiveView diffs/replies.
    // Keep heartbeat acknowledgements flowing while holding the rendered snapshot.
    const socket = window.liveSocket.getSocket(), decode = socket.decode
    window.auditBlockedUpdates = 0
    socket.decode = (raw, callback) => decode.call(socket, raw, message => {
      if (message.topic.startsWith('lv:')) window.auditBlockedUpdates++
      else callback(message)
    })
    // Use the same Now anchor on every scan, after fonts have fixed sizing.
    // Bootstrap scroll/resize callbacks can otherwise leave a different history slice.
    if (S.view !== 'list') fx.jumpNow(true)
    const fingerprint = () => JSON.stringify([...ctx.root.querySelectorAll('.bd-card, .bd-lane, .bd-list, .lr[data-id]')]
      .map(el => {
        const r = el.getBoundingClientRect()
        return [el.dataset.id ?? el.title, ...[r.x, r.y, r.width, r.height].map(n => Math.round(n * 100) / 100)]
      }))
    let changedAt = performance.now(), previous = fingerprint()
    const observer = new MutationObserver(() => { changedAt = performance.now() })
    observer.observe(ctx.vp, { childList: true, subtree: true })
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
    const changes = []
    const record = records => {
      domMutations += records.length
      changes.push(...records.map(r => ({ target: r.target.id || r.target.className || r.target.nodeName,
        added: [...r.addedNodes].map(n => (n.outerHTML || n.textContent || '').slice(0, 240)),
        removed: [...r.removedNodes].map(n => (n.outerHTML || n.textContent || '').slice(0, 240)) })))
    }
    const guard = new MutationObserver(record)
    guard.observe(ctx.vp, { childList: true, subtree: true })
    const before = fingerprint()
    window.finishAuditLayout = () => {
      record(guard.takeRecords())
      guard.disconnect()
      socket.decode = decode
      return { domMutations, unchanged: fingerprint() === before, ...(domMutations ? { changes } : {}) }
    }
  })
}

export async function expectAuditLayoutStable(page) {
  expect(await page.evaluate(() => window.finishAuditLayout()), 'Board changed during axe')
    .toEqual({ domMutations: 0, unchanged: true })
}
