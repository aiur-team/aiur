import { mkdtemp, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { expect, test } from '@playwright/test'
import { browserChildEnvironment, sanitizeDiagnostic, syntheticFixtureEnvironment } from '../scripts/artifact-sanitizer.mjs'
import playwrightConfig from '../playwright.config.mjs'
import { createArtifactRoot } from '../scripts/run-browser-tests.mjs'
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

test('browser child environment excludes parent secrets and only run-owned artifact children are cleaned', async () => {
  const environment = browserChildEnvironment({
    AIUR_BROWSER_PORT: '43123',
    AIUR_BROWSER_SENTINEL: 'fixture-secret-that-must-not-leak',
    GITHUB_TOKEN: 'must-not-leak',
    PATH: process.env.PATH
  })
  const parent = await mkdtemp(path.join(tmpdir(), 'aiur-browser-artifact-parent-'))

  try {
    const child = await createArtifactRoot({ AIUR_BROWSER_ARTIFACT_DIR: parent })

    expect(environment).not.toHaveProperty('AIUR_BROWSER_SENTINEL')
    expect(environment).not.toHaveProperty('GITHUB_TOKEN')
    expect(path.dirname(child)).toBe(parent)
    await rm(child, { recursive: true, force: true })
    await expect(stat(parent)).resolves.toBeDefined()
  } finally {
    await rm(parent, { recursive: true, force: true })
  }
})

test('every post-warmup measurement dimension participates in the budget', () => {
  expect(() => assertMeasurementBudget({ samples: [{ layoutLatencyMs: 1, mainThreadMs: 1, coalescedUpdates: 0 }, { layoutLatencyMs: 999, mainThreadMs: 1, coalescedUpdates: 0 }] }, { maxLayoutLatencyMs: 10 })).toThrow(/999/)
  expect(() => assertMeasurementBudget({ samples: [{ layoutLatencyMs: 1, mainThreadMs: 999, coalescedUpdates: 0 }] }, { maxMainThreadMs: 10 })).toThrow(/999/)
  expect(() => assertMeasurementBudget({ samples: [{ layoutLatencyMs: 1, mainThreadMs: 1, coalescedUpdates: 2 }] }, { maxCoalescedUpdates: 1 })).toThrow(/coalesced/)
  expect(() => assertMeasurementBudget({ samples: [{ layoutLatencyMs: 1, mainThreadMs: 1, coalescedUpdates: 0 }], longTasks: [999] }, { maxLongTaskMs: 10 })).toThrow(/long task/)
  expect(() => assertMeasurementBudget({ samples: [] }, { maxSampleMs: 10 })).toThrow(/post-warmup/)
})

test('browser failures are not retried and have an explicit timeout', () => {
  expect(playwrightConfig.retries).toBe(0)
  expect(playwrightConfig.timeout).toBe(30_000)
})
