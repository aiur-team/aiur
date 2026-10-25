import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { card, tree, tray, open, reveal, lock, whole } from './support/build-home-chains.mjs'
import { installFitObserver } from './support/build-home-chains-parity.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'
test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })
async function diff(page, name) {
  const response = await page.request.get('/build-control/diff?name=' + name)
  expect(response.status(), await response.text()).toBe(200)
}
async function arrowPoint(page, rootId = null) {
  return page.evaluate(rootId => {
    for (const path of document.querySelectorAll('.bd-eh')) {
      if (rootId && path.dataset.e !== rootId) continue
      const matrix = path.getScreenCTM(), len = path.getTotalLength()
      for (let i = 1; i < 50; i++) {
        const p = path.getPointAtLength(len * i / 50)
        const x = matrix.a * p.x + matrix.e, y = matrix.d * p.y + matrix.f
        if (x > 0 && x < innerWidth && y > 0 && y < innerHeight && document.elementFromPoint(x, y) === path) return { x, y, id: path.dataset.e }
      }
    }
    return null
  }, rootId)
}
test('B1 hover requires trees=1; arrow click still locks without it', async ({ page }) => {
  await open(page, { trees: false })
  await reveal(page, '9012'); await card(page, '9012').hover()
  await expect(page.locator('.bd-content')).not.toHaveClass(/hovering/)
  await expect(page.locator('.bd-card.hl')).toHaveCount(0)
  await expect(tray(page)).not.toHaveClass(/show/)
  await expect.poll(() => arrowPoint(page, '9012')).not.toBeNull()
  const point = await arrowPoint(page, '9012')
  expect(point).not.toBeNull()
  await page.mouse.click(point.x, point.y)
  await expect.poll(() => page.evaluate(() => st.ctx.lockId)).toBe(point.id)
})
test('B2 hover clears after 280ms on empty content and 200ms on leaving', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' }); await open(page); await reveal(page, '9012')
  await card(page, '9012').hover()
  await page.clock.install({ time: 1791408000000 }); await page.clock.pauseAt(1791408001000)
  await expect(page.locator('.bd-content')).toHaveClass(/hovering/)
  // Dispatch on the real listener target; fixed clock makes the two boundaries exact.
  await page.locator('#bd-content').dispatchEvent('pointerover', { pointerType: 'mouse' })
  await page.clock.runFor(250)
  await expect(page.locator('.bd-content')).toHaveClass(/hovering/)
  await page.clock.runFor(70)
  await expect(page.locator('.bd-content')).not.toHaveClass(/hovering/)
  await card(page, '9012').dispatchEvent('pointerover', { pointerType: 'mouse' })
  await page.locator('#bd-content').dispatchEvent('mouseleave')
  await page.clock.runFor(190)
  await expect(page.locator('.bd-content')).toHaveClass(/hovering/)
  await page.clock.runFor(30)
  await expect(page.locator('.bd-content')).not.toHaveClass(/hovering/)
})
test('B3 cycle overlay has three actual levels and restores focus', async ({ page }) => {
  await open(page); await whole(page, '3')
  await expect(tree(page).locator('.bd-tree-h')).toContainText('#3 · 3 tickets · 3 levels')
  await expect(tree(page).locator('.bd-tn')).toHaveCount(3)
  await expect(page.locator('#bd-tree-x')).toBeFocused()
  await tree(page).evaluate(el => Promise.all(el.getAnimations().map(animation => animation.finished)))
  await page.screenshot({ path: test.info().outputPath('chain-tree-desktop.png') })
  await page.keyboard.press('Escape')
  await expect(tree(page)).toBeHidden()
  await expect(page.locator('[data-lt="tree"]')).toBeFocused()
  await expect(tray(page)).toHaveClass(/locked/)
  await page.keyboard.press('Escape')
  await expect(tray(page)).not.toHaveClass(/locked/)
})
test('B4 unloaded members and unknown dependency counts are explicit', async ({ page }) => {
  await open(page); await whole(page, '9012')
  await expect(tree(page).locator('.bd-tree-h')).toContainText('4 not on the board')
  await page.keyboard.press('Escape'); await page.keyboard.press('Escape')
  await whole(page, '9024')
  await expect(tree(page).locator('.bd-tree-h')).toContainText('links not yet known')
})
test('B5 unknown node text and hostile titles stay honest and escaped', async ({ page }) => {
  await open(page); await whole(page, '9021')
  await expect(tree(page).locator('.bd-tn[data-id="9020"] em')).toHaveText('State unknown · —')
  await expect(tree(page).locator('.bd-tn[data-id="9020"]')).not.toHaveClass(/ag-/)
  await expect(tree(page).locator('.bd-tn[data-id="9021"] em')).toContainText('Q?')
  await expect(tree(page).locator('.bd-tn[data-id="9022"] em')).toContainText('W?')
  await expect(tree(page).locator('.bd-tn[data-id="9023"] em')).toHaveText('Not planned')
  await expect(tree(page).locator('img, script')).toHaveCount(0)
  expect(await page.evaluate(() => window.__xss)).toBeUndefined()
  await expect(tree(page)).not.toContainText(/null%|Qnull|Wnull|#null|0%/)
  const title = await page.evaluate(() => st.ctx.D.byId['9021'].title)
  await expect(tree(page).locator('.bd-tn[data-id="9021"] .bd-tn1 > span')).toHaveText(title)
})
test('B6 Fit pages history, updates zoom and restores its lock', async ({ page }) => {
  await open(page); await lock(page, '9012')
  await page.evaluate(() => {
    const push = st.ctx.push; window.earlierCalls = []
    st.ctx.push = (event, params) => { if (event === 'load-earlier') earlierCalls.push(params); return push(event, params) }
  })
  await page.locator('[data-lt="fit"]').click()
  await expect.poll(() => page.evaluate(() => earlierCalls.length)).toBeGreaterThan(0)
  await expect.poll(() => page.evaluate(() => st.ctx.fitHistory === null)).toBe(true)
  await expect.poll(() => page.evaluate(() => !st.ctx.isScrolling() && !st.ctx.snapping && st.ctx.root.dataset.bdPaging === 'idle')).toBe(true)
  await expect.poll(() => page.evaluate(() => st.ctx.lockId)).toBe('9012')
  await expect.poll(() => page.evaluate(() => !!st.ctx.D.byId['9001'])).toBe(true)
  await expect(card(page, '9001')).toBeVisible()
  const oldest = await card(page, '9001').boundingBox(), vp = await page.locator('#bd-vp').boundingBox()
  expect(oldest.y).toBeGreaterThanOrEqual(vp.y)
  expect(oldest.y + oldest.height).toBeLessThanOrEqual(vp.y + vp.height)
  const span = await page.evaluate(() => st.S.span)
  expect(span).toBeGreaterThan(1)
  await expect(page).toHaveURL(new RegExp('span=' + span))
  await expect(page.locator('.bd-zv')).toHaveText(Math.round(100 / span) + '%')
})
test('B6 Fit cancels a live-band scroll frame already queued before centering', async ({ page }) => {
  await open(page); await lock(page, '9012')
  await page.evaluate(() => {
    const frame = st.ctx.life.frame, tools = st.fx.renderTools
    window.oldScrollFrames = []
    st.ctx.life.frame = (key, callback) => {
      if (typeof key === 'string' && key.startsWith('scrollVP:')) oldScrollFrames.push(callback)
      else frame(key, callback)
    }
    st.fx.liveGuard = st.fx.markScrolling = () => {} // Isolate the older animator from new native scroll snaps.
    st.fx.renderTools = () => { tools(); st.fx.scrollVP(0, true) }
  })
  await page.locator('[data-lt="fit"]').click()
  await expect.poll(() => page.evaluate(() => st.ctx.fitHistory === null)).toBe(true)
  const result = await page.evaluate(() => {
    const before = st.ctx.vp.scrollTop, count = oldScrollFrames.length
    oldScrollFrames.splice(0).forEach(callback => callback(performance.now() + 1000))
    st.ctx.snapping = false
    return { before, after: st.ctx.vp.scrollTop, count }
  })
  expect(result.count).toBeGreaterThan(0)
  expect(result.before).toBeGreaterThan(0)
  expect(result.after).toBe(result.before)
})
// Hold native snapping across Fit's final frame, then release it explicitly.
test('B6 Fit stays pending until native band snapping settles', async ({ page }) => {
  await open(page); await lock(page, '9012')
  await page.evaluate(() => {
    const tools = st.fx.renderTools, frame = st.ctx.life.frame
    let symbols = 0
    st.fx.renderTools = () => { tools(); st.ctx.snapping = true }
    st.ctx.life.frame = (key, callback) => frame(key, now => {
      callback(now)
      if (typeof key === 'symbol' && ++symbols >= 2) window.fitFinalFrameRan = true
    })
    window.releaseFitSnap = () => { st.fx.renderTools = tools; st.ctx.life.frame = frame; st.ctx.snapping = false }
  })
  await page.locator('[data-lt="fit"]').click()
  await expect.poll(() => page.evaluate(() => window.fitFinalFrameRan)).toBe(true)
  expect(await page.evaluate(() => st.ctx.fitHistory !== null)).toBe(true)
  await page.evaluate(() => releaseFitSnap())
  await expect.poll(() => page.evaluate(() => st.ctx.fitHistory === null)).toBe(true)
  await expect(tray(page)).toHaveClass(/locked/)
})
for (const mode of ['cancel', 'failure']) test(`B6 Fit ${mode} does not reclaim a released lock`, async ({ page }) => {
  await open(page); await lock(page, '9012')
  await page.evaluate(() => {
    const push = st.ctx.push; window.fitFailureRequests = 0
    st.ctx.push = (event, params) => { if (event === 'load-earlier') fitFailureRequests++; return push(event, params) }
  })
  await page.request.get('/build-control/earlier?' + (mode === 'cancel' ? 'delay=500' : 'fail=1'))
  await page.locator('[data-lt="fit"]').click()
  if (mode === 'cancel') {
    await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'loading')
    await page.keyboard.press('Escape')
  } else await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'error')
  await page.waitForTimeout(700)
  if (mode === 'cancel') expect(await page.evaluate(() => st.ctx.lockId)).toBeNull()
  else {
    await expect(page.locator('#bd-sec-hist')).toContainText('earlier days could not load')
    expect(await page.evaluate(() => fitFailureRequests)).toBe(1)
  }
})
test('B6 Fit limits discovery when an unloaded link never resolves', async ({ page }) => {
  await open(page); await lock(page, '9012')
  await page.evaluate(() => {
    const push = st.ctx.push, relayout = st.fx.relayout
    window.discoveryCalls = []; window.fitDiscoveryCount = null
    st.fx.relayout = options => {
      if (!options?.live && fitDiscoveryCount == null) window.fitDiscoveryCount = discoveryCalls.length
      return relayout(options)
    }
    st.ctx.push = (event, params) => {
      if (event !== 'load-earlier') return push(event, params)
      discoveryCalls.push(params)
      // Real valid pages advance the history cursor but never supply the missing blocker.
      // A finite synthetic feed prevents an unbounded implementation hanging the test.
      const from = params.before - 86400000
      const row = { ...st.ctx.D.hist[0], id: 'discovery-' + discoveryCalls.length, deps: [], end: from + 43200000 }
      return Promise.resolve({ kind: 'earlier', epoch: st.ctx.proto.epoch, rows: [row], history: {
        ...st.ctx.snap.history, from, more: discoveryCalls.length < 40,
      } })
    }
  })
  await page.locator('[data-lt="fit"]').click()
  await expect.poll(() => page.evaluate(() => fitDiscoveryCount)).not.toBeNull()
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'idle')
  await expect.poll(() => page.evaluate(() => st.ctx.lockId)).toBe('9012')
  expect(await page.evaluate(() => fitDiscoveryCount)).toBe(3)
  expect(await page.evaluate(() => st.ctx.snap.history.more)).toBe(true)
  expect(await page.evaluate(() => !!st.ctx.D.byId['9001'])).toBe(false)
})
test('B6 Fit waits for delayed density pages before measuring a span', async ({ page }) => {
  await open(page); await lock(page, '9012')
  await page.evaluate(() => {
    const push = st.ctx.push, relayout = st.fx.relayout, template = st.ctx.D.hist[0]
    const oldest = Math.min(...st.ctx.D.hist.map(t => t.end).filter(Number.isFinite))
    window.densityProbe = { pending: false, calls: 0, delayed: 0, premature: [] }
    st.fx.relayout = options => {
      if (!options?.live && densityProbe.pending) densityProbe.premature.push(st.S.span)
      return relayout(options)
    }
    st.ctx.push = (event, params) => {
      if (event !== 'load-earlier') return push(event, params)
      const first = densityProbe.calls++ === 0, from = params.before - 86400000
      const rows = first ? [1, 2, 3, 4].map(i => ({ ...template, id: '900' + i, deps: i === 4 ? ['density-0'] : [], end: oldest })) : []
      for (let i = 0; i < 55; i++) rows.push({ ...template,
        id: (first ? 'density-' : 'filler-' + densityProbe.calls + '-') + i,
        deps: first && i < 54 ? ['density-' + (i + 1)] : [], end: first ? oldest : from + 43200000,
      })
      densityProbe.pending = true
      if (!first) densityProbe.delayed++
      return new Promise(resolve => setTimeout(() => {
        densityProbe.pending = false
        resolve({ kind: 'earlier', epoch: st.ctx.proto.epoch, rows, history: {
          ...st.ctx.snap.history, from, more: densityProbe.calls < 35,
        } })
      }, 150))
    }
  })
  await page.locator('[data-lt="fit"]').click()
  await expect.poll(() => page.evaluate(() => densityProbe.delayed)).toBeGreaterThan(0)
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'idle')
  await expect.poll(() => page.evaluate(() => st.ctx.lockId)).toBe('9012')
  await expect(page).toHaveURL(/[?&]span=\d+/)
  expect(await page.evaluate(() => densityProbe.premature)).toEqual([])
  expect(await page.evaluate(() => st.S.span)).toBeLessThan(30)
})
test('B6 Fit bounds empty density pages without an automatic paging bypass', async ({ page }) => {
  await open(page); await lock(page, '9012')
  await page.evaluate(() => {
    const push = st.ctx.push, template = st.ctx.D.hist[0]
    const oldest = Math.min(...st.ctx.D.hist.map(t => t.end).filter(Number.isFinite))
    window.emptyDensityCalls = 0
    st.ctx.push = (event, params) => {
      if (event !== 'load-earlier') return push(event, params)
      const first = emptyDensityCalls++ === 0, from = params.before - 86400000
      const rows = first ? [1, 2, 3, 4].map(i => ({ ...template, id: '900' + i, deps: i === 4 ? ['empty-0'] : [], end: oldest })) : []
      if (first) for (let i = 0; i < 200; i++) rows.push({ ...template,
        id: 'empty-' + i, deps: i < 199 ? ['empty-' + (i + 1)] : [], end: oldest,
      })
      return new Promise(resolve => setTimeout(() => resolve({ kind: 'earlier', epoch: st.ctx.proto.epoch, rows, history: {
        ...st.ctx.snap.history, from, more: emptyDensityCalls < 70,
      } }), 5))
    }
  })
  await page.locator('[data-lt="fit"]').click()
  await expect(page).toHaveURL(/[?&]span=30/)
  await expect.poll(() => page.evaluate(() => st.ctx.fitHistory)).toBeNull()
  await page.waitForTimeout(200)
  expect(await page.evaluate(() => emptyDensityCalls)).toBeGreaterThan(3)
  expect(await page.evaluate(() => emptyDensityCalls)).toBeLessThanOrEqual(33)
  expect(await page.evaluate(() => st.ctx.snap.history.more)).toBe(true)
  expect(await page.evaluate(() => st.ctx.lockId)).toBe('9012')
})
test('B7 live dependencies refresh highlight, tab position and open overlay', async ({ page }) => {
  await open(page); await whole(page, '9012')
  await page.addStyleTag({ content: '.bd-card { transition-duration: 1s !important; }' })
  await diff(page, 'chain-add-dep')
  await expect(tree(page).locator('.bd-tn[data-id="615"]')).toHaveCount(1)
  await page.keyboard.press('Escape')
  await reveal(page, '615')
  await expect(card(page, '615')).toHaveClass(/hl/)
  await reveal(page, '9012')
  const positions = await page.evaluate(() => {
    const el = [...st.ctx.R.values()].find(el => el.dataset.id === '9012')
    const r = el.getBoundingClientRect(), c = st.ctx.content.getBoundingClientRect(), tab = st.ctx.content.querySelector('.bd-lt')
    return { left: parseFloat(tab.style.left), top: parseFloat(tab.style.top), x: r.right - c.left - 1, y: r.top - c.top + Math.max(0, r.height / 2 - 14) }
  })
  expect(positions.left).toBeCloseTo(positions.x, 1); expect(positions.top).toBeCloseTo(positions.y, 1)
  expect(await page.evaluate(() => st.ctx.lockId)).toBe('9012')
})
test('B8 removed root closes overlay and focuses the board', async ({ page }) => {
  await open(page); await whole(page, '9012')
  await diff(page, 'chain-remove-root')
  await expect(tree(page)).toBeHidden()
  await expect(page.locator('#bd-vp')).toBeFocused()
  expect(await page.evaluate(() => st.ctx.lockId)).toBeNull()
})
test('B9 cards rendered by scrolling receive locked chain classes', async ({ page }) => {
  await open(page, { dataset: 'dense' })
  const id = await page.evaluate(() => [...st.ctx.R.values()].find(el => !el.closest('.bd-now')).dataset.id)
  await lock(page, id)
  const before = await page.locator('.bd-card').evaluateAll(els => els.map(el => el.dataset.id))
  await page.locator('#bd-vp').evaluate(el => { el.scrollTop += 3000 })
  await expect.poll(() => page.locator('.bd-card').evaluateAll((els, before) => els.filter(el => !before.includes(el.dataset.id)).length, before)).toBeGreaterThan(0)
  const classes = await page.locator('.bd-card').evaluateAll((els, id) => els.filter(el => el.dataset.id !== id).map(el => ({ id: el.dataset.id, marked: el.matches('.hl, .hdim') })), id)
  expect(classes.length).toBeGreaterThan(0)
  expect(classes.filter(c => !c.marked)).toEqual([])
  await expect(card(page, id)).toHaveCount(0); await expect(tray(page)).toHaveClass(/show/)
})
test.describe('B10 phone touch', () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true })
  test('card tap opens the ticket without hover; arrow tap locks and opens tree', async ({ page }) => {
    await open(page, { modal: true }); await reveal(page, '9012')
    let cardTouch
    await expect.poll(async () => {
      cardTouch = await card(page, '9012').evaluate(el => {
        const r = el.getBoundingClientRect()
        for (const fy of [0.2, 0.5, 0.8]) for (const fx of [0.5, 0.25, 0.75]) {
          const x = r.x + r.width * fx, y = r.y + r.height * fy, hit = document.elementFromPoint(x, y)
          if (el.contains(hit) && !hit.closest('button, a')) return { x, y, ready: true }
        }
        return { ready: false, rect: { x: r.x, y: r.y, w: r.width, h: r.height },
          hit: document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2)?.outerHTML.slice(0, 160) }
      })
      return cardTouch.ready ? true : JSON.stringify(cardTouch)
    }, { message: 'the visible card must receive the touch' }).toBe(true)
    await page.touchscreen.tap(cardTouch.x, cardTouch.y)
    expect(await page.evaluate(() => window.openedTicket)).toBe('9012')
    await expect(page.locator('.bd-content')).not.toHaveClass(/hovering/)
    await page.keyboard.press('Escape')
    // This right-hand root puts the tree tab over the transparent scrollbar track.
    const point = await arrowPoint(page, '9011')
    expect(point).not.toBeNull()
    expect(point.id).toBe('9011')
    await page.touchscreen.tap(point.x, point.y)
    await expect.poll(() => page.evaluate(() => st.ctx.lockId)).toBe(point.id)
    const eye = page.locator('[data-lt="tree"]')
    await eye.scrollIntoViewIfNeeded()
    await page.waitForTimeout(450) // Let scroll reapply the tab before choosing a touch point.
    let target
    await expect.poll(async () => {
      target = await eye.evaluate(el => {
        const r = el.getBoundingClientRect(), x = r.x + r.width / 2, y = r.y + r.height / 2
        const hit = document.elementFromPoint(x, y)
        return { x, y, hit: hit?.outerHTML.slice(0, 160), ready: el.contains(hit) }
      })
      return target.ready ? 'ready' : JSON.stringify(target)
    }, { message: 'the tree tab must receive the touch' }).toBe('ready')
    await page.touchscreen.tap(target.x, target.y)
    await expect(tree(page)).toBeVisible()
    await tree(page).evaluate(el => Promise.all(el.getAnimations().map(animation => animation.finished)))
    await page.screenshot({ path: test.info().outputPath('chain-tree-phone.png') })
  })
})
test('B11 Escape closes the ticket before the dependency tree', async ({ page }) => {
  await open(page, { modal: true }); await whole(page, '3')
  await tree(page).locator('.bd-tn[data-id="3"]').click()
  await expect(page.locator('#tk-backdrop.show')).toHaveCount(1)
  await page.keyboard.press('Escape')
  await expect(page.locator('#tk-backdrop.show')).toHaveCount(0)
  await expect(tree(page)).toBeVisible()
  await page.keyboard.press('Escape')
  await expect(tree(page)).toBeHidden()
})
test('B12 browser Back disabling trees clears a lock', async ({ page }) => {
  await open(page, { trees: false })
  await page.evaluate(() => window.liveSocket.pushHistoryPatch(new Event('click'), '/build', 'push', null))
  await expect(page).toHaveURL(/\/build$/)
  await page.evaluate(() => window.liveSocket.pushHistoryPatch(new Event('click'), '/build?trees=1', 'push', null))
  await expect.poll(() => page.evaluate(() => st.S.trees)).toBe(true)
  await lock(page, '9012')
  await page.goBack()
  await expect.poll(() => page.evaluate(() => st.S.trees)).toBe(false)
  expect(await page.evaluate(() => st.ctx.lockId)).toBeNull()
  await expect(page.locator('.bd-content')).not.toHaveClass(/hovering/)
})
test('B12 Escape without an active tree lock preserves hover', async ({ page }) => {
  await open(page); await reveal(page, '9012'); await card(page, '9012').hover()
  await expect.poll(() => page.evaluate(() => st.ctx.hoverId)).toBe('9012')
  await page.keyboard.press('Escape')
  expect(await page.evaluate(() => st.ctx.lockId)).toBeNull()
  expect(await page.evaluate(() => st.ctx.hoverId)).toBe('9012')
  await expect(tray(page)).toHaveClass(/show/)
})
test('B13 navigation cancels a pending Fit and removes tree document listeners', async ({ page }) => {
  const errors = []; page.on('pageerror', error => errors.push(error.message))
  await page.addInitScript(() => {
    const add = document.addEventListener.bind(document), remove = document.removeEventListener.bind(document)
    const capture = options => typeof options === 'boolean' ? options : !!options?.capture
    window.treeDocumentListeners = []
    document.addEventListener = (type, fn, options) => {
      if (new Error().stack.includes('/build-home/shell.js')) treeDocumentListeners.push({ type, fn, capture: capture(options) })
      return add(type, fn, options)
    }
    document.removeEventListener = (type, fn, options) => {
      window.treeDocumentListeners = treeDocumentListeners.filter(entry => entry.type !== type || entry.fn !== fn || entry.capture !== capture(options))
      return remove(type, fn, options)
    }
  })
  await open(page); await lock(page, '9012')
  expect(await page.evaluate(() => treeDocumentListeners.map(({ type, capture }) => ({ type, capture })))).toEqual([
    { type: 'click', capture: false }, { type: 'keydown', capture: true }, { type: 'click', capture: false },
  ])
  await page.request.get('/build-control/earlier?delay=500')
  await page.evaluate(() => {
    window.lateTreeCalls = []; const life = st.ctx.life
    for (const key of ['relayout', 'lockTree', 'unlock', 'closeTree']) {
      const fn = st.fx[key]
      st.fx[key] = (...args) => { if (life.disposed) lateTreeCalls.push(key); return fn(...args) }
    }
  })
  await page.locator('[data-lt="fit"]').click()
  await expect(page.locator('#build-root')).toHaveAttribute('data-bd-paging', 'loading')
  await page.evaluate(() => window.liveSocket.main.pushLinkPatch(new Event('click'), '/commands', null))
  await expect(page.locator('#build-root')).toHaveCount(0)
  expect(await page.evaluate(() => treeDocumentListeners.length)).toBe(0)
  await page.keyboard.press('Escape'); await page.locator('body').click({ position: { x: 2, y: 2 } })
  await page.waitForTimeout(700)
  expect(await page.evaluate(() => lateTreeCalls)).toEqual([])
  expect(errors).toEqual([])
})
test('B13 teardown between Fit frames cancels the second frame', async ({ page }) => {
  await open(page); await lock(page, '3')
  await installFitObserver(page)
  const result = await page.evaluate(async () => {
    const life = st.ctx.life, hook = await import('/build-home/hook.js')
    const frame = life.frame.bind(life), calls = []
    let lock = st.ctx.lockId
    Object.defineProperty(st.ctx, 'lockId', { configurable: true,
      get: () => lock,
      set: value => { if (life.disposed) calls.push('lock'); lock = value },
    })
    // Dispose using the hook's real teardown exactly after Fit's first frame.
    life.frame = (key, fn) => frame(key, () => {
      fn()
      if (key.description === 'fit-1') {
        window.lockBeforeTeardown = st.ctx.lockId
        hook.createBuildHomeHook().destroyed.call({ buildLife: life })
      }
    })
    const update = st.fx.update
    st.fx.update = (...args) => { if (life.disposed) calls.push('update'); return update(...args) }
    st.ctx.content.querySelector('[data-lt="fit"]').click()
    await window.chainParityFit
    return { disposed: life.disposed, calls, lock: st.ctx.lockId, before: window.lockBeforeTeardown, paging: st.ctx.fitHistory }
  })
  expect(result.disposed).toBe(true)
  expect(result.calls).toEqual([])
  expect(result.lock).toBe(result.before)
  expect(result.paging).toBeNull()
})

for (const action of ['lock', 'Escape']) test(`B13 ${action} between Fit frames supersedes the pending root`, async ({ page }) => {
  await open(page); await lock(page, '3')
  await installFitObserver(page)
  const result = await page.evaluate(async action => {
    const life = st.ctx.life, frame = life.frame.bind(life)
    life.frame = (key, fn) => frame(key, () => {
      fn()
      if (key.description === 'fit-1') {
        if (action === 'lock') st.fx.lockTree('1')
        else document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
      }
    })
    st.ctx.content.querySelector('[data-lt="fit"]').click()
    await window.chainParityFit
    return st.ctx.lockId
  }, action)
  expect(result).toBe(action === 'lock' ? '1' : null)
})

test('B13 consecutive Fits release the latest paging guard', async ({ page }) => {
  await open(page); await lock(page, '3')
  const overlapping = await page.evaluate(() => {
    st.ctx.content.querySelector('[data-lt="fit"]').click()
    const first = st.ctx.fitHistory
    st.ctx.content.querySelector('[data-lt="fit"]').click()
    return !!first && !!st.ctx.fitHistory && first !== st.ctx.fitHistory
  })
  expect(overlapping).toBe(true)
  await expect.poll(() => page.evaluate(() => st.ctx.fitHistory)).toBeNull()
  expect(await page.evaluate(() => st.ctx.lockId)).toBe('3')
  await expect(tray(page)).toHaveClass(/locked/)
  await page.evaluate(() => {
    const push = st.ctx.push; window.resumedPagingCalls = 0
    st.ctx.push = (event, params) => {
      if (event === 'load-earlier') resumedPagingCalls++
      return push(event, params)
    }
  })
  await page.locator('#bd-vp').hover()
  await page.mouse.wheel(0, -100000)
  await expect.poll(() => page.evaluate(() => resumedPagingCalls)).toBeGreaterThan(0)
})

test('B14 locked board and tree have no axe violations; dialog traps Tab', async ({ page }) => {
  await open(page); await lock(page, '3')
  expect((await new AxeBuilder({ page }).include('#build-root').analyze()).violations).toEqual([])
  await page.locator('[data-lt="tree"]').click()
  await expect(page.getByRole('dialog', { name: 'Dependency tree' })).toBeVisible()
  await expect(page.locator('#bd-tree-x')).toBeFocused()
  await page.keyboard.press('Shift+Tab')
  await expect(tree(page).locator('.bd-tn').last()).toBeFocused()
  await page.keyboard.press('Tab')
  await expect(page.locator('#bd-tree-x')).toBeFocused()
  await expect(tree(page)).toHaveCSS('opacity', '1') // axe must inspect the completed native fade.
  expect((await new AxeBuilder({ page }).include('#bd-tree').analyze()).violations).toEqual([])
})
test.afterEach(async ({ page }) => { await page.request.get('/build-control/earlier') })
