#!/usr/bin/env node

import { readFileSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { dirname, resolve } from 'node:path'
import { discoverSuites, shardCommands, suiteCommand, SUITE_SCRIPT } from '../src/browser/scripts/browser-suites.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const packagePath = process.argv[2] ?? resolve(root, 'src/browser/package.json')
const runnerPath = process.argv[3] ?? resolve(root, 'src/browser/scripts/run-browser-smoke-shard.mjs')
const browserRoot = dirname(packagePath)

const scripts = JSON.parse(readFileSync(packagePath, 'utf8')).scripts
const core = scripts['test:core']
if (typeof core !== 'string') throw new Error('src/browser/package.json is missing test:core')
if (!core.includes(`npm run ${SUITE_SCRIPT} -- --all`)) {
  console.error(`test:core must run discovered home suites with \`npm run ${SUITE_SCRIPT} -- --all\`.`)
  process.exit(1)
}
// Discovered tests/build-home-*.browser.spec.mjs suites are part of the expected set without a list edit.
const expected = [...core.matchAll(/npm run ([\w:-]+)/g)]
  .map((match) => match[1])
  .filter((name) => name !== 'fixture:preflight' && name !== SUITE_SCRIPT)
  .concat(discoverSuites(browserRoot).map(suiteCommand))

const { shards } = await import(pathToFileURL(runnerPath).href)
if (!shards) throw new Error(`${runnerPath} does not export the smoke shard map`)
const selected = Object.values(shardCommands(shards, browserRoot)).flat()

const counts = (names) => names.reduce((result, name) => {
  result.set(name, (result.get(name) ?? 0) + 1)
  return result
}, new Map())
const expectedCounts = counts(expected)
const selectedCounts = counts(selected)
const missing = [...expectedCounts].filter(([name, count]) => selectedCounts.get(name) !== count)
const unexpected = [...selectedCounts].filter(([name, count]) => expectedCounts.get(name) !== count)

if (missing.length || unexpected.length) {
  const describe = (entries) => entries.map(([name, count]) => `${name} (expected ${count}, found ${selectedCounts.get(name) ?? 0})`)
  const unexpectedDescription = unexpected.map(([name, count]) => `${name} (selected ${count}, expected ${expectedCounts.get(name) ?? 0})`)
  console.error('Browser smoke shards must execute every test:core suite exactly once.')
  if (missing.length) console.error(`Missing or duplicated suites: ${describe(missing).join(', ')}`)
  if (unexpected.length) console.error(`Unexpected or duplicated shard entries: ${unexpectedDescription.join(', ')}`)
  process.exit(1)
}

console.log(`Browser smoke shards cover all ${expected.length} test:core suites exactly once.`)
