import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import { browserChildEnvironment } from './artifact-sanitizer.mjs'

const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'))
const selfCheck = await readFile(new URL('./browser-self-check.mjs', import.meta.url), 'utf8')

test('browser self-check invokes the same Playwright runner used by worker specs', () => {
  assert.equal(packageJson.scripts['test:browser-self-check'], 'node scripts/browser-self-check.mjs')
  assert.match(packageJson.scripts['test:admission'], /browser-self-check\.test\.mjs/)
  assert.match(selfCheck, /runBrowserTests\(\['tests\/liveview-smoke\.spec\.mjs'\]\)/)

  const source = {
    BASH_ENV: '/agent-shell.bash',
    AIUR_BUILD_GATE_HOOK: '/build_gate.bash',
    AIUR_AGENT_BIN: '/workspace/bin',
    GITHUB_TOKEN: 'must-not-leak'
  }
  const child = browserChildEnvironment(source)
  assert.equal(child.BASH_ENV, source.BASH_ENV)
  assert.equal(child.AIUR_BUILD_GATE_HOOK, source.AIUR_BUILD_GATE_HOOK)
  assert.equal(child.AIUR_AGENT_BIN, source.AIUR_AGENT_BIN)
  assert.equal(child.GITHUB_TOKEN, undefined)
})
