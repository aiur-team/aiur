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
