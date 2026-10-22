import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 }, timezoneId: 'America/Los_Angeles' })
test.beforeEach(async ({ page }) => {
  page.on('pageerror', error => { throw error })
  await page.goto('/build-fixture/live')
  await expect.poll(() => page.evaluate(async () => !!(await import('/build-home/state.js')).ctx.D?.now.length)).toBe(true)
})

// Opens a running ticket against a stubbed server: `send` answers from `opts.replies`
// in order (a `hold` reply waits for window.releaseSend()); every pushed event is recorded in window.calls.
async function open(page, opts = {}) {
  await page.evaluate(async opts => {
    const { ctx } = await import('/build-home/state.js'), { openModal } = await import('/build-home/modal/frame.js')
    ctx.snap.writable = opts.writable ?? true
    ctx.offline.isLive = () => ctx.socket === 'up'
    window.calls = []; window.replies = opts.replies || []
    let request = 7
    ctx.push = async (event, payload) => {
      window.calls.push({ event, payload })
      if (event === 'conversation-page') return { v: 1, kind: 'conversation', id: payload.id, reset: false, state: 'live', reason: null, live: true, observed_at: null, entries: [], before: null, more: false, note: null, evicted: 0, composer: opts.composer === undefined ? 'ready' : opts.composer }
      if (event !== 'send') return { v: 1, kind: 'ok' }
      const reply = window.replies.shift() || { ok: true }
      if (reply.hang) return new Promise(() => {})
      if (reply.hold) await new Promise(resolve => { window.releaseSend = resolve })
      const text = payload.text.trim()
      return reply.ok ? { v: 1, kind: 'send', ok: true, id: payload.id, request_id: request, entry_id: 'message:r' + request++, text, at: 1791408000000, reason: null, unknown: false, message: null }
        : { v: 1, kind: 'send', ok: false, id: payload.id, request_id: null, entry_id: null, text: null, at: null, reason: reply.reason, unknown: !!reply.unknown, message: reply.message }
    }
    const t = ctx.D.now.find(t => t.agent && t.start != null)
    window.ticketId = t.id
    openModal({ ...t, ...(opts.ticket || {}), agent: { ...t.agent, ...(opts.agent || {}) } })
  }, opts)
}
const sends = page => page.evaluate(() => window.calls.filter(c => c.event === 'send'))
const status = (page, msg) => page.evaluate(async msg => (await import('/build-home/state.js')).fx.sendStatus({ v: 1, kind: 'send-status', id: window.ticketId, ...msg }), msg)
const box = page => page.locator('#cv-in textarea')
const line = page => page.locator('#cv-in-st')

test('placeholder names the agent, the paused copy, an unknown key, and never "Unknown model"', async ({ page }) => {
  await open(page, { agent: { name: 'Claude', state: 'active' } })
  await expect(box(page)).toHaveAttribute('placeholder', 'Message Claude…')
  await expect(box(page)).toHaveAttribute('aria-label', 'Message Claude')
  await expect(page.locator('#cv-in #cv-mic')).toHaveAttribute('aria-disabled', 'true')
  await open(page, { agent: { name: 'Claude', state: 'paused' } })
  await expect(box(page)).toHaveAttribute('placeholder', 'Message the agent — it resumes when you send')
  await open(page, { agent: { name: null, model: 'glm', state: 'active' } })
  await expect(box(page)).toHaveAttribute('placeholder', 'Message glm…')
  await open(page, { agent: { name: null, model: null, state: 'active' } })
  await expect(box(page)).toHaveAttribute('placeholder', 'Message the agent…')
})

test('whitespace is never sent; Enter sends trimmed text once, Shift+Enter and IME Enter do not', async ({ page }) => {
  await open(page, { replies: [{ ok: true, hold: true }] })
  await box(page).fill('   \n  '); await box(page).press('Enter')
  expect(await sends(page)).toHaveLength(0)
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(0)

  await box(page).fill('first'); await box(page).press('Shift+Enter')
  await expect(box(page)).toHaveValue('first\n')
  await box(page).evaluate(el => el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', isComposing: true, bubbles: true, cancelable: true })))
  expect(await sends(page)).toHaveLength(0)

  await box(page).fill('  hello  ')
  await box(page).press('Enter'); await box(page).press('Enter')
  await expect(page.locator('#cv-in .cv-send')).toBeDisabled()
  await expect(page.locator('#cv-in')).toHaveAttribute('aria-busy', 'true')
  // No optimistic row: the message appears only once Aiur accepted it.
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(0)
  await page.evaluate(() => window.releaseSend())
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(1)
  const calls = await sends(page)
  expect(calls).toHaveLength(1)
  expect(calls[0].payload).toEqual({ id: await page.evaluate(() => window.ticketId), text: '  hello  ' })
  await expect(page.locator('#cv-log .cv-op p')).toHaveText('hello')
  await expect(page.locator('#cv-log .cv-op')).toHaveAttribute('data-eid', 'message:r7')
  await expect(box(page)).toHaveValue('')
  await expect(page.locator('#cv-in .cv-send')).toBeEnabled()
})

test('hostile text and agent names stay text', async ({ page }) => {
  await open(page, { agent: { name: '"><img src=x onerror=window.__y=1>', state: 'active' } })
  await expect(box(page)).toHaveAttribute('placeholder', 'Message "><img src=x onerror=window.__y=1>…')
  await expect(page.locator('#cv-in img')).toHaveCount(0)
  await box(page).fill('<img src=x onerror=window.__x=1>'); await box(page).press('Enter')
  await expect(page.locator('#cv-log .cv-op p')).toHaveText('<img src=x onerror=window.__x=1>')
  expect(await page.evaluate(() => [window.__x, window.__y])).toEqual([undefined, undefined])
})

test('failed, unknown and unanswered sends keep the draft and say why', async ({ page }) => {
  const unknown = 'Aiur did not answer in time, so the message may still be queued. Check the log, or press Send again to retry without a duplicate.'
  await open(page, { replies: [{ reason: 'outcome_unknown', unknown: true, message: unknown }, { reason: 'no_running_agent', message: 'Agent is no longer running.' }, { hang: true }] })
  await page.clock.install()
  await box(page).fill('keep me'); await box(page).press('Enter')
  await expect(line(page)).toHaveText(unknown); await expect(line(page)).not.toHaveClass(/bad/)
  await expect(box(page)).toHaveValue('keep me'); await expect(page.locator('#cv-log .cv-op')).toHaveCount(0)
  await box(page).press('Enter')
  await expect(line(page)).toHaveText('Agent is no longer running.'); await expect(line(page)).toHaveClass(/bad/)
  await box(page).press('Enter')
  await page.clock.runFor(15_000)
  await expect(line(page)).toHaveText('No answer from the dashboard, so the message may still be queued. Check the log before you send again.')
  await expect(box(page)).toHaveValue('keep me')
})

test('delivery states: queued, delivered hides the line, failed restores the text, superseded does not', async ({ page }) => {
  await open(page)
  await box(page).fill('one'); await box(page).press('Enter')
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(1)
  await status(page, { request_id: 7, status: 'queued' })
  await expect(line(page)).toHaveText('Queued · waiting for the agent')
  await status(page, { request_id: 6, status: 'failed' })
  await expect(line(page)).toHaveText('Queued · waiting for the agent')
  await status(page, { request_id: 7, status: 'delivered' })
  await expect(line(page)).toBeHidden()
  await status(page, { request_id: 7, status: 'failed' })
  await expect(line(page)).toHaveText('Not delivered (failed)'); await expect(line(page)).toHaveClass(/bad/)
  await expect(box(page)).toHaveValue('one')

  await box(page).fill('two'); await box(page).press('Enter')
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(2)
  await status(page, { request_id: 8, status: 'superseded' })
  await expect(line(page)).toHaveText('Not delivered (superseded)')
  await expect(box(page)).toHaveValue('')
  await status(page, { request_id: 8, status: 'unconfirmed' })
  await expect(line(page)).toHaveText('Queued · delivery unconfirmed')
})

test('read-only, history, no agent and ambiguous targets render no form', async ({ page }) => {
  await open(page, { writable: false })
  await expect(page.locator('#cv-log')).toHaveCount(1); await expect(page.locator('#cv-in')).toHaveCount(0)
  await open(page, { composer: null })
  await expect(page.locator('#cv-log')).toHaveCount(1); await expect(page.locator('#cv-in')).toHaveCount(0)
  await open(page, { composer: 'ambiguous' })
  await expect(page.locator('#cv-in')).toHaveCount(0)
  await expect(page.locator('#cv-in-off')).toHaveText('Agent actions are unavailable because this display identifier is not a unique writable target.')
})

test('offline disables send but keeps the draft editable', async ({ page }) => {
  await open(page)
  await page.clock.install()
  await page.evaluate(async () => { (await import('/build-home/state.js')).ctx.socket = 'down' })
  await page.clock.runFor(1_000)
  await expect(page.locator('#cv-in .cv-send')).toBeDisabled()
  await expect(line(page)).toHaveText('Offline · reconnect to send')
  await box(page).fill('later'); await box(page).press('Enter')
  expect(await sends(page)).toHaveLength(0)
  await page.evaluate(async () => { (await import('/build-home/state.js')).ctx.socket = 'up' })
  await page.clock.runFor(1_000)
  await expect(page.locator('#cv-in .cv-send')).toBeEnabled(); await expect(line(page)).toBeHidden()
  await expect(box(page)).toHaveValue('later')
})

test('a draft survives closing and reopening the modal', async ({ page }) => {
  await open(page)
  await box(page).fill('half written')
  await page.locator('#bd-tk-close').click()
  await open(page)
  await expect(box(page)).toHaveValue('half written')
})

test('a local-worker transcript echo replaces the local row, including a cut long message', async ({ page }) => {
  await open(page)
  const echo = entry => page.evaluate(async entry => (await import('/build-home/state.js')).fx.appendEntries([entry]), entry)
  await box(page).fill('hello'); await box(page).press('Enter')
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(1)
  await echo({ id: 'g1:4096', k: 'op', text: 'hello', at: 1791408000000 })
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(1)
  await expect(page.locator('#cv-log .cv-op')).toHaveAttribute('data-eid', 'g1:4096')

  const long = 'x'.repeat(2000)
  await box(page).fill(long); await box(page).press('Enter')
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(2)
  await echo({ id: 'g1:8192', k: 'op', text: long.slice(0, 1600) + '\n...', at: 1791408000000 })
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(2)
  await expect(page.locator('#cv-log .cv-op').last()).toHaveAttribute('data-eid', 'g1:8192')
  // An unrelated operator message from elsewhere is a new row.
  await echo({ id: 'g1:9000', k: 'op', text: 'from the TUI', at: 1791408000000 })
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(3)
  // Two identical sends are two rows, and each echo claims one of them.
  for (const _ of [1, 2]) { await box(page).fill('again'); await box(page).press('Enter'); await expect(box(page)).toHaveValue('') }
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(5)
  await echo({ id: 'g1:9100', k: 'op', text: 'again', at: 1791408000000 })
  await echo({ id: 'g1:9200', k: 'op', text: 'again', at: 1791408000000 })
  await expect(page.locator('#cv-log .cv-op')).toHaveCount(5)
})
