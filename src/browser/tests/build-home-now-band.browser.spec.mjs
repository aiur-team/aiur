import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import AxeBuilder from '@axe-core/playwright'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles' })
test.beforeEach(async ({ page }, info) => {
  const root = info.project.metadata.bandAssetRoot
  if (root) await page.route('**/build-home/*.js', async route => {
    const file = new URL(route.request().url()).pathname.split('/').at(-1)
    await route.fulfill({ contentType: 'text/javascript', body: await readFile(root + '/' + file, 'utf8') })
  })
})
async function open(page, dataset = 'live', query = '') {
  page.on('pageerror', error => { throw error })
  await page.goto('/build-fixture/' + dataset + query)
  await expect(page.locator('#build-root')).toHaveAttribute('data-build-generation', /\d+/, { timeout: 10000 })
  await expect(page.locator('.bd-now-h > b')).toHaveText('Live')
  await page.evaluate(async () => { window.m = await import('/build-home/state.js'); window.band = await import('/build-home/band.js') })
}
async function settle(page) { for (let i = 0; i < 64; i++) await page.clock.runFor(16) }

test('header, permanent noanim cards, minimize URL and preset toggles are wired', async ({ page }) => {
  await open(page)
  await expect(page.locator('.bd-now-st')).toHaveText('3 running3 stuck2 paused')
  await expect(page.locator('#bd-now .bd-card.noanim')).toHaveCount(8)
  await expect(page.locator('.bd-now-eta')).toHaveText('62 to go · ETA —')
  await page.locator('[data-min]').click()
  await expect(page).toHaveURL(/live=min/)
  await expect(page.locator('#bd-now')).toHaveClass(/min/)
  await expect(page.locator('[data-min]')).toHaveAttribute('aria-expanded', 'false')
  await expect(page.locator('#bd-now .bd-card')).toHaveCount(0)
  expect(await page.locator('#bd-now').evaluate(el => el.style.height)).toBe('38px')
  expect(await page.locator('.bd-now-sum button').evaluateAll(els => els.map(el => getComputedStyle(el).flexGrow))).toEqual(['3', '3', '2'])
  await page.locator('.bd-now-sum .bad').click()
  await expect(page).toHaveURL(/astate=error%2Cretries%2Ccommand|astate=error,retries,command/)
  await expect(page).not.toHaveURL(/live=min/)
  await expect(page.locator('.bd-now-st .bad')).toHaveClass('bad on')
  await expect(page.locator('.bd-now-st .bad')).toHaveAttribute('aria-pressed', 'true')
  await expect(page.locator('[data-min]')).toHaveAttribute('aria-expanded', 'true')
  await page.locator('.bd-now-st .bad').click()
  await expect(page).not.toHaveURL(/astate=/)
  await expect(page.locator('.bd-now-st .bad')).toHaveAttribute('aria-pressed', 'false')
})
test('live=min survives initial mount and unknown state gets an accessible count', async ({ page }) => {
  await open(page, 'live', '?live=min')
  await expect(page.locator('#bd-now')).toHaveClass(/min/)
  expect((await page.request.get('/build-control/diff?name=agent-state-null')).ok()).toBe(true)
  await expect(page.locator('.bd-now-sum')).toHaveAttribute('aria-label', '2 running, 3 stuck, 2 paused, 1 state unknown')
})
test('empty fleet is 86px, unavailable source has separate copy and no presets', async ({ page }) => {
  await open(page, 'now0')
  await expect(page.locator('.bd-now-empty')).toHaveText('No agents are working right now.')
  expect(await page.locator('#bd-now').evaluate(el => el.style.height)).toBe('86px')
  expect((await page.request.get('/build-control/diff?name=agents-unavailable')).ok()).toBe(true)
  await expect(page.locator('.bd-now-empty')).toHaveText('Agent states unavailable')
  await expect(page.locator('.bd-now-st button, .bd-now-sum')).toHaveCount(0)
})
test('unavailable band rows without a rendered card element are skipped during relayout', async ({ page }) => {
  await open(page, 'now0')
  await page.evaluate(async () => {
    const { place } = await import('/build-home/render.js')
    place(undefined, { sec: 'now', key: 'b0', y: 0, h: 20 })
  })
})
test('clock ticks on payload minute boundaries without new diffs and preserves cached timestamps', async ({ page }) => {
  await page.clock.install({ time: 1791407999000 }); await page.clock.pauseAt(1791408000000); await open(page)
  await expect(page.locator('.bd-now-h time')).toHaveText('14:20')
  await page.clock.runFor(59000)
  await expect(page.locator('.bd-now-h time')).toHaveText('14:20')
  await page.clock.runFor(1000)
  await expect(page.locator('.bd-now-h time')).toHaveText('14:21')
  await open(page, 'offline')
  await expect(page.locator('.bd-now-h time')).toHaveText('cached 14:14')
  await page.clock.runFor(60000)
  await expect(page.locator('.bd-now-h time')).toHaveText('cached 14:14')
})
test('scrolling clears unlocked hover, disables card pointers and settles; reduced motion still snaps', async ({ page }) => {
  await page.clock.install({ time: 1791407999000 }); await page.clock.pauseAt(1791408000000); await open(page); await settle(page)
  await page.emulateMedia({ reducedMotion: 'reduce' })
  const instant = await page.evaluate(() => {
    m.fx.scrollVP(0, false); m.fx.jumpNow(false)
    return { actual: m.ctx.vp.scrollTop, target: m.ctx.secs.hist.el.offsetTop + m.ctx.L.secs.hist.h - 46 }
  })
  expect(Math.abs(instant.actual - instant.target)).toBeLessThanOrEqual(1)
  await settle(page)
  await page.evaluate(() => {
    window.hoverCalls = []; m.ctx.hoverId = m.ctx.D.now[0].id; m.fx.setHover = id => hoverCalls.push(id)
    m.ctx.vp.scrollTop -= 20
  })
  await page.clock.runFor(16)
  await expect(page.locator('#bd-content')).toHaveClass(/scrolling/)
  expect(await page.evaluate(() => ({ scrolling: m.ctx.isScrolling(), calls: hoverCalls, pointers: getComputedStyle(document.querySelector('#bd-now .bd-card')).pointerEvents }))).toEqual({ scrolling: true, calls: [null], pointers: 'none' })
  await settle(page)
  await expect(page.locator('#bd-content')).not.toHaveClass(/scrolling/)
  expect(await page.evaluate(() => m.ctx.isScrolling())).toBe(false)
  expect(await page.evaluate(() => Math.abs(m.ctx.vp.scrollTop - (m.ctx.secs.hist.el.offsetTop + m.ctx.L.secs.hist.h - 46)))).toBeLessThanOrEqual(1)
})
test('jump uses 420ms cubic easing, clamps and cancels previous animations', async ({ page }) => {
  await page.clock.install({ time: 1791407999000 }); await page.clock.pauseAt(1791408000000); await open(page); await settle(page)
  await page.evaluate(() => {
    // Tall viewport constraint disables guard so the curve is measured without a second snap.
    m.ctx.vp.style.height = '200px'; m.S.ready = false
    m.fx.scrollVP(300, false); window.start = performance.now(); m.fx.scrollVP(1300, true);
    const sample = at => { window.lastFrame = at; requestAnimationFrame(sample) }; requestAnimationFrame(sample)
  })
  await page.clock.runFor(160)
  const value = await page.evaluate(() => ({ st: m.ctx.vp.scrollTop, elapsed: lastFrame - start }))
  expect(Math.abs(value.st - (300 + 1000 * (1 - (1 - value.elapsed / 420) ** 3)))).toBeLessThanOrEqual(1)
  await page.evaluate(() => m.fx.scrollVP(100, false)); await settle(page)
  expect(await page.evaluate(() => m.ctx.vp.scrollTop)).toBe(100)
  await page.evaluate(() => m.fx.scrollVP(-100, false))
  expect(await page.evaluate(() => m.ctx.vp.scrollTop)).toBe(0)
  await page.evaluate(() => { m.fx.scrollVP(300, false); m.S.view = 'list'; m.fx.jumpNow(true) })
  expect(await page.evaluate(() => m.ctx.vp.scrollTop)).toBe(0)
})
test('animated scrolling redraws sticky edges within each animation frame', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.clock.install({ time: 1791407999000 }); await page.clock.pauseAt(1791408000000)
  await open(page); await settle(page)
  await page.evaluate(() => {
    m.ctx.vp.style.height = m.ctx.vp.style.maxHeight = (m.ctx.bandEl.offsetHeight + 40) + 'px'
    m.fx.relayout(); m.fx.scrollVP(300, false); m.fx.update()
    window.edgeFrames = []
    const frame = m.ctx.life.frame.bind(m.ctx.life)
    m.ctx.life.frame = (key, fn) => frame(key, now => {
      fn(now)
      if (!String(key).startsWith('scrollVP:')) return
      const g = m.ctx.bandEl.querySelector('.bd-now-e g')
      edgeFrames.push({ scroll: m.ctx.vp.scrollTop, drawn: g.transform.baseVal.consolidate().matrix.f,
        actual: m.ctx.content.getBoundingClientRect().top - m.ctx.bandEl.getBoundingClientRect().top })
    })
    m.fx.scrollVP(1300, true)
  })
  await page.clock.runFor(432)
  const frames = await page.evaluate(() => edgeFrames)
  expect(frames.length).toBeGreaterThan(20)
  expect(new Set(frames.map(frame => frame.scroll)).size).toBeGreaterThan(10)
  for (const frame of frames) expect(frame.drawn).toBe(frame.actual)
})
test('tall fleet, paging and scrollbar drag suppress snapping', async ({ page }) => {
  await page.clock.install({ time: 1791407999000 }); await page.clock.pauseAt(1791408000000); await open(page, 'now24'); await settle(page)
  expect(await page.locator('#bd-now .bd-card')).toHaveCount(24)
  const before = await page.evaluate(() => m.ctx.vp.scrollTop)
  await page.evaluate(() => m.ctx.vp.scrollTop -= 100); await settle(page)
  expect(await page.evaluate(() => m.ctx.vp.scrollTop)).toBe(before - 100)
  await open(page); await settle(page)
  for (const mode of ['paging', 'drag']) {
    const result = await page.evaluate(async mode => {
      if (mode === 'paging') (await import('/build-home/history.js')).H.state = 'loading'
      else document.querySelector('#bd-sb').classList.add('drag')
      m.ctx.vp.scrollTop -= 100; return m.ctx.vp.scrollTop
    }, mode)
    await settle(page)
    expect(await page.evaluate(() => m.ctx.vp.scrollTop)).toBe(result)
  }
})
test('destroy cancels band frames, settle locks and clock ticks; remount resets scrolling', async ({ page }) => {
  await openFixture(page)
  await page.clock.install({ time: 1791407999000 }); await page.clock.pauseAt(1791408000000)
  await page.addInitScript(() => {
    window.bandTimerCalls = { registered: 0, cancelled: 0, afterDestroy: 0, active: new Set() }
    const isBandCallback = () => /\/build-home\/(?:band|band-scroll)\.js/.test(new Error().stack)
    for (const [schedule, cancel] of [['setTimeout', 'clearTimeout'], ['requestAnimationFrame', 'cancelAnimationFrame']]) {
      const nativeSchedule = window[schedule].bind(window), nativeCancel = window[cancel].bind(window)
      window[schedule] = (fn, ...args) => {
        const band = isBandCallback()
        let id
        id = nativeSchedule((...values) => {
          if (band) {
            bandTimerCalls.active.delete(id)
            if (window.bandDestroyed) bandTimerCalls.afterDestroy++
          }
          return fn(...values)
        }, ...args)
        if (band) { bandTimerCalls.registered++; bandTimerCalls.active.add(id) }
        return id
      }
      window[cancel] = id => {
        if (bandTimerCalls.active.delete(id)) bandTimerCalls.cancelled++
        return nativeCancel(id)
      }
    }
  })
  await open(page); await settle(page)
  await page.evaluate(() => {
    m.fx.scrollVP(300, true); m.fx.markScrolling()
    const vp = m.ctx.vp, time = m.ctx.bandEl.querySelector('time')
    window.old = { vp, time, writes: 0 }
    const scroll = Object.getOwnPropertyDescriptor(Element.prototype, 'scrollTop')
    Object.defineProperty(vp, 'scrollTop', { get() { return scroll.get.call(this) }, set(value) { old.writes++; scroll.set.call(this, value) } })
    window.liveSocket.main.pushLinkPatch(new Event('click'), '/commands', null);
  })
  await expect(page.locator('#bd-vp')).toHaveCount(0)
  const stopped = await page.evaluate(() => ({ writes: old.writes, text: old.time.textContent, disposed: m.ctx.life.disposed }))
  expect(stopped.disposed).toBe(true)
  await page.evaluate(() => { window.bandDestroyed = true })
  expect(await page.evaluate(() => bandTimerCalls.active.size)).toBe(0)
  expect(await page.evaluate(() => bandTimerCalls.registered)).toBeGreaterThan(0)
  // The build hook is gone; keep LiveView's separate reconnect watchdog out of this long fake-time window.
  await page.evaluate(() => liveSocket.disconnect())
  await page.clock.runFor(65000)
  expect(await page.evaluate(() => bandTimerCalls.afterDestroy)).toBe(0)
  expect(await page.evaluate(() => bandTimerCalls.active.size)).toBe(0)
  expect(await page.evaluate(() => bandTimerCalls.cancelled)).toBeGreaterThan(0)
  expect(await page.evaluate(() => ({ writes: old.writes, text: old.time.textContent, disposed: m.ctx.life.disposed }))).toEqual(stopped)
  await open(page); await expect(page.locator('.bd-now-h > b')).toHaveText('Live')
  await settle(page)
  expect(await page.evaluate(async () => (await import('/build-home/state.js')).ctx.isScrolling())).toBe(false)
})
for (const theme of ['dark', 'light']) test(`normal and minimized band pass axe: ${theme}`, async ({ page }) => {
  await page.emulateMedia({ colorScheme: theme }); await open(page)
  for (const min of [false, true]) {
    if (min) await page.locator('[data-min]').click()
    const results = await new AxeBuilder({ page }).include('#bd-now').withRules(['nested-interactive', 'button-name', 'aria-allowed-attr', 'aria-valid-attr-value']).analyze()
    expect(results.violations).toEqual([])
    if (min) await expect(page.locator('.bd-now-sum')).toHaveAttribute('role', 'group')
  }
})

test('keyboard minimize, expand and preset expansion retain focus', async ({ page }) => {
  await open(page)
  await page.locator('[data-min]').focus(); await page.keyboard.press('Enter')
  await expect(page.locator('[data-min]')).toBeFocused()
  await page.keyboard.press('Space')
  await expect(page.locator('[data-min]')).toBeFocused()
  await expect(page.locator('[data-min]')).toHaveAttribute('aria-expanded', 'true')
  await page.keyboard.press('Enter')
  await page.locator('.bd-now-sum .bad').focus(); await page.keyboard.press('Enter')
  await expect(page.locator('.bd-now-st .bad')).toBeFocused()
})

test('a removed preset returns keyboard focus to the band control', async ({ page }) => {
  await open(page)
  await page.locator('.bd-now-st .bad').focus()
  await expect(page.locator('.bd-now-st .bad')).toBeFocused()
  expect((await page.request.get('/build-control/diff?name=agents-unavailable')).ok()).toBe(true)
  await expect(page.locator('[data-min]')).toBeFocused()
})

test('Live button floating state and click use the actual band geometry', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 1100 })
  await page.clock.install({ time: 1791407999000 }); await page.clock.pauseAt(1791408000000); await open(page, 'newrepo'); await settle(page)
  const floating = await page.evaluate(() => {
    m.ctx.vp.scrollTop = 0; m.fx.update()
    const r = m.ctx.bandEl.getBoundingClientRect(), v = m.ctx.vp.getBoundingClientRect()
    return { top: r.top - v.top, bottom: v.bottom - r.bottom, at: document.querySelector('#bd-nowbtn').classList.contains('at') }
  })
  expect(floating.top).toBeGreaterThan(76); expect(floating.bottom).toBeGreaterThan(30); expect(floating.at).toBe(true)
  await open(page); await settle(page)
  await page.evaluate(() => { m.ctx.vp.scrollTop = m.ctx.secs.hist.el.offsetTop + m.ctx.L.secs.hist.h - 146; m.fx.update() })
  await expect(page.locator('#bd-nowbtn')).toHaveClass(/at/)
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.locator('#bd-nowbtn').evaluate(el => el.click())
  const error = await page.evaluate(() => {
    const vp = m.ctx.vp, target = Math.max(0, Math.min(m.ctx.secs.hist.el.offsetTop + m.ctx.L.secs.hist.h - 46, vp.scrollHeight - vp.clientHeight))
    return Math.abs(vp.scrollTop - target)
  })
  expect(error).toBeLessThanOrEqual(1)
  await page.clock.runFor(20)
  await expect(page.locator('#bd-nowbtn')).not.toHaveClass(/at/)
})

test('source clock states update through real diffs without inventing live time', async ({ page }) => {
  await open(page)
  for (const [name, text] of [['agents-stale', 'cached 14:10'], ['daemon-unknown', '—'], ['offline-no-heartbeat', 'cached —']]) {
    expect((await page.request.get('/build-control/diff?name=' + name)).ok()).toBe(true)
    await expect(page.locator('.bd-now-h time')).toHaveText(text)
  }
})
test('focused band card survives live relayout', async ({ page }) => {
  await open(page)
  const card = page.locator('#bd-now .bd-card').first(), id = await card.getAttribute('data-id')
  await card.focus()
  expect((await page.request.get('/build-control/diff?name=card-pct-null')).ok()).toBe(true)
  await expect(page.locator('#bd-now .bd-card[data-id="' + id + '"]')).toBeFocused()
})

// Future-regression guard for the design's CSS-only re-pin; not counted as change coverage.
test('future guard: added agents stay pinned at the bottom without a new scroll animation', async ({ page }) => {
  await page.clock.install({ time: 1791407999000 }); await page.clock.pauseAt(1791408000000); await open(page); await settle(page)
  await page.evaluate(() => m.fx.scrollVP(m.ctx.secs.hist.el.offsetTop + m.ctx.L.secs.hist.h + m.ctx.L.band.h - m.ctx.vp.clientHeight, false))
  await settle(page)
  await page.evaluate(() => {
    window.scrollFrames = []
    const frame = m.ctx.life.frame
    m.ctx.life.frame = (key, fn) => { if (typeof key === 'string' && key.startsWith('scrollVP:')) scrollFrames.push(key); return frame(key, fn) }
  })
  expect((await page.request.get('/build-control/diff?name=add-four-agents')).ok()).toBe(true)
  await settle(page)
  await expect(page.locator('#bd-now .bd-card')).toHaveCount(12)
  expect(await page.evaluate(() => Math.abs(m.ctx.bandEl.getBoundingClientRect().bottom - m.ctx.vp.getBoundingClientRect().bottom))).toBeLessThanOrEqual(1)
  expect(await page.evaluate(() => scrollFrames)).toEqual([])
})

// Before the first snapshot renderBand is guarded by ctx.D; B3 mutates the null-clock presenter separately.
test('future guard: a mounted hook awaiting its first snapshot never presents midnight', async ({ page }) => {
  await openFixture(page)
  const state = await page.evaluate(async () => {
    const { createBuildHomeHook } = await import('/build-home/hook.js')
    const { ctx } = await import('/build-home/state.js'), clock = await import('/build-home/clock.js')
    document.body.innerHTML = '<main id="build-root" class="bd-root">' + ['bd-usage', 'bd-offline', 'bd-fh', 'bd-tools-l', 'bd-filters', 'bd-tools', 'bd-vp', 'bd-sb', 'bd-tree', 'bd-status'].map(id => `<div id="${id}">${id === 'bd-sb' ? '<i></i>' : ''}</div>`).join('') + '<div id="tk-backdrop"><div id="tk-modal"><header id="tk-head"></header><div id="tk-body"></div></div></div></main>'
    const hook = Object.assign(createBuildHomeHook(), { el: document.querySelector('#build-root'), handleEvent() {}, pushEvent: () => new Promise(() => {}) })
    hook.mounted()
    const result = { now: clock.nowMs(), data: ctx.D, text: document.querySelector('.bd-now-h time')?.textContent ?? null }
    hook.destroyed(); return result
  })
  expect(state.now).toBeNull(); expect(state.data).toBeNull()
  expect([null, '—']).toContain(state.text)
})
