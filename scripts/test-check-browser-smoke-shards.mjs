import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const check = fileURLToPath(new URL('./check-browser-smoke-shards.mjs', import.meta.url))
const core = 'npm run test:fixture-alpha && npm run test:fixture-beta && npm run test:browser-suite -- --all'
const packageJson = { scripts: { 'test:core': core, 'test:fixture-beta': 'x tests/build-home-claimed.browser.spec.mjs' } }
const runner = `export const shards = {\n  1: ['test:fixture-alpha'],\n  2: ['test:fixture-beta'],\n};\n`
const scratch = mkdtempSync(join(tmpdir(), 'browser-smoke-shards-'))
try {
  const packagePath = join(scratch, 'package.json')
  const runnerPath = join(scratch, 'runner.mjs')
  writeFileSync(packagePath, JSON.stringify(packageJson))
  writeFileSync(runnerPath, runner)
  mkdirSync(join(scratch, 'tests'))
  // A spec an explicit script runs keeps that script; an unclaimed one is discovered.
  writeFileSync(join(scratch, 'tests', 'build-home-claimed.browser.spec.mjs'), '')
  const run = () => spawnSync(process.execPath, [check, packagePath, runnerPath], { encoding: 'utf8' })

  const valid = run()
  assert.equal(valid.status, 0, valid.stderr)
  assert.match(valid.stdout, /cover all 2 test:core suites exactly once/)

  // A new home suite file is covered with no package.json or shard-map edit.
  writeFileSync(join(scratch, 'tests', 'build-home-fixture-new.browser.spec.mjs'), '')
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
  writeFileSync(runnerPath, omitted)
  const invalid = run()
  assert.equal(invalid.status, 1)
  assert.match(invalid.stderr, /Missing or duplicated suites: test:fixture-alpha/)
} finally {
  rmSync(scratch, { recursive: true, force: true })
}

console.log('test-check-browser-smoke-shards: discovered suites count; missing core suite fails with its name')
