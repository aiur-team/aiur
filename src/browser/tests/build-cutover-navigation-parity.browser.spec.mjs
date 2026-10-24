import { test } from '@playwright/test'
import { PARITY_MATRIX, expectDesignParity, capturePairEvidence } from '../support/design-parity.mjs'
import { openCutoverParityPair } from '../support/cutover-parity.mjs'

test.setTimeout(90_000)

// Gate responsive CSS separately from the deferred real phone/WebView proof.
const cells = PARITY_MATRIX.filter(cell => cell.dataset === 'live')
  .map(cell => cell.isMobile ? { ...cell, isMobile: false } : cell)

for (const cell of cells) {
  const name = `${cell.dataset}-${cell.viewport.width}-${cell.theme}-${cell.palette}-${cell.reducedMotion ?? 'normal'}${cell.hasTouch ? '-narrow-touch-css' : ''}`
  test(name, async ({ browser }) => {
    const pair = await openCutoverParityPair(browser, cell)
    try {
      await capturePairEvidence(pair)
      await expectDesignParity(pair, { name, region: 'aside.sidenav', clipToViewport: true })
    } finally { await pair.close() }
  })
}
