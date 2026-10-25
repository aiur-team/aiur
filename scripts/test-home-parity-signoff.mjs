import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'

const root = new URL('../', import.meta.url)
const workflow = readFileSync(new URL('.github/workflows/home-parity-signoff.yml', root), 'utf8')
const scripts = JSON.parse(readFileSync(new URL('src/browser/package.json', root), 'utf8')).scripts

test('sign-off is manual-only and read-only (#5124)', () => {
  assert.match(workflow, /^on:\n  workflow_dispatch:\npermissions:\n  contents: read\n/m)
  assert.ok(!/schedule:|merge_group:|pull_request|issues: write/.test(workflow))
  const ci = readFileSync(new URL('.github/workflows/ci.yml', root), 'utf8')
  assert.ok(!/^  home-parity:|home-parity[.]yml/m.test(ci), 'no merge-group home matrix')
  assert.ok(!readdirSync(new URL('.github/workflows/', root)).some(name => name.startsWith('home-parity-nightly')))
})

test('every parity spec is reached by a sign-off job', () => {
  const runs = [...workflow.matchAll(/run: npm run ([\w:-]+)(?: -- (\w[\w -]*))?/g)]
  // An npm script reaches the specs it names and the npm scripts it calls.
  const reach = name => [scripts[name] ?? assert.fail(`unknown npm script ${name}`)]
    .concat([...scripts[name].matchAll(/npm run ([\w:-]+)/g)].flatMap(([, inner]) => reach(inner))).join('\n')
  const reached = runs.map(([, name, args = '']) => reach(name) +
    args.split(' ').map(suite => ` tests/${suite}.browser.spec.mjs`).join('')).join('\n')
  const parity = readdirSync(new URL('src/browser/tests/', root)).filter(file => /parity.*\.browser\.spec\.mjs$/.test(file))
  assert.ok(parity.length > 10)
  for (const file of parity) assert.ok(reached.includes(`tests/${file}`), `${file} has no sign-off job`)
  assert.ok(reached.includes('tests/build-home-filters-parity.browser.spec.mjs'), 'filter full matrix is included')
  assert.match(scripts['test:build-home-filters-parity:full'], /^AIUR_PARITY_FULL=1 npm run test:build-home-filters-parity$/)
  assert.match(workflow, /name: filters, run: npm run test:build-home-filters-parity:full/)
  assert.ok(workflow.includes("grep -v '/build-home-filters-parity[.]browser[.]spec[.]mjs$'"), 'filters do not duplicate the shared flag partitions')
  assert.ok(reached.includes('scripts/run-build-home-band-full.mjs'), 'band full matrix is included')
  assert.equal(workflow.match(/run: npm run test:build-home-band-full, part: '[1-4]'/g)?.length, 4)
  assert.ok(reached.includes('tests/build-home-gantt.browser.spec.mjs'), 'gantt full matrix is included')
  assert.doesNotMatch(scripts['test:build-home-gantt:full'], /--grep/)
  assert.equal(workflow.match(/run: npm run test:build-home-gantt:full -- --shard=[1-4]\/4 }/g)?.length, 4)
  assert.ok(workflow.includes("test -n \"$specs\" ||"), 'flag job fails closed when no spec matches')
})

test('failed-cell list names each failed test and its artifact folder', t => {
  const cwd = mkdtempSync(path.join(process.env.TMPDIR || tmpdir(), 'parity-failures-'))
  t.after(() => rmSync(cwd, { recursive: true, force: true }))
  mkdirSync(path.join(cwd, '.artifacts-run-x/cell-a'), { recursive: true })
  writeFileSync(path.join(cwd, '.artifacts-run-x/cell-a/error-context.md'),
    '# Test info\n\n- Name: motion.spec >> product interactions noqueue 1024 light gruvbox reduce >> snap.tall-band\n- Location: x\n')
  const result = spawnSync('bash', [new URL('scripts/list-parity-failures.sh', root).pathname, 'motion 3/32'], { cwd, encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /^### Failed parity cells: motion 3\/32$/m)
  assert.ok(result.stdout.includes('- motion.spec >> product interactions noqueue 1024 light gruvbox reduce >> snap.tall-band (`.artifacts-run-x/cell-a`)'))
  const empty = spawnSync('bash', [new URL('scripts/list-parity-failures.sh', root).pathname, 'none'], { cwd: tmpdir(), encoding: 'utf8' })
  assert.equal(empty.status, 0, empty.stderr)
})
