import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { mountConversation, scenario } from './support/build-conversation.mjs'

test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 }, reducedMotion: 'reduce' })
test.beforeEach(async ({ page }, info) => {
  await mountConversation(page, info)
  await scenario(page, 'kinds', { entries: Array.from({ length: 600 }, (_, i) => ({
    id: 'row:' + i, k: i % 9 === 0 ? 'ev' : 'say', ev: 'progress', label: 'Progress ' + i,
    text: 'Message ' + i, at: null,
  })), reply: { live: true }, ticket: { agent: { state: 'active', name: 'Worker' } } })
  await expect.poll(() => page.locator('#cv-mm > *').count()).toBe(100)
})
const log = page => page.locator('#cv-log')
const distance = page => log(page).evaluate(el => el.scrollHeight - el.scrollTop - el.clientHeight)
async function scrollUp(page, distance) {
  await log(page).evaluate((el, d) => { el.scrollTop = el.scrollHeight - el.clientHeight - d; el.dispatchEvent(new Event('scroll')) }, distance)
}
async function push(page, entries, fields = {}) {
  await page.evaluate(async ({ entries, fields }) => {
    const { fx } = await import('/build-home/state.js'), { MS } = await import('/build-home/modal/frame.js')
    fx.receiveConversation({ v: 1, id: MS.t.id, kind: 'conversation-append', entries, ...fields })
  }, { entries, fields })
}
const entry = id => ({ id, k: 'say', text: 'New live message ' + id, at: null })

test('batch appends pin within 60px; older reading stays still and the pill returns to the bottom', async ({ page }) => {
  await expect(log(page).locator('.in')).toHaveCount(0)
  await scrollUp(page, 59)
  await push(page, [entry('fresh:1'), entry('fresh:2'), entry('fresh:3')])
  await expect(log(page).locator('.in')).toHaveCount(3)
  expect(await distance(page)).toBeLessThanOrEqual(1)
  await expect(page.locator('#cv-new')).toBeHidden()
  await scrollUp(page, 61)
  const before = await log(page).evaluate(el => el.scrollTop)
  await push(page, [entry('fresh:4')])
  expect(await log(page).evaluate(el => el.scrollTop)).toBeCloseTo(before, 0)
  await expect(page.locator('#cv-new')).toBeVisible()
  await page.locator('#cv-new').click()
  await expect.poll(() => distance(page)).toBeLessThanOrEqual(1)
  await expect(page.locator('#cv-new')).toBeHidden()
  await expect.poll(() => page.locator('#cv-mm > *').count()).toBe(104)
})

test('replacement updates content without animation or activity notification', async ({ page }) => {
  await scrollUp(page, 200)
  const before = await log(page).evaluate(el => el.scrollTop)
  await push(page, [entry('row:599')])
  await expect(log(page).locator('[data-eid="row:599"]')).toContainText('New live message')
  await expect(log(page).locator('[data-eid="row:599"]')).not.toHaveClass(/\bin\b/)
  await expect(page.locator('#cv-new')).toBeHidden()
  expect(await log(page).evaluate(el => el.scrollTop)).toBeCloseTo(before, 0)
  await expect(page.locator('#cv-mm > *')).toHaveCount(100)
})

test('map matches design geometry, ignores status rows and supports ticks, hover and cancelled drags', async ({ page }) => {
  const geometry = await page.evaluate(() => {
    const log = document.querySelector('#cv-log'), map = document.querySelector('#cv-map'), mm = document.querySelector('#cv-mm')
    const s = Math.min(.14, map.clientHeight / log.scrollHeight)
    return { actual: parseFloat(mm.style.height), expected: log.scrollHeight * s,
      tick: parseFloat(mm.querySelector('.mm-e').style.top), row: log.querySelector('[data-k=ev]').offsetTop * s }
  })
  expect(geometry.actual).toBeCloseTo(geometry.expected, 1)
  expect(geometry.tick).toBeCloseTo(geometry.row, 1)
  const tick = page.locator('#cv-mm .mm-e').first()
  await tick.hover()
  await expect(page.locator('#cv-tip')).toContainText('Progress 504')
  await expect(page.locator('#cv-tip time')).toHaveText('—')
  await tick.click()
  await expect(log(page).locator('[data-eid="row:504"]')).toHaveClass(/flash/)
  await expect(tick).toHaveAttribute('tabindex', '-1')
  const map = page.locator('#cv-map'), box = await map.boundingBox()
  const emptyY = await map.evaluate(el => {
    const r = el.getBoundingClientRect()
    for (let y = r.top + r.height / 3; y < r.bottom; y++) if (document.elementFromPoint(r.x + r.width / 2, y) === el) return y
    throw new Error('No minimap background point')
  })
  await page.mouse.move(box.x + box.width / 2, emptyY)
  await page.mouse.down()
  await page.mouse.move(box.x + box.width / 2, box.y + box.height * .6)
  const expected = await map.evaluate(el => {
    const log = document.querySelector('#cv-log'), s = Math.min(.14, el.clientHeight / log.scrollHeight)
    return Math.min(log.scrollHeight - log.clientHeight, el.clientHeight * .6 / s - log.clientHeight / 2)
  })
  expect(await log(page).evaluate(el => el.scrollTop)).toBeCloseTo(expected, 0)
  await map.dispatchEvent('pointercancel')
  const stopped = await log(page).evaluate(el => el.scrollTop)
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  expect(await log(page).evaluate(el => el.scrollTop)).toBe(stopped)
  await page.mouse.up()
  await log(page).focus(); await page.keyboard.press('End')
  await expect.poll(() => distance(page)).toBeLessThanOrEqual(1)
  await page.setViewportSize({ width: 390, height: 700 })
  await expect(map).toBeVisible()
  await expect.poll(() => page.locator('#cv-vw').evaluate(el => parseFloat(el.style.height))).toBeGreaterThanOrEqual(8)
})

test('typing responds to real diff, conversation and socket facts, including unknown states', async ({ page }) => {
  // Match the open row with the store so subsequent real diff messages update that exact row.
  const row = await page.evaluate(async () => {
    const { MS } = await import('/build-home/modal/frame.js')
    return MS.t
  })
  const diff = async patch => page.evaluate(async ({ row, patch }) => {
    const { receive } = await import('/build-home/hook.js'), { ctx } = await import('/build-home/state.js')
    receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now,
      upsert: [{ ...row, ...patch }], remove: [], set: {} })
  }, { row, patch })
  await diff({ agent: { ...row.agent, state: 'active', name: '<Worker>' } })
  await expect(page.locator('#cv-typing')).toBeVisible()
  await expect(page.locator('#cv-typing')).toHaveText('<Worker> is working')
  await push(page, [], { kind: 'conversation-state', state: 'known_empty', live: true })
  await expect(page.locator('#cv-typing')).toBeVisible()
  for (const state of ['paused', 'command', 'error', null]) {
    await diff({ agent: { ...row.agent, state } })
    await expect(page.locator('#cv-typing')).toBeHidden()
  }
  await diff({ agent: { ...row.agent, state: 'active', name: null } })
  await expect(page.locator('#cv-typing')).toHaveText('Agent is working')
  await expect(page.locator('#cv-typing')).toBeVisible()
  for (const state of ['ended', 'stale', 'unavailable', 'restart_unknown']) {
    await push(page, [], { kind: 'conversation-state', state, live: false })
    await expect(page.locator('#cv-typing')).toBeHidden()
  }
  await push(page, [], { kind: 'conversation-state', state: 'live', live: true })
  await expect(page.locator('#cv-typing')).toBeVisible()
  await page.evaluate(async () => {
    const { receive } = await import('/build-home/hook.js'), { ctx } = await import('/build-home/state.js')
    receive({ v: 1, kind: 'diff', epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now, upsert: [], remove: [], set: { daemon: { ...ctx.snap.daemon, state: 'offline' } } })
  })
  await expect(page.locator('#cv-typing')).toBeHidden()
  await page.evaluate(() => window.liveSocket.disconnect())
  await expect(page.locator('#cv-typing')).toBeHidden()
})

test('top trimming preserves the visible anchor; bottom trimming fetches the tail and reset rewires', async ({ page }) => {
  // Load five pages without reaching the cap yet.
  for (let i = 0; i < 4; i++) {
    await log(page).evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')) })
    await expect(log(page).locator('[data-k]')).toHaveCount((i + 2) * 100)
  }
  await log(page).evaluate(el => { el.style.overflowAnchor = 'none' })
  await scrollUp(page, 200)
  const anchor = await log(page).evaluate(el => {
    const row = [...el.children].find(row => row.offsetTop + row.offsetHeight > el.scrollTop)
    return { id: row.dataset.eid, offset: row.offsetTop - el.scrollTop }
  })
  await push(page, Array.from({ length: 10 }, (_, i) => entry('cap:' + i)))
  await expect(log(page).locator('[data-k]')).toHaveCount(500)
  expect(await log(page).evaluate((el, id) => [...el.children].find(row => row.dataset.eid === id).offsetTop - el.scrollTop, anchor.id)).toBeCloseTo(anchor.offset, 0)
  await log(page).evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')) })
  await expect(log(page).locator('[data-eid="row:10"]')).toHaveCount(1)
  await log(page).evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')) })
  await expect(log(page).locator('[data-eid="row:0"]')).toHaveCount(1)
  await push(page, [entry('dropped')])
  await expect(log(page).locator('[data-eid=dropped]')).toHaveCount(0)
  await expect(page.locator('#cv-new')).toBeVisible()
  const calls = await page.evaluate(() => window.conversationCalls.filter(c => c.event === 'conversation-page' && c.payload.before === null).length)
  await page.locator('#cv-new').click()
  await expect.poll(() => page.evaluate(() => window.conversationCalls.filter(c => c.event === 'conversation-page' && c.payload.before === null).length)).toBe(calls + 1)
  await expect(log(page).locator('[data-k]')).toHaveCount(100)
  await expect(page.locator('#cv-mm > *')).toHaveCount(100)
  await scrollUp(page, 200); await push(page, [entry('after-reset')])
  await expect(page.locator('#cv-new')).toBeVisible()
  await page.locator('#bd-tk-close').click()
  await expect(page.locator('#cv-map')).toHaveCount(0)
})

test('pending older page keeps event tick indices current and status rows out of the map', async ({ page }) => {
  await scenario(page, 'kinds', { hold: 1, entries: Array.from({ length: 200 }, (_, i) => ({
    id: 'held:' + i, k: i % 3 ? 'say' : 'ev', ev: 'progress', label: '<b>x</b>&', text: 'Message ' + i, at: null,
  })) })
  await expect(page.locator('#cv-mm > *')).toHaveCount(100)
  await log(page).evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')) })
  await expect(log(page).locator(':scope > :first-child')).toHaveText('Loading earlier…')
  await expect.poll(() => page.locator('#cv-mm .mm-e').first().getAttribute('data-i')).toBe('3')
  await expect(page.locator('#cv-mm > *')).toHaveCount(100)
  await expect(page.locator('#cv-mm .k-undefined')).toHaveCount(0)
  const tick = page.locator('#cv-mm .mm-e').first()
  await tick.hover()
  await expect(page.locator('#cv-tip')).toHaveText('<b>x</b>&—')
  await expect(page.locator('#cv-tip b')).toHaveCount(0)
  await log(page).locator('[data-k=ev]').first().evaluate(el => { el.dataset.at = '' })
  await page.locator('#cv-map').dispatchEvent('pointermove', { clientY: 0 })
  await tick.hover()
  await expect(page.locator('#cv-tip time')).toHaveText('—')
  await tick.click()
  await expect(log(page).locator('[data-eid="held:102"]')).toHaveClass(/flash/)
  await page.evaluate(() => window.releaseOlder())
  await expect(log(page).locator('[data-k]')).toHaveCount(200)
})
