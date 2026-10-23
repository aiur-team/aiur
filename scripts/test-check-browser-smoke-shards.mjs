import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, unlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const check = fileURLToPath(new URL('./check-browser-smoke-shards.mjs', import.meta.url))
const core = 'npm run test:fixture-alpha && npm run test:fixture-beta && npm run test:browser-suite -- --all'
const packageJson = { scripts: {
  'test:core': core,
  'test:fixture-beta': 'x tests/build-home-claimed.browser.spec.mjs',
  'test:fixture-ci': 'x tests/ci-only.browser.spec.mjs',
  'test:manual-only': 'x tests/manual-only.browser.spec.mjs',
} }
const runner = `export const shards = {\n  1: ['test:fixture-alpha'],\n  2: ['test:fixture-beta'],\n};\n`
const timing = (alpha, extra = '') => `export const budgetMs = 100_000\nexport const preflightSeconds = 10\nexport const setupSeconds = 10\nexport const tailSeconds = 10\nexport const recordedSeconds = { 'test:fixture-alpha': ${alpha}, 'test:fixture-beta': 20${extra} }\n`
const newSuite = ", 'test:browser-suite -- build-home-fixture-new': 5"
const scratch = mkdtempSync(join(tmpdir(), 'browser-smoke-shards-'))
try {
  const packagePath = join(scratch, 'package.json')
  const runnerPath = join(scratch, 'runner.mjs')
  const exclusionsPath = join(scratch, 'exclusions.json')
  const ciRoot = join(scratch, '.github')
  writeFileSync(packagePath, JSON.stringify(packageJson))
  writeFileSync(runnerPath, runner + timing(20))
  mkdirSync(join(scratch, 'tests'))
  mkdirSync(join(ciRoot, 'actions', 'fixture'), { recursive: true })
  mkdirSync(join(ciRoot, 'workflows'))
  const workflow = minutes => writeFileSync(join(ciRoot, 'workflows', 'ci.yml'),
    `jobs:\n  browser:\n    name: browser smoke\n\n    timeout-minutes: ${minutes}\n  later:\n    timeout-minutes: 9\n`)
  workflow(2)
  // A spec an explicit script runs keeps that script; an unclaimed one is discovered.
  writeFileSync(join(scratch, 'tests', 'build-home-claimed.browser.spec.mjs'), '')
  writeFileSync(join(scratch, 'tests', 'ci-only.browser.spec.mjs'), '')
  writeFileSync(join(scratch, 'tests', 'manual-only.browser.spec.mjs'), '')
  writeFileSync(join(ciRoot, 'actions', 'fixture', 'action.yml'), [
    'runs:', '  steps:', '    - name: Browser suite', '      working-directory: src/browser',
    '      run: npm run test:fixture-ci', '',
  ].join('\n'))
  writeFileSync(exclusionsPath, JSON.stringify([{ spec: 'tests/manual-only.browser.spec.mjs', reason: 'Manual sign-off only; workflow_dispatch does not gate merges.', ticket: 5124 }]))
  const run = () => spawnSync(process.execPath, [check, packagePath, runnerPath, exclusionsPath, ciRoot], { encoding: 'utf8' })

  const valid = run()
  assert.equal(valid.status, 0, valid.stderr)
  assert.match(valid.stdout, /cover all 2 test:core suites exactly once/)

  // CI coverage comes from active action/workflow run steps, not a copied script allowlist.
  writeFileSync(join(ciRoot, 'actions', 'fixture', 'action.yml'), 'runs:\n  steps:\n    - name: no browser run\n      working-directory: src/browser\n      run: echo skipped\n')
  const actionRemoved = run()
  assert.equal(actionRemoved.status, 1, actionRemoved.stdout)
  assert.match(actionRemoved.stderr, /tests\/ci-only\.browser\.spec\.mjs/)
  writeFileSync(join(ciRoot, 'actions', 'fixture', 'action.yml'), [
    'runs:', '  steps:', '    - name: Browser suite', '      working-directory: src/browser',
    '      run: npm run test:fixture-ci', '',
  ].join('\n'))

  // Exclusions are explicit and must name both a reason and a tracking ticket.
  for (const exclusion of [
    { spec: 'tests/manual-only.browser.spec.mjs', reason: 'Manual sign-off only.' },
    { spec: 'tests/manual-only.browser.spec.mjs', ticket: 5124 },
  ]) {
    writeFileSync(exclusionsPath, JSON.stringify([exclusion]))
    const untrackedExclusion = run()
    assert.equal(untrackedExclusion.status, 1, untrackedExclusion.stdout)
    assert.match(untrackedExclusion.stderr, /non-empty reason, and positive numeric ticket/)
  }
  writeFileSync(exclusionsPath, JSON.stringify([{ spec: 'tests/manual-only.browser.spec.mjs', reason: 'Manual sign-off only; workflow_dispatch does not gate merges.', ticket: 5124 }]))

  // A new home suite file needs no package.json or shard-map edit, but fails until its duration is recorded.
  writeFileSync(join(scratch, 'tests', 'build-home-fixture-new.browser.spec.mjs'), '')
  const unrecorded = run()
  assert.equal(unrecorded.status, 1, unrecorded.stdout)
  assert.match(unrecorded.stderr, /no recorded duration: test:browser-suite -- build-home-fixture-new\./)
  writeFileSync(runnerPath, runner + timing(20, newSuite))
  const added = run()
  assert.equal(added.status, 0, added.stderr)
  assert.match(added.stdout, /cover all 3 test:core suites exactly once/)

  writeFileSync(packagePath, JSON.stringify({ scripts: { 'test:core': core.replace(' && npm run test:browser-suite -- --all', '') } }))
  const unrun = run()
  assert.equal(unrun.status, 1)
  assert.match(unrun.stderr, /test:core must run discovered home suites/)
  writeFileSync(packagePath, JSON.stringify(packageJson))

  const omitted = runner.replace("'test:fixture-alpha'", '')
  assert.notEqual(omitted, runner, 'fixture must remove a core suite')
  writeFileSync(runnerPath, omitted + timing(20, newSuite))
  const invalid = run()
  assert.equal(invalid.status, 1)
  assert.match(invalid.stderr, /Missing or duplicated suites: test:fixture-alpha/)

  // A shard whose recorded total passes 75% of its budget fails with its number and total.
  writeFileSync(runnerPath, runner + timing(61, newSuite))
  const over = run()
  assert.equal(over.status, 1, over.stdout)
  // The discovered suite is hashed onto shard 1 with its recorded 5s: 10 + 61 + 5.
  assert.match(over.stderr, /Browser smoke shard 1: 76s recorded of 75s/)
  writeFileSync(runnerPath, runner + timing(60, newSuite))
  const atLimit = run()
  assert.equal(atLimit.status, 0, atLimit.stderr)
  assert.match(atLimit.stdout, /browser job timeout 120s for setup 10s \+ suite budget 100s \+ tail 10s = 120s/)

  // The browser job deadline must cover setup, the whole suite budget and the post-suite tail.
  workflow(1)
  const shortDeadline = run()
  assert.equal(shortDeadline.status, 1, shortDeadline.stdout)
  assert.match(shortDeadline.stderr, /browser job timeout 60s for setup 10s \+ suite budget 100s \+ tail 10s = 120s: too short/)
  workflow(2)

  // An unreferenced browser spec must fail.
  writeFileSync(join(scratch, 'tests', 'orphan.browser.spec.mjs'), '')
  const orphan = run()
  assert.equal(orphan.status, 1, orphan.stdout)
  assert.match(orphan.stderr, /not referenced by any npm script: tests\/orphan\.browser\.spec\.mjs/)

  // A referenced script outside smoke and active CI paths must fail reachability.
  unlinkSync(join(scratch, 'tests', 'orphan.browser.spec.mjs'))
  writeFileSync(packagePath, JSON.stringify({ scripts: { ...packageJson.scripts, 'test:orphan': 'x tests/orphan-ci.browser.spec.mjs' } }))
  writeFileSync(join(scratch, 'tests', 'orphan-ci.browser.spec.mjs'), '')
  const unreachable = run()
  assert.equal(unreachable.status, 1, unreachable.stdout)
  assert.match(unreachable.stderr, /not reachable from a smoke shard or CI workflow\/action script and have no exclusion: tests\/orphan-ci\.browser\.spec\.mjs/)

  // A script path to a missing spec is a separate failure from reachability.
  writeFileSync(packagePath, JSON.stringify({ scripts: {
    ...packageJson.scripts,
    'test:fixture-beta': 'x tests/build-home-claimed.browser.spec.mjs tests/missing.browser.spec.mjs',
  } }))
  const missing = run()
  assert.equal(missing.status, 1, missing.stdout)
  assert.match(missing.stderr, /CI scripts reference missing browser specs: tests\/missing\.browser\.spec\.mjs/)
} finally {
  rmSync(scratch, { recursive: true, force: true })
}

console.log('test-check-browser-smoke-shards: core coverage, CI script discovery, reasoned exclusions, missing/unreachable specs, shard budget and job deadline guards pass')
