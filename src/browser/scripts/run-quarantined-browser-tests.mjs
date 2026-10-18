import process from 'node:process'
import { readQuarantine, runnableSpec } from './browser-quarantine.mjs'
import { runBrowserTests } from './run-browser-tests.mjs'

// Runs only the quarantined specs, for the non-blocking CI step; blocking runs skip them.
const specs = [...new Set(readQuarantine().map(runnableSpec))]
if (specs.length === 0) console.log('No quarantined browser specs.')

let failed = 0
for (const spec of specs) {
  const config = /-parity\.browser\.spec\.mjs$/.test(spec) ? ['--config', 'playwright.design-parity.config.mjs'] : []
  const result = await runBrowserTests([spec, ...config], { ...process.env, AIUR_RUN_QUARANTINED: '1' })
  if (result.code !== 0) failed += 1
}

process.exitCode = failed ? 1 : 0
