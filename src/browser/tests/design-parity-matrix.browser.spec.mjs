import { test } from '@playwright/test'
import { PARITY_MATRIX, openParityPair, expectDesignParity, capturePairEvidence } from '../support/design-parity.mjs'

for (const cell of PARITY_MATRIX) {
  const name = `${cell.dataset}-${cell.viewport.width}-${cell.theme}-${cell.palette}-${cell.reducedMotion ?? 'normal'}`
  test(name, async ({ browser }) => {
    const pair = await openParityPair(browser, cell)
    try {
      await capturePairEvidence(pair)
      await expectDesignParity(pair, { name })
    } finally { await pair.close() }
  })
}

// C9-T03 enables these captures after the timeline render window lands.
for (const region of ['sec-hist', 'sec-plan', 'sec-nq']) {
  test.fixme(region, async ({ browser }) => {
    const pair = await openParityPair(browser, PARITY_MATRIX[0])
    try { await expectDesignParity(pair, { name: region, region: '#bd-' + region }) }
    finally { await pair.close() }
  })
}
