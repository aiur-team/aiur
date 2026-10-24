import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { readFileSync } from 'node:fs'

const require = createRequire(import.meta.url)
const browserRoot = fileURLToPath(new URL('..', import.meta.url))
const spec = 'tests/build-home-motion.browser.spec.mjs'

function collect(config, full, grep, selectedSpec = spec, extra = []) {
  const child = spawnSync(process.execPath, [require.resolve('@playwright/test/cli'), 'test', selectedSpec, ...extra, '--config', config, '--list', '--reporter=json', ...(grep ? ['--grep', grep] : [])], {
    cwd: browserRoot,
    env: { ...process.env, AIUR_BROWSER_PORT: '43210', AIUR_PARITY_FULL: full ? '1' : '' },
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

test('routine motion collects every determinism case; full mode preserves the original matrix', () => {
  const routine = collect('playwright.build-home-motion.config.mjs', false)
  assert.equal(routine.titles.filter(title => title.startsWith('design determinism:')).length, 76)
  assert.equal(routine.titles.filter(title => title.startsWith('clock probe:')).length, 2)
  assert.ok(routine.titles.every(title => /^(clock probe:|harness self-check:|design determinism:)/.test(title)))
  assert.equal(routine.config.workers, 2)
  assert.equal(routine.config.fullyParallel, true)

  const full = collect('playwright.build-home-motion.config.mjs', true)
  const original = collect('playwright.design-parity.config.mjs', true)
  assert.ok(full.titles.length > routine.titles.length)
  assert.deepEqual(full.titles, original.titles)
  assert.deepEqual(routine.titles, original.titles.filter(title => /^(clock probe:|harness self-check:|design determinism:)/.test(title)))
  assert.ok(full.titles.includes('full sign-off: no missing ports or stale motion entries'))
  assert.equal(full.config.workers, 1)
  assert.equal(full.config.fullyParallel, false)
})

test('routine band motion keeps the mobile snap sequences', () => {
  const scripts = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).scripts
  const grep = /--grep '([^']+)'/.exec(scripts['test:build-home-band-motion'])?.[1]
  assert.ok(grep)
  const { titles } = collect('playwright.design-parity.config.mjs', false, grep)
  for (const name of ['settle-near-top', 'settle-near-bottom', 'pinned', 'guard-up', 'guard-down', 'tall-band', 'list-view', 'scroll-curve', 'scrollbar-drag', 'reduce'])
    assert.equal(titles.filter(title => title === 'snap.' + name).length, 1, name)
  assert.equal(titles.length, 10)
  assert.ok(scripts['test:core'].includes('npm run test:build-home-band-motion'))
})
