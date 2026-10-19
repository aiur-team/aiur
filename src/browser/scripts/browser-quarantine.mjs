import { readFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
export const QUARANTINE_LIST = path.join(browserRoot, 'quarantine.txt')
// Specs that fail on purpose (scripts/verify-failure-artifacts.mjs): never annotated, never quarantinable.
export const PROBE_SPECS = ['src/browser/tests/failure-evidence.spec.mjs', 'src/browser/tests/timeout-evidence.spec.mjs']

// Same shape as src/test/quarantine.txt, keyed like the reporter's annotation
// (`new-failure :: BrowserSpec :: <spec>`): `BrowserSpec`, spec path, tracking ticket; tabs delimit fields.
export function parseQuarantine(text) {
  return text.split('\n').flatMap((raw, index) => {
    const line = raw.replace(/\r$/, '')
    if (line.trim() === '' || line.trim().startsWith('#')) return []
    const [module, spec, ticket, ...rest] = line.split('\t')
    if (rest.length || module !== 'BrowserSpec' || !/^src\/browser\/tests\/[\w./-]+\.spec\.mjs$/.test(spec ?? '') || spec.includes('..') || PROBE_SPECS.includes(spec) || !/^#?[1-9]\d*$/.test(ticket ?? '')) {
      throw new Error(`invalid browser quarantine entry on line ${index + 1}`)
    }
    return [{ spec, ticket }]
  })
}

export function readQuarantine(file = QUARANTINE_LIST) {
  try {
    return parseQuarantine(readFileSync(file, 'utf8'))
  } catch (error) {
    if (error.code === 'ENOENT') return []
    throw error
  }
}

const escapeRegex = text => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

// The spec path as Playwright runs it, relative to src/browser.
export const runnableSpec = entry => entry.spec.replace(/^src\/browser\//, '')

// Playwright matches --grep against "<file relative to testDir> <describe...> <title>"; match the whole file.
export const specPattern = entries => entries.map(entry => `(?:^| )${escapeRegex(entry.spec.replace(/^src\/browser\/tests\//, ''))}`).join('|')

// Blocking runs skip quarantined specs; the non-blocking quarantine step sets AIUR_RUN_QUARANTINED=1.
export function quarantineArgs(entries, environment = process.env) {
  if (environment.AIUR_RUN_QUARANTINED === '1' || environment.AIUR_BROWSER_EXPECT_FAILURE === '1' || entries.length === 0) return []
  return ['--grep-invert', specPattern(entries), '--pass-with-no-tests']
}

// Playwright keeps only the last --grep-invert, so fold a caller's filter into the quarantine one.
export function withQuarantine(args, entries, environment = process.env) {
  const [flag, pattern, ...rest] = quarantineArgs(entries, environment)
  const index = args.indexOf('--grep-invert')
  if (!flag || index < 0) return [...args, ...[flag, pattern, ...rest].filter(Boolean)]
  return [...args.slice(0, index), ...args.slice(index + 2), flag, `(?:${args[index + 1]})|${pattern}`, ...rest]
}
