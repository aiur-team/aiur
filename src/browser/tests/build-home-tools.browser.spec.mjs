import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { openFixture, expectAuditClean } from './support/browser-helpers.mjs'

test.beforeEach(async ({ page }) => {
  await openFixture(page)
  await page.evaluate(async () => {
    const state = await import('/build-home/state.js')
    const { createBuildHomeHook } = await import('/build-home/hook.js')
    document.body.innerHTML = '<main id="build-root" class="bd-root">' + ['bd-usage', 'bd-offline', 'bd-fh', 'bd-tools-l', 'bd-filters', 'bd-tools', 'bd-vp', 'bd-sb', 'bd-tree', 'bd-status'].map(id => `<div id="${id}">${id === 'bd-sb' ? '<i></i>' : ''}</div>`).join('') + '</main>'
    window.events = {}; window.pushes = []; window.board = []; window.m = state
    window.hook = createBuildHomeHook()
    Object.assign(hook, { el: document.querySelector('#build-root'), handleEvent: (name, fn) => events[name] = fn,
      pushEvent: (name, params) => { pushes.push({ name, params }); return name === 'build-resync' ? new Promise(() => {}) : Promise.resolve() } })
    hook.mounted()
    for (const name of ['viewport', 'relayout', 'update', 'jumpNow']) state.fx[name] = (...args) => board.push([name, ...args])
  })
})
test('mounted loading toolbar reports unknown and early switch preserves unavailable board', async ({ page }) => {
  await expect(page.getByRole('tab')).toHaveCount(3)
  await expect(page.locator('.bd-daemon')).toHaveText('Daemon status unknown')
  await expect(page.locator('.bd-daemon')).toHaveClass('bd-daemon off')
  await page.evaluate(() => document.querySelector('#bd-vp').textContent = 'Build timeline unavailable')
  await page.getByRole('tab', { name: 'Gantt' }).click()
  await expect(page.locator('#bd-vp')).toHaveText('Build timeline unavailable')
  expect(await page.evaluate(() => ({ view: m.S.view, board, params: pushes.filter(p => p.name === 'build:url').map(p => p.params) }))).toEqual({ view: 'gantt', board: [], params: [{ view: 'gantt' }] })
  await expect(page.locator('.bd-leg')).toHaveText(['Cleared', 'Pending', 'Planned estimate'])
  await expect(page.locator('.bd-exl, #bd-ex, #build-root select')).toHaveCount(0)
})
test('selected view is inert and switches invoke board in order and omit list legend', async ({ page }) => {
  await page.evaluate(() => { m.S.loading = false; window.original = document.querySelector('.bd-seg') })
  await page.getByRole('tab', { name: 'Timeline' }).click()
  expect(await page.evaluate(() => ({ same: original === document.querySelector('.bd-seg'), count: pushes.filter(p => p.name === 'build:url').length }))).toEqual({ same: true, count: 0 })
  await page.getByRole('tab', { name: 'Gantt' }).click()
  expect(await page.evaluate(() => board)).toEqual([['viewport'], ['relayout'], ['jumpNow', true]])
  await page.getByRole('tab', { name: 'List', exact: true }).click()
  await expect(page.locator('.bd-key')).toHaveCount(0)
  await expect(page.locator('#bd-tools > *')).toHaveCount(1)
  await expect(page.locator('#bd-nowbtn')).toHaveText('Live')
})
test('manual keyboard wraps, activates and preserves focus through cached and rewritten controls', async ({ page }) => {
  const tab = name => page.getByRole('tab', { name, exact: true })
  await tab('Timeline').focus()
  await page.keyboard.press('ArrowLeft'); await expect(tab('List')).toBeFocused()
  await page.keyboard.press('Home'); await expect(tab('Timeline')).toBeFocused()
  await page.keyboard.press('End'); await expect(tab('List')).toBeFocused()
  expect(await page.evaluate(() => m.S.view)).toBe('graph')
  await page.keyboard.press('Enter'); await expect(tab('List')).toBeFocused()
  await expect(tab('List')).toHaveAttribute('aria-selected', 'true')
  await page.keyboard.press('Home'); await page.keyboard.press('ArrowRight')
  await page.evaluate(() => { window.focused = document.activeElement; m.fx.renderTools() })
  expect(await page.evaluate(() => document.activeElement === focused)).toBe(true)
  await page.evaluate(() => { m.S.span = 7; m.fx.renderTools() })
  await expect(tab('Gantt')).toBeFocused()
  await page.keyboard.press('Space'); await expect(tab('Gantt')).toHaveAttribute('aria-selected', 'true')
})
test('daemon status follows snapshot and socket changes and escapes helper text', async ({ page }) => {
  for (const state of ['live', 'offline', 'stale', 'unknown']) {
    await page.evaluate(state => { m.ctx.snap = { daemon: { state } }; m.fx.renderTools() }, state)
    await expect(page.locator('.bd-daemon')).toHaveText(state === 'unknown' ? 'Daemon status unknown' : `Daemon ${state}`)
    expect(await page.locator('.bd-daemon').evaluate(el => el.classList.contains('off'))).toBe(state !== 'live')
  }
  await page.evaluate(() => { m.ctx.snap = { daemon: { state: 'live' } }; m.fx.renderTools(); hook.disconnected() })
  await expect(page.locator('.bd-daemon')).toHaveText('Daemon unreachable')
  await page.evaluate(() => hook.reconnected())
  await expect(page.locator('.bd-daemon')).toHaveText('Daemon live')
  await page.evaluate(() => { m.fx.daemonView = () => ({ dotOff: true, dotText: '<img src=x>' }); m.fx.renderStatus() })
  await expect(page.locator('.bd-daemon')).toHaveText('<img src=x>')
  await expect(page.locator('.bd-daemon img')).toHaveCount(0)
})
test('server URL change rebuilds viewport and jumps without URL echo', async ({ page }) => {
  for (const view of ['gantt', 'graph']) {
    await page.evaluate(view => { m.S.loading = false; board.length = 0; events['build:url']({ state: { view } }) }, view)
    expect(await page.evaluate(() => ({ board, count: pushes.filter(p => p.name === 'build:url').length }))).toEqual({ board: [['viewport'], ['relayout'], ['update'], ['jumpNow', true]], count: 0 })
  }
})
test('span HTML invalidates cache, list omits span controls, lifecycle releases listeners', async ({ page }) => {
  await page.evaluate(() => { window.wired = 0; window.span = '<button data-span="7">Week</button>'; m.fx.spanToolsHTML = () => span; m.fx.wireSpanTools = () => wired++; m.fx.renderTools(); m.fx.renderTools() })
  expect(await page.evaluate(() => wired)).toBe(1)
  await page.evaluate(() => { span = '<button data-span="7" disabled>Week</button>'; m.fx.renderTools() })
  await expect(page.locator('[data-span]')).toBeDisabled()
  expect(await page.evaluate(() => wired)).toBe(2)
  await page.getByRole('tab', { name: 'List', exact: true }).click()
  await expect(page.locator('[data-span]')).toHaveCount(0)
  await page.evaluate(() => { hook.destroyed(); pushes.length = 0 })
  await page.getByRole('tab', { name: 'Gantt' }).click()
  expect(await page.evaluate(() => pushes)).toEqual([])
  await page.evaluate(() => hook.mounted())
  await page.getByRole('tab', { name: 'Gantt' }).click()
  expect(await page.evaluate(() => pushes.filter(p => p.name === 'build:url').length)).toBe(1)
})
test('tabs and status have complete accessible roles in every view', async ({ page }) => {
  for (const name of ['Timeline', 'Gantt', 'List']) {
    await page.getByRole('tab', { name, exact: true }).click()
    expectAuditClean(await new AxeBuilder({ page }).include('#bd-tools-l').include('#bd-tools').include('#bd-status').analyze())
  }
})

test('real LiveView URL history and server diff retain selected view and focused tab', async ({ page }) => {
  await openFixture(page)
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.goto('/build-fixture/live')
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'); const push = ctx.push
    window.urlCalls = 0; ctx.push = (name, params) => { if (name === 'build:url') urlCalls++; return push(name, params) }
  })
  await page.getByRole('tab', { name: 'Gantt' }).click()
  await expect(page).toHaveURL(/\?view=gantt$/)
  // Toolbar URL writes deliberately replace the current entry (BuildLive.patch_url).
  await page.getByRole('tab', { name: 'Timeline' }).click()
  await expect(page).toHaveURL(/\/build$/)
  await page.evaluate(() => {
    const link = document.createElement('a'); link.href = '/build?view=gantt'; link.textContent = 'History Gantt'
    link.setAttribute('data-phx-link', 'patch'); link.setAttribute('data-phx-link-state', 'push'); document.body.append(link)
  })
  await page.getByRole('link', { name: 'History Gantt' }).click()
  await expect(page.getByRole('tab', { name: 'Gantt' })).toHaveAttribute('aria-selected', 'true')
  await page.goBack()
  await expect(page.getByRole('tab', { name: 'Timeline' })).toHaveAttribute('aria-selected', 'true')
  expect(await page.evaluate(() => urlCalls)).toBe(2)
  await page.getByRole('tab', { name: 'Timeline' }).focus()
  await page.keyboard.press('ArrowRight')
  const generation = await page.locator('#build-root').getAttribute('data-build-generation')
  await page.evaluate(() => window.savedFocus = document.activeElement)
  await page.request.get('/build-control/diff')
  await expect(page.locator('#build-root')).not.toHaveAttribute('data-build-generation', generation)
  expect(await page.evaluate(() => document.activeElement === savedFocus)).toBe(true)
  // The fixture's HTTP diff has an empty set; exercise the chrome redraw path too.
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js')
    const { receive } = await import('/build-home/hook.js')
    receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1,
      now: ctx.snap.now, set: { daemon: ctx.snap.daemon }, upsert: [], remove: [] })
  })
  expect(await page.evaluate(() => document.activeElement === savedFocus)).toBe(true)
})

test('default daemon helper remains unknown before offline module registration', async ({ browser }) => {
  const page = await browser.newPage({ baseURL: test.info().project.use.baseURL })
  try {
    await openFixture(page)
    await page.route('**/tools-default', route => route.fulfill({ contentType: 'text/html', body: '<main id="build-root"><div id="bd-status"></div></main>' }))
    await page.goto('/tools-default')
    await page.evaluate(async () => {
      const { ctx, resetState } = await import('/build-home/state.js')
      const { renderStatus } = await import('/build-home/tools.js')
      resetState(); ctx.root = document.querySelector('#build-root'); renderStatus()
    })
    await expect(page.locator('.bd-daemon')).toHaveText('Daemon status unknown')
    await expect(page.locator('.bd-daemon')).toHaveClass('bd-daemon off')
  } finally { await page.close() }
})
