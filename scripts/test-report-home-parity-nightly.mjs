import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { marker, reportNightly } from './report-home-parity-nightly.mjs'

const environment = {
  GITHUB_EVENT_NAME: 'schedule', GITHUB_REF: 'refs/heads/main',
  GITHUB_REPOSITORY: 'aiur-team/aiur', GITHUB_SHA: 'a'.repeat(40),
  GITHUB_RUN_ID: '1234', GITHUB_RUN_ATTEMPT: '2', GH_TOKEN: 'fake-test-token'
}
const root = 'https://api.github.com/repos/aiur-team/aiur/'
const trustedIssue = (overrides = {}) => ({ number: 8, title: 'Home parity nightly failed on main', body: marker,
  user: { login: 'github-actions[bot]' }, html_url: 'issue-8', ...overrides })

function mock(routes) {
  const calls = []
  const request = async (url, options) => {
    const path = url.slice(root.length)
    assert.ok(url.startsWith(root))
    assert.equal(options.headers.Authorization, 'Bearer fake-test-token')
    const call = { path, method: options.method, body: options.body && JSON.parse(options.body) }
    calls.push(call)
    const route = routes.shift()
    assert.ok(route, `Unexpected ${call.method} ${path}`)
    assert.equal(call.method + ' ' + path, route[0])
    const result = typeof route[1] === 'function' ? route[1](call) : route[1]
    return { ok: route[2] === undefined, status: route[2] || 200, json: async () => result }
  }
  return { calls, request, done: () => assert.equal(routes.length, 0) }
}

test('new failure files an unlabelled ticket with exact run/head evidence and verifies its body', async () => {
  let posted
  const api = mock([
    ['GET issues?state=open&per_page=100&page=1', []],
    ['POST issues', call => { posted = call.body; return { number: 7 } }],
    ['GET issues/7', () => ({ ...posted, html_url: 'https://github.com/aiur-team/aiur/issues/7' })]
  ])
  assert.equal(await reportNightly(environment, api.request), 'https://github.com/aiur-team/aiur/issues/7')
  assert.equal(posted.title, 'Home parity nightly failed on main')
  assert.ok(posted.body.includes(marker))
  assert.ok(posted.body.includes('actions/runs/1234/attempts/2'))
  assert.ok(posted.body.includes('Tested head: ' + 'a'.repeat(40)))
  assert.ok(posted.body.includes('fixture/toolchain infrastructure'))
  assert.ok(posted.body.includes('home-parity artifacts'))
  assert.equal(posted.labels, undefined, 'failure ticket must not dispatch an agent automatically')
  api.done()
})

test('later failure comments on the existing marked open issue and verifies the write', async () => {
  let body
  const api = mock([
    ['GET issues?state=open&per_page=100&page=1', [trustedIssue()]],
    ['GET issues/8/comments?per_page=100&page=1', []],
    ['POST issues/8/comments', call => { body = call.body.body; return { id: 9 } }],
    ['GET issues/comments/9', () => ({ body })]
  ])
  assert.equal(await reportNightly(environment, api.request), 'issue-8')
  assert.ok(body.includes('<!-- home-parity-run:1234:2 -->'))
  api.done()
})

for (const location of ['body', 'comment']) test(`repeat delivery is deduplicated from ${location}`, async () => {
  const occurrence = '<!-- home-parity-run:1234:2 -->'
  const routes = [['GET issues?state=open&per_page=100&page=1', [trustedIssue({ body: marker + (location === 'body' ? occurrence : '') })]]]
  if (location === 'comment') routes.push(['GET issues/8/comments?per_page=100&page=1', [{ body: marker + occurrence, user: { login: 'github-actions[bot]' } }]])
  const api = mock(routes)
  assert.equal(await reportNightly(environment, api.request), 'issue-8')
  assert.ok(api.calls.every(call => call.method === 'GET'))
  api.done()
})

test('issue census follows pagination and ignores a marked pull request', async () => {
  const page = Array.from({ length: 100 }, (_, number) => ({ number, body: 'unrelated' }))
  page[0] = trustedIssue({ number: 9, pull_request: {} })
  const api = mock([
    ['GET issues?state=open&per_page=100&page=1', page],
    ['GET issues?state=open&per_page=100&page=2', [trustedIssue({ body: marker + '<!-- home-parity-run:1234:2 -->' })]]
  ])
  assert.equal(await reportNightly(environment, api.request), 'issue-8')
  api.done()
})

test('PR and non-main invocations fail before any GitHub request', async () => {
  for (const replacement of [{ GITHUB_EVENT_NAME: 'pull_request' }, { GITHUB_EVENT_NAME: 'merge_group' }, { GITHUB_REF: 'refs/heads/other' }]) {
    await assert.rejects(reportNightly({ ...environment, ...replacement }, () => assert.fail('unexpected API call')), /scheduled main/)
  }
})

test('malformed run identity fails before any GitHub request', async () => {
  for (const replacement of [{ GITHUB_SHA: 'unknown' }, { GITHUB_REPOSITORY: '../other/repo' }, { GITHUB_RUN_ID: '1234/other' }, { GH_TOKEN: '' }]) {
    await assert.rejects(reportNightly({ ...environment, ...replacement }, () => assert.fail('unexpected API call')), /Incomplete/)
  }
})

test('failed API response does not create a ticket from an unknown census', async () => {
  const api = mock([['GET issues?state=open&per_page=100&page=1', {}, 403]])
  await assert.rejects(reportNightly(environment, api.request), /HTTP 403/)
  assert.equal(api.calls.length, 1)
  api.done()
})

test('exhausted census cap fails closed instead of filing a duplicate ticket', async () => {
  const routes = Array.from({ length: 20 }, (_, i) => [`GET issues?state=open&per_page=100&page=${i + 1}`, Array.from({ length: 100 }, () => ({ body: '' }))])
  const api = mock(routes)
  await assert.rejects(reportNightly(environment, api.request), /Incomplete issue census/)
  api.done()
})

test('a mismatched read-back fails the reporter', async () => {
  const api = mock([
    ['GET issues?state=open&per_page=100&page=1', []],
    ['POST issues', { number: 7 }],
    ['GET issues/7', { body: 'different content' }]
  ])
  await assert.rejects(reportNightly(environment, api.request), /read-back mismatch/)
  api.done()
})

test('untrusted or quoted issue markers cannot suppress filing the genuine nightly failure', async () => {
  let posted
  const occurrence = '<!-- home-parity-run:1234:2 -->'
  const api = mock([
    ['GET issues?state=open&per_page=100&page=1', [
      trustedIssue({ user: { login: 'public-user' }, body: marker + occurrence }),
      trustedIssue({ title: 'Another issue', body: marker + occurrence }),
      trustedIssue({ body: 'Quoted marker: ' + marker + occurrence })
    ]],
    ['POST issues', call => { posted = call.body; return { number: 7 } }],
    ['GET issues/7', () => ({ ...posted, html_url: 'new-nightly-issue' })]
  ])
  assert.equal(await reportNightly(environment, api.request), 'new-nightly-issue')
  assert.ok(posted.body.includes(occurrence))
  api.done()
})

test('a public comment spoofing this run cannot suppress the genuine bot failure comment', async () => {
  let body
  const occurrence = '<!-- home-parity-run:1234:2 -->'
  const api = mock([
    ['GET issues?state=open&per_page=100&page=1', [trustedIssue()]],
    ['GET issues/8/comments?per_page=100&page=1', [
      { body: marker + occurrence, user: { login: 'public-user' } },
      { body: 'Quoted marker: ' + marker + occurrence, user: { login: 'github-actions[bot]' } }
    ]],
    ['POST issues/8/comments', call => { body = call.body.body; return { id: 9 } }],
    ['GET issues/comments/9', () => ({ body })]
  ])
  assert.equal(await reportNightly(environment, api.request), 'issue-8')
  assert.ok(body.startsWith(marker))
  assert.ok(body.includes(occurrence))
  api.done()
})

test('new ticket read-back verifies the expected title as well as the body', async () => {
  let body
  const api = mock([
    ['GET issues?state=open&per_page=100&page=1', []],
    ['POST issues', call => { body = call.body.body; return { number: 7 } }],
    ['GET issues/7', () => ({ body, title: 'Unexpected title' })]
  ])
  await assert.rejects(reportNightly(environment, api.request), /read-back mismatch/)
  api.done()
})

test('nightly wiring isolates issue writes from the reusable four-part matrix', () => {
  const matrix = readFileSync(new URL('../.github/workflows/home-parity.yml', import.meta.url), 'utf8')
  const nightly = readFileSync(new URL('../.github/workflows/home-parity-nightly.yml', import.meta.url), 'utf8')
  assert.ok(matrix.includes('workflow_call:'))
  assert.ok(!matrix.includes('issues: write'))
  assert.ok(!matrix.includes('schedule:'))
  assert.ok(matrix.includes('part: [1, 2, 3, 4]'))
  assert.ok(matrix.includes("AIUR_HOME_PARITY_FULL: '1'"))
  assert.ok(matrix.includes('AIUR_HOME_PARITY_PART: ${{ matrix.part }}'))
  assert.ok(matrix.includes('npm run test:build-home-band-full'))
  assert.ok(matrix.includes('if: ${{ failure() }}'))
  assert.ok(matrix.includes('src/browser/.artifacts-run-*/'))
  assert.ok(nightly.includes('schedule:'))
  assert.ok(nightly.includes('uses: ./.github/workflows/home-parity.yml'))
  assert.ok(nightly.includes("github.ref == 'refs/heads/main'"))
  assert.ok(nightly.includes("needs.matrix.result == 'failure'"))
  assert.ok(nightly.includes('issues: write'))
  assert.ok(nightly.includes('node scripts/report-home-parity-nightly.mjs'))
})
