import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { browserChildEnvironment, fixtureServerEnvironment } from './artifact-sanitizer.mjs'

function run(command, environment) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, ['--version'], { env: environment, encoding: 'utf8' })
    let stdout = ''
    let stderr = ''
    child.stdout.on('data', (chunk) => { stdout += chunk })
    child.stderr.on('data', (chunk) => { stderr += chunk })
    child.once('error', reject)
    child.once('exit', (code, signal) => resolve({ code, signal, stdout, stderr }))
  })
}

test('browser and fixture child environments preserve gate hooks and exclude credentials', () => {
  const admission = {
    BASH_ENV: '/release/agent-shell-environment.bash',
    AIUR_BUILD_GATE_HOOK: '/release/priv/build_gate.bash',
    AIUR_AGENT_BIN: '/workspace/.aiur-runtime/bin',
    AIUR_BUILD_GATE_BIN: '/workspace/.aiur-runtime/build-bin',
    AIUR_BUILD_GATE_DIR: '/host/gate',
    AIUR_BUILD_GATE_LOCK_DIR: '/host/gate.locks',
    AIUR_BUILD_GATE_SLOTS: '2',
    AIUR_BUILD_START_STAGGER_SECONDS: '0',
    AIUR_MIN_FREE_MEMORY_MB: '128',
    AIUR_BUILD_GATE_TIMEOUT_SECONDS: '30',
    AIUR_BUILD_GATE_MAX_HOLD_SECONDS: '60',
    AIUR_BUILD_GATE_RETAIN_SECONDS: '0',
    AIUR_BUILD_GATE_LEASE_PATH: '/host/gate/slot-1.owner',
    AIUR_BUILD_GATE_LEASE_TOKEN: 'live-token',
    AIUR_BROWSER_GATE_WORKSPACE: '/workspace'
  }
  const browser = browserChildEnvironment({ ...admission, GITHUB_TOKEN: 'secret', AIUR_SUPERVISOR_TOKEN: 'secret' })
  const fixture = fixtureServerEnvironment(browser)

  for (const child of [browser, fixture]) {
    for (const [name, value] of Object.entries(admission)) assert.equal(child[name], value, name)
    assert.equal(child.GITHUB_TOKEN, undefined)
    assert.equal(child.AIUR_SUPERVISOR_TOKEN, undefined)
  }
})

test('worker-shaped browser child loads the build function before the gated node wrapper runs', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'aiur-browser-hook-'))
  const agentBin = path.join(root, 'bin')
  const gateHook = path.join(root, 'build_gate.bash')
  const shellHook = path.join(root, 'agent-shell.bash')
  const wrapper = path.join(agentBin, 'node')
  const environment = browserChildEnvironment({
    PATH: `${agentBin}:${process.env.PATH}`,
    AIUR_AGENT_BIN: agentBin,
    AIUR_BUILD_GATE_HOOK: gateHook,
    BASH_ENV: shellHook,
    AIUR_BUILD_GATE_DIR: root
  })

  try {
    await (await import('node:fs/promises')).mkdir(agentBin, { recursive: true })
    await writeFile(gateHook, 'node() { printf "gate-loaded\\n"; }\n')
    await writeFile(shellHook, '[ -n "${AIUR_AGENT_BIN:-}" ] && PATH="$AIUR_AGENT_BIN:$PATH"; [ -r "${AIUR_BUILD_GATE_HOOK:-}" ] && . "$AIUR_BUILD_GATE_HOOK"\n')
    await writeFile(wrapper, '#!/bin/bash\ndeclare -F node >/dev/null || { echo \"hook_unavailable command=node\" >&2; exit 125; }\nnode \"$@\"\n', { mode: 0o755 })

    const result = await run(wrapper, environment)
    assert.equal(result.code, 0, result.stderr)
    assert.match(result.stdout, /gate-loaded/)

    const missingHook = { ...environment, AIUR_BUILD_GATE_HOOK: '' }
    const broken = await run(wrapper, missingHook)
    assert.equal(broken.code, 125)
    assert.match(broken.stderr, /hook_unavailable command=node/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
