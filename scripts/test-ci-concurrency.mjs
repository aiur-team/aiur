import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const workflow = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
const concurrency = workflow.match(/^concurrency:\n((?:  .+\n)+)/m)?.[1];
assert.ok(concurrency, 'workflow must declare concurrency');
const group = concurrency.match(/^  group: (.+)$/m)?.[1];
const cancel = concurrency.match(/^  cancel-in-progress: \$\{\{ (.+) \}\}$/m)?.[1];
assert.ok(group && cancel, 'group and cancellation expressions must exist');
assert.ok(!/^  queue:/m.test(concurrency), 'keep the default single pending slot');

// These expressions use the shared JS/Actions operators and format syntax only.
function evaluate(expression, github) {
  return runInNewContext(expression, {
    github,
    format: (template, ...args) => template.replace(/\{(\d+)\}/g, (_, i) => args[i]),
  });
}

function policy(event, ref, runId, attempt = 1, pr = 42, name = 'ci', action = 'synchronize', label = 'ci:full') {
  const github = {
    workflow: name, event_name: event, ref, run_id: runId, run_attempt: attempt,
    event: event === 'pull_request' ? { action, label: { name: label }, pull_request: { number: pr } } : {},
  };
  return {
    group: group.replace(/\$\{\{ (.*?) \}\}/g, (_, expression) => evaluate(expression, github)),
    cancel: evaluate(cancel, github),
  };
}
assert.equal(policy('pull_request', 'refs/pull/42/merge', 100, 1, 42, 'ci', 'labeled', 'other').cancel, false);
assert.equal(policy('pull_request', 'refs/pull/42/merge', 100, 1, 42, 'ci', 'labeled', 'ci:full').cancel, true);

// Existing event policies deliberately remain unchanged, including exact groups.
for (const [event, ref] of [
  ['push', 'refs/heads/v2'],
  ['merge_group', 'refs/heads/gh-readonly-queue/main/pr-42-abc'],
  ['workflow_dispatch', 'refs/heads/main'],
]) {
  for (const runId of [100, 101]) {
    for (const attempt of [1, 2]) {
      assert.deepEqual(policy(event, ref, runId, attempt), {
        group: `ci-${event}-${runId}-${attempt}`, cancel: false,
      });
    }
  }
}
for (const pr of [42, 43]) {
  for (const runId of [100, 101]) {
    assert.deepEqual(policy('pull_request', `refs/pull/${pr}/merge`, runId, 1, pr), {
      group: `ci-pull_request-${pr}-1`, cancel: true,
    });
    assert.deepEqual(policy('pull_request', `refs/pull/${pr}/merge`, runId, 2, pr), {
      group: `ci-pull_request-${runId}-2`, cancel: false,
    });
  }
}
const security = workflow.match(/^  workflow-security:\n([\s\S]*?)(?=^  build:)/m)?.[1];
assert.ok(security?.includes('run: node scripts/test-ci-concurrency.mjs'),
  'workflow security must execute this test');
console.log('CI concurrency tests passed');

for (const [job, upstream] of [['test', 'coverage-partition']]) {
  const body = workflow.match(new RegExp(`^  ${job}:\\n([\\s\\S]*?)(?=^  [a-z][a-z-]*:)`, 'm'))?.[1];
  const condition = body?.match(/^    if: \$\{\{ (.+) \}\}$/m)?.[1];
  assert.ok(condition, `${job} must declare a condition`);
  function runs(result, cancelled = false, draft = false, event = 'pull_request') {
    return runInNewContext(condition, {
      github: { event_name: event },
      needs: { [upstream]: { result }, changes: { outputs: { full_ci: String(!draft) } } }, cancelled: () => cancelled, always: () => true,
    });
  }
  assert.equal(runs('cancelled', true), false, `${job} must skip a cancelled run's inputs`);
  assert.equal(runs('success', true), false, `${job} must stop on workflow cancellation`);
  assert.equal(runs('skipped', true), false, `${job} must skip cancelled runs with skipped inputs`);
  assert.equal(runs('skipped'), true, `${job} must diagnose a skipped shard`);
  for (const result of ['success', 'failure']) {
    assert.equal(runs(result), true, `${job} must still run on ${result}`);
    assert.equal(runs(result, false, true), false, `${job} must skip fast PR runs`);
    assert.equal(runs(result, false, false, 'merge_group'), true, `${job} must run in the merge queue`);
  }
  console.log(`${job} cancellation tests passed`);
}

const testJob = workflow.match(/^  test:\n([\s\S]*?)(?=^  [a-z][a-z-]*:)/m)?.[1];
assert.ok(testJob?.includes('run: make coverage-report'), 'test must retain the coverage gate');
assert.ok(testJob?.includes('needs: [coverage-partition, changes]'),
  'test must wait directly for all coverage shards');
assert.ok(/for partition in 1 2 3 4; do\n\s+test -s "cover\/\$\{partition\}\.coverdata"/.test(testJob),
  'test must fail when any shard skips its coverage export');
assert.ok(!/^  coverage:$/m.test(workflow), 'coverage and test must use one runner job');
