import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const check = fileURLToPath(new URL('./check-browser-smoke-shards.mjs', import.meta.url))
const packageJson = { scripts: { 'test:core': 'npm run test:fixture-alpha && npm run test:fixture-beta' } }
const runner = `const shards = {\n  1: ['test:fixture-alpha'],\n  2: ['test:fixture-beta'],\n};\n`
const scratch = mkdtempSync(join(tmpdir(), 'browser-smoke-shards-'))
try {
  const packagePath = join(scratch, 'package.json')
  const runnerPath = join(scratch, 'runner.mjs')
  writeFileSync(packagePath, JSON.stringify(packageJson))
  writeFileSync(runnerPath, runner)

  const valid = spawnSync(process.execPath, [check, packagePath, runnerPath], { encoding: 'utf8' })
  assert.equal(valid.status, 0, valid.stderr)
  assert.match(valid.stdout, /cover all \d+ test:core suites exactly once/)

  const omitted = runner.replace("'test:fixture-alpha'", '')
  assert.notEqual(omitted, runner, 'fixture must remove a core suite')
  writeFileSync(runnerPath, omitted)
  const invalid = spawnSync(process.execPath, [check, packagePath, runnerPath], { encoding: 'utf8' })
  assert.equal(invalid.status, 1)
  assert.match(invalid.stderr, /Missing or duplicated suites: test:fixture-alpha/)
} finally {
  rmSync(scratch, { recursive: true, force: true })
}

console.log('test-check-browser-smoke-shards: missing core suite fails with its name')
