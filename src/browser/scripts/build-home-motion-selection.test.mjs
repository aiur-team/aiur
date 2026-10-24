import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const require = createRequire(import.meta.url)
const browserRoot = fileURLToPath(new URL('..', import.meta.url))
const spec = 'tests/build-home-motion.browser.spec.mjs'

function collect(config, selectedSpec = spec) {
  const child = spawnSync(process.execPath, [require.resolve('@playwright/test/cli'), 'test', selectedSpec, '--config', config, '--list', '--reporter=json'], {
    cwd: browserRoot,
    env: { ...process.env, AIUR_BROWSER_PORT: '43210' },
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024
  })
  assert.equal(child.status, 0, child.error?.message || child.stderr)
  const report = JSON.parse(child.stdout)
  const titles = [], qualified = []
  function visit(suites = [], prefix = '') {
    for (const suite of suites) {
      titles.push(...suite.specs.map(spec => spec.title))
      qualified.push(...suite.specs.map(spec => prefix + suite.title + ' / ' + spec.title))
      visit(suite.suites, prefix + suite.title + ' / ')
    }
  }
  visit(report.suites)
  return { titles: titles.sort(), qualified: qualified.sort(), config: report.config }
}

test('motion suite contains product behavior and helper checks only', () => {
  const routine = collect('playwright.build-home-motion.config.mjs')
  assert.equal(routine.titles.filter(title => title.startsWith('clock probe:')).length, 0)
  assert.ok(routine.titles.includes('product reduced-motion preference disables animated effects'))
  assert.ok(routine.titles.every(title => /^(clock probe:|harness self-check:|product )/.test(title)))
  assert.ok(!routine.titles.some(title => /design determinism|parity|sign-off/i.test(title)))
  assert.equal(routine.config.workers, 2)
  assert.equal(routine.config.fullyParallel, true)
})
