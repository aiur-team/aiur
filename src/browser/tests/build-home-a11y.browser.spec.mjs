import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import AxeBuilder from '@axe-core/playwright'
import { measureGlyphContrast, expectGlyphContrast } from './support/build-home-glyph-contrast.mjs'
import { recordContrastBaselines, measureContrastBaselines } from './support/build-home-contrast-baselines.mjs'
import { boardAudit, canonicalBoardOverlaps, contrastRatio } from './support/build-home-a11y-audit.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'
import { expectAuditClean, openFixture, settleAnimations } from './support/browser-helpers.mjs'

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })

async function open(page, dataset = 'live', view = 'graph', mode = 'read_only') {
  await openFixture(page, mode)
  const query = view === 'graph' ? '' : '?view=' + view
  await page.goto('/build-fixture/' + dataset + query)
  await expect(page.locator(view === 'list' ? '.bd-list' : '#bd-content')).toHaveCount(1)
  await page.evaluate(async () => {
    window.a11y = await import('/build-home/a11y.js')
    window.hook = await import('/build-home/hook.js')
    window.state = await import('/build-home/state.js')
  })
}

test('overlap selectors resolve only to actual card interiors', async ({ page }) => {
  await page.setContent('<svg id="bd-edges"></svg><div class="bd-card" data-id="607">' +
    '<div class="bd-in" title="#607 · Card"><span id="inside">Text</span></div></div>' +
    '<div title="#608 · Unrelated">Text</div>')
  const input = { violations: [], incomplete: [{ id: 'color-contrast', nodes: [{ target: ['#inside'],
    any: [{ data: { messageKey: 'imgNode' }, relatedNodes: [
      { target: ['#bd-edges'] }, { target: ['div[title="#607 · Card"]'] }
    ] }], all: [], none: [] }] }] }
  const normalized = await canonicalBoardOverlaps(page, input)
  expect(normalized.incomplete[0].nodes[0].any[0].relatedNodes[1].target)
    .toEqual(['div[data-id="607"] > .bd-in'])
  expectAuditClean(boardAudit(normalized))
  expect(input.incomplete[0].nodes[0].any[0].relatedNodes[1].target).toEqual(['div[title="#607 · Card"]'])
  input.incomplete[0].nodes[0].any[0].relatedNodes[1].target = ['div[title="#608 · Unrelated"]']
  const unrelated = await canonicalBoardOverlaps(page, input)
  expect(() => expectAuditClean(boardAudit(unrelated))).toThrow()
})

test('cards expose complete names and a single roving button stop', async ({ page }) => {
  await open(page)
  const result = await page.evaluate(() => {
    const { ctx } = state
    const cards = [...document.querySelectorAll('.bd-card')]
    const current = cards.find(card => card.tabIndex === 0)
    const live = cards.find(card => card.dataset.id === ctx.D.now[0].id)
    const row = structuredClone(ctx.D.now[0])
    row.pct = null; row.cx = null; row.deps = null; row.agent = { ...row.agent, state: null }
    const pack = { ...row, id: 'pack:accessibility', num: null, title: 'Accessibility pass', deps: null }
    return {
      region: [ctx.vp.getAttribute('role'), ctx.vp.getAttribute('aria-label'), ctx.vp.tabIndex],
      stops: cards.filter(card => card.tabIndex === 0).length,
      label: live?.getAttribute('aria-label'),
      complexityNames: cards.filter(card => card.querySelector('.bd-cx')).map(card => ({
        hidden: card.querySelector('.bd-cx').getAttribute('aria-hidden'),
        label: card.getAttribute('aria-label'), cx: ctx.D.byId[card.dataset.id].cx
      })),
      unknown: a11y.cardLabel(row, { ...ctx.D, children: {} }, current),
      pack: a11y.cardLabel(pack, { ...ctx.D, children: {} }, current)
    }
  })
  expect(result.region).toEqual(['region', 'Build timeline', -1])
  expect(result.stops).toBe(1)
  expect(result.complexityNames.length).toBeGreaterThan(0)
  for (const row of result.complexityNames) {
    expect(row.hidden).toBe('true')
    expect(row.label).toContain(Number.isInteger(row.cx) && row.cx >= 1 && row.cx <= 5 ? 'Complexity ' + row.cx + ' of 5' : 'complexity unknown')
  }
  expect(result.label).toMatch(/^#\d+ .+\. Agent .+: .+\./)
  expect(result.unknown).toContain('progress unknown')
  expect(result.unknown).toContain('complexity unknown')
  expect(result.unknown).toContain('state unknown')
  expect(result.unknown).toContain('dependency count unknown')
  expect(result.unknown).toContain('unblock count unknown')
  expect(result.pack).toMatch(/^Not filed yet\. Accessibility pass\./)
})

test('arrow keys move focus and space uses the board button behavior', async ({ page }) => {
  await open(page)
  const first = page.locator('.bd-card[tabindex="0"]')
  await first.focus()
  const initial = await first.getAttribute('data-id')
  await page.keyboard.press('ArrowDown')
  const moved = await page.evaluate(() => document.activeElement.dataset.id)
  expect(moved).not.toBe(initial)
  await page.evaluate(() => { window.opened = []; state.fx.openModal = (ticket, options) => opened.push([ticket.id, options.origin.dataset.id]) })
  await page.keyboard.press(' ')
  expect(await page.evaluate(() => opened)).toEqual([[moved, moved]])
  await page.evaluate(() => {
    state.S.trees = true
    window.locks = []
    state.fx.lockTree = id => locks.push(['lock', id])
    state.fx.unlock = () => locks.push(['unlock'])
  })
  await page.keyboard.press(' ')
  await page.evaluate(id => { state.ctx.lockId = id }, moved)
  await page.keyboard.press(' ')
  expect(await page.evaluate(() => locks)).toEqual([['lock', moved], ['unlock']])
})

test('scrolling with no focused card moves the roving stop to the visible section', async ({ page }) => {
  await open(page)
  const roving = await page.evaluate(() => {
    const { ctx, fx } = state
    document.querySelector('#bd-nowbtn').focus()
    ctx.vp.scrollTop = ctx.secs.plan.el.offsetTop
    fx.update()
    const expected = a11y.readingOrder().find(item => {
      const host = item.section === 'now' ? ctx.bandEl : ctx.secs[item.section].el
      return host.offsetTop + item.y >= ctx.vp.scrollTop
    })?.t.id
    return { expected, roving: ctx.a11y.roving, stops: [...document.querySelectorAll('.bd-card[tabindex="0"]')].length }
  })
  expect(roving.roving).toBe(roving.expected)
  expect(roving.stops).toBe(1)
})

test('live rendering keeps the focused card node when its detail tier changes', async ({ page }) => {
  await open(page)
  const result = await page.evaluate(() => {
    const { ctx, fx } = state
    const card = [...ctx.R.values()].find(el => el.closest('#bd-sec-plan'))
    card.focus()
    card.classList.remove('full', 'line', 'mini', 'bar')
    card.classList.add('stale-detail')
    fx.update(true)
    return { sameNode: document.activeElement === card, stillConnected: card.isConnected }
  })
  expect(result).toEqual({ sameNode: true, stillConnected: true })
})

test('keyboard tree highlighting ends when card focus leaves the board', async ({ page }) => {
  await open(page)
  const planId = await page.evaluate(() => {
    state.S.trees = true
    state.ctx.vp.scrollTop = state.ctx.secs.plan.el.offsetTop
    state.fx.update()
    const card = [...state.ctx.R.values()].find(card => card.closest('#bd-sec-plan'))
    state.ctx.a11y.roving = card.dataset.id
    for (const rendered of state.ctx.R.values()) rendered.tabIndex = rendered === card ? 0 : -1
    return card.dataset.id
  })
  await page.locator('.bd-card[data-id="' + planId + '"]').focus()
  await page.keyboard.press('ArrowDown')
  await expect(page.locator('.bd-content')).toHaveClass(/hovering/)
  await page.locator('#bd-nowbtn').focus()
  expect(await page.locator('.bd-content').getAttribute('class')).not.toContain('hovering')
})

test('view switches retain the focused ticket when it is still visible', async ({ page }) => {
  await open(page)
  const card = page.locator('.bd-card[tabindex="0"]')
  await card.focus()
  const id = await card.getAttribute('data-id')
  await page.evaluate(() => state.fx.setView('list'))
  await expect(page.locator('.lr[data-id="' + id + '"]')).toBeFocused()
  await page.evaluate(() => state.fx.setView('graph'))
  await expect(page.locator('.bd-card[data-id="' + id + '"]')).toBeFocused()
})

test('applied agent-state diffs announce only the changed state', async ({ page }) => {
  await open(page)
  const changed = await page.evaluate(() => {
    const { ctx } = state
    const row = structuredClone(ctx.D.now[0])
    row.agent.state = 'error'
    hook.receive({ kind: 'diff', v: 1, epoch: ctx.proto.epoch, generation: ctx.proto.generation + 1, now: ctx.snap.now, upsert: [row], remove: [], set: {} })
    return '#' + row.num + ': Error, state age unknown'
  })
  await expect(page.locator('#bd-state-live')).toHaveText(changed, { timeout: 2000 })
})

test('forced colours preserve visible state', async ({ page }) => {
  await open(page)
  await page.emulateMedia({ forcedColors: 'active' })
  const card = page.locator('.bd-card').first()
  await card.evaluate(element => element.classList.add('dim', 'ag-active'))
  await card.focus()
  await expect(card).toHaveCSS('opacity', '1')
  await expect(card.locator('.bd-in')).toHaveCSS('border-style', 'solid')
  await expect(card.locator('.bd-in')).toHaveCSS('border-width', '2px')
})

test('reduced motion keeps the board operable without a moving transition', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await open(page)
  const duration = await page.locator('.bd-card').first().evaluate(card => parseFloat(getComputedStyle(card).transitionDuration))
  expect(duration).toBeLessThanOrEqual(0.00001)
  await page.locator('.bd-card[tabindex="0"]').focus()
  await page.keyboard.press('End')
  await expect(page.locator('.bd-card[tabindex="0"]')).toBeFocused()
})

for (const dataset of ['live', 'dense', 'newrepo', 'noqueue', 'offline', 'unknowns']) {
  for (const view of ['graph', 'gantt', 'list']) {
    for (const theme of ['dark', 'light']) {
      for (const mode of ['read_only', 'writable']) test(`axe: ${dataset}, ${view}, ${theme}, ${mode}`, async ({ page }) => {
        test.setTimeout(90_000)
        await open(page, dataset, view, mode)
        await page.locator('html').evaluate((html, selected) => { html.dataset.theme = selected }, theme)
        await settleAnimations(page, '#build-root')
        const audit = await new AxeBuilder({ page }).include('#bd-vp').exclude('.bd-cx[aria-hidden="true"]').analyze()
        await test.info().attach('axe-audit', { body: JSON.stringify(audit), contentType: 'application/json' })
        const cell = { dataset, view, theme, mode }
        const measurements = await measureContrastBaselines(page, audit, cell)
        const classified = recordContrastBaselines(boardAudit(await canonicalBoardOverlaps(page, audit)), cell, measurements)
        await test.info().attach('known-contrast-baseline-violations', {
          body: JSON.stringify(classified.known), contentType: 'application/json'
        })
        for (const known of classified.known) test.info().annotations.push({ type: 'known baseline violation',
          description: known.id + ': ' + known.measuredRatio + ':1; ' + known.followup })
        expectAuditClean(classified.audit)
      })
    }
  }
}

for (const theme of ['dark', 'light']) for (const palette of ['aiur', 'gruvbox']) {
  test(`future regression guard: card text token contrast, ${theme}, ${palette}`, async ({ page }) => {
    await open(page)
    const tokens = await page.locator('#build-root').evaluate((root, { theme, palette }) => {
      document.documentElement.dataset.theme = theme
      document.documentElement.dataset.palette = palette
      const styles = getComputedStyle(root)
      return Object.fromEntries(['--fg', '--muted', '--faint', '--surface'].map(name => [name, styles.getPropertyValue(name).trim()]))
    }, { theme, palette })
    // Card titles, references and status text share the opaque card surface.
    for (const name of ['--fg', '--muted', '--faint']) {
      expect(contrastRatio(tokens[name], tokens['--surface']), `${name} on --surface (${theme}, ${palette})`).toBeGreaterThanOrEqual(4.5)
    }
  })
}

const glyphBaselines = JSON.parse(readFileSync(new URL('./fixtures/build-home-glyph-contrast.json', import.meta.url), 'utf8'))
for (const theme of ['dark', 'light']) for (const palette of ['aiur', 'gruvbox']) {
  test(`future regression guard: decorative glyph contrast, ${theme}, ${palette}`, async ({ page }) => {
    await open(page)
    await page.locator('html').evaluate((html, values) => Object.assign(html.dataset, values), { theme, palette })
    await settleAnimations(page, '#build-root')
    const selectors = await page.locator('.bd-card .bd-cx').evaluateAll(glyphs => [...new Set(glyphs.map(glyph =>
      '.bd-card[data-id=' + JSON.stringify(glyph.closest('.bd-card').dataset.id) + '] .bd-cx'))])
    const baseline = glyphBaselines[theme][palette]
    const measurements = await measureGlyphContrast(page, selectors)
    expect(measurements.length).toBeGreaterThan(0)
    expectGlyphContrast(measurements, baseline)
    // A deliberately invisible glyph must fail the same arithmetic guard.
    const selector = selectors[0]
    await page.locator(selector).evaluate(glyph => {
      glyph.style.setProperty('color', getComputedStyle(glyph.closest('.bd-in')).backgroundColor, 'important')
    })
    const degraded = await measureGlyphContrast(page, [selector])
    expect(degraded[0].ratio).toBeLessThan(baseline[selector])
    expect(() => expectGlyphContrast(degraded, baseline)).toThrow()
  })
}
