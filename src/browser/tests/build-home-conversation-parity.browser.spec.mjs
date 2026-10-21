import { test, expect } from '@playwright/test'
import { readFile } from 'node:fs/promises'
import { openModalPair } from '../support/build-home-modal-pair.mjs'
import { compareRegion } from '../support/build-home-region-parity.mjs'
import { PARITY_VIEWPORTS } from '../support/design-parity.mjs'

const snapshot = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/live.json', import.meta.url), 'utf8'))
const conversations = JSON.parse(await readFile(new URL('../../test/fixtures/build_home/conversations/live.json', import.meta.url), 'utf8'))
const tickets = [
  snapshot.sections.hist.find(t => t.status === 'done' && conversations[t.id]?.some(o => o.ev === 'dep')),
  snapshot.sections.hist.find(t => t.status === 'failed'),
  snapshot.sections.hist.find(t => conversations[t.id]?.some(o => o.k === 'diff') && conversations[t.id]?.some(o => o.k === 'tool' && o.bad)),
]
// Three history conversations per cell avoid the design's mock active-stream controls.
test.setTimeout(180000)
for (const viewport of [PARITY_VIEWPORTS[0], PARITY_VIEWPORTS[2]]) for (const theme of ['dark', 'light']) for (const palette of ['aiur', 'gruvbox']) {
  test(`parity conversation ${viewport.viewport.width} ${theme} ${palette}`, async ({ browser }) => {
    expect(tickets.every(Boolean)).toBe(true)
    const pair = await openModalPair(browser, { ...viewport, theme, palette, dataset: 'live' })
    try {
      for (const ticket of tickets) {
        await pair.design.evaluate(id => window.AiurBuild.open('AIUR-' + id), ticket.id)
        await pair.product.evaluate(async id => (await import('/build-home/modal/frame.js')).openById(id), ticket.id)
        await expect(pair.product.locator('#cv-log [data-k]')).toHaveCount(conversations[ticket.id].length)
        for (const side of ['design', 'product']) await pair[side].locator('#tk-modal').evaluate(el => el.getAnimations().forEach(a => a.finish()))
        const census = async page => page.locator('#cv-log').evaluate(log => ({
          kinds: Object.fromEntries(['sys', 'say', 'op', 'tool', 'diff', 'ev'].map(k => [k, log.querySelectorAll('[data-k=' + k + ']').length])),
          bottom: Math.abs(log.scrollTop + log.clientHeight - log.scrollHeight) <= 1,
        }))
        await expect.poll(async () => (await census(pair.product)).bottom).toBe(true)
        await expect.poll(async () => (await census(pair.design)).bottom).toBe(true)
        const product = await census(pair.product), design = await census(pair.design)
        expect(product.kinds).toEqual(design.kinds); expect(product.bottom).toBe(true); expect(design.bottom).toBe(true)
        for (const side of ['design', 'product']) await pair[side].locator('.cv-main').evaluate(el => { el.style.height = el.getBoundingClientRect().height + 'px' })
        await compareRegion(pair, { name: `conversation.${ticket.id}.${viewport.viewport.width}.${theme}.${palette}`, region: '.cv-main' })
      }
    } finally { await pair.close() }
  })
}
