import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const packageJson = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'))
const selfCheck = await readFile(new URL('./browser-self-check.mjs', import.meta.url), 'utf8')

test('browser package exposes a Chromium self-check and runs it in admission tests', () => {
  assert.equal(packageJson.scripts['test:browser-self-check'], 'node scripts/browser-self-check.mjs')
  assert.match(packageJson.scripts['test:admission'], /browser-self-check\.test\.mjs/)
  assert.match(selfCheck, /chromium\.launch\(\{ headless: true \}\)/)
  assert.match(selfCheck, /Browser self-check failed during/)
  assert.match(selfCheck, /npm ci --prefix src\/browser/)
})
