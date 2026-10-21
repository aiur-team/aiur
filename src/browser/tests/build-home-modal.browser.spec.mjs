import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 1000 } })
// Cohesive end-to-end modal flows share the same mounted hook and fixture helpers.
test.beforeEach(async ({ page }, info) => {
  page.on('pageerror', error => { throw error })
  const root = info.project.metadata.agentAssets
  if (root) await page.route('**/build-home/home.css', async route => route.fulfill({
    body: await readFile(root + '/home.css', 'utf8'), contentType: 'text/css',
  }))
  if (root) for (const name of ['frame', 'header', 'focus']) await page.route('**/build-home/modal/' + name + '.js', async route => route.fulfill({
    body: await readFile(root + '/modal/' + name + '.js', 'utf8'), contentType: 'text/javascript',
  }))
})
async function open(page, dataset = 'live', query = '') {
  await page.goto('/build-fixture/' + dataset + query)
  await expect(page.locator('#bd-content')).toHaveCount(1)
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/state.js')).ctx.D?.now.length)).not.toBeUndefined()
}
async function row(page, section = 'now', index = 0) {
  return page.evaluate(async ({ section, index }) => structuredClone((await import('/build-home/state.js')).ctx.D[section][index]), { section, index })
}
async function display(page, t) {
  await page.evaluate(async t => (await import('/build-home/modal/frame.js')).openModal(t), t)
  await expect(page.locator('#bm-title')).toHaveText('#' + t.num + t.title)
}
async function installSpy(page) {
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), push = ctx.push
    window.modalCalls = []
    ctx.push = (event, payload) => { window.modalCalls.push({ event, payload }); return push(event, payload) }
  })
}
const calls = page => page.evaluate(() => window.modalCalls.filter(c => ['open-ticket', 'close-ticket'].includes(c.event)))

test('card open, header identity, notices, focus trap and all close paths', async ({ page }) => {
  await open(page); await installSpy(page)
  const t = await row(page), card = page.locator('.bd-card[data-id="' + t.id + '"]').first()
  await card.scrollIntoViewIfNeeded()
  for (const close of ['button', 'escape', 'backdrop']) {
    await card.click()
    await expect(page.locator('#tk-modal')).toHaveClass(/\bbdm\b/)
    await expect(page.locator('#tk-modal')).toHaveAttribute('aria-labelledby', 'bm-title')
    await expect(page.locator('#bm-title')).toHaveText('#' + t.num + t.title)
    await expect(page.locator('#bm-title')).toBeFocused()
    await expect(page).toHaveURL(new RegExp('ticket=' + t.id))
    expect(await page.evaluate(() => document.body.style.overflow)).toBe('hidden')
    await page.locator('#bm-title').click()
    await expect(page.locator('#tk-backdrop')).toHaveClass(/\bshow\b/)
    await page.locator('#bm-title').focus(); await page.keyboard.press('Shift+Tab')
    await expect(page.locator('#bd-tk-close')).toBeFocused()
    await page.keyboard.press('Tab')
    await expect(page.locator('#tk-head a').first()).toBeFocused()
    if (close === 'button') await page.locator('#bd-tk-close').click()
    if (close === 'escape') {
      expect(await page.evaluate(() => { const e = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }); document.dispatchEvent(e); return e.defaultPrevented })).toBe(true)
    }
    if (close === 'backdrop') await page.locator('#tk-backdrop').click({ position: { x: 2, y: 2 } })
    await expect(page.locator('#tk-backdrop')).not.toHaveClass(/\bshow\b/)
    await expect(page).not.toHaveURL(/ticket=/)
    await expect(card).toBeFocused()
    expect(await page.evaluate(() => document.body.style.overflow)).toBe('')
  }
  expect(await calls(page)).toEqual(Array.from({ length: 3 }, () => [
    { event: 'open-ticket', payload: { id: t.id, loaded: true } }, { event: 'close-ticket', payload: {} },
  ]).flat())
})

test('focused cards open once with Enter and Space through the mounted hook', async ({ page }) => {
  await open(page); await installSpy(page)
  const t = await row(page), card = page.locator('.bd-card[data-id="' + t.id + '"]').first()
  for (const key of ['Enter', 'Space']) {
    await card.focus(); await page.keyboard.press(key)
    await expect(page.locator('#bm-title')).toHaveText('#' + t.num + t.title)
    await expect(page.locator('#bm-title')).toBeFocused()
    await expect(page).toHaveURL(new RegExp('ticket=' + t.id))
    await page.keyboard.press('Escape')
    await expect(page.locator('#tk-backdrop')).not.toHaveClass(/\bshow\b/)
    await expect(page).not.toHaveURL(/ticket=/)
    await expect(card).toBeFocused()
  }
  expect(await calls(page)).toEqual(Array.from({ length: 2 }, () => [
    { event: 'open-ticket', payload: { id: t.id, loaded: true } }, { event: 'close-ticket', payload: {} },
  ]).flat())
})

test('deep links open loaded and older history rows; unknown and malformed links stay distinct', async ({ page }) => {
  await open(page)
  const t = await row(page)
  await open(page, 'live', '?ticket=' + t.id)
  await expect(page.locator('#bm-title')).toHaveText('#' + t.num + t.title)
  await open(page, 'dense')
  const old = await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    const reply = await ctx.push('load-earlier', { before: ctx.snap.history.from })
    return reply.rows.at(-1)
  })
  expect(old).toBeTruthy()
  await open(page, 'dense', '?ticket=' + old.id)
  await expect(page.locator('#bm-title')).toHaveText('#' + old.num + old.title)
  await open(page, 'live', '?ticket=99999')
  await expect(page.locator('#bm-title')).toHaveText('#99999Ticket not found')
  await expect(page.locator('.bm-act button')).toHaveCount(1)
  await expect(page).toHaveURL(/ticket=99999/)
  await page.locator('#bd-tk-close').click(); await expect(page).not.toHaveURL(/ticket=/)
  await open(page, 'live', '?ticket=AIUR-12')
  await expect(page.locator('#tk-backdrop')).not.toHaveClass(/\bshow\b/)
  await expect(page).not.toHaveURL(/ticket=/)
})

test('loaded opens never wait for replies; stale fetches cannot replace a newer selection', async ({ page }) => {
  await open(page); const t = await row(page)
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { openById } = await import('/build-home/modal/frame.js')
    const push = ctx.push; window.modalCalls = []
    ctx.push = (event, payload) => {
      window.modalCalls.push({ event, payload })
      if (event === 'open-ticket') return new Promise(resolve => { window.replyTicket = resolve })
      return push(event, payload)
    }
    openById(ctx.D.now[0].id)
  })
  await expect(page.locator('#bm-title')).toHaveText('#' + t.num + t.title)
  expect(await calls(page)).toEqual([{ event: 'open-ticket', payload: { id: t.id, loaded: true } }])
  await page.evaluate(async () => { void (await import('/build-home/modal/frame.js')).openById('99999') })
  await page.evaluate(() => { window.lateTicketReply = window.replyTicket })
  await display(page, t)
  await page.evaluate(() => window.lateTicketReply({ kind: 'error', reason: 'not_found' }))
  await expect(page.locator('#bm-title')).toHaveText('#' + t.num + t.title)
})

test('unavailable, disconnected, lost replies and unknown causes never say not found', async ({ page }) => {
  await open(page)
  for (const [reason, text] of [['unavailable', 'source unavailable'], ['invalid_params', 'invalid ticket id'], ['odd', 'unknown cause']]) {
    await page.evaluate(async reason => {
      const { ctx } = await import('/build-home/state.js'), push = ctx.push
      ctx.push = (e, p) => e === 'open-ticket' ? Promise.resolve({ kind: 'error', reason }) : push(e, p)
      await (await import('/build-home/modal/frame.js')).openById('99999')
    }, reason)
    await expect(page.locator('#bm-title')).toHaveText('#99999Ticket unavailable')
    await expect(page.locator('#tk-head .bm-meta')).toHaveText(text)
  }
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'); ctx.socket = 'down'
    const push = ctx.push; window.offlineTicketReads = 0
    ctx.push = (e, p) => { if (e === 'open-ticket') window.offlineTicketReads++; return push(e, p) }
    await (await import('/build-home/modal/frame.js')).openById('88888')
  })
  await expect(page.locator('#tk-head .bm-meta')).toHaveText('connection lost')
  expect(await page.evaluate(() => window.offlineTicketReads)).toBe(0)
  await page.clock.install()
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'); ctx.socket = 'up'; const push = ctx.push
    ctx.push = (e, p) => e === 'open-ticket' ? new Promise(() => {}) : push(e, p)
    void (await import('/build-home/modal/frame.js')).openById('77777')
  })
  await page.clock.runFor(10_001)
  await expect(page.locator('#bm-title')).toHaveText('#77777Ticket unavailable')
  await expect(page.locator('#tk-head .bm-meta')).toHaveText('timed out')
})

test('goto and server URL pushes replace without replaying tkin; body seams clean up', async ({ page }) => {
  await open(page); const t = await row(page), next = await row(page, 'now', 1)
  await page.evaluate(async () => {
    const { fx } = await import('/build-home/state.js'), { onModalClose } = await import('/build-home/modal/frame.js')
    window.bodyCalls = []; window.cleanups = 0
    fx.renderConversation = (t, el, opts) => { window.bodyCalls.push(['conversation', t.id, opts.note]); el.textContent = 'conversation body' }
    fx.renderDocBody = (t, el, opts) => { window.bodyCalls.push(['doc', t.id, opts.note]); el.textContent = 'doc body' }
    onModalClose(() => window.cleanups++)
  })
  await display(page, t)
  await page.locator('#tk-modal').evaluate(async el => { await Promise.all(el.getAnimations().map(a => a.finished)) })
  await page.locator('#tk-body').evaluate((el, id) => { const b = document.createElement('button'); b.dataset.goto = id; b.textContent = 'Next'; el.append(b) }, next.id)
  await page.getByRole('button', { name: 'Next', exact: true }).click()
  await expect(page.locator('#bm-title')).toHaveText('#' + next.num + next.title)
  expect(await page.locator('#tk-modal').evaluate(el => el.getAnimations().length)).toBe(0)
  expect(await page.evaluate(() => window.bodyCalls.map(c => c.slice(0, 2)))).toEqual([['conversation', t.id], ['conversation', next.id]])
  await page.evaluate(async id => {
    const state = { ...(await import('/build-home/state.js')).S, ticket: id }
    window.dispatchEvent(new CustomEvent('phx:build:url', { detail: { state } }))
  }, t.id)
  await expect(page.locator('#bm-title')).toHaveText('#' + t.num + t.title)
  await page.evaluate(() => window.dispatchEvent(new CustomEvent('phx:build:url', { detail: { state: {} } })))
  await expect(page.locator('#tk-backdrop')).not.toHaveClass(/\bshow\b/)
  expect(await page.evaluate(() => window.cleanups)).toBeGreaterThanOrEqual(3)
  await page.evaluate(async t => (await import('/build-home/modal/frame.js')).openModal({ ...t, agent: null }, { note: 'handoff' }), t)
  await expect(page.locator('#tk-body')).toHaveText('doc body')
  expect(await page.evaluate(() => window.bodyCalls.at(-1))).toEqual(['doc', t.id, 'handoff'])
})

test('unknown header values, real links, PR absence, pack safety and hostile text', async ({ page }) => {
  await open(page); const base = await row(page)
  const cases = [
    [{ ...base, pct: null, pts: null, agent: { model: 'alien', state: null, effort: null } }, 'State unknown', 'idle'],
    ...[['not_planned', 'Not planned'], ['closed', 'Closed'], ['weird', 'State unknown']].map(([status, text]) => [{ ...base, sec: 'hist', status, pct: null }, text, 'idle']),
    [{ ...base, sec: 'plan', qpos: null }, 'Queued · Q?', 'idle'],
  ]
  for (const [t, text, tone] of cases) {
    await display(page, t)
    await expect(page.locator('.bm-st')).toContainText(text); await expect(page.locator('.bm-st')).toHaveClass('bm-st ' + tone)
    expect(await page.locator('.bm-st').evaluate(el => el.style.getPropertyValue('--ph'))).toBe('')
  }
  await display(page, cases[0][0]); await expect(page.locator('#bm-pct')).toHaveText('?%')
  await expect(page.locator('[data-unknown="pts"]')).toHaveText('? pts')
  await expect(page.locator('.bm-agent .ax-mono')).toHaveText('A')
  await page.setViewportSize({ width: 390, height: 844 })
  await expect(page.locator('.bm-agent .ax-mono')).toBeVisible()
  await page.setViewportSize({ width: 1440, height: 1000 })
  await expect(page.locator('.bm-agent')).not.toHaveAttribute('title', /null/)
  const hostile = { ...base, title: '<img src=x onerror="window.__xss=1">', epic: 'missing', feature: '<script>bad</script>', pr: { num: 233, state: 'merged' } }
  await page.evaluate(async () => { (await import('/build-home/state.js')).ctx.D.repo = { url: 'https://github.com/acme/widgets/' } })
  await display(page, hostile)
  await expect(page.locator('.bm-pr.merged')).toHaveAttribute('href', 'https://github.com/acme/widgets/pull/233')
  await expect(page.getByRole('link', { name: `Issue #${base.num} on GitHub` })).toHaveAttribute('href', `https://github.com/acme/widgets/issues/${base.num}`)
  expect(await page.evaluate(() => window.__xss)).toBeUndefined()
  await expect(page.locator('#bm-title img')).toHaveCount(0)
  await display(page, { ...base, pr: null }); await expect(page.locator('.bm-pr')).toHaveCount(0)
  await page.evaluate(async () => { (await import('/build-home/state.js')).ctx.D.repo = null })
  await display(page, hostile); await expect(page.locator('.bm-links a')).toHaveCount(0)
  await page.evaluate(async t => (await import('/build-home/modal/frame.js')).openModal({ ...t, id: 'pack:test/item', num: null, sec: 'plan' }), base)
  await expect(page.locator('.bm-num')).toHaveText('—')
  await expect(page.locator('[data-a="none"]')).toHaveAttribute('aria-disabled', 'true')
  await expect(page).not.toHaveURL(/ticket=/)
})

test('copy success, fallback and failure reflect the actual clipboard outcome', async ({ page }) => {
  await open(page); const t = await row(page)
  for (const mode of ['clipboard', 'fallback', 'failure']) {
    await display(page, t)
    await page.evaluate(mode => {
      window.copiedText = null
      Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: async text => {
        if (mode !== 'clipboard') throw new Error('denied'); window.copiedText = text
      } } })
      document.execCommand = () => { window.copiedText = document.activeElement.value; return mode === 'fallback' }
    }, mode)
    const copy = page.locator('[data-a="link"]'); await copy.click()
    if (mode === 'failure') { await expect(copy).not.toHaveClass(/\bok\b/); await expect(copy).toHaveAttribute('title', /^Copy failed/); }
    else { await expect(copy).toHaveClass(/\bok\b/); await expect(copy).toHaveAttribute('title', 'Copied'); expect(await page.evaluate(() => window.copiedText)).toContain('ticket=' + t.num) }
  }
})

test('applied diffs refresh metadata and retire removed rows without rerendering the body', async ({ page }) => {
  await open(page); const t = await row(page); await display(page, t)
  // Opening the modal schedules its initial title focus on the next frame.
  // Let that settle before focusing the action whose focus must survive a diff.
  await expect(page.locator('#bm-title')).toBeFocused()
  const copy = page.locator('[data-a="link"]')
  await copy.focus()
  await expect(copy).toBeFocused()
  await page.evaluate(() => { window.copyButtonBeforeDiff = document.querySelector('[data-a="link"]') })
  await page.evaluate(async t => {
    const { ctx } = await import('/build-home/state.js'), { receive } = await import('/build-home/hook.js')
    receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now,
      upsert: [{ ...t, pct: 61 }], remove: [], set: {} })
  }, t)
  await expect(page.locator('#bm-pct')).toHaveText('61%')
  expect(await page.locator('.bm-st').evaluate(el => el.style.getPropertyValue('--ph'))).toBe('105')
  await expect.poll(() => page.evaluate(() => ({
    sameNode: window.copyButtonBeforeDiff === document.querySelector('[data-a="link"]'),
    activeAction: document.activeElement?.dataset?.a ?? null,
  }))).toEqual({ sameNode: false, activeAction: 'link' })
  await expect(copy).toBeFocused()
  await page.evaluate(async id => {
    const { ctx } = await import('/build-home/state.js'), { receive } = await import('/build-home/hook.js')
    receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now, upsert: [], remove: [id], set: {} })
  }, t.id)
  await expect(page.locator('#bm-title')).toHaveText('#' + t.num + 'Ticket not found')
})

test('navigation away disposes modal listeners and restores page scrolling', async ({ page }) => {
  await open(page); await display(page, await row(page))
  await page.evaluate(() => window.liveSocket.execJS(document.querySelector('#build-root'), JSON.stringify([['patch', { href: '/build?view=list', replace: false }]])))
  // A full LiveView navigation exercises destroyed(), rather than calling closeModal in the test.
  await page.evaluate(() => window.liveSocket.execJS(document.querySelector('#build-root'), JSON.stringify([['navigate', { href: '/conversations', replace: false }]])))
  await expect(page).toHaveURL(/conversations/)
  expect(await page.evaluate(() => document.body.style.overflow)).toBe('')
})
