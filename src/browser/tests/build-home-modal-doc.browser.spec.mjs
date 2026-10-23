import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 1000 } })
test.beforeEach(async ({ page }, info) => {
  const root = info.project.metadata.agentAssets
  if (root) {
    for (const path of ['hook.js', 'home.css', 'modal/doc.js', 'home/19-modal-doc.css']) await page.route('**/build-home/' + path, async route => route.fulfill({
      body: await readFile(root + '/' + path, 'utf8'), contentType: path.endsWith('.css') ? 'text/css' : 'text/javascript',
    }))
  }
  page.on('pageerror', error => { throw error })
  await page.goto('/build-fixture/live')
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/state.js')).ctx.D?.all.length)).toBeGreaterThan(0)
})
async function display(page, patch = {}, options = {}) {
  const ticket = await page.evaluate(async ({ patch, options }) => {
    const { ctx } = await import('/build-home/state.js')
    const t = { ...(patch.sec === 'nq' ? ctx.D.nq[0] : ctx.D.plan[0]), agent: null, ...patch }
    window.docCalls = []
    const push = window.docPush ||= ctx.push
    ctx.push = (event, payload) => {
      window.docCalls.push({ event, payload })
      if (['ticket-doc', 'queue-add'].includes(event)) return new Promise(resolve => { window[event + 'Reply'] = resolve })
      return push(event, payload)
    }
    ctx.snap.writable = options.writable ?? true
    ctx.D.sources = { ...ctx.D.sources, queue: { state: 'ok', ...options.queue } }
    if (options.missing) ctx.D.children[t.id] = ['998']
    const opts = {}
    if (options.note) { opts.note = document.createElement('p'); opts.note.textContent = 'Conversation not retained'; opts.note.id = 'not-retained' }
    ;(await import('/build-home/modal/frame.js')).openModal(t, opts)
    return t
  }, { patch, options })
  if (!ticket.agent || ticket.start == null) await expect(page.locator('.bm-doc')).toBeVisible()
  return ticket
}
async function pushDoc(page, id, values) {
  await page.evaluate(doc => window.dispatchEvent(new CustomEvent('phx:build-ticket-doc', { detail: { v: 1, kind: 'doc', ...doc } })), { id, ...values })
}
async function result(page, id, values) {
  await page.evaluate(msg => window.dispatchEvent(new CustomEvent('phx:build-queue-add', { detail: { v: 1, kind: 'queue-add-result', ...msg } })), { id, ...values })
}

test('fixture body and author load through the real ticket-doc event', async ({ page }) => {
  const t = await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    const t = ctx.D.plan[0]
    ;(await import('/build-home/modal/frame.js')).openModal(t)
    return t
  })
  await expect(page.locator('.bm-body h4').first()).toHaveText('Scope')
  await expect(page.locator('.bm-src')).toContainText(/by @\w/)
  await expect(page.locator('.bm-body')).not.toContainText('Loading the issue body')
  expect(t.agent).toBeFalsy()
})

test('doc cues preserve order, hostile text, unknown facts, dependencies and note placement', async ({ page }) => {
  const held = 'Held " onmouseover="window.__xss=1'
  const t = await display(page, { cue: { held, failed: { by: 7, blocks: [12, 13, 14] }, unknown: true }, override: { reason: 'operator <decision>' }, deps: ['999'], qpos: null, cx: null, est: null }, { missing: true, note: true })
  await pushDoc(page, t.id, { state: 'available', body_html: '<p>Summary</p><h4>Scope</h4><ul><li>Real scope</li></ul>' })
  expect(await page.locator('.bm-body .bm-cue').allTextContents()).toEqual([held, 'Prerequisite #7 failed — this and 2 more are blocked', 'Prerequisite state unknown', 'operator <decision>'])
  expect(await page.locator('.bm-body > p').first().evaluate(el => el.nextElementSibling.textContent)).toBe(held)
  await expect(page.locator('.bm-facts')).toContainText('Queue—')
  await expect(page.locator('.bm-facts')).toContainText('Complexity—')
  await expect(page.locator('.bm-facts')).toContainText('Estimate—')
  await expect(page.locator('.bm-dep')).toHaveText(['#999not loaded', '#998not loaded'])
  await expect(page.locator('.bm-src + #not-retained')).toHaveCount(1)
  await page.locator('.bm-dep').first().focus(); await page.keyboard.press('Tab')
  await expect(page.locator('.bm-dep').last()).toBeFocused()
  expect(await page.evaluate(() => window.__xss)).toBeUndefined()
  const style = await page.locator('.bm-body .bm-cue').first().evaluate(el => ({ size: getComputedStyle(el).fontSize, margin: getComputedStyle(el).marginBottom, root: getComputedStyle(document.documentElement).fontSize }))
  expect(parseFloat(style.size)).toBeCloseTo(parseFloat(style.root) * .84)
  expect(parseFloat(style.margin)).toBeCloseTo(parseFloat(style.root) * .5)
})

for (const [state, text] of [['loading', 'Loading the issue body…'], ['unavailable', 'Issue body unavailable · rate limited · retry in 30s'], ['identity_unknown', 'Issue body not loaded here · open it on GitHub'], ['empty', 'No description.'], ['stale', '(4m ago) · not refreshed']]) {
  test('body state ' + state + ' stays explicit', async ({ page }) => {
    const t = await display(page)
    const observed = await page.evaluate(async () => (await import('/build-home/clock.js')).nowMs() - 240_000)
    await pushDoc(page, t.id, { state, reason: state === 'stale' ? 'not_fresh' : 'rate_limited', retry_after: 30, observed_at: observed, body_html: '<p>Retained description</p>' })
    await expect(page.locator('.bm-body')).toContainText(text)
    if (state !== 'empty') await expect(page.locator('.bm-body')).not.toContainText('No description.')
    if (['unavailable', 'identity_unknown', 'loading'].includes(state)) await expect(page.locator('.bm-body')).not.toContainText('Retained description')
  })
}

test('body links are isolated, foreign replies ignored, upserts retain body and scroll without rereading', async ({ page }) => {
  const t = await display(page)
  await pushDoc(page, t.id, { state: 'available', body_html: '<p><a href="https://example.com">x</a></p>' + '<p>long paragraph</p>'.repeat(100) })
  await expect(page.locator('.bm-body a')).toHaveAttribute('target', '_blank')
  await expect(page.locator('.bm-body a')).toHaveAttribute('rel', 'noopener noreferrer')
  await page.locator('.bm-doc').evaluate(el => { el.scrollTop = 120 })
  await pushDoc(page, '99999', { state: 'empty' })
  await expect(page.locator('.bm-body a')).toHaveCount(1)
  await page.evaluate(async t => {
    const { ctx } = await import('/build-home/state.js')
    ;(await import('/build-home/hook.js')).receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now, upsert: [{ ...t, qpos: 3, wave: 2 }], remove: [], set: {} })
  }, t)
  await expect(page.locator('.bm-facts')).toContainText('QueueQ3WaveW2')
  expect(await page.locator('.bm-doc').evaluate(el => el.scrollTop)).toBe(120)
  expect(await page.evaluate(() => window.docCalls.filter(c => c.event === 'ticket-doc').length)).toBe(1)
})

for (const [state, writable, expected] of [['ok', false, 'hidden'], ['disabled', true, 'hidden'], ['unavailable', true, 'disabled'], ['incomplete', true, 'disabled'], ['ok', true, 'enabled'], ['stale', true, 'enabled']]) {
  test(`queue visibility ${state} writable=${writable}`, async ({ page }) => {
    await display(page, { sec: 'nq' }, { writable, queue: { state, reason: 'writes_paused' } })
    const button = page.getByRole('button', { name: 'Add to queue' })
    if (expected === 'hidden') await expect(button).toHaveCount(0)
    else if (expected === 'enabled') { await expect(button).toBeEnabled(); await expect(page.locator('.bm-qadd')).toHaveAttribute('title', 'writes_paused') }
    else {
      await expect(button).toBeDisabled()
      const reason = state === 'unavailable' ? 'Build queue unavailable · writes_paused' : 'Build queue state unknown'
      await expect(page.locator('.bm-qadd')).toHaveAttribute('title', reason)
      await expect(page.locator('#bm-qadd-reason')).toHaveText(reason)
      await expect(button).toHaveAttribute('aria-describedby', 'bm-qadd-reason')
    }
  })
}

test('queue add pending, refusal, unknown outcome and success settle through registered events', async ({ page }) => {
  const t = await display(page, { sec: 'nq' })
  const button = page.getByRole('button', { name: 'Add to queue' })
  await button.click(); await expect(button).toHaveAttribute('aria-busy', 'true'); await expect(button).toBeDisabled()
  await result(page, t.id, { ok: false, reason: 'closed' })
  await expect(button).toBeEnabled(); await expect(page.locator('.bm-side .bm-cue.bad')).toHaveText('Could not add to queue · the issue is closed')
  await button.click(); await result(page, t.id, { ok: false, reason: 'outcome_unknown' })
  await expect(button).toBeEnabled(); await expect(page.locator('.bm-side .bm-cue')).toContainText('outcome unknown')
  await button.click(); await result(page, t.id, { ok: true })
  await expect(button).toBeDisabled(); await expect(page.locator('.bm-qadd')).toHaveAttribute('title', 'Added · waiting for the queue')
  await page.evaluate(async t => {
    const { ctx } = await import('/build-home/state.js')
    ;(await import('/build-home/hook.js')).receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now, upsert: [{ ...t, sec: 'plan', qpos: 1, wave: 1 }], remove: [], set: {} })
  }, t)
  await expect(button).toHaveCount(0); await expect(page.locator('.bm-facts')).toContainText('QueueQ1WaveW1')
})

test('mounted hook reconnect re-reads doc and turns pending adds into unknown outcomes', async ({ page }) => {
  const t = await display(page, { sec: 'nq' })
  await page.getByRole('button', { name: 'Add to queue' }).click()
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    const hook = (await import('/build-home/hook.js')).createBuildHomeHook()
    const instance = { buildActive: true }
    hook.disconnected.call(instance); hook.reconnected.call(instance)
  })
  await expect(page.locator('.bm-side .bm-cue')).toContainText('outcome unknown')
  await expect(page.getByRole('button', { name: 'Add to queue' })).toBeEnabled()
  expect(await page.evaluate(() => window.docCalls.filter(c => c.event === 'ticket-doc').length)).toBe(2)
  expect(t.id).toBeTruthy()
})

test('conversation opens skip body reads; doc close unsubscribes and pack ids never request GitHub', async ({ page }) => {
  await display(page, { agent: { model: 'codex', state: 'active' }, start: 1 })
  expect(await page.evaluate(() => window.docCalls.filter(c => c.event === 'ticket-doc'))).toEqual([])
  await page.keyboard.press('Escape')
  expect(await page.evaluate(() => window.docCalls.filter(c => c.event === 'ticket-doc-close'))).toEqual([])
  await display(page)
  await page.keyboard.press('Escape')
  expect(await page.evaluate(() => window.docCalls.filter(c => c.event === 'ticket-doc-close').length)).toBe(1)
  await page.evaluate(async () => {
    window.docCalls = []
    const { ctx } = await import('/build-home/state.js')
    ;(await import('/build-home/modal/frame.js')).openModal({ ...ctx.D.plan[0], id: 'pack:future/item', num: null, agent: null })
  })
  await expect(page.locator('.bm-doc')).toBeVisible()
  expect(await page.evaluate(() => window.docCalls.filter(c => c.event === 'ticket-doc'))).toEqual([])
})

test('read-only add reply removes the control and settled duplicates name their queue', async ({ page }) => {
  const t = await display(page, { sec: 'nq' })
  await page.getByRole('button', { name: 'Add to queue' }).click()
  await result(page, t.id, { ok: true, reason: 'already_queued', queue: 'paseo' })
  await expect(page.getByRole('button', { name: 'Add to queue' })).toBeDisabled()
  await expect(page.locator('.bm-qadd')).toHaveAttribute('title', 'Already in queue paseo')
  // A different ticket exercises the event reply that discovers a server-side access change.
  await page.keyboard.press('Escape')
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    ;(await import('/build-home/modal/frame.js')).openModal({ ...ctx.D.nq[1], agent: null })
  })
  await page.getByRole('button', { name: 'Add to queue' }).click()
  await page.evaluate(() => window['queue-addReply']({ v: 1, kind: 'error', reason: 'read_only' }))
  await expect(page.getByRole('button', { name: 'Add to queue' })).toHaveCount(0)
})

async function upsert(page, rows) {
  await page.evaluate(async rows => {
    const { ctx } = await import('/build-home/state.js')
    ;(await import('/build-home/hook.js')).receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now, upsert: rows, remove: [], set: {} })
  }, rows)
}

for (const settleBeforeDiff of [true, false]) {
  test(`authoritative queue transition permits re-adding after ${settleBeforeDiff ? 'success' : 'pending with late success'}`, async ({ page }) => {
    const t = await display(page, { sec: 'nq' })
    const button = page.getByRole('button', { name: 'Add to queue' })
    await button.click(); await expect(button).toBeDisabled()
    if (settleBeforeDiff) await result(page, t.id, { ok: true })
    await upsert(page, [{ ...t, sec: 'plan', qpos: 1, wave: 1 }])
    await expect(button).toHaveCount(0)
    if (!settleBeforeDiff) await result(page, t.id, { ok: true })
    await upsert(page, [{ ...t, sec: 'nq', qpos: null, wave: null }])
    await expect(button).toBeEnabled()
    await button.click(); await expect(button).toHaveAttribute('aria-busy', 'true')
    expect(await page.evaluate(() => window.docCalls.filter(c => c.event === 'queue-add').length)).toBe(2)
  })
}

test('board diffs preserve dependency and queue focus without taking focus from the header', async ({ page }) => {
  const t = await display(page, { sec: 'nq', deps: ['999'] })
  const dep = page.locator('.bm-dep[data-goto="999"]')
  const button = page.getByRole('button', { name: 'Add to queue' })
  await dep.focus()
  const unrelated = await page.evaluate(async () => (await import('/build-home/state.js')).ctx.D.plan[0])
  await upsert(page, [{ ...unrelated, title: unrelated.title + ' unrelated update' }])
  await expect(dep).toBeFocused()
  await upsert(page, [{ ...t, title: t.title + ' updated' }])
  await expect(dep).toBeFocused()
  await page.keyboard.press('Tab'); await expect(button).toBeFocused()
  await upsert(page, [{ ...t, title: t.title + ' updated again' }])
  await expect(button).toBeFocused()
  await page.keyboard.press('Enter'); await expect(button).toHaveAttribute('aria-busy', 'true')
  await result(page, t.id, { ok: false, reason: 'closed' })
  await page.locator('[data-a="link"]').focus()
  await upsert(page, [{ ...t, title: t.title + ' header update' }])
  await expect(page.locator('[data-a="link"]')).toBeFocused()
  expect(await page.evaluate(() => window.docCalls.filter(c => c.event === 'queue-add').length)).toBe(1)
})

// Unknown observations must never acquire a plausible freshness age.
test('stale body with no observation renders unknown age and retains content', async ({ page }) => {
  const t = await display(page)
  await pushDoc(page, t.id, { state: 'stale', reason: 'not_fresh', observed_at: null, body_html: '<p>Retained description</p>' })
  await expect(page.locator('.bm-body')).toContainText('Retained description')
  await expect(page.locator('.bm-cue')).toContainText('unknown time (age unknown)')
})

test('board updates preserve focused body links', async ({ page }) => {
  const t = await display(page)
  await pushDoc(page, t.id, { state: 'available', body_html: '<p><a href="https://example.com">Body link</a></p>' })
  await page.locator('.bm-body a').focus()
  await page.evaluate(async () => (await import('/build-home/state.js')).fx.modalSync({ upsert: [], remove: [], set: {} }))
  await expect(page.locator('.bm-body a')).toBeFocused()
})
