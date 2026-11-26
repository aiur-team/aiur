import assert from 'node:assert/strict'
import test from 'node:test'
import { browserSelfCheck } from './browser-self-check.mjs'

test('browser self-check reports the Playwright child exit and exact stderr on failure', async () => {
  let stderr = ''
  const status = await browserSelfCheck(
    async (args) => {
      assert.deepEqual(args, ['tests/liveview-smoke.spec.mjs'])
      return { code: 125, signal: null, stderr: 'hook_unavailable command=node' }
    },
    { stdout: { write() {} }, stderr: { write(value) { stderr += value } } }
  )

  assert.equal(status, 1)
  assert.match(stderr, /npx playwright exited code=125/)
  assert.match(stderr, /hook_unavailable command=node/)
})
