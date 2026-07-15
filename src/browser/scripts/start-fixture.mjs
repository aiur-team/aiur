import { spawn } from 'node:child_process'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { syntheticFixtureEnvironment } from './artifact-sanitizer.mjs'

const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const sourceRoot = path.resolve(browserRoot, '..')
const inheritedRuntimeNames = [
  'HOME',
  'PATH',
  'TMPDIR',
  'LANG',
  'LC_ALL',
  'SSL_CERT_FILE',
  'HEX_HOME',
  'MIX_HOME',
  'MISE_TRUSTED_CONFIG_PATHS',
  'MISE_CACHE_DIR',
  'MISE_CONFIG_ROOT',
  'MISE_DATA_DIR'
]

function fixtureEnvironment(environment = process.env) {
  const runtimeEnvironment = Object.fromEntries(
    inheritedRuntimeNames.flatMap((name) => environment[name] ? [[name, environment[name]]] : [])
  )

  return { ...runtimeEnvironment, ...syntheticFixtureEnvironment(environment) }
}

const child = spawn('mise', ['exec', '--', 'mix', 'run', '--no-start', 'test/browser/fixture_server.exs'], {
  cwd: sourceRoot,
  env: fixtureEnvironment(),
  stdio: 'inherit'
})

const stop = (signal) => {
  if (!child.killed) child.kill(signal)
}

process.once('SIGINT', () => stop('SIGINT'))
process.once('SIGTERM', () => stop('SIGTERM'))
child.once('error', (error) => {
  process.stderr.write(`${error.message}\n`)
  process.exitCode = 1
})
child.once('exit', (code, signal) => {
  if (signal) process.exitCode = 1
  else process.exitCode = code ?? 1
})
