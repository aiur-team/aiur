import { test, expect } from '@playwright/test'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { mountConversation, scenario } from './support/build-conversation.mjs'

test.use({ httpCredentials: dashboardCredentials, viewport: { width: 1440, height: 900 }, reducedMotion: 'reduce' })
test.beforeEach(async ({ page }, info) => {
  await page.addInitScript(() => {
    const audit = window.liveAudit = { listeners: [], observers: [], frames: new Set() }
    const tracked = el => el instanceof Element && /^cv-(log|map|new)$/.test(el.id)
    const add = EventTarget.prototype.addEventListener, remove = EventTarget.prototype.removeEventListener
    EventTarget.prototype.addEventListener = function (type, listener, options) {
      if (!tracked(this) || !listener) return add.call(this, type, listener, options)
      const record = { target: this, type, listener, capture: !!(typeof options === 'boolean' ? options : options?.capture), active: true, calls: 0 }
      record.wrapper = function (event) { record.calls++; return typeof listener === 'function' ? listener.call(this, event) : listener.handleEvent(event) }
      audit.listeners.push(record); return add.call(this, type, record.wrapper, options)
    }
    EventTarget.prototype.removeEventListener = function (type, listener, options) {
      const capture = !!(typeof options === 'boolean' ? options : options?.capture)
      const record = audit.listeners.find(r => r.active && r.target === this && r.type === type && r.listener === listener && r.capture === capture)
      if (record) { record.active = false; return remove.call(this, type, record.wrapper, options) }
      return remove.call(this, type, listener, options)
    }
    const NativeObserver = ResizeObserver
    window.ResizeObserver = class extends NativeObserver {
      constructor(callback) {
        super((entries, observer) => { observer.deliveries++; callback(entries, observer) })
        this.targets = new Set(); this.deliveries = 0; audit.observers.push(this)
      }
      observe(target, options) { this.targets.add(target); super.observe(target, options) }
      unobserve(target) { this.targets.delete(target); super.unobserve(target) }
      disconnect() { this.targets.clear(); super.disconnect() }
    }
    const frame = requestAnimationFrame, cancel = cancelAnimationFrame
    window.requestAnimationFrame = callback => {
      const id = frame(time => { audit.frames.delete(id); callback(time) }); audit.frames.add(id); return id
    }
    window.cancelAnimationFrame = id => { audit.frames.delete(id); return cancel(id) }
  })
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
async function mapGeometry(page) {
  return page.evaluate(() => {
    const log = document.querySelector('#cv-log'), map = document.querySelector('#cv-map'), mm = document.querySelector('#cv-mm'), vw = document.querySelector('#cv-vw')
    const s = Math.min(.14, map.clientHeight / Math.max(1, log.scrollHeight)), close = (a, b) => Math.abs(a - b) <= .15
    const rows = [...log.children], items = [...mm.children]
    return {
      count: items.length === rows.filter(el => el.dataset.k).length,
      height: close(parseFloat(mm.style.height), log.scrollHeight * s),
      blocks: items.filter(el => el.classList.contains('mm-b')).every(block => {
        const index = items.indexOf(block), row = rows.filter(el => el.dataset.k)[index]
        return close(parseFloat(block.style.top), row.offsetTop * s) && close(parseFloat(block.style.height), Math.max(1.5, row.offsetHeight * s - 1.5))
      }),
      ticks: items.filter(el => el.classList.contains('mm-e')).every(tick => close(parseFloat(tick.style.top), rows[+tick.dataset.i].offsetTop * s)),
      viewport: close(parseFloat(vw.style.top), log.scrollTop * s) && close(parseFloat(vw.style.height), Math.max(8, log.clientHeight * s)),
    }
  })
}

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

test('L16/L18: map geometry survives resize; ticks jump to their row and cancelled drags stop', async ({ page }) => {
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
  const plainRow = page.locator('#cv-mm .mm-b.k-say').first()
  const plainRowBox = await plainRow.boundingBox()
  await page.mouse.move(plainRowBox.x + plainRowBox.width / 2, plainRowBox.y + plainRowBox.height / 2)
  await expect(page.locator('#cv-tip')).toContainText('say message')
  await expect(page.locator('#cv-tip time')).not.toBeEmpty()
  await tick.click()
  await expect(log(page).locator('[data-eid="row:504"]')).toHaveClass(/flash/)
  await expect.poll(() => log(page).evaluate(el => el.scrollTop - Math.max(0, el.querySelector('[data-eid="row:504"]').offsetTop - 16))).toBeCloseTo(0, 0)
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
  await expect.poll(() => mapGeometry(page)).toEqual({ count: true, height: true, blocks: true, ticks: true, viewport: true })
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


test('L9: reset removes retired listeners and observers; one scroll synchronizes the new viewport once', async ({ page }) => {
  await page.evaluate(async () => {
    window.retired = [...document.querySelectorAll('#cv-log, #cv-map, #cv-new')]
    const { fx } = await import('/build-home/state.js'), { MS } = await import('/build-home/modal/frame.js')
    fx.receiveConversation({ v: 1, kind: 'conversation', id: MS.t.id, reset: true, state: 'live', live: true, more: false, before: null,
      entries: Array.from({ length: 60 }, (_, i) => ({ id: 'reset:' + i, k: 'say', text: 'Reset message ' + i, at: null })) })
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
  })
  await expect(page.getByRole('region', { name: 'Conversation', exact: true })).toHaveAttribute('tabindex', '0')
  expect(await page.evaluate(() => {
    const audit = window.liveAudit, retired = new Set(window.retired)
    return { listeners: audit.listeners.filter(r => r.active && retired.has(r.target)).length,
      observers: audit.observers.flatMap(o => [...o.targets]).filter(el => retired.has(el)).length }
  })).toEqual({ listeners: 0, observers: 0 })
  expect(await page.evaluate(() => {
    const vw = document.querySelector('#cv-vw'), realStyle = vw.style
    realStyle.top = '-1px'; window.viewportTopWrites = 0
    Object.defineProperty(vw, 'style', { configurable: true, value: new Proxy(realStyle, {
      get: (target, key) => Reflect.get(target, key, target),
      set: (target, key, value) => { if (key === 'top') window.viewportTopWrites++; return Reflect.set(target, key, value, target) },
    }) })
    window.retired.find(el => el.id === 'cv-log').dispatchEvent(new Event('scroll'))
    return { top: vw.style.top, writes: window.viewportTopWrites }
  })).toEqual({ top: '-1px', writes: 0 })
  expect(await log(page).evaluate(el => {
    const callbacks = window.liveAudit.listeners.filter(r => r.target === el && r.type === 'scroll' && r.active)
    callbacks.forEach(r => { r.calls = 0 }); window.viewportTopWrites = 0; el.dispatchEvent(new Event('scroll'))
    const s = Math.min(.14, document.querySelector('#cv-map').clientHeight / el.scrollHeight)
    return { calls: callbacks.map(r => r.calls), writes: window.viewportTopWrites, viewport: Math.abs(parseFloat(document.querySelector('#cv-vw').style.top) - el.scrollTop * s) < .1 }
  })).toEqual({ calls: [1, 1], writes: 1, viewport: true }) // Paging listener and viewport listener each execute once.
})

test('L23: three reopens retain one live registration set and one map rebuild for one appended child', async ({ page }) => {
  const ticket = await page.evaluate(async () => (await import('/build-home/modal/frame.js')).MS.t)
  for (let i = 0; i < 3; i++) {
    await page.locator('#bd-tk-close').click()
    await expect(page).toHaveURL(/\/build$/)
    expect(await page.evaluate(() => ({
      listeners: window.liveAudit.listeners.filter(r => r.active && !r.target.isConnected).length,
      observers: window.liveAudit.observers.flatMap(o => [...o.targets]).filter(el => /^cv-/.test(el.id) && !el.isConnected).length,
    }))).toEqual({ listeners: 0, observers: 0 })
    await page.evaluate(async t => (await import('/build-home/modal/frame.js')).openModal(t), ticket)
    await expect(log(page).locator('[data-k]')).toHaveCount(100)
    await expect(page).toHaveURL(new RegExp('ticket=' + ticket.id + '$'))
  }
  await expect(page.locator('#tk-head .bm-agent')).toHaveAttribute('data-control', 'ready')
  // An initial ResizeObserver delivery can follow the URL acknowledgement and two frames.
  // Wait for both real subscriptions before counting rebuilds caused by the append.
  await expect.poll(() => page.evaluate(() => ['cv-log', 'cv-map'].every(id =>
    window.liveAudit.observers.some(observer => observer.targets.has(document.getElementById(id)) && observer.deliveries > 0)
  ))).toBe(true)
  await page.evaluate(async () => {
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
    window.mapBuilds = 0
    const mm = document.querySelector('#cv-mm')
    window.mapWatch = new MutationObserver(records => { window.mapBuilds += records.filter(r => r.type === 'childList' && r.target === mm).length })
    window.mapWatch.observe(mm, { childList: true })
  })
  await push(page, [entry('reopened')])
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  await expect(log(page).locator('[data-k]')).toHaveCount(101)
  await expect(log(page).locator('[data-eid=reopened]')).toHaveCount(1)
  expect(await page.evaluate(() => window.mapBuilds)).toBe(1)
})

test('L7: close cancels the pending map frame and late server/local appends leave the conversation closed', async ({ page }) => {
  expect(await page.evaluate(async () => {
    const { fx } = await import('/build-home/state.js'), { MS, closeModal } = await import('/build-home/modal/frame.js')
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
    const before = new Set(window.liveAudit.frames), id = MS.t.id, oldLog = document.querySelector('#cv-log')
    fx.appendItem({ id: 'before-close', k: 'say', text: 'Pending map frame', at: null })
    const addedFrames = [...window.liveAudit.frames].filter(id => !before.has(id))
    closeModal()
    const cancelled = addedFrames.every(id => !window.liveAudit.frames.has(id))
    fx.receiveConversation({ v: 1, id, kind: 'conversation-append', entries: [{ id: 'late-server', k: 'say', text: 'Late server row', at: null }] })
    const local = fx.appendItem({ id: 'late-local', k: 'op', text: 'Late accepted row', at: null })
    return { scheduled: addedFrames.length, cancelled, local, lateRows: oldLog.querySelectorAll('[data-eid^=late-]').length }
  })).toEqual({ scheduled: 1, cancelled: true, local: [], lateRows: 0 })
  await expect(page.locator('#cv-log')).toHaveCount(0)
})

for (const reducedMotion of ['reduce', 'no-preference']) {
  test('L21: pill and tick use ' + (reducedMotion === 'reduce' ? 'same-frame auto' : 'scrollend smooth') + ' scrolling', async ({ page }) => {
    await page.emulateMedia({ reducedMotion })
    await scrollUp(page, 300); await push(page, [entry('motion')])
    await page.evaluate(() => {
      const log = document.querySelector('#cv-log'), scrollTo = log.scrollTo.bind(log)
      window.scrollCalls = []; window.scrollEnds = 0
      log.addEventListener('scrollend', () => window.scrollEnds++)
      log.scrollTo = options => {
        const before = log.scrollTop; scrollTo(options)
        window.scrollCalls.push({ ...options, before, immediate: log.scrollTop })
      }
    })
    await page.locator('#cv-new').click()
    await expect.poll(() => distance(page)).toBeLessThanOrEqual(1)
    await expect(page.locator('#cv-new')).toBeHidden()
    const pill = await page.evaluate(() => window.scrollCalls[0])
    expect(pill.behavior).toBe(reducedMotion === 'reduce' ? 'auto' : 'smooth')
    if (reducedMotion === 'reduce') expect(pill.immediate).toBeCloseTo(await log(page).evaluate(el => el.scrollHeight - el.clientHeight), 0)
    else { expect(pill.immediate).toBe(pill.before); await expect.poll(() => page.evaluate(() => window.scrollEnds)).toBeGreaterThan(0) }
    const ended = await page.evaluate(() => window.scrollEnds)
    await page.locator('#cv-mm .mm-e').first().click()
    await expect.poll(() => log(page).evaluate(el => el.scrollTop - Math.max(0, el.querySelector('[data-eid="row:504"]').offsetTop - 16))).toBeCloseTo(0, 0)
    const tick = await page.evaluate(() => window.scrollCalls[1])
    expect(tick.behavior).toBe(reducedMotion === 'reduce' ? 'auto' : 'smooth')
    if (reducedMotion === 'reduce') expect(tick.immediate).toBeCloseTo(tick.top, 0)
    else { expect(tick.immediate).toBe(tick.before); await expect.poll(() => page.evaluate(() => window.scrollEnds)).toBeGreaterThan(ended) }
  })
}
