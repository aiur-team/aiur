import { spawn } from 'node:child_process'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { fixtureServerEnvironment } from './artifact-sanitizer.mjs'

const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const sourceRoot = path.resolve(browserRoot, '..')

export async function startFixture(environment = process.env) {
  const child = spawn('mise', ['exec', '--', 'mix', 'run', '--no-start', 'test/browser/fixture_server.exs'], {
    cwd: sourceRoot,
    env: fixtureServerEnvironment(environment),
    stdio: ['ignore', 'pipe', 'inherit'],
    detached: process.platform !== 'win32'
  })
  let output = ''
  let resolvePort
  let rejectPort
  const port = new Promise((resolve, reject) => { resolvePort = resolve; rejectPort = reject })
  const timeout = setTimeout(() => rejectPort(new Error('Fixture server did not bind within 60s')), 60_000)
  const closed = new Promise((resolve) => child.once('close', resolve))
  const stop = (signal = 'SIGTERM') => {
    clearTimeout(timeout)
    try {
      if (process.platform !== 'win32' && child.pid) process.kill(-child.pid, signal)
      else child.kill(signal)
    } catch (error) {
      if (error.code !== 'ESRCH') throw error
    }
    return closed
  }

  child.stdout.on('data', (chunk) => {
    output = `${output}${String(chunk)}`.slice(-4096)
    const match = output.match(/^AIUR_BROWSER_FIXTURE_PORT=(\d+)$/m)
    if (match) resolvePort(Number(match[1]))
  })
  child.once('error', rejectPort)
  child.once('exit', (code) => rejectPort(new Error(`Fixture server exited before binding (exit ${code})`)))

  try {
    return { port: await port, stop }
  } catch (error) {
    await stop()
    throw error
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const fixture = await startFixture()
  process.stdout.write(`Aiur browser harness fixture ready at http://127.0.0.1:${fixture.port}\n`)
  const stop = (signal) => fixture.stop(signal)
  process.once('SIGINT', () => stop('SIGINT'))
  process.once('SIGTERM', () => stop('SIGTERM'))
}
