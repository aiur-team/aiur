import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

const browserRoot = new URL('../', import.meta.url)
const scripts = JSON.parse(readFileSync(new URL('package.json', browserRoot), 'utf8')).scripts
const playwright = createRequire(import.meta.url).resolve('@playwright/test/cli')

function collect(script) {
  // Use the shipped command's real selectors without starting its fixture server.
  const args = script.split('scripts/run-browser-tests.mjs ')[1].trim().split(/\s+/)
  const result = spawnSync(process.execPath, [playwright, 'test', ...args, '--list', '--reporter=json'], {
    cwd: fileURLToPath(browserRoot), encoding: 'utf8', maxBuffer: 4 * 1024 * 1024,
    env: { ...process.env, AIUR_BROWSER_PORT: '1' }
  })
  assert.equal(result.status, 0, result.stderr || result.stdout)
  const report = JSON.parse(result.stdout)
  assert.deepEqual(report.errors, [])
  assert.equal(report.config.workers, 1, 'card partitions must keep fixture access sequential')
  function ids(suite) {
    return [...(suite.specs ?? []).map(spec => spec.id), ...(suite.suites ?? []).flatMap(ids)]
  }
  return report.suites.flatMap(ids)
}

test('card CI partitions collect every standalone card case exactly once', () => {
  const baseline = collect(scripts['test:build-home-cards'])
  assert.ok(baseline.length > 0, 'the full card suite must collect tests')
  const partitions = [1, 2, 3, 4].map(n => collect(scripts[`test:build-home-cards:${n}`]))
  for (const partition of partitions) assert.ok(partition.length > 0)
  const counts = partitions.map(partition => partition.length)
  assert.ok(Math.max(...counts) - Math.min(...counts) <= 1, `balanced partitions: ${counts}`)
  const selected = partitions.flat()
  assert.equal(new Set(selected).size, selected.length, 'partitions must not duplicate any card case')
  assert.deepEqual(selected.sort(), baseline.sort(), 'partitions must cover the complete standalone suite')
})
