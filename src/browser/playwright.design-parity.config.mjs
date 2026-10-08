import config from './playwright.config.mjs'
import path from 'node:path'

export default {
  ...config,
  snapshotDir: path.join(config.outputDir, 'design-baselines'),
  snapshotPathTemplate: '{snapshotDir}/{testFilePath}/{arg}{ext}',
  expect: { ...config.expect, toHaveScreenshot: { animations: 'disabled', caret: 'hide', threshold: 0 } }
}
