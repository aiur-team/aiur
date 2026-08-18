import { spawn } from 'node:child_process'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { fixtureServerEnvironment } from './artifact-sanitizer.mjs'

const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const sourceRoot = path.resolve(browserRoot, '..')

const child = spawn('mise', ['exec', '--', 'mix', 'run', '--no-start', 'test/browser/fixture_server.exs'], {
  cwd: sourceRoot,
  env: fixtureServerEnvironment(),
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
