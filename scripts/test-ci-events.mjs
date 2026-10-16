import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { spawnSync } from 'node:child_process';

const source = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
const trigger = source.split(/^concurrency:/m)[0];
assert.ok(/^  pull_request:$/m.test(trigger));
assert.ok(/types: \[opened, synchronize, reopened, ready_for_review, labeled\]/.test(trigger), 'label events let ci:full start a full run');
assert.ok(source.includes("github.event.action != 'labeled' || github.event.label.name == 'ci:full'"), 'unrelated labels must not cancel active CI');
assert.ok(/^  merge_group:$/m.test(trigger));
assert.ok(/  push:\n    branches: \[main, v2\]/.test(trigger), 'main pushes trigger CI');
assert.ok(/  schedule:\n    - cron:/.test(trigger), 'scheduled CI is configured');
const jobs = new Map([...source.split(/^jobs:\n/m)[1].matchAll(/^  ([\w-]+):\n([\s\S]*?)(?=^  [\w-]+:|$(?![\s\S]))/gm)]
  .map(([, id, body]) => [id, body]));
const fullJobs = ['build', 'coverage-partition', 'test', 'dialyzer', 'browser', 'browser-2', 'browser-3', 'browser-4', 'home-css', 'layout-release', 'analytics', 'streamdeck'];
const fastJobs = ['changes', 'workflow-security', 'lint', 'affected-tests', 'ci-gate'];
function selected(event, full, dialyzer = false) {
  return [...jobs].filter(([, body]) => {
    const expression = body.match(/^    if: \$\{\{ (.+) \}\}$/m)?.[1];
    return !expression || runInNewContext(expression, {
      github: { event_name: event, ref: event === 'push' ? 'refs/heads/main' : '' }, cancelled: () => false, always: () => true,
      needs: { changes: { result: 'success', outputs: { full_ci: String(full), dialyzer: String(dialyzer) } } },
    });
  }).map(([id]) => id);
}
assert.deepEqual(selected('pull_request', false).sort(), fastJobs.sort(), 'PR without Elixir source changes selects only fast jobs');
assert.ok(selected('pull_request', false, true).includes('dialyzer'), 'PR changing src/lib Elixir runs dialyzer');
assert.ok(!selected('pull_request', false, false).includes('dialyzer'), 'docs-only PR skips dialyzer');
console.log(`Fast PR jobs (non-CI changes): ${selected('pull_request', false).sort().join(', ')}`);
assert.ok(selected('push', false).includes('quarantine'), 'main push selects quarantine');
assert.ok(selected('schedule', false).includes('quarantine'), 'schedule selects quarantine');
assert.ok(!selected('pull_request', false).includes('quarantine'), 'pull request skips quarantine');
assert.ok(!selected('merge_group', true).includes('quarantine'), 'merge group skips quarantine');
assert.ok(selected('merge_group', false).includes('ci-gate'), 'merge-group ci gate always runs');
for (const event of ['merge_group', 'workflow_dispatch']) {
  const selectedFull = selected(event, true);
  for (const job of fullJobs) assert.ok(selectedFull.includes(job), `${event} requires ${job}`);
  assert.ok(!selectedFull.includes('affected-tests'));
}
assert.ok(jobs.get('ci-gate').includes('always()'), 'aggregate must run after failed dependencies');
assert.ok(jobs.get('ci-gate').includes("github.event_name != 'schedule'"), 'schedule does not need the blocking gate');
assert.ok(jobs.get('affected-tests').includes("github.event_name == 'pull_request'"), 'scoped selector only runs for PRs');
assert.ok(jobs.get('changes').includes('affected_paths_b64: "${{ steps.classify.outputs.affected_paths_b64 }}"'));
assert.ok(jobs.get('changes').includes('dialyzer: "${{ steps.classify.outputs.dialyzer }}"'));
assert.ok(jobs.get('affected-tests').includes('AIUR_CI_CHANGED_PATHS_B64: ${{ needs.changes.outputs.affected_paths_b64 }}'));
for (const job of [...fullJobs.filter((job) => job !== 'quarantine'), ...fastJobs.filter((job) => job !== 'ci-gate')]) {
  assert.ok(jobs.get('ci-gate').includes(job), `gate needs ${job}`);
}
function gate(event, full, dialyzer, failedJob, result = 'failure', dialyzerOutput = String(dialyzer)) {
  const needs = Object.fromEntries([...jobs.keys()].map((job) => [job, { result: 'skipped' }]));
  for (const job of selected(event, full, dialyzer)) needs[job].result = 'success';
  needs.changes.outputs = { full_ci: String(full), dialyzer: dialyzerOutput };
  if (failedJob) needs[failedJob].result = result;
  return spawnSync('python3', ['scripts/check-ci-gate.py'], {
    encoding: 'utf8', env: { ...process.env, EVENT_NAME: event, NEEDS_JSON: JSON.stringify(needs) },
  });
}
for (const [event, full, required] of [
  ['pull_request', false, fastJobs.filter((job) => job !== 'ci-gate')],
  ['merge_group', true, ['changes', 'workflow-security', 'lint', ...fullJobs]],
  ['pull_request', true, ['changes', 'workflow-security', 'lint', ...fullJobs]],
]) {
  assert.equal(gate(event, full, false).status, 0, `${event} passes with selected set successful`);
  for (const job of required) {
    for (const result of ['failure', 'skipped', 'cancelled', '']) {
      const run = gate(event, full, false, job, result);
      assert.notEqual(run.status, 0, `${event} rejects ${job}=${result}`);
      const cancelledAffected = event === 'pull_request' && !full && job === 'affected-tests' && result === 'cancelled';
      assert.ok(run.stderr.includes(cancelledAffected
        ? 'CI gate failed: affected tests (cancelled; possible timeout)'
        : `CI gate failed: ${job}`), run.stderr);
    }
  }
}
assert.equal(gate('pull_request', false, false).status, 0, 'fast docs PR passes with skipped dialyzer');
assert.equal(gate('pull_request', false, true).status, 0, 'fast source PR passes when dialyzer succeeds');
for (const result of ['failure', 'skipped', 'cancelled', '']) {
  const run = gate('pull_request', false, true, 'dialyzer', result);
  assert.notEqual(run.status, 0, `fast source PR rejects dialyzer=${result}`);
  assert.ok(run.stderr.includes('CI gate failed: dialyzer'), run.stderr);
}
assert.notEqual(gate('pull_request', false, false, null, 'failure', 'missing').status, 0, 'gate rejects missing dialyzer output');
assert.notEqual(gate('pull_request', false, false, null, 'failure', 'sometimes').status, 0, 'gate rejects malformed dialyzer output');
assert.notEqual(gate('merge_group', false, false).status, 0, 'queue cannot claim fast evidence');
assert.notEqual(gate('schedule', true, false).status, 0, 'gate refuses unsupported event');
assert.ok(jobs.has('quarantine'), 'quarantine job remains available for scheduled/main runs');
assert.ok(jobs.get('quarantine').includes("github.event_name == 'schedule'"));
assert.ok(jobs.get('quarantine').includes("github.event_name == 'push' && github.ref == 'refs/heads/main'"));
assert.ok(jobs.get('workflow-security').includes('Set up Elixir for evidence and classifier tests'));
assert.ok(!jobs.get('workflow-security').includes("Set up Elixir for PR evidence\n        if:"));
const affected = jobs.get('affected-tests');
const affectedTimeout = Number(affected.match(/^    timeout-minutes: (\d+)$/m)?.[1]);
assert.equal(affectedTimeout, 15, 'the job retains its original overall budget');
assert.ok(affected.includes('run-ci-affected-tests.sh'), 'affected-tests delegates setup and base selection to its helper');
const affectedRunner = readFileSync(new URL('../scripts/run-ci-affected-tests.sh', import.meta.url), 'utf8');
assert.ok(affectedRunner.includes('git rev-parse HEAD^1'), 'affected-tests uses the PR merge base, not a stale event payload');
assert.ok(affectedRunner.includes('affected-tests merge base: $PR_BASE'), 'affected-tests logs the base used for selection');
assert.ok(affectedRunner.includes('affected-tests dependency setup duration: $((SECONDS - started))s'),
  'affected-tests logs dependency setup duration');
for (const guard of ['base_branch_literal_guard', 'state_owners', 'placement_rule', 'non_transition_facade', 'waiting_descriptor', 'application_child_order', 'health_scanner_child_order']) {
  assert.ok(affected.includes(`${guard}_test.exs`), `fast CI includes ${guard}`);
}
assert.ok(affectedRunner.includes('run-ci-affected-tests.py "$PR_BASE"'));
assert.ok(jobs.get('lint').includes('mix compile --warnings-as-errors'));
assert.ok(jobs.get('workflow-security').includes('node scripts/test-ci-events.mjs'));
const packageJson = JSON.parse(readFileSync(new URL('../src/browser/package.json', import.meta.url), 'utf8'));
const coreCommands = [...packageJson.scripts['test:core'].matchAll(/npm run (test:[\w:-]+)/g)].map(([, name]) => name);
const shardScript = readFileSync(new URL('../src/browser/scripts/run-browser-smoke-shard.mjs', import.meta.url), 'utf8');
const shardCommands = [...shardScript.matchAll(/'(test:[\w:-]+)'/g)].map(([, name]) => name);
for (const command of coreCommands) {
  assert.equal(shardCommands.filter((name) => name === command).length, 1, `${command} appears in exactly one browser shard`);
}
assert.deepEqual([...new Set(shardCommands)].sort(), [...new Set(coreCommands)].sort(), 'shards match npm test:core commands');
for (const [job, shard] of [['browser', 1], ['browser-2', 2], ['browser-3', 3], ['browser-4', 4]]) {
  assert.ok(jobs.get(job).includes('./.github/actions/browser-smoke'), `${job} uses the shared browser action`);
  assert.ok(jobs.get(job).includes('actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd'), `${job} checks out before the local action`);
  assert.ok(jobs.get(job).includes('timeout-minutes: 15'), `${job} retains its 15-minute timeout`);
  assert.ok(jobs.get(job).includes(`shard: ${shard}`), `${job} selects shard ${shard}`);
}
const browserAction = readFileSync(new URL('../.github/actions/browser-smoke/action.yml', import.meta.url), 'utf8');
assert.ok(browserAction.includes('using: composite'), 'shared browser setup is an allowed local composite action');
assert.ok(browserAction.includes('run: node scripts/run-browser-smoke-shard.mjs ${{ inputs.shard }}'), 'shared action runs its selected shard');
assert.ok(!source.includes('npm run test:core'), 'no single job runs the unsharded browser suite');
console.log('CI event selection and aggregate failure tests passed');
