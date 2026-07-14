import { expect, test } from '@playwright/test'
import { sanitizeDiagnostic, syntheticFixtureEnvironment } from '../scripts/artifact-sanitizer.mjs'
import playwrightConfig from '../playwright.config.mjs'
import { assertMeasurementBudget } from './support/measurements.mjs'

test('diagnostic sanitization preserves only synthetic fixture settings', () => {
  const environment = {
    AIUR_BROWSER_PORT: '43123',
    AIUR_DASHBOARD_PASSWORD: 'must-not-leak',
    GITHUB_TOKEN: 'must-not-leak-either'
  }

  expect(syntheticFixtureEnvironment(environment)).toEqual({ AIUR_BROWSER_PORT: '43123', AIUR_BROWSER_FIXTURE_MODE: 'synthetic' })
  expect(sanitizeDiagnostic('authorization: Bearer must-not-leak', environment)).toContain('[REDACTED]')
  expect(sanitizeDiagnostic('authorization: Bearer must-not-leak', environment)).not.toContain('must-not-leak')
})

test('every post-warmup measurement sample participates in the budget', () => {
  expect(() => assertMeasurementBudget({ samples: [1, 999, 1] }, { maxSampleMs: 10 })).toThrow(/999/)
  expect(() => assertMeasurementBudget({ samples: [] }, { maxSampleMs: 10 })).toThrow(/post-warmup/)
})

test('browser failures are not retried and have an explicit timeout', () => {
  expect(playwrightConfig.retries).toBe(0)
  expect(playwrightConfig.timeout).toBe(30_000)
})
