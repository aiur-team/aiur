import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { dashboardCredentials } from './support/layout-worker.mjs'

// Event rows are the operator's record of what happened to a ticket: each kind
// must look exactly like the design's row, and an unknown time or percent must
// stay visibly unknown instead of turning into a real-looking value.
const EVK = { dep: [190, 'link'], commit: [255, 'commit'], prog: [null, 'prog'], pr: [300, 'pr'], review: [85, 'review'], comment: [220, 'chat'], merge: [150, 'merge'], fail: [25, 'warn'], cmd: [25, 'warn'], you: [0, 'pause'] }
const AT = 1791407600000
test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 }, timezoneId: 'America/Los_Angeles' })
test.beforeEach(async ({ page }, info) => {
  const errors = []; page.on('pageerror', error => errors.push(error)); info.errors = errors
  const root = info.project.metadata.agentAssets
  if (root) await page.route('**/build-home/**/*.js', async route => {
    const relative = new URL(route.request().url()).pathname.replace('/build-home/', '')
    try { await route.fulfill({ body: await readFile(root + '/' + relative, 'utf8'), contentType: 'text/javascript' }) }
    catch { await route.continue() }
  })
  await page.goto('/build-fixture/live')
  await expect.poll(() => page.evaluate(async () => !!(await import('/build-home/state.js')).ctx.D?.now.length)).toBe(true)
})
test.afterEach(async ({}, info) => { expect(info.errors).toEqual([]) })

async function show(page, entries) {
  await page.evaluate(async entries => {
    const { ctx } = await import('/build-home/state.js'), { openModal } = await import('/build-home/modal/frame.js')
    const original = ctx.push
    ctx.push = async (event, payload) => event !== 'conversation-page' ? original(event, payload)
      : { v: 1, kind: 'conversation', id: payload.id, reset: false, state: 'ended', reason: null, live: false, observed_at: null, entries, before: null, more: false, note: null, evicted: 0 }
    openModal(ctx.D.hist.find(t => t.agent && t.start != null))
  }, entries)
  await expect(page.locator('#cv-log [data-k]')).toHaveCount(entries.length)
}
const row = (ev, extra = {}) => ({ id: 'ev:' + ev, k: 'ev', ev, label: ev + ' label', at: AT, ...(ev === 'prog' ? { pct: 50 } : {}), ...extra })

test('B1 every kind renders the design row: class, hue, icon and data attributes', async ({ page }) => {
  await show(page, Object.keys(EVK).map(ev => row(ev, ev === 'dep' ? { go: '597', sub: 'Dependency title' } : {})))
  for (const [ev, [hue, icon]] of Object.entries(EVK)) {
    const el = page.locator('#cv-log [data-ev=' + ev + ']')
    const got = await el.evaluate(async (el, icon) => {
      const { I, MI } = await import('/build-home/icons.js'), probe = document.createElement('span'); probe.innerHTML = I[icon] || MI[icon]
      const svg = el.querySelector('.cv-evi svg').cloneNode(true); svg.removeAttribute('aria-hidden')
      return { cls: el.className, eh: el.style.getPropertyValue('--eh'), icon: svg.outerHTML === probe.innerHTML, k: el.dataset.k, label: el.dataset.label, at: el.dataset.at, go: !!el.querySelector('.cv-go') }
    }, icon)
    expect(got.cls, ev).toBe('cv-ev' + (['fail', 'cmd'].includes(ev) ? ' bad' : ev === 'you' ? ' mute' : ''))
    expect(got.eh, ev).toBe(String(ev === 'prog' ? 94 : hue))
    expect(got.icon, ev).toBe(true)
    expect(await el.locator('.cv-evi svg').getAttribute('aria-hidden')).toBe('true')
    expect(got, ev).toMatchObject({ k: 'ev', label: ev + ' label', at: '14:13', go: ev === 'dep' })
  }
  await expect(page.locator('.cv-go')).toHaveAttribute('aria-label', 'Open #597 Dependency title')
  await expect(page.locator('.cv-go')).toHaveText('Open')
})

test('B2 an unknown time is a dash, never a clock reading', async ({ page }) => {
  await show(page, [row('pr', { at: null })])
  const time = page.locator('.cv-ev time')
  await expect(time).toHaveText('—'); await expect(time).toHaveAttribute('title', 'Time unknown')
  expect(await time.getAttribute('datetime')).toBeNull()
  await expect(page.locator('.cv-ev')).toHaveAttribute('data-at', '—')
})

test('B3 an unknown percent is muted, never the 0% hue', async ({ page }) => {
  await show(page, [{ id: 'ev:log:1', k: 'ev', ev: 'prog', label: 'Progress updated', at: AT }])
  const el = page.locator('.cv-ev')
  await expect(el).toHaveClass('cv-ev mute')
  expect(await el.evaluate(el => el.style.getPropertyValue('--eh'))).toBe('')
  await expect(el.locator('b')).toHaveText('Progress updated')
})

test('B4 Open on a dependency row navigates to the dependency', async ({ page }) => {
  const dep = await page.evaluate(async () => { const { ctx } = await import('/build-home/state.js'); const t = ctx.D.hist.find(t => t.agent && t.start != null && t.deps.length); return { id: t.deps[0] } })
  await show(page, [row('dep', { go: dep.id, label: 'Dependency #' + dep.id + ' merged' })])
  await page.locator('.cv-go').click()
  await expect(page).toHaveURL(new RegExp('[?&]ticket=' + dep.id + '(&|$)'))
  await expect(page.locator('#tk-head')).toContainText('#' + dep.id)
})

test('B5 hostile label and sub stay text', async ({ page }) => {
  const hostile = '<img src=x onerror="window.__pwned=1"><script>window.__pwned=1</script>'
  await show(page, [row('pr', { label: hostile, sub: hostile, go: '"><img src=x onerror="window.__pwned=1">' })])
  await expect(page.locator('.cv-ev b')).toHaveText(hostile)
  await expect(page.locator('#cv-log img, #cv-log script')).toHaveCount(0)
  expect(await page.evaluate(() => window.__pwned)).toBeUndefined()
})

test('B6 times are local, across the DST change', async ({ page }) => {
  await show(page, [row('pr', { id: 'a' }), row('pr', { id: 'b', at: Date.parse('2026-11-01T08:30:00Z') }), row('pr', { id: 'c', at: Date.parse('2026-11-01T09:30:00Z') })])
  const times = page.locator('.cv-ev time')
  await expect(times).toHaveText(['14:13', '01:30', '01:30'])
  expect(await times.nth(1).getAttribute('datetime')).not.toBe(await times.nth(2).getAttribute('datetime'))
})

test('B7 a merge row with no sub shows its local date and time', async ({ page }) => {
  await show(page, [row('merge', { id: 'm1', label: 'Merged PR #8' }), row('merge', { id: 'm2', label: 'Merged PR #9', at: null })])
  await expect(page.locator('[data-eid=m1] .cv-evs')).toHaveText('Oct 7 14:13')
  await expect(page.locator('[data-eid=m2] .cv-evs')).toHaveCount(0)
})

test.describe('UTC', () => {
  test.use({ timezoneId: 'UTC' })
  test('B6 the same instant reads in the viewer zone', async ({ page }) => {
    await show(page, [row('pr')])
    await expect(page.locator('.cv-ev time')).toHaveText('21:13')
  })
})
