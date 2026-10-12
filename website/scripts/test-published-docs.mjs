import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const workflow = readFileSync(new URL('../../.github/workflows/website.yml', import.meta.url), 'utf8');
// ponytail: extract the known block style; use a YAML parser if the workflow switches styles.
const gate = workflow.match(/      - name: Post-deploy docs smoke check\n([\s\S]+)$/)?.[1];
assert.ok(gate, 'workflow must retain the post-deploy smoke step');
assert.match(gate, /if: github.event_name != 'pull_request'/);
assert.match(gate, /DEPLOYED_SHA: \$\{\{ inputs.deployed_sha \}\}/);
assert.match(workflow, /ref: \$\{\{ inputs.deployed_sha \|\| github.sha \}\}/, 'build the deployed SHA');
assert.match(workflow, /deployed_sha:\n[\s\S]*?required: true\n        type: string/);
assert.match(workflow, /run: node scripts\/test-published-docs.mjs/, 'CI must collect this test');
const validation = workflow.match(/      - name: Validate deployed SHA\n([\s\S]*?)      - name: Checkout/)[1];
assert.match(validation, /working-directory: \./, 'validation runs before checkout creates website/');
const validate = validation.match(/run: '(.+)'/)[1];
for (const [sha, expected] of [['a'.repeat(40), 0], ['', 1], ['main', 1], ['a'.repeat(39), 1]]) {
  assert.equal(spawnSync('bash', ['-c', validate], { env: { ...process.env, DEPLOYED_SHA: sha } }).status, expected);
}
console.log('PASS: dispatch requires a full deployed SHA');
const command = gate.split('        run: |\n')[1]?.replace(/^          /gm, '');
assert.ok(command, 'smoke step must have an executable run block');
const smoke = readFileSync(new URL('./smoke-published-docs.sh', import.meta.url), 'utf8');
const root = mkdtempSync(join(tmpdir(), 'published-docs-'));
try {
  mkdirSync(join(root, 'scripts'));
  mkdirSync(join(root, 'dist/docs/guide'), { recursive: true });
  writeFileSync(join(root, 'scripts/smoke-published-docs.sh'), smoke);
  const html = (hash) => `window.__VP_HASH_MAP__=JSON.parse(${JSON.stringify(JSON.stringify({ 'guide_stream-deck.md': hash }))})`;
  writeFileSync(join(root, 'dist/docs/guide/stream-deck.html'), html('new'));
  // Replace transport only: execute the actual workflow gate and smoke parser/comparison.
  const curl = join(root, 'curl');
  writeFileSync(curl, '#!/usr/bin/env bash\ncp "$LIVE_FIXTURE" "$3"\nprintf "%s" "$LIVE_STATUS"\n');
  chmodSync(curl, 0o755);
  const live = join(root, 'live.html');
  const run = (deployedSha, content, status = '200') => {
    writeFileSync(live, content);
    return spawnSync('bash', ['-e', '-c', command], {
      cwd: root,
      encoding: 'utf8',
      env: {
        ...process.env, PATH: `${root}:${process.env.PATH}`, DEPLOYED_SHA: deployedSha,
        LIVE_FIXTURE: live, LIVE_STATUS: status, SMOKE_POLL_TIMEOUT_SECONDS: '0',
      },
    });
  };
  const skipped = run('', html('old'), '503');
  assert.equal(skipped.status, 0, skipped.stderr);
  assert.match(skipped.stdout, /SKIP: no production deploy triggered/);
  assert.doesNotMatch(skipped.stdout, /attempt/, 'skip must not contact the stale/unreachable site');
  console.log('PASS: push without deploy skips smoke');
  const sha = 'a'.repeat(40);
  // Future-regression guards: the existing smoke script already rejects these bad deploys.
  const fresh = run(sha, html('new'));
  assert.equal(fresh.status, 0, fresh.stderr);
  assert.match(fresh.stdout, /content hash map matches/);
  console.log('PASS: deployed fresh docs pass');
  for (const [name, content, status] of [
    ['stale', html('old'), '200'], ['unreachable', '', '503'], ['malformed', '<html></html>', '200'],
  ]) {
    const result = run(sha, content, status);
    assert.equal(result.status, 1, `${name}: ${result.stdout}\n${result.stderr}`);
    assert.match(result.stderr, /published docs site is stale or unreachable/);
    console.log(`PASS: deployed ${name} docs fail`);
  }
} finally {
  rmSync(root, { recursive: true, force: true });
}
