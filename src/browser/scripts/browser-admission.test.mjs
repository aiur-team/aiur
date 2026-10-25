import assert from 'node:assert/strict'
import test from 'node:test'
import { browserChildEnvironment, fixtureServerEnvironment } from './artifact-sanitizer.mjs'

test('browser and fixture environment hops preserve admission and exclude credentials', () => {
  const admission = {
    BASH_ENV: '/release/priv/build_gate.bash',
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
  for (const child of [browser, fixtureServerEnvironment(browser)]) {
    for (const [name, value] of Object.entries(admission)) assert.equal(child[name], value, name)
    assert.equal(child.GITHUB_TOKEN, undefined)
    assert.equal(child.AIUR_SUPERVISOR_TOKEN, undefined)
  }
})
