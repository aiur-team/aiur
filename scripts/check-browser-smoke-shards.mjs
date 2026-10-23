#!/usr/bin/env node
// Cohesion: one guard that the browser smoke shards, their recorded budget and the CI job deadline agree.

import { readFileSync, readdirSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { dirname, resolve } from 'node:path'
import { discoverSuites, shardCommands, suiteCommand, SUITE_SCRIPT } from '../src/browser/scripts/browser-suites.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const packagePath = process.argv[2] ?? resolve(root, 'src/browser/package.json')
const runnerPath = process.argv[3] ?? resolve(root, 'src/browser/scripts/run-browser-smoke-shard.mjs')
const exclusionsPath = process.argv[4] ?? resolve(root, 'src/browser/scripts/browser-spec-exclusions.json')
const ciRoot = process.argv[5] ?? resolve(root, '.github')
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

function filesUnder(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const path = resolve(directory, entry.name)
    return entry.isDirectory() ? filesUnder(path) : entry.isFile() ? [path] : []
  })
}

function stepBlocks(source) {
  const lines = source.split(/\r?\n/)
  const blocks = []
  for (let index = 0; index < lines.length; index += 1) {
    const start = lines[index].match(/^(\s*)-\s+/)
    if (!start) continue
    let end = index + 1
    while (end < lines.length && !new RegExp(`^${start[1]}-\\s+`).test(lines[end])) end += 1
    blocks.push(lines.slice(index, end).join('\n'))
    index = end - 1
  }
  return blocks
}

function ciBrowserScripts() {
  const scripts = new Set()
  for (const file of filesUnder(ciRoot).filter(path => /\.(?:yml|yaml)$/.test(path))) {
    const source = readFileSync(file, 'utf8')
    const isWorkflow = file.includes('/workflows/')
    if (isWorkflow && !/^\s*(?:pull_request|pull_request_target|merge_group|push|schedule|workflow_call|workflow_run):/m.test(source)) continue
    for (const block of stepBlocks(source)) {
      if (!/^\s*working-directory:\s*src\/browser\s*$/m.test(block)) continue
      for (const match of block.matchAll(/\bnpm run ([\w:-]+)/g)) scripts.add(match[1])
    }
  }
  return scripts
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
const ciScripts = ciBrowserScripts()
const ciReachable = new Set()
for (const scriptName of ciScripts) {
  for (const spec of reachableSpecs(scriptName)) ciReachable.add(spec)
}
if (ciScripts.has(SUITE_SCRIPT)) {
  for (const suite of discoverSuites(browserRoot)) ciReachable.add(`tests/${suite}.browser.spec.mjs`)
}

const exclusions = JSON.parse(readFileSync(exclusionsPath, 'utf8'))
if (!Array.isArray(exclusions)) throw new Error(`${exclusionsPath} must contain a JSON array`)
const exclusionBySpec = new Map()
for (const entry of exclusions) {
  if (!entry || typeof entry.spec !== 'string' || typeof entry.reason !== 'string' || !entry.reason.trim() || !Number.isInteger(entry.ticket) || entry.ticket <= 0) {
    console.error(`Every browser spec exclusion must have a spec, non-empty reason, and positive numeric ticket: ${JSON.stringify(entry)}`)
    process.exit(1)
  }
  if (exclusionBySpec.has(entry.spec)) {
    console.error(`Duplicate browser spec exclusion: ${entry.spec}`)
    process.exit(1)
  }
  exclusionBySpec.set(entry.spec, entry)
}
const unknownExclusions = [...exclusionBySpec.keys()].filter(spec => !browserSpecs.includes(spec))
if (unknownExclusions.length) {
  console.error(`Browser spec exclusions do not match existing specs: ${unknownExclusions.join(', ')}`)
  process.exit(1)
}

const missingFiles = [...new Set([...scriptsReachable, ...reachable, ...ciReachable])].filter(spec => !browserSpecs.includes(spec))
if (missingFiles.length) {
  console.error(`CI scripts reference missing browser specs: ${missingFiles.join(', ')}`)
  process.exit(1)
}

const unreferenced = browserSpecs.filter(spec => !scriptsReachable.has(spec))
if (unreferenced.length) {
  console.error(`Browser specs are not referenced by any npm script: ${unreferenced.join(', ')}`)
  process.exit(1)
}
const smokeOrCi = new Set([...reachable, ...ciReachable])
const unreachable = browserSpecs.filter(spec => !smokeOrCi.has(spec) && !exclusionBySpec.has(spec))
if (unreachable.length) {
  console.error(`Browser specs are not reachable from a smoke shard or CI workflow/action script and have no exclusion: ${unreachable.join(', ')}`)
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

console.log(`Browser smoke shards cover all ${expected.length} test:core suites exactly once; all ${browserSpecs.length} browser specs are CI-reachable or explicitly excluded.`)

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

// The job deadline must cover setup, the runner's whole suite budget and post-suite steps, so a loaded
// shard that is still making progress is stopped by its own budget or per-test timeouts, never cancelled.
const { setupSeconds, tailSeconds } = await import(pathToFileURL(runnerPath).href)
const browserJob = readFileSync(resolve(ciRoot, 'workflows/ci.yml'), 'utf8').match(/^ {2}browser:\n(?:(?: {3,}.*)?\n)*/m)?.[0]
const jobSeconds = 60 * Number(browserJob?.match(/^ {4}timeout-minutes: (\d+)$/m)?.[1])
const neededSeconds = setupSeconds + budgetMs / 1000 + tailSeconds
const deadline = `browser job timeout ${jobSeconds}s for setup ${setupSeconds}s + suite budget ${budgetMs / 1000}s + tail ${tailSeconds}s = ${neededSeconds}s`
// NaN (no timeout found, or a missing export) fails this comparison too.
if (!(jobSeconds >= neededSeconds)) {
  console.error(`Browser smoke ${deadline}: too short. Raise timeout-minutes in .github/workflows/ci.yml.`)
  process.exit(1)
}
console.log(deadline)
