import config from './playwright.config.mjs'
import path from 'node:path'
import { PARITY_THRESHOLD } from './support/design-parity.mjs'

export default {
  ...config,
  snapshotDir: path.join(config.outputDir, 'design-baselines'),
  snapshotPathTemplate: '{snapshotDir}/{testFilePath}/{arg}{ext}',
  expect: { ...config.expect, toHaveScreenshot: { animations: 'disabled', caret: 'hide', threshold: PARITY_THRESHOLD, maxDiffPixels: 0 } }
}
