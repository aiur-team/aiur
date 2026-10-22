import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { openModalPair } from '../support/build-home-modal-pair.mjs'
import { compareRegion } from '../support/build-home-region-parity.mjs'
import { PARITY_VIEWPORTS } from '../support/design-parity.mjs'

// One event row at a time, so a drift in one kind's hue, icon or spacing names that kind. Each kind is
// compared once per cell: history tickets carry dep/prog/pr/review/comment/commit/merge/fail rows, and the
// closing row of each now ticket carries the cmd, error, retries, paused (you) and parked (you) states.
// The whole conversation (.cv-main) is also compared in build-home-conversation-parity.
const snapshot = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/live.json', import.meta.url), 'utf8'))
const conversations = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/conversations/live.json', import.meta.url), 'utf8'))
const hist = [
  snapshot.sections.hist.find(t => t.status === 'failed'),
  snapshot.sections.hist.find(t => t.status === 'done' && conversations[t.id]?.some(o => o.ev === 'dep')),
]
const now = ['command', 'error', 'retries', 'paused', 'parked'].map(state => snapshot.sections.now.find(t => t.agent?.state === state))
test.setTimeout(360000)
const cells = [[0, 'dark', 'aiur'], [0, 'light', 'gruvbox'], [2, 'dark', 'gruvbox'], [2, 'light', 'aiur']]
for (const [v, theme, palette] of cells) {
  const viewport = PARITY_VIEWPORTS[v]
  test(`parity event rows ${viewport.viewport.width} ${theme} ${palette} (${[...hist, ...now].map(t => t?.id).join(',')})`, async ({ browser }) => {
    expect([...hist, ...now].every(Boolean)).toBe(true)
    const pair = await openModalPair(browser, { ...viewport, theme, palette, dataset: 'live' })
    try {
      const seen = new Set()
      for (const ticket of [...hist, ...now]) {
        await pair.design.evaluate(id => window.AiurBuild.open('AIUR-' + id), ticket.id)
        await pair.product.evaluate(async id => (await import('/build-home/modal/frame.js')).openById(id), ticket.id)
        const rows = conversations[ticket.id].filter(o => o.k === 'ev').length
        await expect(pair.product.locator('#cv-log > .cv-ev')).toHaveCount(rows)
        await expect(pair.design.locator('#cv-log > .cv-ev')).toHaveCount(rows)
        for (const side of ['design', 'product']) await pair[side].locator('#tk-modal').evaluate(el => el.getAnimations().forEach(a => a.finish()))
        const evs = conversations[ticket.id].filter(o => o.k === 'ev')
        const indexes = ticket.sec === 'now' ? [rows - 1] : evs.flatMap((o, i) => seen.has(o.ev) ? [] : (seen.add(o.ev), [i]))
        for (const i of indexes) {
          for (const side of ['design', 'product']) await pair[side].locator('#cv-log > .cv-ev').nth(i).scrollIntoViewIfNeeded()
          await compareRegion(pair, { name: `event-row.${ticket.id}.${i}.${viewport.viewport.width}.${theme}.${palette}`, region: `#cv-log > .cv-ev >> nth=${i}` })
        }
      }
    } finally { await pair.close() }
  })
}
