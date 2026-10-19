import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { failedSpecAnnotationLines } from '../support/github-failure-annotations.mjs'
import GitHubFailureReporter from '../support/github-failure-reporter.mjs'
import { PROBE_SPECS, parseQuarantine, quarantineArgs, readQuarantine, runnableSpec, withQuarantine } from './browser-quarantine.mjs'
import { playwrightChildEnvironment } from './run-browser-tests.mjs'

const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

// Real flakes of 2026-10-18: #5118 (main + merge group 39133390224) and #5111.
const list = [
  '# BrowserSpec, spec path (as the failure annotation names it), and tracking ticket. Tabs delimit fields.',
  'BrowserSpec\tsrc/browser/tests/build-home-list.browser.spec.mjs\t#5118',
  'BrowserSpec\tsrc/browser/tests/build-home-usage-parity.browser.spec.mjs\t#5111',
  ''
].join('\n')

// Playwright's --grep subject: project, file relative to testDir, describe and title joined by spaces.
const subject = (file, title) => ` ${file} ${title}`

test('blocking runs skip exactly the listed spec files', () => {
  const args = quarantineArgs(parseQuarantine(list), {})
  assert.equal(args[0], '--grep-invert')
  assert.ok(args.includes('--pass-with-no-tests'))
  const pattern = new RegExp(args[1])
  assert.match(subject('build-home-list.browser.spec.mjs', 'B4 server paging disables duplicate clicks and permits an explicit retry'), pattern)
  assert.match(subject('build-home-usage-parity.browser.spec.mjs', 'usage 1440 dark gruvbox n4'), pattern)
  assert.doesNotMatch(subject('build-home-usage.browser.spec.mjs', 'usage 1440 dark gruvbox n4'), pattern)
  assert.doesNotMatch(subject('build-home-list-unit.browser.spec.mjs', 'B4 server paging'), pattern)
  assert.doesNotMatch(subject('nested/build-home-list.browser.spec.mjs', 'B4 server paging'), pattern)
})

test('a list entry uses the identity the failure annotation reports', () => {
  const [line] = failedSpecAnnotationLines([{ file: path.join(browserRoot, 'tests/build-home-list.browser.spec.mjs'), status: 'failed' }])
  const [, module, spec] = line.match(/::(new-failure :: .*)$/)[1].split(' :: ')
  assert.deepEqual(parseQuarantine(`${module}\t${spec}\t#5118`), [{ spec: 'src/browser/tests/build-home-list.browser.spec.mjs', ticket: '#5118' }])
  assert.equal(runnableSpec({ spec }), 'tests/build-home-list.browser.spec.mjs')
})

test('the quarantine step and an empty list add no filter', () => {
  assert.deepEqual(quarantineArgs(parseQuarantine(list), { AIUR_RUN_QUARANTINED: '1' }), [])
  assert.deepEqual(quarantineArgs([], {}), [])
})

test("a caller's --grep-invert survives the quarantine filter", () => {
  const entries = parseQuarantine(list)
  const args = withQuarantine(['tests/x.spec.mjs', '--grep-invert', 'full acceptance', '--workers=1'], entries, {})
  assert.equal(args.filter(arg => arg === '--grep-invert').length, 1)
  const pattern = new RegExp(args[args.indexOf('--grep-invert') + 1])
  assert.match(subject('x.spec.mjs', 'B1 Gantt full acceptance composition'), pattern)
  assert.match(subject('build-home-list.browser.spec.mjs', 'B4 server paging'), pattern)
  assert.doesNotMatch(subject('x.spec.mjs', 'B1 Gantt composition parity'), pattern)
  assert.deepEqual(withQuarantine(['a', '--grep-invert', 'b'], [], {}), ['a', '--grep-invert', 'b'])
  assert.deepEqual(withQuarantine(['a'], entries, {}), ['a', ...quarantineArgs(entries, {})])
})

test('the checked-in list parses', () => {
  assert.ok(Array.isArray(readQuarantine()))
})

test('a malformed entry fails loudly instead of quarantining nothing', () => {
  assert.throws(() => parseQuarantine('BrowserSpec\tsrc/browser/tests/a.browser.spec.mjs'), /line 1/)
  assert.throws(() => parseQuarantine('Spec\tsrc/browser/tests/a.browser.spec.mjs\t#1'), /line 1/)
  assert.throws(() => parseQuarantine('BrowserSpec\tsrc/browser/../a.spec.mjs\t#1'), /line 1/)
})

test('the intentional-failure probe is never annotated, filtered or quarantinable', () => {
  const probes = PROBE_SPECS.map((spec) => ({ file: path.join(browserRoot, spec.replace(/^src\/browser\//, '')), status: 'failed' }))
  assert.deepEqual(failedSpecAnnotationLines(probes), [])
  for (const spec of PROBE_SPECS) assert.throws(() => parseQuarantine(`BrowserSpec\t${spec}\t#1`), /line 1/)

  const previous = { actions: process.env.GITHUB_ACTIONS, expect: process.env.AIUR_BROWSER_EXPECT_FAILURE }
  const output = []
  const reporter = new GitHubFailureReporter({}, (line) => output.push(line))
  reporter.onTestEnd({ location: { file: path.join(browserRoot, 'tests/build-home-list.browser.spec.mjs') } }, { status: 'failed' })

  try {
    process.env.GITHUB_ACTIONS = 'true'
    process.env.AIUR_BROWSER_EXPECT_FAILURE = '1'
    reporter.onEnd()
    assert.deepEqual(output, [])
  } finally {
    for (const [name, value] of [['GITHUB_ACTIONS', previous.actions], ['AIUR_BROWSER_EXPECT_FAILURE', previous.expect]]) {
      if (value === undefined) delete process.env[name]
      else process.env[name] = value
    }
  }

  assert.deepEqual(quarantineArgs(parseQuarantine(list), { AIUR_BROWSER_EXPECT_FAILURE: '1' }), [])
  assert.match(readFileSync(path.join(browserRoot, 'scripts/verify-failure-artifacts.mjs'), 'utf8'), /AIUR_BROWSER_EXPECT_FAILURE: '1'/)
})

test('the Playwright child sees GITHUB_ACTIONS, so the config turns on the failure reporter in CI', () => {
  const child = playwrightChildEnvironment({ GITHUB_ACTIONS: 'true', AIUR_BROWSER_EXPECT_FAILURE: '1', PATH: '/usr/bin' }, 4321, '/tmp/artifacts')
  assert.equal(child.GITHUB_ACTIONS, 'true')
  assert.equal(child.AIUR_BROWSER_EXPECT_FAILURE, '1')
})
