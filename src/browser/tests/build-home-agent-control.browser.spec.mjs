import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 1000 } })
// Mutation runs serve the isolated production module through the real mounted hook.
test.beforeEach(async ({ page }, info) => {
  const root = info.project.metadata.agentAssets
  if (root) await page.route('**/build-home/modal/agent-control.js', async route => route.fulfill({
    body: await readFile(root + '/modal/agent-control.js', 'utf8'), contentType: 'text/javascript',
  }))
})
const pause = page => page.locator('#tk-head [data-a="pause"]')
async function tokenColor(page, token) {
  return page.evaluate(token => {
    const probe = document.createElement('span'); probe.style.color = 'var(' + token + ')'; document.body.append(probe)
    const color = getComputedStyle(probe).color; probe.remove(); return color
  }, token)
}
async function capture(page, name) {
  await test.info().attach(name, { body: await page.locator('#tk-head .bm-agent').screenshot(), contentType: 'image/png' })
}
const chat = page => page.locator('#tk-head [data-a="chat"]')
async function open(page, writable = true, state = 'active') {
  await page.request.get('/streamdeck-control/' + (writable ? 'writable' : 'read_only'))
  await page.goto('/build-fixture/live')
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/state.js')).ctx.D?.now.length)).not.toBeUndefined()
  const row = await page.evaluate(async state => (await import('/build-home/state.js')).ctx.D.now.find(t => t.agent?.state === state), state)
  await page.evaluate(async row => (await import('/build-home/modal/frame.js')).openModal(row), row)
  await expect(page.locator('.bm-agent')).toHaveAttribute('data-control', 'ready')
  return row
}
async function lifecycle(page, id, control, status, rejection) {
  await page.request.get('/build-control/lifecycle?' + new URLSearchParams({ id, control, status, ...(rejection ? { class: rejection } : {}) }))
}
async function calls(page) {
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), push = ctx.push
    window.controlCalls = []
    ctx.push = (event, payload) => { window.controlCalls.push({ event, payload }); return push(event, payload) }
  })
}

test('pending pause waits for lifecycle and diff, keeps focus, then resumes', async ({ page }) => {
  const row = await open(page)
  await calls(page)
  await expect(pause(page)).toHaveAttribute('title', 'Pause agent')
  await pause(page).focus(); await page.keyboard.press('Enter')
  await expect(pause(page)).toHaveAttribute('aria-busy', 'true')
  await expect(pause(page)).toBeFocused()
  await expect(page.locator('.bm-agent [role="status"]')).toHaveText('Pause requested…')
  await capture(page, 'pending')
  expect(await page.evaluate(async id => (await import('/build-home/state.js')).ctx.D.byId[id].agent.state, row.id)).toBe('active')
  await pause(page).click({ force: true })
  expect(await page.evaluate(() => window.controlCalls.filter(c => c.event === 'request-unit-control').length)).toBe(1)
  await lifecycle(page, row.id, 'pause', 'applied')
  await expect(pause(page)).toHaveAttribute('title', 'Resume agent')
  await expect(pause(page)).not.toHaveAttribute('aria-busy')
  await expect(page.locator('.bm-agent [role="status"]')).toHaveText('Paused')
  await pause(page).click()
  await expect(pause(page)).toHaveAttribute('title', 'Resume requested…')
  await lifecycle(page, row.id, 'resume', 'applied')
  await expect(pause(page)).toHaveAttribute('title', 'Pause agent')
})

test('read-only is reachable, dimmed and never sends a control request', async ({ page }) => {
  await open(page, false)
  await calls(page)
  await expect(pause(page)).toHaveAttribute('aria-disabled', 'true')
  await expect(pause(page)).toHaveAttribute('title', 'Dashboard is read-only')
  await expect(pause(page)).toHaveCSS('opacity', '0.4')
  await capture(page, 'read-only')
  await expect(pause(page)).not.toHaveAttribute('disabled')
  await pause(page).focus(); await page.keyboard.press('Enter')
  expect(await page.evaluate(() => window.controlCalls.filter(c => c.event === 'request-unit-control'))).toEqual([])
  await expect(chat(page)).toBeHidden()
})

test('expiry permits retry, same-row diffs preserve control and error feedback', async ({ page }) => {
  const row = await open(page)
  await pause(page).click()
  await lifecycle(page, row.id, 'pause', 'expired')
  await expect(pause(page)).toHaveClass(/bad/)
  await expect(pause(page)).toHaveCSS('color', await tokenColor(page, '--block-ink'))
  await capture(page, 'expired')
  await expect(pause(page)).toHaveAttribute('title', 'Pause timed out — retry')
  await expect(pause(page)).not.toHaveAttribute('aria-disabled')
  await page.request.get('/build-control/diff?' + new URLSearchParams({ id: row.id, op: 'title' }))
  await expect(page.locator('#bm-title')).toContainText('updated')
  await expect(pause(page)).toHaveAttribute('title', 'Pause timed out — retry')
  await expect(pause(page)).not.toHaveAttribute('disabled')
  await pause(page).click()
  await lifecycle(page, row.id, 'pause', 'rejected', 'stale_generation')
  await expect(pause(page)).toHaveClass(/warn/)
  await expect(pause(page)).toHaveCSS('color', await tokenColor(page, '--attn-ink'))
  await expect(pause(page)).toHaveAttribute('title', 'Unit changed generation — pause canceled')
  await capture(page, 'stale-generation-warning')
})

test('unavailable and historical controls stay safe, mobile keeps live buttons', async ({ page }) => {
  const row = await open(page)
  await page.evaluate(async id => (await import('/build-home/modal/frame.js')).controlMessage({ v: 1, kind: 'control', id, control: null, chat: null }), row.id)
  await expect(pause(page)).toHaveAttribute('title', 'Agent control unavailable')
  await expect(pause(page)).toHaveAttribute('aria-disabled', 'true')
  await expect(chat(page)).toBeHidden()
  await capture(page, 'unavailable')
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    await (await import('/build-home/modal/frame.js')).openModal(ctx.D.hist.find(t => t.agent && t.start))
  })
  await expect(chat(page)).toBeHidden()
  await page.evaluate(async row => (await import('/build-home/modal/frame.js')).openModal(row), row)
  await expect(chat(page)).toBeHidden()
  await page.setViewportSize({ width: 390, height: 844 })
  await expect(page.locator('.bm-agent > span').first()).toBeHidden()
  await expect(pause(page)).toBeVisible()
  await expect(chat(page)).toBeHidden()
})

test('guard: parked and command rows retain the existing design visibility rule', async ({ page }) => {
  await open(page, true, 'command')
  await expect(pause(page)).toHaveCount(0)
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), row = structuredClone(ctx.D.now[0])
    row.agent.state = 'parked'
    await (await import('/build-home/modal/frame.js')).openModal(row)
  })
  await expect(pause(page)).toHaveCount(0)
})


test('conversation handoff stays hidden while legacy chat routes return to this modal', async ({ page }) => {
  const row = await open(page)
  await expect(page).toHaveURL(new RegExp('ticket=' + row.id))
  await expect(chat(page)).toBeHidden()
  const reply = await page.evaluate(async id => (await import('/build-home/state.js')).ctx.push('open-conversation', { id }), row.id)
  expect(reply).toEqual({ v: 1, kind: 'error', reason: 'unavailable' })
  await expect(page).toHaveURL(new RegExp('ticket=' + row.id))
  await expect(page.locator('#tk-backdrop')).toHaveClass(/show/)
})
