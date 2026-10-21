import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { dashboardCredentials } from './support/layout-worker.mjs'

const states = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/conversations/states.json', import.meta.url), 'utf8'))
test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 }, timezoneId: 'America/Los_Angeles' })
test.beforeEach(async ({ page }, info) => {
  page.on('pageerror', error => { throw error })
  const root = info.project.metadata.agentAssets
  if (root) await page.route('**/build-home/**/*.js', async route => {
    const relative = new URL(route.request().url()).pathname.replace('/build-home/', '')
    try { await route.fulfill({ body: await readFile(root + '/' + relative, 'utf8'), contentType: 'text/javascript' }) }
    catch { await route.continue() }
  })
  await page.goto('/build-fixture/live')
  await expect.poll(() => page.evaluate(async () => !!(await import('/build-home/state.js')).ctx.D?.now.length)).toBe(true)
})
async function scenario(page, name, opts = {}) {
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
      const end = before == null ? entries.length : Number(before.split(':')[1]), start = Math.max(0, end - 100)
      return { v: 1, kind: before == null ? 'conversation' : 'conversation-earlier', id: payload.id, ...fixture, ...opts.reply,
        entries: entries.slice(start, end), before: 'fx:' + start, more: start > 0 }
    }
    const t = { ...ctx.D.now[0], ...(opts.ticket || {}) }
    openModal(t)
  }, { fixture: states[name], opts })
}
const proof = async (page, name) => test.info().attach(name, { body: await page.locator('#tk-modal').screenshot({ animations: 'disabled', path: test.info().outputPath(name + '.png') }), contentType: 'image/png' })
const messageCount = page => page.locator('#cv-log [data-k]')
const top = page => page.locator('#cv-log').evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')) })

test('mounted body requests the real exported conversation and closes its subscription', async ({ page }) => {
  const id = await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { openModal } = await import('/build-home/modal/frame.js')
    window.conversationCalls = []; const original = ctx.push
    ctx.push = (event, payload) => { window.conversationCalls.push({ event, payload }); return original(event, payload) }
    const t = ctx.D.hist.find(t => t.agent && t.start != null); openModal(t); return t.id
  })
  await expect(messageCount(page)).not.toHaveCount(0)
  await expect(page.locator('#cv-log .cv-say').first()).toContainText('Reading the ticket')
  await page.evaluate(() => window.liveSocket.disconnect())
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-socket', 'down')
  await page.evaluate(() => window.liveSocket.connect())
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-socket', 'up')
  await expect.poll(() => page.evaluate(() => window.conversationCalls.filter(c => c.event === 'conversation-page').length)).toBeGreaterThan(1)
  await expect(messageCount(page)).not.toHaveCount(0)
  await page.locator('#bd-tk-close').click()
  expect(await page.evaluate(id => window.conversationCalls.filter(c => c.event === 'conversation-close' && c.payload.id === id).length, id)).toBe(1)
})

test('all six item branches render; hostile text stays text and unknown times/models stay unknown', async ({ page }) => {
  await scenario(page, 'kinds')
  for (const kind of ['sys', 'say', 'op', 'tool', 'diff', 'ev']) await expect(page.locator('#cv-log [data-k=' + kind + ']')).toHaveCount(1)
  await expect(page.locator('.cv-say img')).toHaveCount(1)
  await expect(page.locator('.cv-op time')).toHaveText('You · 14:20')
  await expect(page.locator('.cv-tool.bad .cv-tr')).toHaveText('✗ exit 2')
  await scenario(page, 'hostile'); await expect(page.locator('.cv-say p')).toHaveText(states.hostile.entries[0].text)
  expect(await page.evaluate(() => window.__xss)).toBeUndefined()
  await scenario(page, 'unknown_time'); await expect(page.locator('#cv-log [title="Time unknown"]')).toHaveCount(2)
  await expect(page.locator('.cv-op time')).toHaveText('You')
  await expect(page.locator('#cv-log')).not.toContainText(/00:00|Jan 1|NaN|Invalid/)
  await proof(page, 'conversation-unknown-time')
  await scenario(page, 'unknown_model', { ticket: { agent: { model: 'muse', state: 'active' } } })
  await expect(page.locator('.cv-say .ax-mono')).toHaveText('M'); await expect(page.locator('.cv-say img')).toHaveCount(0)
  await proof(page, 'conversation-unknown-model')
})

test('state cues, retained-history handoff and unknown dates render explicitly', async ({ page }) => {
  await scenario(page, 'not_retained')
  await expect(page.locator('.cv')).toHaveCount(0)
  await expect(page.locator('.bm-cue')).toHaveText('Conversation not retained')
  await proof(page, 'conversation-not-retained')
  await page.evaluate(async () => {
    const { registerBody } = await import('/build-home/modal/frame.js')
    registerBody('doc', (_t, body, opts) => { window.docNote = opts.note; body.innerHTML = '<div class="bm-doc"><p class="bm-cue"></p></div>'; body.querySelector('p').textContent = opts.note })
  })
  await scenario(page, 'not_retained'); await expect(page.locator('.cv')).toHaveCount(0)
  await expect(page.locator('.bm-doc .bm-cue')).toHaveText('Conversation not retained')
  expect(await page.evaluate(() => window.docNote)).toBe('Conversation not retained')
  await proof(page, 'conversation-doc-cue')
  await scenario(page, 'known_empty'); await expect(page.locator('#cv-log [data-empty]')).toHaveText('No messages yet'); await expect(messageCount(page)).toHaveCount(0)
  await scenario(page, 'unavailable'); await expect(page.locator('#cv-footer')).toHaveText('Conversation unavailable'); await expect(messageCount(page)).toHaveCount(0)
  await proof(page, 'conversation-unavailable')
  await scenario(page, 'restart_unknown'); await expect(page.locator('#cv-footer')).toHaveText('Live state unknown after a restart')
  await proof(page, 'conversation-restart-unknown')
  for (const [note, text] of [['live_window', 'Only the latest messages are shown'], ['legacy_log', 'Older entries are in a legacy log and are not shown'], ['remote_window', '12 earlier messages are not kept for remote workers']]) {
    await scenario(page, 'ended', { reply: { note, evicted: 12 } })
    await expect(page.locator('#cv-log > :first-child')).toHaveText(text)
  }
  await page.clock.install()
  await page.evaluate(async () => (await import('/build-home/clock.js')).setNow(1791408000000))
  await scenario(page, 'stale'); await expect(page.locator('#cv-footer')).toHaveText('Live updates unavailable · read 7m ago')
  await page.evaluate(async () => (await import('/build-home/clock.js')).setNow(1791408000000 + 3 * 60000))
  await page.clock.runFor(60000)
  await expect(page.locator('#cv-footer')).toHaveText('Live updates unavailable · read 10m ago')
  await proof(page, 'conversation-stale-age')
  await scenario(page, 'stale', { reply: { observed_at: null } })
  await expect(page.locator('#cv-footer')).toHaveText('Live updates unavailable · read time unknown')
  await scenario(page, 'ended', { ticket: { sec: 'hist', status: 'not_planned', end: null } })
  await expect(page.locator('#cv-footer')).toHaveText('Session ended'); await expect(page.locator('#cv-footer')).not.toContainText('merged')
  await scenario(page, 'ended', { ticket: { sec: 'hist', status: 'done', end: null } })
  await expect(page.locator('#cv-footer')).toHaveText('Session ended · merged'); await expect(page.locator('#cv-footer')).toHaveAttribute('title', 'Merge time unknown')
})

test('older loading, retry without a loop, anchor preservation, cap and tail recovery', async ({ page }) => {
  await scenario(page, 'paged', { delay: 500, failures: 1, hold: 1 })
  await expect(messageCount(page)).toHaveCount(100)
  await top(page)
  await expect(page.locator('#cv-log > :first-child')).toHaveText('Loading earlier…')
  await proof(page, 'conversation-loading-earlier')
  await expect(page.locator('#cv-log > :first-child')).toHaveText('Loading earlier…')
  await page.evaluate(() => window.releaseOlder())
  await expect(page.locator('#cv-log > :first-child')).toContainText('Could not load earlier entries')
  expect(await page.evaluate(() => window.conversationCalls.filter(c => c.event === 'conversation-page').length)).toBe(2)
  await top(page)
  expect(await page.evaluate(() => window.conversationCalls.filter(c => c.event === 'conversation-page').length)).toBe(2)
  // The loading row replaces the error row; record the real entry's position while it is pending.
  await page.getByRole('button', { name: 'Retry', exact: true }).click()
  await expect(page.locator('#cv-log > :first-child')).toHaveText('Loading earlier…')
  const anchor = page.locator('[data-eid="page:500"]'), before = (await anchor.boundingBox()).y
  await expect(messageCount(page)).toHaveCount(200)
  expect(Math.abs((await anchor.boundingBox()).y - before)).toBeLessThanOrEqual(1)
  for (const count of [300, 400, 500, 500]) {
    await top(page)
    await expect(page.locator('#cv-log > :first-child')).toHaveText('Loading earlier…')
    await expect(messageCount(page)).toHaveCount(count)
    await expect(page.locator('#cv-log > :first-child')).not.toHaveText('Loading earlier…')
  }
  expect(await page.evaluate(async () => (await import('/build-home/modal/conversation.js')).trimmedBottom())).toBe(true)
  await page.evaluate(async () => {
    const { fx } = await import('/build-home/state.js'); fx.appendItem({ id: 'ignored', k: 'op', text: 'new', at: null })
  })
  await expect(page.locator('[data-eid=ignored]')).toHaveCount(0)
  await page.evaluate(async () => (await import('/build-home/modal/conversation.js')).requestTail())
  await expect(messageCount(page)).toHaveCount(100)
  expect(await page.evaluate(async () => (await import('/build-home/modal/conversation.js')).trimmedBottom())).toBe(false)
})

test('mounted hook routes appends and states; ids replace in place and append trims synchronously', async ({ page }) => {
  await scenario(page, 'kinds')
  await page.evaluate(async () => {
    const { fx } = await import('/build-home/state.js')
    fx.appendItem({ k: 'op', id: 'echo', text: 'first', at: null }); fx.appendItem({ k: 'op', id: 'echo', text: 'second', at: null })
    fx.onConversation = msg => { window.receivedConversation = msg }
    window.dispatchEvent(new CustomEvent('phx:build-conversation', { detail: { v: 1, kind: 'conversation-append', id: (await import('/build-home/modal/frame.js')).MS.t.id,
      entries: [{ id: 'push', k: 'say', text: 'Pushed through hook', at: null }], gap: true } }))
  })
  await expect(page.locator('[data-eid=echo]')).toHaveCount(1); await expect(page.locator('[data-eid=echo] p')).toHaveText('second')
  await expect(page.locator('[data-eid=push] p')).toHaveText('Pushed through hook')
  expect(await page.evaluate(() => window.receivedConversation.gap)).toBe(true)
  await page.evaluate(async () => {
    const { fx } = await import('/build-home/state.js'), { MS } = await import('/build-home/modal/frame.js')
    fx.appendEntries(Array.from({ length: 510 }, (_, n) => ({ id: n === 10 ? 'answer:act' : 'many:' + n, cursor: n === 10 ? 'ab:40' : 'many:' + n, k: 'say', text: 'Row ' + n, at: null })))
    window.synchronousRows = document.querySelectorAll('#cv-log [data-k]').length
    window.dispatchEvent(new CustomEvent('phx:build-conversation', { detail: { v: 1, kind: 'conversation-state', id: MS.t.id, state: 'restart_unknown', live: false, observed_at: null } }))
  })
  expect(await page.evaluate(() => window.synchronousRows)).toBe(500)
  await top(page)
  await expect.poll(() => page.evaluate(() => window.conversationCalls.at(-1)?.payload.before)).toBe('ab:40')
  await expect(page.locator('#cv-footer')).toHaveText('Live state unknown after a restart')
})

test('late first replies and pushes cannot overwrite another ticket or reopen a closed modal', async ({ page }) => {
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { openModal } = await import('/build-home/modal/frame.js'), original = ctx.push
    window.held = []; ctx.push = (e, p) => e === 'conversation-page' ? new Promise(resolve => window.held.push({ resolve, id: p.id })) : original(e, p)
    openModal(ctx.D.now[0]); openModal(ctx.D.now[1]);
    const reply = (n, text) => window.held[n].resolve({ v: 1, kind: 'conversation', id: window.held[n].id, entries: [{ id: text, k: 'say', text, at: null }], state: 'live', more: false, before: null })
    reply(1, 'Current ticket'); reply(0, 'Old ticket')
  })
  await expect(page.locator('#cv-log')).toContainText('Current ticket'); await expect(page.locator('#cv-log')).not.toContainText('Old ticket')
  await page.locator('#bd-tk-close').click()
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { openModal, closeModal } = await import('/build-home/modal/frame.js')
    openModal(ctx.D.now[0]); closeModal()
    window.held[2].resolve({ v: 1, kind: 'conversation', id: window.held[2].id, entries: [], state: 'known_empty', more: false, before: null })
  })
  await expect(page.locator('.cv')).toHaveCount(0); await expect(page.locator('#tk-backdrop')).not.toHaveClass(/show/)
})
