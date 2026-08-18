import { mkdtemp, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { expect, test } from '@playwright/test'
import { browserChildEnvironment, fixtureServerEnvironment, sanitizeDiagnostic, syntheticFixtureEnvironment } from '../scripts/artifact-sanitizer.mjs'
import playwrightConfig from '../playwright.config.mjs'
import { createArtifactRoot } from '../scripts/run-browser-tests.mjs'
import { assertMeasurementBudget } from './support/measurements.mjs'

test('diagnostic sanitization preserves only synthetic fixture settings', () => {
  const environment = {
    AIUR_BROWSER_PORT: '43123',
    AIUR_DASHBOARD_PASSWORD: 'must-not-leak',
    DEEPSEEK_API_KEY: 'real-provider-key-that-must-not-leak',
    GITHUB_TOKEN: 'must-not-leak-either'
  }

  expect(syntheticFixtureEnvironment(environment)).toEqual({
    AIUR_BROWSER_PORT: '43123',
    AIUR_BROWSER_FIXTURE_MODE: 'synthetic',
    DEEPSEEK_API_KEY: 'fixture-deepseek-key',
    MOONSHOT_API_KEY: 'fixture-moonshot-key'
  })
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

// The fixture server reaches `mix` through two env filters — Playwright's child
// and then the `mise exec` child — and `mix` cannot resolve the heroicons git
// dependency without a usable git. Dropping AIUR_REAL_GIT at *either* hop makes
// the Aiur agent-workspace git wrapper exit 127, so the server dies before it
// serves a page and every browser spec fails on webServer startup instead of on
// anything it asserts. Both hops are covered because fixing only one still
// leaves the suite unrunnable.
test('both fixture env hops forward the real git path without forwarding secrets', () => {
  const environment = {
    AIUR_REAL_GIT: '/usr/bin/git',
    AIUR_DASHBOARD_PASSWORD: 'must-not-leak',
    GITHUB_TOKEN: 'must-not-leak-either',
    PATH: '/aiur/.aiur-runtime/bin:/usr/bin'
  }

  for (const build of [browserChildEnvironment, fixtureServerEnvironment]) {
    const child = build(environment)

    expect(child.AIUR_REAL_GIT).toBe('/usr/bin/git')
    expect(child).not.toHaveProperty('AIUR_DASHBOARD_PASSWORD')
    expect(child).not.toHaveProperty('GITHUB_TOKEN')
  }

  // An unset variable stays unset rather than becoming an empty string, which
  // the wrapper would treat the same as missing but `mix` would not.
  expect(fixtureServerEnvironment({ PATH: '/usr/bin' })).not.toHaveProperty('AIUR_REAL_GIT')
  // CI changes Mix behaviour, so it must not reach the fixture server even
  // though the Playwright child does receive it.
  expect(fixtureServerEnvironment({ CI: 'true', PATH: '/usr/bin' })).not.toHaveProperty('CI')
  expect(browserChildEnvironment({ CI: 'true', PATH: '/usr/bin' }).CI).toBe('true')
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
