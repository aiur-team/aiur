import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const workflow = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
const concurrency = workflow.match(/^concurrency:\n((?:  .+\n)+)/m)?.[1];
assert.ok(concurrency, 'workflow must declare concurrency');
const group = concurrency.match(/^  group: (.+)$/m)?.[1];
const cancel = concurrency.match(/^  cancel-in-progress: \$\{\{ (.+) \}\}$/m)?.[1];
assert.ok(group && cancel, 'group and cancellation expressions must exist');

// These expressions use the shared JS/Actions operators and format syntax only.
function evaluate(expression, github) {
  return runInNewContext(expression, {
    github,
    format: (template, ...args) => template.replace(/\{(\d+)\}/g, (_, i) => args[i]),
  });
}

function policy(event, ref, runId, attempt = 1, pr = 42, name = 'ci') {
  const github = {
    workflow: name, event_name: event, ref, run_id: runId, run_attempt: attempt,
    event: event === 'pull_request' ? { pull_request: { number: pr } } : {},
  };
  return {
    group: group.replace(/\$\{\{ (.*?) \}\}/g, (_, expression) => evaluate(expression, github)),
    cancel: evaluate(cancel, github),
  };
}

const main = policy('push', 'refs/heads/main', 100);
assert.equal(main.cancel, true, 'main pushes must cancel older running runs');
for (const attempt of [1, 2]) {
  assert.deepEqual(policy('push', 'refs/heads/main', 101, attempt), main,
    'main pushes and reruns must share a cancelling group across run IDs');
}
assert.notEqual(policy('push', 'refs/heads/main', 101, 1, 42, 'other').group, main.group,
  'main group must be scoped to this workflow');

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
const security = workflow.match(/^  workflow-security:\n([\s\S]*?)(?=^  merge-ruleset-drift:)/m)?.[1];
assert.ok(security?.includes('run: node scripts/test-ci-concurrency.mjs'),
  'workflow security must execute this test');
console.log('CI concurrency tests passed');
