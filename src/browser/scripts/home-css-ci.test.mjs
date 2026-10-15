import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import test from 'node:test'

// Playwright pins this YAML parser; use it without adding a test-only dependency.
const { yaml } = createRequire(import.meta.url)('../node_modules/playwright-core/lib/utilsBundle.js')
const root = new URL('../../../', import.meta.url)
const read = path => readFileSync(new URL(path, root), 'utf8')
const workflow = yaml.parse(read('.github/workflows/ci.yml'))
const home = yaml.parse(read('.github/actions/verify-home-css/action.yml'))
const scripts = JSON.parse(read('src/browser/package.json')).scripts

test('required full CI gate rejects failures, cancellations and skipped browser jobs', () => {
  const gate = workflow.jobs['ci-gate']
  assert.ok(gate.needs.includes('browser'))
  assert.ok(gate.needs.includes('home-css'))
  assert.match(gate.if, /always\(\)/)
  const step = gate.steps.find(step => step.name === "Require the event's selected jobs")
  assert.equal(step.env.EVENT_NAME, '${{ github.event_name }}')
  assert.equal(step.env.NEEDS_JSON, '${{ toJSON(needs) }}')
  for (const browser of ['success', 'failure', 'cancelled', 'skipped']) {
    for (const css of ['success', 'failure', 'cancelled', 'skipped']) {
      const needs = Object.fromEntries(gate.needs.map(job => [job, { result: 'success' }]))
      needs.changes.outputs = { full_ci: 'true' }
      needs.browser.result = browser
      needs['home-css'].result = css
      const result = spawnSync('bash', ['-c', step.run], {
        cwd: root, env: { ...process.env, EVENT_NAME: 'merge_group', NEEDS_JSON: JSON.stringify(needs) }
      })
      assert.equal(result.status === 0, browser === 'success' && css === 'success', `${browser}/${css}`)
    }
  }
})

test('home matrix has an independent deadline and stays in the local full suite', () => {
  assert.equal(workflow.jobs.browser['timeout-minutes'], 30)
  assert.match(workflow.jobs['home-css'].if, /outputs.full_ci == 'true'/)
  assert.equal(workflow.jobs['home-css']['timeout-minutes'], 25)
  assert.equal(workflow.jobs['home-css'].steps.at(-1).uses, './.github/actions/verify-home-css')
  assert.equal(home.runs.steps.find(step => step.name === 'Run complete home CSS matrix').run,
    'npm run fixture:preflight && npm run test:home-css')
  assert.equal(home.runs.steps.at(-1).if, '${{ always() }}')
  assert.equal(scripts.test, 'npm run test:core && npm run test:home-css')
  assert.ok(!scripts['test:core'].includes('npm run test:home-css'))
  assert.match(scripts['test:home-css'], /home-css-census\.browser\.spec\.mjs tests\/home-css-parity\.browser\.spec\.mjs/)
})
