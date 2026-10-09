import { expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { FIXTURE_META, openDesign } from './design-parity.mjs'

const live = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/live.json', import.meta.url), 'utf8')).data
export const BASE = { dataset: 'live', theme: 'dark', palette: 'gruvbox', viewport: { width: 1440, height: 900 } }
const feature = Object.keys(live.features)[0]
const epic = live.now.find(t => t.epic)?.epic
export const HOME_MATRIX = FIXTURE_META.datasets.flatMap(dataset => ['graph', 'gantt', 'list'].flatMap(view => ['dark', 'light'].flatMap(theme => ['gruvbox', 'aiur'].map(palette => ({ ...BASE, dataset, theme, palette, query: `view=${view}`, name: `${dataset}-${view}-${theme}-${palette}` })))))
for (const width of [1440, 1024, 390]) for (const query of ['live=min', 'trees=1', 'models=2', 'models=7', 'span=1', 'span=7', 'span=30', `feature=${feature}&fmode=focus`, `feature=${feature}&fmode=compact`, `epic=${epic}`]) HOME_MATRIX.push({ ...BASE, viewport: { width, height: 900 }, query, name: `${width}-${query}` })
for (const width of [1181, 1180, 721, 720]) for (const interaction of [undefined, 'modal']) HOME_MATRIX.push({ ...BASE, viewport: { width, height: 900 }, interaction, name: `boundary-${width}-${interaction ?? 'graph'}` })
for (const interaction of ['modal', 'command', 'nq', 'filter', 'lock', 'tree', 'usage', 'loading']) HOME_MATRIX.push({ ...BASE, interaction, name: interaction })
HOME_MATRIX.push({ ...BASE, viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, name: 'touch' })
for (const view of ['graph', 'gantt', 'list']) for (const theme of ['dark', 'light']) for (const palette of ['gruvbox', 'aiur']) HOME_MATRIX.push({ ...BASE, theme, palette, query: `view=${view}`, reducedMotion: 'reduce', name: `reduce-${view}-${theme}-${palette}` })

export async function openHomeState(page, cell) {
  let query = cell.query ?? ''
  if (cell.interaction === 'command') query += `&ticket=${live.now.find(t => t.agent?.state === 'command').id}`
  if (cell.interaction === 'nq') query += '&view=list'
  if (cell.interaction === 'lock' || cell.interaction === 'tree') query += '&trees=1'
  await openDesign(page, cell, { query, phase: cell.interaction === 'loading' ? 'loading' : query.includes('view=list') ? 'shell' : 'board' })
  if (query.includes('view=list')) {
    await expect(page.locator('.bd-loading')).toHaveCount(0)
    await expect(page.locator('.lr-h')).toBeAttached()
  }
  if (cell.interaction === 'modal') {
    // Active agents run mock streaming timers; use a non-streaming now card.
    await page.locator('.bd-card.now:not(.ag-active)').first().click({ force: true })
  }
  if (cell.interaction === 'nq') await page.locator('.lr.nq').first().click({ force: true })
  if (cell.interaction === 'filter') await page.locator('.bd-fg').first().click()
  if (cell.interaction === 'usage') await page.locator('.ax-seg').first().click()
  if (cell.interaction === 'lock' || cell.interaction === 'tree') {
    await page.locator('.bd-card.plan').first().hover({ force: true })
    await page.locator('.bd-lt [data-lt="lock"]').click({ force: true })
    if (cell.interaction === 'tree') await page.locator('.bd-lt [data-lt="tree"]').click()
  }
  if (['modal', 'command', 'nq'].includes(cell.interaction)) await expect(page.locator('.tk-backdrop')).toHaveClass(/show/)
  if (cell.interaction === 'command') await expect(page.locator('.cv-cmd')).toBeVisible()
  if (cell.interaction === 'filter') await expect(page.locator('.bd-pop')).toBeVisible()
  if (cell.interaction === 'usage') await expect(page.locator('body > .ax-pop')).toBeVisible()
  if (cell.interaction === 'lock') await expect(page.locator('.bd-lt')).toHaveClass(/locked/)
  if (cell.interaction === 'tree') await expect(page.locator('#bd-tree')).toBeVisible()
  await page.locator('.bd-fd').evaluateAll(nodes => nodes.forEach(e => e.remove()))
  await page.evaluate(() => { document.getAnimations().forEach(a => { a.pause(); a.currentTime = 0 }) })
}
