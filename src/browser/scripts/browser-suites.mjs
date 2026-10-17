import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

// Home suites are registered by file name alone: tests/build-home-<name>.browser.spec.mjs needs no
// package.json script, shard-map line or guard edit, so parallel home PRs never conflict on them.
export const SUITE_SCRIPT = 'test:browser-suite'
const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const SPEC = /^(build-home-[\w-]+)\.browser\.spec\.mjs$/

// Suites whose spec an explicit npm script already runs keep that script and their hand-placed shard.
export function discoverSuites(root = browserRoot) {
  const scripts = Object.values(JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8')).scripts).join('\n')
  return readdirSync(path.join(root, 'tests'))
    .map(file => file.match(SPEC)?.[1])
    .filter(name => name && !scripts.includes(`tests/${name}.browser.spec.mjs`))
    .sort()
}

// ponytail: FNV-1a of the name spreads suites without timings; switch to recorded timings once a discovered suite has one.
export function suiteShard(name, count) {
  let hash = 0x811c9dc5
  for (const char of name) hash = Math.imul(hash ^ char.charCodeAt(0), 0x01000193) >>> 0
  return (hash % count) + 1
}

export const suiteCommand = name => `${SUITE_SCRIPT} -- ${name}`

// The hand-placed map's key count is the shard count, so adding a shard there is the only edit.
export function shardCommands(shards, root = browserRoot) {
  const count = Object.keys(shards).length
  const plan = Object.fromEntries(Array.from({ length: count }, (_, index) => [index + 1, [...(shards[index + 1] ?? [])]]))
  for (const name of discoverSuites(root)) plan[suiteShard(name, count)].push(suiteCommand(name))
  return plan
}

// `-parity` suites compare against design baselines, like the hand-registered parity suites.
export const suiteArgs = name => [`tests/${name}.browser.spec.mjs`,
  ...(name.endsWith('-parity') ? ['--config', 'playwright.design-parity.config.mjs'] : [])]

async function main(args) {
  const { runBrowserTests } = await import('./run-browser-tests.mjs')
  const names = args[0] === '--all' ? discoverSuites() : args
  const known = new Set(discoverSuites())
  for (const name of names) {
    if (!known.has(name)) throw new Error(`Unknown discovered browser suite: ${name}`)
    const result = await runBrowserTests(suiteArgs(name))
    if (result.code !== 0) {
      process.stderr.write(`Browser suite ${name} failed; sanitized evidence is at ${result.artifactRoot}\n`)
      process.exit(result.code ?? 1)
    }
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main(process.argv.slice(2))
