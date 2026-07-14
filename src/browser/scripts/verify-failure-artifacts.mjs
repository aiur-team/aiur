import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { artifactFiles, writeSanitizedDiagnostic } from './artifact-sanitizer.mjs'
import { allocatePort, runBrowserTests } from './run-browser-tests.mjs'

const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

async function assertPortReleased(port) {
  const server = createServer()

  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, '127.0.0.1', resolve)
  })

  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()))
}

async function main() {
  const firstPort = await allocatePort()
  const secondPort = await allocatePort()
  assert.notEqual(firstPort, secondPort, 'isolated runner allocations must not share a port')

  const root = await mkdtemp(path.join(tmpdir(), 'aiur-browser-harness-proof-'))
  const sentinel = 'fixture-secret-that-must-not-leak'
  const preserveEvidence = process.env.AIUR_BROWSER_KEEP_ARTIFACTS === '1'

  try {
    const diagnostic = await writeSanitizedDiagnostic(root, 'fixture.log', `authorization: Bearer ${sentinel}`, {
      AIUR_SUPERVISOR_TOKEN: sentinel
    })
    const contents = await readFile(diagnostic, 'utf8')
    assert.match(contents, /\[REDACTED\]/)
    assert.doesNotMatch(contents, new RegExp(sentinel))

    const evidenceRoot = path.join(root, 'evidence')
    const result = await runBrowserTests(['tests/failure-evidence.spec.mjs', 'tests/timeout-evidence.spec.mjs'], {
      ...process.env,
      AIUR_BROWSER_ARTIFACT_DIR: evidenceRoot,
      AIUR_BROWSER_KEEP_ARTIFACTS: '1'
    })

    assert.notEqual(result.code, 0, 'the failure-evidence probe must fail intentionally')
    const files = await artifactFiles(evidenceRoot)
    assert(files.some((file) => file.endsWith('trace.zip')), 'expected a failure trace')
    assert(files.some((file) => file.endsWith('.png')), 'expected a failure screenshot')
    await assertPortReleased(result.port)
    const disposition = preserveEvidence ? 'Retained' : 'Verified'
    process.stdout.write(`${disposition} sanitized failure evidence at ${evidenceRoot}\n`)
  } finally {
    if (!preserveEvidence) await rm(root, { recursive: true, force: true })
  }
}

await main()
