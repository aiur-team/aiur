import { spawn } from 'node:child_process'
import { createServer } from 'node:net'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { sanitizeArtifactRoot, syntheticFixtureEnvironment } from './artifact-sanitizer.mjs'

const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const allocatedPorts = new Set()

export async function allocatePort() {
  let port

  do {
    const server = createServer()

    await new Promise((resolve, reject) => {
      server.once('error', reject)
      server.listen(0, '127.0.0.1', resolve)
    })

    const address = server.address()

    if (!address || typeof address === 'string') throw new Error('Could not allocate an isolated browser-fixture port')

    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()))
    port = address.port
  } while (allocatedPorts.has(port))

  allocatedPorts.add(port)
  return port
}

export async function runBrowserTests(args, environment = process.env) {
  const port = await allocatePort()
  const artifactRoot = environment.AIUR_BROWSER_ARTIFACT_DIR ?? await mkdtemp(path.join(browserRoot, '.artifacts-run-'))
  const npx = process.platform === 'win32' ? 'npx.cmd' : 'npx'
  const fixtureEnvironment = syntheticFixtureEnvironment({ ...environment, AIUR_BROWSER_PORT: String(port) })
  const childEnvironment = {
    ...environment,
    ...fixtureEnvironment,
    AIUR_BROWSER_ARTIFACT_DIR: artifactRoot,
    AIUR_BROWSER_SCREENSHOTS: environment.AIUR_BROWSER_SCREENSHOTS ?? '',
    CI: environment.CI ?? ''
  }

  const result = await new Promise((resolve, reject) => {
    const child = spawn(npx, ['playwright', 'test', ...args], {
      cwd: browserRoot,
      env: childEnvironment,
      stdio: 'inherit'
    })

    child.once('error', reject)
    child.once('exit', (code, signal) => resolve({ code, signal }))
  })

  await sanitizeArtifactRoot(artifactRoot, environment)

  const retainArtifacts = result.code !== 0 || environment.AIUR_BROWSER_SCREENSHOTS === '1' || environment.AIUR_BROWSER_KEEP_ARTIFACTS === '1'

  if (!retainArtifacts) await rm(artifactRoot, { recursive: true, force: true })

  return { ...result, artifactRoot, port }
}

async function main() {
  const result = await runBrowserTests(process.argv.slice(2))

  if (result.code !== 0) {
    process.stderr.write(`Browser tests failed; sanitized evidence is at ${result.artifactRoot}\n`)
    process.exitCode = result.code ?? 1
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main()
