import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { HOME_MATRIX, BASE } from '../support/home-css-states.mjs'
import { transplant, compareStyles, styleSnapshot } from '../support/home-css-parity.mjs'
import { DEAD } from '../support/home-css-census.mjs'
import { expectDesignParity } from '../support/design-parity.mjs'
import { openFixture } from './support/browser-helpers.mjs'
import { dashboardCredentials } from './support/layout-worker.mjs'

for (const cell of HOME_MATRIX) test(`computed styles match the design: ${cell.name}`, async ({ browser }) => {
  test.setTimeout(60_000)
  const pair = await transplant(browser, cell)
  try { await compareStyles(pair) } finally { await pair.close() }
})

test('keyframes and @property match', async ({ browser }) => {
  const pair = await transplant(browser, BASE)
  const atRules = () => {
    const result = []
    const walk = rules => [...rules].forEach(r => {
      if (r.type === CSSRule.KEYFRAMES_RULE || r.constructor.name === 'CSSPropertyRule') result.push(r.cssText)
      else if (r.cssRules) walk(r.cssRules)
    })
    for (const sheet of [...document.styleSheets].filter(s => !s.href || new URL(s.href).origin === location.origin)) walk(sheet.cssRules)
    return result.filter(s => /(?:bdPulse|bdRot|bdStuck|bdAg|cvIn|cvFlash|cvDot|cvRec|bdTreeIn|khSpin|tkin|--bd-a)\b/.test(s)).sort()
  }
  try { expect(await pair.product.evaluate(atRules)).toEqual(await pair.design.evaluate(atRules)) } finally { await pair.close() }
})

test('dead classes are absent', async ({ browser }) => {
  const pair = await transplant(browser, BASE)
  try {
    const selectors = await pair.product.evaluate(() => {
      const result = []
      const walk = rules => [...rules].forEach(r => { if (r.selectorText) result.push(r.selectorText); else if (r.cssRules && r.type !== CSSRule.KEYFRAMES_RULE) walk(r.cssRules) })
      walk([...document.styleSheets].find(s => s.href?.endsWith('/build-home/home.css')).cssRules)
      return result
    })
    expect(selectors.filter(s => DEAD.test(s))).toEqual([])
  } finally { await pair.close() }
})

test('design fallbacks are kept', async () => {
  const css = await readFile(new URL('../../priv/static/build-home/home.css', import.meta.url), 'utf8')
  for (const [pattern, count] of [[/var\(--ph, 60\)/g, 12], [/var\(--ph, 90\)/g, 1], [/var\(--pct, 0%\)/g, 24]]) expect([...css.matchAll(pattern)]).toHaveLength(count)
})

for (const interaction of ['command', undefined]) test(`product rules do not leak into home elements: ${interaction ?? 'offline'}`, async ({ browser }) => {
  const pair = await transplant(browser, { ...BASE, dataset: interaction ? 'live' : 'offline', interaction })
  try {
    expect(await pair.design.locator('.btn').count()).toBeGreaterThan(0)
    await compareStyles(pair, '.bd-root .btn, .tk-backdrop .btn, .bd-root .mono, .tk-backdrop .mono, .bd-root a, .tk-backdrop a')
  } finally { await pair.close() }
})

for (const region of ['.bd-vpw', '.bd-now', '.tk-modal', '.ax-usage']) test(`element pixels match: ${region}`, async ({ browser }) => {
  const pair = await transplant(browser, { ...BASE, interaction: region === '.tk-modal' ? 'command' : undefined })
  try { await expectDesignParity(pair, { name: `home-${region.slice(1)}`, region }) } finally { await pair.close() }
})

test('other pages are unchanged', async ({ page }) => {
  test.setTimeout(120_000)
  let buttons = 0
  let anchors = 0
  for (const route of ['/', '/commands', '/units', '/ticket-context', '/provider-meters', '/meter-row', '/quota-panel', '/fixture']) {
    const snapshots = []
    for (const empty of [true, false]) {
      if (empty) await page.route('**/build-home/home.css', r => r.fulfill({ contentType: 'text/css', body: '' }))
      else await page.unroute('**/build-home/home.css')
      await openFixture(page, 'writable')
      await page.context().setHTTPCredentials(dashboardCredentials)
      await page.addInitScript(() => { localStorage.setItem('aiur-theme', 'dark'); localStorage.setItem('aiur-palette', 'gruvbox') })
      await page.goto(route)
      await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1)
      if (route === '/units') {
        await page.getByRole('button', { name: 'Select no filters' }).click()
        await expect(page.getByRole('button', { name: 'Reset Units filters' })).toBeVisible()
      }
      await page.evaluate(() => document.fonts.ready)
      await page.evaluate(() => { document.getAnimations().forEach(a => { a.pause(); a.currentTime = 0 }) })
      snapshots.push((await page.evaluate(styleSnapshot, { roots: 'body', reduced: false })).map(({ tag, styles }) => ({ tag, styles })))
    }
    expect(snapshots[1], `stylesheet affected ${route}`).toEqual(snapshots[0])
    buttons += await page.locator('.btn').count()
    anchors += await page.locator('a').count()
  }
  expect(buttons, 'T-8 has no button target').toBeGreaterThan(0)
  expect(anchors, 'T-8 has no anchor target').toBeGreaterThan(0)
})

for (const theme of ['dark', 'light']) for (const palette of ['aiur', 'gruvbox']) test(`white-on-fill contrast evidence: ${theme}/${palette}`, async ({ browser }) => {
  const pair = await transplant(browser, { ...BASE, theme, palette, interaction: 'command', query: 'models=7' })
  try {
    const measurements = await pair.product.evaluate(() => {
      const canvas = document.createElement('canvas')
      canvas.width = canvas.height = 1
      const ctx = canvas.getContext('2d')
      const rgb = color => { ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = color; ctx.fillRect(0, 0, 1, 1); return [...ctx.getImageData(0, 0, 1, 1).data].slice(0, 3) }
      const luminance = color => rgb(color).map(v => v / 255).map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4).reduce((sum, v, i) => sum + v * [.2126, .7152, .0722][i], 0)
      return ['.btn.sm:not(.secondary)', '.cv-new', '.cv-send', '.ax-mono'].map(selector => {
        const element = document.querySelector(selector)
        if (!element) throw Error(`contrast target missing: ${selector}`)
        const style = getComputedStyle(element)
        const ink = luminance(style.color), fill = luminance(style.backgroundColor)
        return { selector, ink: style.color, fill: style.backgroundColor, ratio: (Math.max(ink, fill) + .05) / (Math.min(ink, fill) + .05) }
      })
    })
    await test.info().attach('white-on-fill-contrast.json', { body: JSON.stringify(measurements, null, 2), contentType: 'application/json' })
    for (const m of measurements) { expect(m.ink).toBe('rgb(255, 255, 255)'); expect(m.ratio).toBeGreaterThan(1) }
  } finally { await pair.close() }
})

for (const theme of ['dark', 'light']) test(`hover styles match the design: ${theme}`, async ({ browser }) => {
  test.setTimeout(240_000)
  const { census, ownsBuildLine } = await import('../support/home-css-census.mjs')
  const covered = new Set()
  for (const state of [{}, { query: 'view=list' }, { interaction: 'command' }, { interaction: 'nq' }, { interaction: 'filter' }, { interaction: 'usage' }, { interaction: 'tree' }]) {
    const pair = await transplant(browser, { ...BASE, theme, ...state })
    try {
      const rules = (await census(pair.design)).filter(r => r.selector && (r.source !== 'C' || ownsBuildLine(r.line)))
      for (const r of rules) for (const m of r.matches) {
        if (!m.count || !m.selector.includes(':hover') || DEAD.test(m.selector)) continue
        const key = `${r.source}:${r.line}:${m.selector}`
        if (covered.has(key)) continue
        const target = m.selector.replace(/::[\w-]+|:hover/g, '')
        const candidates = pair.design.locator(target)
        for (let i = 0; i < await candidates.count(); i++) {
          if (!await candidates.nth(i).isVisible()) continue
          for (const page of [pair.design, pair.product]) await page.locator(target).nth(i).hover({ force: true })
          // Finish hover transitions at the same endpoint; keep declared timings observable.
          for (const page of [pair.design, pair.product]) await page.evaluate(() => document.getAnimations().forEach(a => { if (a instanceof CSSTransition) a.finish() }))
          await compareStyles(pair, target, i)
          covered.add(key)
          break
        }
      }
    } finally { await pair.close() }
  }
  expect(covered.size, 'hover exercise had no targets').toBeGreaterThan(10)
  await test.info().attach('hover-coverage.json', { body: JSON.stringify([...covered], null, 2), contentType: 'application/json' })
})


test('home base utilities keep the design font stack', async ({ browser }) => {
  const pair = await transplant(browser, BASE)
  try {
    for (const page of [pair.design, pair.product]) await page.locator('#build-root').evaluate(root => {
      const sample = document.createElement('span')
      sample.className = 'mono num'
      sample.textContent = '0123456789'
      root.append(sample)
    })
    // .num is a future regression guard; its values already agree on main.
    await compareStyles(pair, '#build-root > .mono.num')
  } finally { await pair.close() }
})
