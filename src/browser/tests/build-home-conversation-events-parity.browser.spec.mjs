import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { openModalPair } from '../support/build-home-modal-pair.mjs'
import { compareRegion } from '../support/build-home-region-parity.mjs'
import { PARITY_VIEWPORTS } from '../support/design-parity.mjs'

// Each event row on its own, so a drift in one kind's hue, icon or spacing names that row.
// History tickets carry dep/prog/pr/review/comment/commit/merge/fail rows; the closing row of each
// now ticket carries the cmd, error, retries, paused (you) and parked (you) states.
const snapshot = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/live.json', import.meta.url), 'utf8'))
const conversations = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/conversations/live.json', import.meta.url), 'utf8'))
const hist = [
  snapshot.sections.hist.find(t => t.status === 'failed'),
  snapshot.sections.hist.find(t => t.status === 'done' && conversations[t.id]?.some(o => o.ev === 'dep')),
]
const now = ['command', 'error', 'retries', 'paused', 'parked'].map(state => snapshot.sections.now.find(t => t.agent?.state === state))
test.setTimeout(240000)
for (const viewport of [PARITY_VIEWPORTS[0], PARITY_VIEWPORTS[2]]) for (const theme of ['dark', 'light']) for (const palette of ['aiur', 'gruvbox']) {
  test(`parity event rows ${viewport.viewport.width} ${theme} ${palette} (${[...hist, ...now].map(t => t?.id).join(',')})`, async ({ browser }) => {
    expect([...hist, ...now].every(Boolean)).toBe(true)
    const pair = await openModalPair(browser, { ...viewport, theme, palette, dataset: 'live' })
    try {
      for (const ticket of [...hist, ...now]) {
        await pair.design.evaluate(id => window.AiurBuild.open('AIUR-' + id), ticket.id)
        await pair.product.evaluate(async id => (await import('/build-home/modal/frame.js')).openById(id), ticket.id)
        const rows = conversations[ticket.id].filter(o => o.k === 'ev').length
        await expect(pair.product.locator('#cv-log > .cv-ev')).toHaveCount(rows)
        await expect(pair.design.locator('#cv-log > .cv-ev')).toHaveCount(rows)
        for (const side of ['design', 'product']) await pair[side].locator('#tk-modal').evaluate(el => el.getAnimations().forEach(a => a.finish()))
        const indexes = ticket.sec === 'now' ? [rows - 1] : [...Array(rows).keys()]
        for (const i of indexes) {
          for (const side of ['design', 'product']) await pair[side].locator('#cv-log > .cv-ev').nth(i).scrollIntoViewIfNeeded()
          await compareRegion(pair, { name: `event-row.${ticket.id}.${i}.${viewport.viewport.width}.${theme}.${palette}`, region: `#cv-log > .cv-ev >> nth=${i}` })
        }
      }
    } finally { await pair.close() }
  })
}
