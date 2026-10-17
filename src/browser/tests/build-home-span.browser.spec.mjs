import { test, expect } from '@playwright/test'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

const spans = [1, 2, 3, 5, 7, 10, 14, 21, 30]
test.beforeEach(async ({ page }) => {
  page.on('pageerror', error => { throw error })
  await openFixture(page)
  await page.evaluate(async () => {
    window.m = await import('/build-home/state.js')
    window.span = await import('/build-home/span.js')
    const { createBuildHomeHook } = await import('/build-home/hook.js')
    document.body.innerHTML = '<main id="build-root" class="bd-root">' + ['bd-usage', 'bd-offline', 'bd-fh', 'bd-tools-l', 'bd-filters', 'bd-tools', 'bd-vp', 'bd-sb', 'bd-tree', 'bd-status'].map(id => `<div id="${id}">${id === 'bd-sb' ? '<i></i>' : ''}</div>`).join('') + '</main>'
    window.events = {}; window.calls = []; window.hook = createBuildHomeHook()
    Object.assign(hook, { el: document.querySelector('#build-root'), handleEvent: (name, fn) => events[name] = fn,
      pushEvent: (name, params) => { if (name === 'build-resync') return new Promise(() => {}); calls.push([name, params]); return Promise.resolve() } })
    hook.mounted()
    const render = m.fx.renderTools
    m.fx.renderTools = () => { calls.push(['tools']); render() }
    for (const name of ['relayout', 'jumpNow', 'viewport', 'update']) m.fx[name] = (...args) => calls.push([name, ...args])
  })
})
test('calNear matches the logarithmic design table', async ({ page }) => {
  expect(await page.evaluate(spans => spans.map(value => { m.S.span = value; return span.calNear() }), spans)).toEqual([1, 1, 7, 7, 7, 7, 7, 30, 30])
})
test('zoom label, title and pressed state follow every span', async ({ page }) => {
  for (const [i, value] of spans.entries()) {
    await page.evaluate(value => { m.S.span = value; m.fx.renderTools() }, value)
    await expect(page.locator('.bd-zv')).toHaveText(['100%', '50%', '33%', '20%', '14%', '10%', '7%', '5%', '3%'][i])
    await expect(page.locator('.bd-zv')).toHaveAttribute('title', `${value} day${value === 1 ? '' : 's'} in view`)
    const selected = [1, 1, 7, 7, 7, 7, 7, 30, 30][i]
    for (const n of [1, 7, 30]) await expect(page.locator(`[data-span="${n}"]`)).toHaveAttribute('aria-pressed', String(n === selected))
    await expect(page.getByRole('group', { name: 'Range', exact: true })).toHaveCount(1)
    await expect(page.getByRole('group', { name: 'Zoom', exact: true })).toHaveCount(1)
  }
})
test('zoom steps through SPANS and stops at both ends', async ({ page }) => {
  await expect(page.locator('[data-z="-1"]')).toBeDisabled()
  for (const value of spans.slice(1)) {
    await page.locator('[data-z="1"]').click()
    expect(await page.evaluate(() => m.S.span)).toBe(value)
  }
  await expect(page.locator('[data-z="1"]')).toBeDisabled()
  await page.locator('[data-z="1"]').evaluate(el => el.click())
  expect(await page.evaluate(() => calls.filter(c => c[0] === 'build:url').map(c => c[1].span))).toEqual(spans.slice(1).map(String))
  for (const value of [...spans].reverse().slice(1)) {
    await page.locator('[data-z="-1"]').click()
    expect(await page.evaluate(() => m.S.span)).toBe(value)
  }
  await expect(page.locator('[data-z="-1"]')).toBeDisabled()
})
test('range sets exact span and repeat values do nothing', async ({ page }) => {
  await page.evaluate(() => { span.setSpan(10); m.S.loading = false; calls.length = 0 })
  await expect(page.locator('[data-span="7"]')).toHaveAttribute('aria-pressed', 'true')
  await page.locator('[data-span="7"]').click()
  expect(await page.evaluate(() => ({ value: m.S.span, calls }))).toEqual({ value: 7, calls: [['build:url', { span: '7' }], ['tools'], ['relayout'], ['jumpNow', true]] })
  await page.evaluate(() => calls.length = 0)
  await page.locator('[data-span="7"]').click()
  expect(await page.evaluate(() => calls)).toEqual([])
})
test('span change calls URL, tools, relayout and jump in order', async ({ page }) => {
  await page.evaluate(() => { m.S.loading = false; span.setSpan(7) })
  expect(await page.evaluate(() => calls)).toEqual([['build:url', { span: '7' }], ['tools'], ['relayout'], ['jumpNow', true]])
})
test('list hides controls and keeps span for the next timeline', async ({ page }) => {
  expect(await page.evaluate(() => { m.S.view = 'list'; return span.spanToolsHTML() })).toBe('')
  await page.evaluate(() => events['build:url']({ state: { view: 'list', span: 7 } }))
  await expect(page.locator('.bd-cal, .bd-zoom')).toHaveCount(0)
  await page.getByRole('tab', { name: 'Timeline', exact: true }).click()
  await expect(page.locator('[data-span="7"]')).toHaveClass('on')
  await expect(page.locator('.bd-zv')).toHaveText('14%')
})
test('only numeric SPANS values are accepted', async ({ page }) => {
  expect(await page.evaluate(() => {
    const html = document.querySelector('#bd-tools').innerHTML
    for (const value of [4, '7', NaN]) span.setSpan(value)
    return { value: m.S.span, calls, same: html === document.querySelector('#bd-tools').innerHTML }
  })).toEqual({ value: 1, calls: [], same: true })
})
test('loading span changes only update URL and toolbar', async ({ page }) => {
  await page.locator('[data-span="7"]').click()
  expect(await page.evaluate(() => ({ value: m.S.span, calls }))).toEqual({ value: 7, calls: [['build:url', { span: '7' }], ['tools']] })
})
test('keyboard focus survives re-render and disabled ends', async ({ page }) => {
  await page.locator('[data-z="1"]').focus()
  for (let i = 0; i < 8; i++) {
    await page.keyboard.press('Enter')
    await expect(page.locator(`[data-z="${i === 7 ? '-1' : '1'}"]`)).toBeFocused()
  }
  for (let i = 0; i < 8; i++) {
    await page.keyboard.press('Space')
    await expect(page.locator(`[data-z="${i === 7 ? '1' : '-1'}"]`)).toBeFocused()
  }
  await page.locator('[data-span="7"]').focus(); await page.keyboard.press('Enter')
  await expect(page.locator('[data-span="7"]')).toBeFocused()
})
test('change is announced in one persistent live region', async ({ page }) => {
  await page.locator('[data-z="1"]').click()
  await expect(page.locator('#bd-range-live')).toHaveText('2 days in view, zoom 50%')
  await expect(page.locator('#bd-range-live')).toHaveAttribute('aria-live', 'polite')
  await expect(page.locator('#bd-range-live')).toHaveAttribute('aria-atomic', 'true')
  await page.evaluate(() => window.region = document.querySelector('#bd-range-live'))
  await page.locator('[data-z="1"]').click()
  await expect(page.locator('#bd-range-live')).toHaveText('3 days in view, zoom 33%')
  expect(await page.evaluate(() => region === document.querySelector('#bd-range-live') && region.parentElement === m.ctx.root)).toBe(true)
})
test('delegation wires once, disposes and reattaches on the same host', async ({ page }) => {
  await page.evaluate(() => {
    window.bindings = 0; const on = m.ctx.life.on
    m.ctx.life.on = (...args) => { bindings++; return on(...args) }
    for (let i = 0; i < 10; i++) span.wireSpanTools(document.querySelector('#bd-tools'))
  })
  expect(await page.evaluate(() => bindings)).toBe(0)
  await page.locator('[data-span="7"] svg path').dispatchEvent('click')
  expect(await page.evaluate(() => calls.filter(c => c[0] === 'build:url').length)).toBe(1)
  await page.evaluate(() => { hook.destroyed(); calls.length = 0 })
  await page.locator('[data-span="30"]').click()
  expect(await page.evaluate(() => calls)).toEqual([])
  await page.evaluate(() => hook.mounted())
  await page.locator('[data-span="30"]').click()
  expect(await page.evaluate(() => calls.filter(c => c[0] === 'build:url').map(c => c[1].span))).toEqual(['30'])
})
async function realBoard(page, dataset = 'live') {
  await page.context().setHTTPCredentials(dashboardCredentials)
  await page.goto('/build-fixture/' + dataset)
  if (dataset !== 'unavailable') await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/)
}
test('dot grid follows relayout and server URLs without echo', async ({ page }) => {
  await realBoard(page)
  await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), push = ctx.push
    window.echoes = 0
    ctx.push = (...args) => { if (args[0] === 'build:url') echoes++; return push(...args) }
  })
  for (const view of ['graph']) for (const [i, value] of [1, 2, 3, 5, 30].entries()) {
    await page.evaluate(({ view, value }) => window.liveSocket.main.pushLinkPatch(new Event('click'), `/build?view=${view}&span=${value}`, null), { view, value })
    await expect(page.locator('.bd-zv')).toHaveText(`${Math.round(100 / value)}%`)
    const result = await page.evaluate(async () => {
      const { ctx, S } = await import('/build-home/state.js')
      ctx.vp.getAnimations().forEach(a => a.finish())
      return { value: S.span, echoes, dot: ctx.vp.style.getPropertyValue('--dot'), size: getComputedStyle(ctx.vp).backgroundSize }
    })
    expect(result).toEqual({ value, echoes: 0, dot: ['30.0px', '19.9px', '14.0px', '14.0px', '14.0px'][i], size: ['30px 30px', '19.9px 19.9px', '14px 14px', '14px 14px', '14px 14px'][i] })
  }
})
test('unavailable board keeps its copy after a span click', async ({ page }) => {
  await realBoard(page, 'unavailable')
  await expect(page.locator('.bd-loading')).toContainText('Build timeline unavailable')
  const result = await page.evaluate(async () => {
    const { fx } = await import('/build-home/state.js'), layout = fx.relayout
    let layouts = 0
    fx.relayout = (...args) => { layouts++; return layout(...args) }
    const before = document.querySelector('.bd-loading').textContent
    document.querySelector('[data-span="7"]').click()
    return { before, after: document.querySelector('.bd-loading').textContent, layouts }
  })
  expect(result.after).toBe(result.before); expect(result.layouts).toBe(0)
  await expect(page).toHaveURL(/span=7/)
  await expect(page.locator('.bd-loading')).toContainText('Build timeline unavailable')
  await expect(page.locator('.bd-spin, #bd-content')).toHaveCount(0)
  await expect(page.locator('[data-span="7"]')).toHaveClass('on')
})
test('offline data remains zoomable and writes only the view URL', async ({ page }) => {
  await realBoard(page, 'offline')
  await page.evaluate(async () => {
    const { ctx, fx } = await import('/build-home/state.js'), push = ctx.push, layout = fx.relayout
    window.actualCalls = []
    ctx.push = (...args) => { actualCalls.push(args); return push(...args) }
    fx.relayout = (...args) => { actualCalls.push(['relayout']); return layout(...args) }
    fx.jumpNow = (...args) => actualCalls.push(['jumpNow', ...args])
  })
  await page.locator('[data-span="7"]').click()
  await expect(page).toHaveURL(/span=7/)
  expect(await page.evaluate(() => actualCalls.slice(actualCalls.findIndex(c => c[0] === 'build:url'), actualCalls.findIndex(c => c[0] === 'build:url') + 3))).toEqual([['build:url', { span: '7' }], ['relayout'], ['jumpNow', true]])
  expect(await page.evaluate(() => actualCalls.filter(c => !['relayout', 'jumpNow', 'load-earlier'].includes(c[0])))).toEqual([['build:url', { span: '7' }]])
  await expect(page.locator('#bd-vp')).toHaveAttribute('style', /--dot: 14.0px/)
})
