import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const runner = fileURLToPath(new URL('../src/browser/scripts/run-build-home-band-full.mjs', import.meta.url))

function invoke(t, environment = {}) {
  const cwd = mkdtempSync(path.join(process.env.TMPDIR || tmpdir(), 'home-band-runner-'))
  t.after(() => rmSync(cwd, { recursive: true, force: true }))
  mkdirSync(path.join(cwd, 'scripts'))
  writeFileSync(path.join(cwd, 'scripts/run-browser-tests.mjs'), `
import { appendFileSync } from 'node:fs'
appendFileSync('calls.jsonl', JSON.stringify({ argv: process.argv.slice(2), full: process.env.AIUR_PARITY_FULL, part: process.env.AIUR_HOME_PARITY_PART }) + '\\n')
process.exit(Number(process.env.FAKE_BROWSER_EXIT || '0'))
`)
  const result = spawnSync(process.execPath, [runner], {
    cwd, encoding: 'utf8',
    env: { ...process.env, AIUR_HOME_PARITY_PART: '2', AIUR_PARITY_FULL: '1', ...environment }
  })
  assert.equal(result.error, undefined)
  let calls = []
  try { calls = readFileSync(path.join(cwd, 'calls.jsonl'), 'utf8').trim().split('\n').map(JSON.parse) }
  catch (error) { if (error.code !== 'ENOENT') throw error }
  return { ...result, calls }
}

test('actual full-band CLI runs each owned spec in partition two and clears shared sign-off expansion', t => {
  const result = invoke(t)
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.calls.length, 2)
  const options = ['--config', 'playwright.design-parity.config.mjs', '--fully-parallel', '--workers=1', '--shard=2/4']
  assert.deepEqual(result.calls[0].argv, ['tests/build-home-now-band-parity.browser.spec.mjs', ...options])
  assert.deepEqual(result.calls[1].argv, [
    'tests/build-home-motion.browser.spec.mjs', '--grep',
    'product interactions .*snap[.]|product inventory/grain live 1440 dark gruvbox no-preference.*(grain[.]static [.]bd-now|inventory [.]bd-now-h)',
    ...options
  ])
  for (const call of result.calls) {
    assert.equal(call.full, '', 'shared C12 full matrix must remain disabled')
    assert.equal(call.part, '2')
  }
})

test('actual full-band CLI stops after a failed child and propagates its exit code', t => {
  const result = invoke(t, { FAKE_BROWSER_EXIT: '23' })
  assert.equal(result.status, 23, result.stderr)
  assert.equal(result.calls.length, 1, 'motion must not hide a preceding parity failure')
  assert.equal(result.calls[0].argv[0], 'tests/build-home-now-band-parity.browser.spec.mjs')
})

test('actual full-band CLI rejects invalid partitions before launching either spec', t => {
  for (const part of ['', '0', '5', '2/4', 'two']) {
    const result = invoke(t, { AIUR_HOME_PARITY_PART: part })
    assert.notEqual(result.status, 0, `partition ${JSON.stringify(part)}`)
    assert.match(result.stderr, /AIUR_HOME_PARITY_PART must be 1\.\.4/)
    assert.deepEqual(result.calls, [])
  }
})
