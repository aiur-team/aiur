import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { spawnSync } from 'node:child_process';

const source = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
const trigger = source.split(/^concurrency:/m)[0];
assert.ok(/^  pull_request:$/m.test(trigger));
assert.ok(!/\b(unlabeled|labeled)\b/.test(trigger), 'unrelated labels must not start or cancel CI');
assert.ok(/^  merge_group:$/m.test(trigger));
assert.ok(/  push:\n    branches: \[v2\]/.test(trigger), 'push CI is limited to v2; main pushes create no run');
const jobs = new Map([...source.split(/^jobs:\n/m)[1].matchAll(/^  ([\w-]+):\n([\s\S]*?)(?=^  [\w-]+:|$(?![\s\S]))/gm)]
  .map(([, id, body]) => [id, body]));
const fullJobs = ['build', 'coverage-partition', 'test', 'dialyzer', 'browser', 'home-css', 'layout-release', 'analytics', 'streamdeck', 'quarantine'];
const fastJobs = ['changes', 'workflow-security', 'lint', 'affected-tests', 'ci-gate'];
function selected(event, full) {
  return [...jobs].filter(([, body]) => {
    const expression = body.match(/^    if: \$\{\{ (.+) \}\}$/m)?.[1];
    return !expression || runInNewContext(expression, {
      github: { event_name: event }, cancelled: () => false, always: () => true,
      needs: { changes: { result: 'success', outputs: { full_ci: String(full) } } },
    });
  }).map(([id]) => id);
}
assert.deepEqual(selected('pull_request', false).sort(), fastJobs.sort(), 'PR selects only five fast jobs');
for (const event of ['merge_group', 'workflow_dispatch', 'pull_request']) {
  const selectedFull = selected(event, true);
  for (const job of fullJobs) assert.ok(selectedFull.includes(job), `${event} requires ${job}`);
  assert.ok(!selectedFull.includes('affected-tests'));
}
assert.ok(jobs.get('ci-gate').includes('if: ${{ always() }}'), 'aggregate must run after failed dependencies');
assert.ok(jobs.get('changes').includes('affected_paths_b64: "${{ steps.classify.outputs.affected_paths_b64 }}"'));
assert.ok(jobs.get('affected-tests').includes('AIUR_CI_CHANGED_PATHS_B64: ${{ needs.changes.outputs.affected_paths_b64 }}'));
for (const job of [...fullJobs.filter((job) => job !== 'quarantine'), ...fastJobs.filter((job) => job !== 'ci-gate')]) {
  assert.ok(jobs.get('ci-gate').includes(job), `gate needs ${job}`);
}
function gate(event, full, failedJob, result = 'failure') {
  const needs = Object.fromEntries([...jobs.keys()].map((job) => [job, { result: 'skipped' }]));
  for (const job of selected(event, full)) needs[job].result = 'success';
  needs.changes.outputs = { full_ci: String(full) };
  if (failedJob) needs[failedJob].result = result;
  return spawnSync('python3', ['scripts/check-ci-gate.py'], {
    encoding: 'utf8', env: { ...process.env, EVENT_NAME: event, NEEDS_JSON: JSON.stringify(needs) },
  });
}
for (const [event, full, required] of [
  ['pull_request', false, fastJobs.filter((job) => job !== 'ci-gate')],
  ['merge_group', true, ['changes', 'workflow-security', 'lint', ...fullJobs.filter((job) => job !== 'quarantine')]],
  ['pull_request', true, ['changes', 'workflow-security', 'lint', ...fullJobs.filter((job) => job !== 'quarantine')]],
]) {
  assert.equal(gate(event, full).status, 0, `${event} passes with selected set successful`);
  for (const job of required) {
    for (const result of ['failure', 'skipped', 'cancelled', '']) {
      const run = gate(event, full, job, result);
      assert.notEqual(run.status, 0, `${event} rejects ${job}=${result}`);
      const cancelledAffected = event === 'pull_request' && !full && job === 'affected-tests' && result === 'cancelled';
      assert.ok(run.stderr.includes(cancelledAffected
        ? 'CI gate failed: affected tests (cancelled; possible timeout)'
        : `CI gate failed: ${job}`), run.stderr);
    }
  }
}
assert.notEqual(gate('merge_group', false).status, 0, 'queue cannot claim fast evidence');
assert.notEqual(gate('schedule', true).status, 0, 'gate refuses unsupported event');
assert.equal(gate('merge_group', true, 'quarantine').status, 0, 'quarantine remains non-blocking');
assert.ok(jobs.get('workflow-security').includes('Set up Elixir for evidence and classifier tests'));
assert.ok(!jobs.get('workflow-security').includes("Set up Elixir for PR evidence\n        if:"));
const affected = jobs.get('affected-tests');
for (const guard of ['base_branch_literal_guard', 'state_owners', 'placement_rule', 'non_transition_facade', 'waiting_descriptor', 'application_child_order', 'health_scanner_child_order']) {
  assert.ok(affected.includes(`${guard}_test.exs`), `fast CI includes ${guard}`);
}
assert.ok(affected.includes('run-ci-affected-tests.py "$PR_BASE"'));
assert.ok(jobs.get('lint').includes('mix compile --warnings-as-errors'));
assert.ok(jobs.get('workflow-security').includes('node scripts/test-ci-events.mjs'));
console.log('CI event selection and aggregate failure tests passed');
