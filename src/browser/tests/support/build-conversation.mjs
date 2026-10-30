import { expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
export const states = JSON.parse(await readFile(new URL('../../../test/fixtures/build_home/conversations/states.json', import.meta.url), 'utf8'))
export async function mountConversation(page, info) {
  page.on('pageerror', error => { throw error })
  const root = info.project.metadata.agentAssets
  if (root) await page.route('**/build-home/**/*.js', async route => {
    const relative = new URL(route.request().url()).pathname.replace('/build-home/', '')
    try { await route.fulfill({ body: await readFile(root + '/' + relative, 'utf8'), contentType: 'text/javascript' }) }
    catch { await route.continue() }
  })
  await page.goto('/build-fixture/live')
  await expect(page).toHaveURL(/\/build$/)
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/)
  await expect.poll(() => page.evaluate(async () => !!(await import('/build-home/state.js')).ctx.D?.now.length)).toBe(true)
}
export async function scenario(page, name, opts = {}) {
  await page.evaluate(async ({ fixture, opts }) => {
    const { ctx } = await import('/build-home/state.js'), { openModal } = await import('/build-home/modal/frame.js')
    const original = ctx.push
    window.conversationCalls = []; window.olderFailures = opts.failures || 0; window.olderHolds = opts.hold || 0
    const entries = fixture.entries
    ctx.push = async (event, payload) => {
      window.conversationCalls.push({ event, payload })
      if (event !== 'conversation-page') return original(event, payload)
      const before = payload.before
      if (before != null && window.olderHolds-- > 0) await new Promise(resolve => { window.releaseOlder = resolve })
      if (before != null && opts.delay) await new Promise(resolve => setTimeout(resolve, opts.delay))
      if (before != null && window.olderFailures-- > 0) return { v: 1, kind: 'error', reason: 'unavailable' }
      const allEntries = opts.entries ?? entries
      const end = before == null ? allEntries.length : Number(before.split(':')[1]), start = Math.max(0, end - 100)
      return { v: 1, kind: before == null ? 'conversation' : 'conversation-earlier', id: payload.id, ...fixture, ...opts.reply,
        entries: allEntries.slice(start, end), before: 'fx:' + start, more: start > 0 }
    }
    const t = { ...ctx.D.now[0], ...(opts.ticket || {}) }
    openModal(t)
  }, { fixture: states[name], opts })
}
