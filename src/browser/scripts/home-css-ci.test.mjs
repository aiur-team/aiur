import assert from 'node:assert/strict'
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import test from 'node:test'
import { discoverSuites, shardCommands, suiteArgs, suiteCommand, suiteShard, SUITE_SCRIPT } from './browser-suites.mjs'
import { shards } from './run-browser-smoke-shard.mjs'

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
  assert.ok(gate.needs.includes('browser-4'))
  assert.ok(gate.needs.includes('home-css'))
  for (const job of ['browser', 'browser-2', 'browser-3', 'browser-4']) assert.ok(gate.needs.includes(job))
  assert.match(gate.if, /always\(\)/)
  const step = gate.steps.find(step => step.name === "Require the event's selected jobs")
  assert.equal(step.env.EVENT_NAME, '${{ github.event_name }}')
  assert.equal(step.env.NEEDS_JSON, '${{ toJSON(needs) }}')
  for (const browser of ['success', 'failure', 'cancelled', 'skipped']) {
    for (const css of ['success', 'failure', 'cancelled', 'skipped']) {
      const needs = Object.fromEntries(gate.needs.map(job => [job, { result: 'success' }]))
      needs.changes.outputs = { full_ci: 'true', dialyzer: 'false' }
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
  for (const [job, shard] of [['browser', 1], ['browser-2', 2], ['browser-3', 3], ['browser-4', 4]]) {
    assert.equal(workflow.jobs[job].steps[0].uses, 'actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd')
    assert.equal(workflow.jobs[job].steps[1].name, 'Disclose rerun attempt')
    assert.match(workflow.jobs[job].steps[1].if, /github.run_attempt > 1/)
    assert.match(workflow.jobs[job].steps[1].run, /scripts\/report-ci-run-attempt\.sh/)
    assert.equal(workflow.jobs[job].steps[2].with.shard, shard)
    assert.equal(workflow.jobs[job].steps[2].uses, './.github/actions/browser-smoke')
    assert.equal(workflow.jobs[job].name, `browser smoke (${shard}/4)`)
    assert.equal(workflow.jobs[job]['timeout-minutes'], 15)
  }
  assert.equal(workflow.jobs['browser-2'].steps[2].with.visual_regression, 'first')
  assert.equal(workflow.jobs['browser-4'].steps[2].with.visual_regression, 'second')
  assert.equal(browserAction.runs.using, 'composite')
  assert.equal(browserAction.runs.steps.find(step => step.name === 'Run browser smoke shard').run,
    'node scripts/run-browser-smoke-shard.mjs ${{ inputs.shard }}')
  assert.match(workflow.jobs['home-css'].if, /outputs.full_ci == 'true'/)
  assert.equal(workflow.jobs['home-css']['timeout-minutes'], 25)
  assert.equal(workflow.jobs['home-css'].steps.at(-1).uses, './.github/actions/verify-home-css')
  assert.equal(home.runs.steps.find(step => step.name === 'Run complete home CSS matrix').run,
    'npm run fixture:preflight && npm run test:home-css')
  assert.equal(home.runs.steps.at(-1).if, '${{ always() }}')
  assert.equal(scripts.test, 'npm run test:core && npm run test:home-css')
  assert.doesNotMatch(scripts['test:core'], /npm run test:home-css(?:\s|$)/)
  assert.match(scripts['test:home-css'], /home-css-census\.browser\.spec\.mjs tests\/home-css-parity\.browser\.spec\.mjs/)
})

test('browser shards execute every core suite exactly once', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'browser-shard-collection-'))
  try {
    const bin = join(scratch, 'bin'), calls = join(scratch, 'calls')
    mkdirSync(bin)
    // Stub only npm: execute the real shard runner and record its selected suites.
    writeFileSync(join(bin, 'npm'), '#!/bin/sh\nprintf "%s\\n" "$*" >> "$BROWSER_SHARD_CALLS"\n', { mode: 0o755 })
    for (const shard of [1, 2, 3, 4]) {
      const result = spawnSync(process.execPath, [fileURLToPath(new URL('./run-browser-smoke-shard.mjs', import.meta.url)), String(shard)], {
        cwd: new URL('../', import.meta.url), encoding: 'utf8',
        env: { ...process.env, PATH: bin + ':' + process.env.PATH, BROWSER_SHARD_CALLS: calls }
      })
      assert.equal(result.status, 0, result.stderr)
    }
    const invalid = spawnSync(process.execPath, [fileURLToPath(new URL('./run-browser-smoke-shard.mjs', import.meta.url)), '5'], {
      cwd: new URL('../', import.meta.url), encoding: 'utf8',
      env: { ...process.env, PATH: bin + ':' + process.env.PATH, BROWSER_SHARD_CALLS: calls }
    })
    assert.notEqual(invalid.status, 0, 'only the four workflow shard ids are accepted')
    assert.match(invalid.stderr, /Unknown browser smoke shard: 5/)
    const expected = [...scripts['test:core'].matchAll(/npm run ([\w:-]+)/g)].map(match => match[1])
      .filter(name => name !== 'fixture:preflight' && name !== SUITE_SCRIPT)
      .concat(discoverSuites().map(suiteCommand)).sort()
    const selected = readFileSync(calls, 'utf8').trim().split('\n').map(line => line.replace(/^run /, ''))
      .filter(name => name !== 'fixture:preflight').sort()
    assert.deepEqual(selected, expected)
    assert.equal(selected.length, new Set(selected).size, 'each core suite runs exactly once across shards')
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
    assert.deepEqual(placed.map(([shard]) => Number(shard)), [suiteShard('build-home-fixture-new')])
    assert.equal(scripts[SUITE_SCRIPT], 'node scripts/browser-suites.mjs')
    assert.match(scripts['test:core'], /npm run test:browser-suite -- --all$/)
  } finally { rmSync(scratch, { recursive: true, force: true }) }
  // Pinned so a hash change, which would silently move every discovered suite, fails here.
  assert.deepEqual(['build-home-a', 'build-home-b-parity', 'build-home-c', 'build-home-fixture-new'].map(name => suiteShard(name)), [4, 1, 2, 3])
  assert.deepEqual(suiteArgs('build-home-x'), ['tests/build-home-x.browser.spec.mjs'])
  assert.deepEqual(suiteArgs('build-home-x-parity'), ['tests/build-home-x-parity.browser.spec.mjs', '--config', 'playwright.design-parity.config.mjs'])
})
