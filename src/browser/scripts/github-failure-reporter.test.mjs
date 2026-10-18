import assert from 'node:assert/strict'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { failedSpecAnnotationLines } from '../support/github-failure-annotations.mjs'
import GitHubFailureReporter from '../support/github-failure-reporter.mjs'

const browserRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const spec = path.join(browserRoot, 'tests', 'one.browser.spec.mjs')

test('browser failure reporter emits one annotation per failed spec, not per test case', () => {
  assert.deepEqual(failedSpecAnnotationLines([
    { file: spec, status: 'failed' },
    { location: { file: spec }, status: 'timedOut' },
    { file: path.join(browserRoot, 'tests', 'nested', 'two.spec.mjs'), status: 'failed' },
    { file: spec, status: 'passed' },
    { file: path.join(browserRoot, 'scripts', 'helper.mjs'), status: 'failed' }
  ]), [
    '::error title=aiur-test-failure,file=src/browser/tests/nested/two.spec.mjs::new-failure :: BrowserSpec :: src/browser/tests/nested/two.spec.mjs',
    '::error title=aiur-test-failure,file=src/browser/tests/one.browser.spec.mjs::new-failure :: BrowserSpec :: src/browser/tests/one.browser.spec.mjs'
  ])
})

test('browser failure reporter marks overflow as truncated', () => {
  const failures = Array.from({ length: 11 }, (_, index) => ({
    file: path.join(browserRoot, 'tests', `spec-${index}.spec.mjs`),
    status: 'failed'
  }))
  const lines = failedSpecAnnotationLines(failures)
  assert.equal(lines.length, 11)
  assert.equal(lines.at(-1), '::error title=aiur-test-failure::truncated :: and 1 more')
})

test('Playwright config wires the GitHub reporter only for Actions runs', async () => {
  const previousActions = process.env.GITHUB_ACTIONS
  const previousPort = process.env.AIUR_BROWSER_PORT

  try {
    process.env.GITHUB_ACTIONS = 'true'
    process.env.AIUR_BROWSER_PORT = '43211'
    const { default: actionsConfig } = await import('../playwright.config.mjs?github-reporter-test')
    assert.deepEqual(actionsConfig.reporter, [['line'], ['./support/github-failure-reporter.mjs']])

    process.env.GITHUB_ACTIONS = 'false'
    const { default: localConfig } = await import('../playwright.config.mjs?local-reporter-test')
    assert.equal(localConfig.reporter, 'list')
  } finally {
    if (previousActions === undefined) delete process.env.GITHUB_ACTIONS
    else process.env.GITHUB_ACTIONS = previousActions
    if (previousPort === undefined) delete process.env.AIUR_BROWSER_PORT
    else process.env.AIUR_BROWSER_PORT = previousPort
  }
})

test('reporter writes annotations only when running in GitHub Actions', () => {
  const previous = process.env.GITHUB_ACTIONS
  const output = []
  const reporter = new GitHubFailureReporter({}, (line) => output.push(line))
  reporter.onTestEnd({ location: { file: spec } }, { status: 'failed' })

  try {
    process.env.GITHUB_ACTIONS = 'false'
    reporter.onEnd()
    assert.deepEqual(output, [])
    process.env.GITHUB_ACTIONS = 'true'
    reporter.onEnd()
    assert.equal(output.length, 1)
    assert.match(output[0], /file=src\/browser\/tests\/one\.browser\.spec\.mjs/)
  } finally {
    if (previous === undefined) delete process.env.GITHUB_ACTIONS
    else process.env.GITHUB_ACTIONS = previous
  }
})
