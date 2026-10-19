#!/usr/bin/env node

import { readFileSync, readdirSync } from 'node:fs'
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

const { shards, budgetMs, recordedSeconds, preflightSeconds } = await import(pathToFileURL(runnerPath).href)
if (!shards) throw new Error(`${runnerPath} does not export the smoke shard map`)
if (!budgetMs || !recordedSeconds) throw new Error(`${runnerPath} must export budgetMs and recordedSeconds`)
const plan = shardCommands(shards, browserRoot)
const selected = Object.values(plan).flat()

function reachableSpecs(command, seen = new Set()) {
  const scriptName = command.split(' ')[0]
  if (seen.has(scriptName)) return new Set()
  seen.add(scriptName)
  const body = scripts[scriptName]
  if (typeof body !== 'string') return new Set()
  const reachable = new Set([...body.matchAll(/(?:^|\s)(tests\/[\w./-]+\.browser\.spec\.mjs)(?=\s|$)/g)].map(match => match[1]))
  for (const nested of body.matchAll(/npm run ([\w:-]+)/g)) {
    for (const spec of reachableSpecs(nested[1], seen)) reachable.add(spec)
  }
  return reachable
}

const reachable = new Set()
for (const command of selected.concat(expected)) {
  for (const spec of reachableSpecs(command)) reachable.add(spec)
}
if (selected.some(command => command.split(' ')[0] === SUITE_SCRIPT)) {
  for (const suite of discoverSuites(browserRoot)) reachable.add(`tests/${suite}.browser.spec.mjs`)
}
const browserSpecs = []
function collectSpecs(directory, prefix = '') {
  for (const entry of readdirSync(resolve(browserRoot, directory), { withFileTypes: true })) {
    const relative = prefix ? `${prefix}/${entry.name}` : entry.name
    if (entry.isDirectory()) collectSpecs(`${directory}/${entry.name}`, relative)
    else if (entry.isFile() && entry.name.endsWith('.browser.spec.mjs')) browserSpecs.push(`tests/${relative}`)
  }
}
collectSpecs('tests')
const scriptsReachable = new Set()
for (const scriptName of Object.keys(scripts)) {
  for (const spec of reachableSpecs(scriptName)) scriptsReachable.add(spec)
}
if (Object.values(scripts).some(body => body.includes(`npm run ${SUITE_SCRIPT} -- --all`))) {
  for (const suite of discoverSuites(browserRoot)) scriptsReachable.add(`tests/${suite}.browser.spec.mjs`)
}
const unreferenced = browserSpecs.filter(spec => !scriptsReachable.has(spec))
if (unreferenced.length) {
  console.error(`Browser specs are not referenced by any npm script: ${unreferenced.join(', ')}`)
  process.exit(1)
}
const dedicatedCiScripts = new Set(['test:home-css', 'test:visual', 'parity:matrix'])
const smokeOrDedicated = new Set(reachable)
for (const scriptName of dedicatedCiScripts) {
  for (const spec of reachableSpecs(scriptName)) smokeOrDedicated.add(spec)
}
const unreachable = [...scriptsReachable].filter(spec => !smokeOrDedicated.has(spec))
if (unreachable.length) {
  console.error(`Browser specs are referenced by npm scripts but not reachable from a smoke shard or dedicated CI script: ${unreachable.join(', ')}`)
  process.exit(1)
}
const missingFiles = [...scriptsReachable].filter(spec => !browserSpecs.includes(spec))
if (missingFiles.length) {
  console.error(`Smoke shard scripts reference missing browser specs: ${missingFiles.join(', ')}`)
  process.exit(1)
}

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

console.log(`Browser smoke shards cover all ${expected.length} test:core suites exactly once; all ${browserSpecs.length} browser specs are referenced and CI-reachable.`)

// A shard's recorded total (preflight plus suites) must leave a quarter of its budget for ci variance.
const unrecorded = selected.filter((command) => recordedSeconds[command] === undefined)
if (unrecorded.length) {
  console.error(`Browser smoke suites with no recorded duration: ${unrecorded.join(', ')}. ` +
    'Add each to recordedSeconds in src/browser/scripts/browser-smoke-durations.mjs, from its shard log.')
  process.exit(1)
}
const limitSeconds = 0.75 * budgetMs / 1000
let over = false
for (const [shard, commands] of Object.entries(plan)) {
  const total = commands.reduce((sum, command) => sum + recordedSeconds[command], preflightSeconds)
  const line = `shard ${shard}: ${total}s recorded of ${limitSeconds}s (75% of ${budgetMs / 1000}s)`
  if (total > limitSeconds) {
    over = true
    console.error(`Browser smoke ${line}. Move suites to a lighter shard in run-browser-smoke-shard.mjs.`)
  } else console.log(line)
}
if (over) process.exit(1)
