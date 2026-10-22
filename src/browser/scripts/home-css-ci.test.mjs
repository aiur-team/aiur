import assert from 'node:assert/strict'
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import test from 'node:test'
import { discoverSuites, shardCommands, suiteArgs, suiteCommand, suiteShard, SUITE_SCRIPT } from './browser-suites.mjs'
import { shards, budgetMs } from './run-browser-smoke-shard.mjs'

const shardIds = Object.keys(shards).map(Number)

// Playwright pins this YAML parser; use it without adding a test-only dependency.
const { yaml } = createRequire(import.meta.url)('../node_modules/playwright-core/lib/utilsBundle.js')
const root = new URL('../../../', import.meta.url)
const read = path => readFileSync(new URL(path, root), 'utf8')
const workflow = yaml.parse(read('.github/workflows/ci.yml'))
const home = yaml.parse(read('.github/actions/verify-home-css/action.yml'))
const browserAction = yaml.parse(read('.github/actions/browser-smoke/action.yml'))
const scripts = JSON.parse(read('src/browser/package.json')).scripts

test('required full CI gate rejects failures, cancellations and skipped browser jobs', () => {
  const gate = workflow.jobs['ci-gate']
  assert.ok(gate.needs.includes('browser'))
  assert.ok(gate.needs.includes('home-css'))
  assert.match(gate.if, /always\(\)/)
  const step = gate.steps.find(step => step.name === "Require the event's selected jobs")
  assert.equal(step.env.EVENT_NAME, '${{ github.event_name }}')
  assert.equal(step.env.NEEDS_JSON, '${{ toJSON(needs) }}')
  for (const browser of ['success', 'failure', 'cancelled', 'skipped']) {
    for (const css of ['success', 'failure', 'cancelled', 'skipped']) {
      const needs = Object.fromEntries(gate.needs.map(job => [job, { result: 'success' }]))
      needs.changes.outputs = { full_ci: 'true', dialyzer: 'false', browser_smoke: 'true' }
      needs.browser.result = browser
      needs['home-css'].result = css
      const result = spawnSync('bash', ['-c', step.run], {
        cwd: root, env: { ...process.env, EVENT_NAME: 'merge_group', NEEDS_JSON: JSON.stringify(needs) }
      })
      assert.equal(result.status === 0, browser === 'success' && css === 'success', `${browser}/${css}`)
    }
  }
})

test('browser shards have bounded timeouts and home matrix keeps an independent deadline', () => {
  const browser = workflow.jobs.browser
  assert.equal(browser.steps[0].uses, 'actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd')
  assert.equal(browser.steps[1].name, 'Disclose rerun attempt')
  assert.match(browser.steps[1].if, /github.run_attempt > 1/)
  assert.match(browser.steps[1].run, /scripts\/report-ci-run-attempt\.sh/)
  assert.equal(browser.steps[2].uses, './.github/actions/browser-smoke')
  assert.equal(browser.steps[2].with.shard, '${{ matrix.shard }}')
  assert.equal(browser.name, 'browser smoke (${{ matrix.shard }}/' + shardIds.length + ')')
  assert.equal(browser['timeout-minutes'], 35)
  assert.equal(browser['timeout-minutes'] * 60_000 - budgetMs, 2 * 60_000, 'the runner reports slow suites before the job deadline')
  assert.equal(browser.strategy['fail-fast'], false)
  assert.deepEqual(browser.strategy.matrix.shard, shardIds)
  assert.deepEqual(browser.strategy.matrix.include, [
    { shard: 1, verify_fixtures: true, upload_evidence: true },
    { shard: 2, visual_regression: 'first' },
    { shard: 5, visual_regression: 'second' },
    ...Object.entries(shards).filter(([id, commands]) => Number(id) !== 1 &&
      commands.some(command => ['test:build-home-usage', 'test:build-home-edges-parity', 'test:build-home-gantt', 'test:build-home-chains'].includes(command)))
      .map(([id]) => ({ shard: Number(id), upload_evidence: true })),
  ])
  assert.equal(browser.steps[2].with.visual_regression, "${{ matrix.visual_regression || 'none' }}")
  assert.equal(browserAction.runs.using, 'composite')
  assert.equal(browserAction.runs.steps.find(step => step.name === 'Run browser smoke shard').run,
    'node scripts/run-browser-smoke-shard.mjs ${{ inputs.shard }}')
  assert.equal(browserAction.runs.steps.find(step => step.name === 'Report slowest browser smoke suites').if, '${{ always() }}')
  assert.match(workflow.jobs['home-css'].if, /outputs.full_ci == 'true'/)
  assert.equal(workflow.jobs['home-css']['timeout-minutes'], 25)
  assert.equal(workflow.jobs['home-css'].strategy['fail-fast'], false)
  assert.deepEqual(workflow.jobs['home-css'].strategy.matrix.shard, [1, 2, 3, 4])
  assert.equal(workflow.jobs['home-css'].steps.at(-1).uses, './.github/actions/verify-home-css')
  const homeRun = home.runs.steps.find(step => step.name === 'Run complete home CSS matrix')
  assert.equal(homeRun.run,
    'npm run fixture:preflight && npm run test:home-css -- --shard=${{ inputs.shard }}/4')
  assert.equal(home.inputs.shard.required, true)
  assert.match(home.runs.steps.at(-1).with.name, /home-css-artifacts-\$\{\{ inputs\.shard \}\}/)
  assert.equal(home.runs.steps.at(-1).if, '${{ always() }}')
  assert.equal(scripts.test, 'npm run test:core && npm run test:home-css')
  assert.doesNotMatch(scripts['test:core'], /npm run test:home-css(?:\s|$)/)
  assert.match(scripts['test:home-css'], /home-css-census\.browser\.spec\.mjs tests\/home-css-parity\.browser\.spec\.mjs/)
  assert.match(scripts['test:home-css'], /--fully-parallel --workers=4/)
})

test('browser shards execute every core suite exactly once', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'browser-shard-collection-'))
  try {
    const bin = join(scratch, 'bin'), calls = join(scratch, 'calls')
    mkdirSync(bin)
    // Stub only npm: execute the real shard runner and record its selected suites.
    writeFileSync(join(bin, 'npm'), '#!/bin/sh\nprintf "%s\\n" "$*" >> "$BROWSER_SHARD_CALLS"\n', { mode: 0o755 })
    for (const shard of shardIds) {
      const result = spawnSync(process.execPath, [fileURLToPath(new URL('./run-browser-smoke-shard.mjs', import.meta.url)), String(shard)], {
        cwd: new URL('../', import.meta.url), encoding: 'utf8',
        env: { ...process.env, PATH: bin + ':' + process.env.PATH, BROWSER_SHARD_CALLS: calls }
      })
      assert.equal(result.status, 0, result.stderr)
    }
    const invalidId = Math.max(...shardIds) + 1
    const invalid = spawnSync(process.execPath, [fileURLToPath(new URL('./run-browser-smoke-shard.mjs', import.meta.url)), String(invalidId)], {
      cwd: new URL('../', import.meta.url), encoding: 'utf8',
      env: { ...process.env, PATH: bin + ':' + process.env.PATH, BROWSER_SHARD_CALLS: calls }
    })
    assert.notEqual(invalid.status, 0, 'only configured workflow shard ids are accepted')
    assert.match(invalid.stderr, new RegExp('Unknown browser smoke shard: ' + invalidId))
    const expected = [...scripts['test:core'].matchAll(/npm run ([\w:-]+)/g)].map(match => match[1])
      .filter(name => name !== 'fixture:preflight' && name !== SUITE_SCRIPT)
      .concat(discoverSuites().map(suiteCommand)).sort()
    const selected = readFileSync(calls, 'utf8').trim().split('\n').map(line => line.replace(/^run /, ''))
      .filter(name => name !== 'fixture:preflight').sort()
    assert.deepEqual(selected, expected)
    assert.equal(selected.length, new Set(selected).size, 'each core suite runs exactly once across shards')
    const runner = readFileSync(fileURLToPath(new URL('./run-browser-smoke-shard.mjs', import.meta.url)), 'utf8')
    assert.match(runner, /export const budgetMs = 33 \* 60_000/)
    assert.match(runner, /slowest completed suites/)
  } finally { rmSync(scratch, { recursive: true, force: true }) }
})

test('a new build-home spec file joins exactly one shard with no list edit', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'browser-suite-discovery-'))
  try {
    mkdirSync(join(scratch, 'tests'))
    writeFileSync(join(scratch, 'package.json'), read('src/browser/package.json'))
    writeFileSync(join(scratch, 'tests', 'build-home-fixture-new.browser.spec.mjs'), '')
    writeFileSync(join(scratch, 'tests', 'build-home-shell.browser.spec.mjs'), '')
    writeFileSync(join(scratch, 'tests', 'build-home-fixture-new.helper.mjs'), '')
    assert.deepEqual(discoverSuites(scratch), ['build-home-fixture-new'], 'explicitly scripted and non-spec files are not discovered')
    const placed = Object.entries(shardCommands(shards, scratch))
      .filter(([, commands]) => commands.includes('test:browser-suite -- build-home-fixture-new'))
    assert.deepEqual(placed.map(([shard]) => Number(shard)), [suiteShard('build-home-fixture-new', Object.keys(shards).length)])
    assert.equal(scripts[SUITE_SCRIPT], 'node scripts/browser-suites.mjs')
    assert.match(scripts['test:core'], /npm run test:browser-suite -- --all$/)
  } finally { rmSync(scratch, { recursive: true, force: true }) }
  // Pinned so a hash change, which would silently move every discovered suite, fails here.
  assert.deepEqual(['build-home-a', 'build-home-b-parity', 'build-home-c', 'build-home-fixture-new'].map(name => suiteShard(name, 5)), [5, 4, 3, 1])
  assert.deepEqual(suiteArgs('build-home-x'), ['tests/build-home-x.browser.spec.mjs'])
  assert.deepEqual(suiteArgs('build-home-x-parity'), ['tests/build-home-x-parity.browser.spec.mjs', '--config', 'playwright.design-parity.config.mjs'])
})
