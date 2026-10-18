import { test, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { readFile } from 'node:fs/promises'
import { dashboardCredentials } from './support/layout-worker.mjs'

test.use({ httpCredentials: dashboardCredentials, timezoneId: 'America/Los_Angeles', viewport: { width: 1440, height: 900 } })
test.beforeEach(async ({ page }, info) => {
  // Mutation checks serve real production assets from an isolated worktree.
  const root = info.project.metadata.agentAssets
  if (root) for (const file of ['agents.js', 'cards.js', 'home.css']) await page.route('**/build-home/' + file, async route => route.fulfill({
    body: await readFile(root + '/' + file, 'utf8'), contentType: file.endsWith('.css') ? 'text/css' : 'text/javascript',
  }))
  page.on('pageerror', error => { throw error })
})
async function open(page, dataset = 'unknowns') {
  await page.goto('/build-fixture/' + dataset)
  await expect(page.locator('#bd-content')).toHaveCount(1)
  await expect.poll(() => page.evaluate(async () => (await import('/build-home/history.js')).H.state)).toBe('idle')
}
async function draw(page, id, tier = 'full', width = 260) {
  await page.evaluate(async ({ id, tier, width }) => {
    const { ctx } = await import('/build-home/state.js'), { makeCard } = await import('/build-home/cards.js')
    document.querySelector('#agent-probe')?.remove()
    const det = ctx.L.det; ctx.L.det = tier
    const t = ctx.D.byId[id], el = makeCard({ t, sec: t.sec, h: 160 })
    ctx.L.det = det; el.id = 'agent-probe'
    Object.assign(el.style, { position: 'fixed', left: '200px', top: '180px', width: width + 'px', height: tier === 'full' ? '160px' : '32px', zIndex: '9999' })
    ctx.content.append(el)
  }, { id, tier, width })
  return page.locator('#agent-probe')
}
for (const tier of ['full', 'line', 'mini', 'bar']) test(`screen-reader state on ${tier}`, async ({ page }) => {
  await open(page)
  const card = await draw(page, '9007', tier)
  await expect(card.locator('.bd-in > .sr-only:first-child')).toHaveText('Agent muse: Running')
  const size = await card.locator('.sr-only').boundingBox()
  expect([size.width, size.height]).toEqual([1, 1])
  for (const logo of await card.locator('.bd-ag, .bd-lg').all()) await expect(logo).toHaveAttribute('aria-hidden', 'true')
  expect(await card.evaluate(el => {
    const children = [...el.querySelector('.bd-in').children].filter(el => !el.classList.contains('sr-only'))
    const positions = () => children.map(el => { const r = el.getBoundingClientRect(); return [r.x, r.y, r.width, r.height] })
    const before = positions(); el.querySelector('.sr-only').remove()
    return JSON.stringify(before) === JSON.stringify(positions())
  })).toBe(true)
})
test('narrow state remains complete and known logo is decorative', async ({ page }) => {
  await open(page, 'live')
  const id = await page.evaluate(async () => (await import('/build-home/state.js')).ctx.D.now.find(t => t.agent.state === 'retries').id)
  const card = await draw(page, id, 'full', 140)
  await expect(card.locator('.sr-only')).toHaveText('Agent Kimi: Retries exhausted')
  await expect(card.locator('.bd-ag')).toHaveAttribute('aria-hidden', 'true')
  await expect(card.locator('.bd-ag img')).toHaveAttribute('alt', '')
  expect(await card.locator('.bd-status > span').first().evaluate(el => el.scrollWidth > el.clientWidth)).toBe(true)
})
test('fallback circles fill full and line slots', async ({ page }) => {
  await open(page)
  for (const [id, letter] of [['9007', 'M'], ['9014', 'Z'], ['9015', 'O'], ['9016', '?']]) {
    const card = await draw(page, id)
    await expect(card.locator('.bd-ag > .ax-mono')).toHaveText(letter)
    await expect(card.locator('.bd-ag img')).toHaveCount(0)
    expect(await card.locator('.bd-ag').evaluate(el => Math.max(Math.abs(el.clientWidth - el.firstElementChild.getBoundingClientRect().width), Math.abs(el.clientHeight - el.firstElementChild.getBoundingClientRect().height)))).toBeLessThanOrEqual(.5)
    if (id === '9015') {
      await expect(card.locator('.sr-only')).toHaveText('Agent openrouter')
      expect(await card.locator('.bd-ag').evaluate(el => getComputedStyle(el).filter)).toBe('grayscale(1)')
    } else {
      await draw(page, id, 'line')
      await expect(card.locator('.bd-lg.ax-mono')).toHaveText(letter)
      expect(await card.evaluate(el => Math.abs(el.querySelector('.bd-lg').getBoundingClientRect().width - parseFloat(getComputedStyle(el).fontSize) * 1.05))).toBeLessThanOrEqual(.5)
    }
  }
  await draw(page, '9014'); await page.locator('#agent-probe').screenshot({ path: test.info().outputPath('S-13-letter-circle.png') })
})
test('unknown state and absent agent on every tier', async ({ page }) => {
  await open(page)
  for (const id of ['9008', '9009']) for (const tier of ['full', 'line', 'mini', 'bar']) {
    const card = await draw(page, id, tier)
    await expect(card).not.toHaveClass(/ag-/); await expect(card.locator('.bd-glow')).toHaveCount(0)
    await expect(card.locator('.sr-only')).toHaveText(id === '9008' ? 'Agent Claude: state unknown' : 'Agent: state unknown')
    if (tier === 'full') await expect(card.locator('[data-unknown="state"]')).toHaveText('State unknown')
    if (id === '9009' && tier === 'line') await expect(card.locator('.ax-mono')).toHaveText('?')
  }
  await draw(page, '9008'); await page.locator('#agent-probe').screenshot({ path: test.info().outputPath('unknown-state.png') })
})
test('offline age and unavailable ages', async ({ page }) => {
  await open(page, 'offline')
  const id = await page.evaluate(async () => (await import('/build-home/state.js')).ctx.D.now[0].id)
  await draw(page, id); await expect(page.locator('#agent-probe .sr-only')).toHaveText(/, as of 14:14$/)
  expect(await page.evaluate(async () => {
    const { agentText } = await import('/build-home/agents.js')
    const t = { sec: 'now', agent: { model: 'claude', state: 'active' } }
    const read = (daemon, agents = { state: 'ok' }) => agentText(t, { daemon, sources: { agents } })
    return [read({ state: 'offline', heartbeat_at: null }, { state: 'stale', observed_at: 1791407400000 }),
      read({ state: 'unknown' }), read({ state: 'live' }, { state: 'stale', observed_at: 1791407400000 }),
      read({ state: 'live' }, { state: 'unavailable', observed_at: null }), read({ state: 'live' })]
  })).toEqual(['Agent Claude: Running, state age unknown', 'Agent Claude: Running, state age unknown',
    'Agent Claude: Running, as of 14:10', 'Agent Claude: Running, state age unknown', 'Agent Claude: Running'])
})
test('pure helpers protect unknown keys and escape payload names', async ({ page }) => {
  await open(page)
  expect(await page.evaluate(async () => {
    const a = await import('/build-home/agents.js'), { UNKNOWN_STATE } = await import('/build-home/now-state.js')
    const t = { sec: 'now', agent: { model: 'claude', name: 'a"b<i>', state: 'active' } }
    const slot = document.createElement('div'); slot.innerHTML = a.logoHTML(t, 'full')
    return { unknown: [null, 'zz', 'constructor', '__proto__'].map(state => a.rowState({ sec: 'now', agent: { state } }) === UNKNOWN_STATE),
      absent: a.rowState({ sec: 'now', agent: null }) === UNKNOWN_STATE, history: a.rowState({ sec: 'hist', agent: t.agent }),
      empty: a.agentText({ sec: 'plan', agent: null }, {}), models: [null, '', 'constructor'].map(a.modelInfo),
      title: slot.firstElementChild.title, injection: slot.querySelectorAll('i').length, html: a.logoHTML(t, 'full') }
  })).toEqual({ unknown: [true, true, true, true], absent: true, history: null, empty: null,
    models: [{ name: 'Model unknown', logo: null, mono: '?' }, { name: 'Model unknown', logo: null, mono: '?' }, { name: 'constructor', logo: null, mono: 'C' }],
    title: 'a"b<i> · Running', injection: 0,
    html: '<span class="bd-ag" title="a&quot;b&lt;i&gt; · Running" aria-hidden="true"><img src="/provider-assets/claude-symbol.svg" alt=""></span>' })
})
test('payload names reach rebuilt accessible cards through the store', async ({ page }) => {
  await open(page, 'live')
  const id = await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { acceptSnapshot } = await import('/build-home/store.js')
    const snap = structuredClone(ctx.snap), t = snap.sections.now.find(t => t.agent.model === 'claude')
    t.agent.name = 'Claude Opus 4.1'
    if (acceptSnapshot(snap).error) throw new Error('snapshot rejected')
    return t.id
  })
  const card = await draw(page, id)
  await expect(card.locator('.bd-ag')).toHaveAttribute('title', 'Claude Opus 4.1 · Running')
  await expect(card.locator('.sr-only')).toHaveText('Agent Claude Opus 4.1: Running')
  expect((await new AxeBuilder({ page }).include('#agent-probe').analyze()).violations).toEqual([])
})

// These are regression guards for the existing design classes and animation cascade.
for (const theme of ['dark', 'light']) test(`design indicator regression guard in ${theme}`, async ({ page }) => {
  await open(page, 'live'); await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme)
  const rows = await page.evaluate(async () => (await import('/build-home/state.js')).ctx.D.now.map(t => ({ id: t.id, state: t.agent.state, model: t.agent.model })))
  for (const row of rows) {
    const cls = row.state === 'active' ? 'active' : ['paused', 'parked'].includes(row.state) ? 'idle' : 'stuck'
    const card = await draw(page, row.id)
    expect(await card.evaluate(el => [...el.classList].filter(c => c.startsWith('ag-')))).toEqual(['ag-' + cls])
    await expect(card.locator(':scope > .bd-glow:first-child')).toHaveCount(1)
    await expect(card.locator('.bd-ag')).toHaveClass(['kimi', 'deepseek'].includes(row.model) ? 'bd-ag fill' : 'bd-ag')
    const styles = await card.evaluate(el => {
      const glow = getComputedStyle(el.querySelector('.bd-glow')), logo = getComputedStyle(el.querySelector('.bd-ag'))
      return { glow: glow.animationName, duration: glow.animationDuration, logo: logo.animationName, pulse: logo.animationDuration, opacity: glow.opacity }
    })
    expect(styles.glow).toBe(cls === 'active' ? 'bdRot' : 'none')
    expect(styles.logo).toBe(cls === 'active' ? 'bdAg' : 'none')
    if (cls === 'active') { expect(styles.duration).toBe('9s'); expect(styles.pulse).toBe('3.6s') }
    if (cls === 'idle') expect(styles.opacity).toBe('0')
  }
})
test('reduced motion regression guard', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' }); await open(page, 'live')
  await expect(page.locator('#build-root')).toHaveClass(/\brm\b/)
  const id = await page.evaluate(async () => (await import('/build-home/state.js')).ctx.D.now.find(t => t.agent.state === 'active').id)
  const card = await draw(page, id)
  expect(await card.evaluate(el => ['.bd-glow', '.bd-ag'].map(sel => getComputedStyle(el.querySelector(sel)).animationName))).toEqual(['none', 'none'])
  expect(await card.locator('.bd-glow').evaluate(el => getComputedStyle(el).backgroundImage)).toBe('none')
})
test('state changes rebuild indicators without retained classes', async ({ page }) => {
  await open(page, 'live')
  const id = await page.evaluate(async () => (await import('/build-home/state.js')).ctx.D.now.find(t => t.agent.state === 'active').id)
  const card = await draw(page, id)
  for (const [state, cls, text] of [['error', 'stuck', 'Error'], ['paused', 'idle', 'Paused']]) {
    await page.evaluate(async ({ id, state }) => {
      const { ctx } = await import('/build-home/state.js'), { applyDiff } = await import('/build-home/store.js')
      const { refreshTicket } = await import('/build-home/cards.js'), el = document.querySelector('#agent-probe'), it = el._it
      const t = structuredClone(ctx.D.byId[id]); t.agent.state = state
      if (applyDiff({ now: ctx.snap.now, generation: ctx.snap.generation + 1, remove: [], upsert: [t], set: {} }).error) throw new Error('diff rejected')
      it.el = el; it.key = 'agent-probe'; it.y = 20; ctx.L.band.items = [it]; ctx.bandMap[it.key] = { x: 200, w: 260 }
      refreshTicket(id); it.el.id = 'agent-probe'
      if (el.isConnected) throw new Error('old card survived refresh')
    }, { id, state })
    expect(await card.evaluate(el => [...el.classList].filter(c => c.startsWith('ag-')))).toEqual(['ag-' + cls])
    await expect(card.locator('.sr-only')).toContainText(': ' + text)
  }
})

// Relayout rebuilds a moved row; agent helpers must not carry now-state into history.
test('history transition removes state and keeps the accessible identity', async ({ page }) => {
  await open(page, 'live')
  const id = await page.evaluate(async () => {
    const { ctx } = await import('/build-home/state.js'), { applyDiff } = await import('/build-home/store.js')
    const t = structuredClone(ctx.D.now[0]); t.sec = 'hist'; t.status = 'done'; t.end = ctx.snap.now; t.agent.state = null
    if (applyDiff({ now: ctx.snap.now, generation: ctx.snap.generation + 1, remove: [], upsert: [t], set: {} }).error) throw new Error('history diff rejected')
    return t.id
  })
  const card = await draw(page, id)
  await expect(card).not.toHaveClass(/ag-/); await expect(card.locator('.bd-glow')).toHaveCount(0)
  await expect(card.locator('.bd-ag')).toHaveCount(1)
  await expect(card.locator('.sr-only')).toHaveText('Agent Claude')
})
