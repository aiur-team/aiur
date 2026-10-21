import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { spawnSync } from 'node:child_process';

const source = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
const trigger = source.split(/^concurrency:/m)[0];
assert.ok(/^  pull_request:$/m.test(trigger));
assert.ok(/types: \[opened, synchronize, reopened, ready_for_review, labeled\]/.test(trigger), 'label events let ci:full start a full run');
assert.ok(source.includes("github.event.action == 'synchronize'"), 'a new PR head cancels its superseded CI run');
assert.ok(source.includes("github.event.label.name == 'ci:full'"), 'the full-CI label replaces the fast run');
assert.ok(/^  merge_group:$/m.test(trigger));
assert.ok(/  push:\n    branches: \[main, v2\]/.test(trigger), 'main pushes trigger CI');
assert.ok(/  schedule:\n    - cron:/.test(trigger), 'scheduled CI is configured');
const jobs = new Map([...source.split(/^jobs:\n/m)[1].matchAll(/^  ([\w-]+):\n([\s\S]*?)(?=^  [\w-]+:|$(?![\s\S]))/gm)]
  .map(([, id, body]) => [id, body]));
const fullJobs = ['build', 'coverage-partition', 'test', 'dialyzer', 'browser', 'home-css', 'layout-release', 'analytics', 'streamdeck', 'pre-handoff'];
const fastJobs = ['changes', 'workflow-security', 'lint', 'affected-tests', 'soak', 'ci-gate', 'pre-handoff'];
function selected(event, full, dialyzer = false, payload = { pull_request: {} }) {
  const condition = (body) => body.match(/^    if: \$\{\{ (.+) \}\}$/m)?.[1];
  const run = (expression, changes) => !expression || runInNewContext(expression, {
    github: { event_name: event, event: payload, ref: event === 'push' ? 'refs/heads/main' : '' }, cancelled: () => false, always: () => true,
    needs: { changes, 'pre-handoff': { result: changes.result } },
  });
  const changesRuns = run(condition(jobs.get('changes')), {});
  const changes = changesRuns ? { result: 'success', outputs: { full_ci: String(full), dialyzer: String(dialyzer), browser_smoke: String(event === 'merge_group') } } : { result: 'skipped', outputs: {} };
  // Every other job needs changes, so a skipped changes skips it unless a status function overrides that.
  return [...jobs].filter(([id, body]) => id === 'changes' ? changesRuns
    : (changesRuns || /always\(\)|cancelled\(\)/.test(condition(body) ?? '')) && run(condition(body), changes)).map(([id]) => id);
}
assert.deepEqual(selected('pull_request', false).sort(), fastJobs.sort(), 'PR without Elixir source changes selects only fast jobs');
for (const payload of [{ pull_request: { draft: true } }, { action: 'labeled', pull_request: { draft: true } }]) {
  assert.deepEqual(selected('pull_request', true, true, payload), [], `no CI job holds a runner for ${JSON.stringify(payload)} (#4942)`);
}
assert.deepEqual(selected('pull_request', false, false, { action: 'ready_for_review', pull_request: { draft: false } }).sort(), fastJobs.sort(), 'marking a draft ready runs CI');
const website = readFileSync(new URL('../.github/workflows/website.yml', import.meta.url), 'utf8');
assert.ok(website.includes('types: [opened, synchronize, reopened, ready_for_review, closed]'), 'website starts on ready and cancels on close');
assert.ok(website.includes("  guards:\n    if: ${{ github.event.pull_request.draft != true && github.event.action != 'closed' }}"), 'website skips drafts and closed PRs');
const websiteGuards = website.split(/^  guards:\n/m)[1];
assert.ok(/^    timeout-minutes: 15$/m.test(websiteGuards), 'website guards job has a finite runner budget');
assert.ok(/      - name: Test visual regressions\n        timeout-minutes: 8\n/.test(websiteGuards), 'Docker visual regression step has a shorter finite budget');
const visualDocker = JSON.parse(readFileSync(new URL('../website/package.json', import.meta.url), 'utf8')).scripts['test:visual:docker'];
assert.ok(visualDocker.includes('-v "$PWD/..":/repo -w /repo/website --tmpfs /repo/website/docs-app/node_modules:exec'),
  'Docker visual build mounts the repository root so docs loaders resolve repository-relative paths');
const aiurStyle = readFileSync(new URL('../.github/workflows/aiur-style.yml', import.meta.url), 'utf8');
assert.ok(/^  merge_group:$/m.test(aiurStyle.split(/^jobs:/m)[0]), 'aiur-style checks dist on merge queue candidates (#4983)');
const [queueDist, buildAndTest] = aiurStyle.split(/^  build-and-test:\n/m);
assert.ok(queueDist.includes("if: ${{ github.event_name == 'merge_group' }}") && queueDist.includes('npm run check-dist'), 'queue job runs check-dist');
assert.ok(!queueDist.includes('test:visual') && !queueDist.includes('container:'), 'queue job skips the Playwright visual suite');
assert.ok(buildAndTest.startsWith("    if: ${{ github.event_name != 'merge_group' }}\n"), 'full aiur-style suite stays off merge groups');
assert.ok(/^    timeout-minutes: 20$/m.test(buildAndTest), 'aiur-style visual job has a finite runner budget');
assert.ok(selected('pull_request', false, true).includes('dialyzer'), 'PR changing src/lib Elixir runs dialyzer');
assert.ok(!selected('pull_request', false, false).includes('dialyzer'), 'docs-only PR skips dialyzer');
console.log(`Fast PR jobs (non-CI changes): ${selected('pull_request', false).sort().join(', ')}`);
assert.ok(selected('push', false).includes('quarantine'), 'main push selects quarantine');
assert.ok(selected('schedule', false).includes('quarantine'), 'schedule selects quarantine');
assert.ok(!selected('pull_request', false).includes('quarantine'), 'pull request skips quarantine');
assert.ok(!selected('merge_group', true).includes('quarantine'), 'merge group skips quarantine');
const browserSmoke = readFileSync(new URL('../.github/actions/browser-smoke/action.yml', import.meta.url), 'utf8');
assert.ok(/github.ref == 'refs\/heads\/main' }}\n.*\n      run: node scripts\/run-quarantined-browser-tests.mjs \|\| echo/.test(browserSmoke), 'quarantined browser specs run on main and never block');
assert.ok(selected('merge_group', false).includes('ci-gate'), 'merge-group ci gate always runs');
for (const event of ['merge_group', 'workflow_dispatch']) {
  const selectedFull = selected(event, true);
  for (const job of fullJobs) assert.ok(selectedFull.includes(job), `${event} requires ${job}`);
  assert.equal(selectedFull.includes('affected-tests'), event === 'merge_group',
    `${event} ${event === 'merge_group' ? 'runs' : 'skips'} the time-bomb guard job`);
}
assert.ok(!jobs.has('home-parity') && !jobs.get('ci-gate').includes('home-parity'), 'the full home matrix is manual-only (#5124)');
assert.ok(jobs.get('ci-gate').includes('always()'), 'aggregate must run after failed dependencies');
assert.ok(jobs.get('ci-gate').includes("github.event_name != 'schedule'"), 'schedule does not need the blocking gate');
assert.ok(jobs.get('affected-tests').includes("github.event_name == 'merge_group'"), 'merge queue also runs the time-bomb guard');
assert.ok(jobs.get('changes').includes('affected_paths_b64: "${{ steps.classify.outputs.affected_paths_b64 }}"'));
assert.ok(jobs.get('changes').includes('dialyzer: "${{ steps.classify.outputs.dialyzer }}"'));
assert.ok(jobs.get('changes').includes('browser_smoke: "${{ steps.classify.outputs.browser_smoke }}"'));
assert.ok(jobs.get('affected-tests').includes('AIUR_CI_CHANGED_PATHS_B64: ${{ needs.changes.outputs.affected_paths_b64 }}'));
for (const job of [...fullJobs.filter((job) => job !== 'quarantine'), ...fastJobs.filter((job) => job !== 'ci-gate')]) {
  assert.ok(jobs.get('ci-gate').includes(job), `gate needs ${job}`);
}
function gate(event, full, dialyzer, failedJob, result = 'failure', dialyzerOutput = String(dialyzer)) {
  const needs = Object.fromEntries([...jobs.keys()].map((job) => [job, { result: 'skipped' }]));
  for (const job of selected(event, full, dialyzer)) needs[job].result = 'success';
  needs.changes.outputs = { full_ci: String(full), dialyzer: dialyzerOutput, browser_smoke: String(event === 'merge_group') };
  if (failedJob) needs[failedJob].result = result;
  return spawnSync('python3', ['scripts/check-ci-gate.py'], {
    encoding: 'utf8', env: { ...process.env, EVENT_NAME: event, NEEDS_JSON: JSON.stringify(needs) },
  });
}
for (const [event, full, required] of [
  ['pull_request', false, fastJobs.filter((job) => job !== 'ci-gate')],
  ['merge_group', true, ['changes', 'workflow-security', 'lint', 'affected-tests', ...fullJobs]],
  ['pull_request', true, ['changes', 'workflow-security', 'lint', 'soak', ...fullJobs.filter((job) => job !== 'browser')]],
]) {
  assert.equal(gate(event, full, false).status, 0, `${event} passes with selected set successful`);
  for (const job of required) {
    for (const result of ['failure', 'skipped', 'cancelled', '']) {
      const run = gate(event, full, false, job, result);
      assert.notEqual(run.status, 0, `${event} rejects ${job}=${result}`);
      const cancelledAffected = job === 'affected-tests' && result === 'cancelled';
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
assert.notEqual(gate('merge_group', true, false, 'affected-tests', 'skipped').status, 0,
  'merge-group gate requires the time-bomb guard');
// Soak: every PR, fast or full, repeats its changed tests; the queue never soaks.
assert.ok(selected('pull_request', true).includes('soak'), 'full PR runs still soak');
for (const event of ['merge_group', 'workflow_dispatch']) assert.ok(!selected(event, true).includes('soak'), `${event} never soaks`);
assert.ok(jobs.get('soak').includes('uses: ./.github/workflows/soak.yml'));
const soak = readFileSync(new URL('../.github/workflows/soak.yml', import.meta.url), 'utf8');
assert.ok(/^on:\n  workflow_call:$/m.test(soak), 'soak runs only when ci.yml calls it');
assert.ok(soak.includes('bash ../scripts/install-ci-zsh.sh'), 'soak uses the shared resilient zsh installer');
assert.ok(soak.includes('python3 scripts/ci-soak.py select HEAD^1 >> "$GITHUB_OUTPUT"'), 'soak selects against the PR merge base');
assert.ok(soak.includes('SOAK_TESTS: ${{ needs.select.outputs.soak_tests }}'), 'paths reach the runner through env, not shell');
assert.ok(soak.includes('SOAK_SPECS: ${{ needs.select.outputs.soak_specs }}'));
assert.notEqual(gate('schedule', true, false).status, 0, 'gate refuses unsupported event');
assert.ok(jobs.has('quarantine'), 'quarantine job remains available for scheduled/main runs');
assert.ok(jobs.get('quarantine').includes("github.event_name == 'schedule'"));
assert.ok(jobs.get('quarantine').includes("github.event_name == 'push' && github.ref == 'refs/heads/main'"));
assert.ok(jobs.get('workflow-security').includes('timeout-minutes: 15'), 'security job allows for dependency setup and a cold registry');
assert.ok(jobs.get('workflow-security').includes("needs['pre-handoff'].result"),
  'required workflow security check fails when pre-handoff checks fail');
assert.ok(jobs.get('pre-handoff').includes('./.github/actions/pre-handoff'), 'bounded pre-handoff job runs its dedicated action');
assert.ok(readFileSync(new URL('../.github/actions/pre-handoff/action.yml', import.meta.url), 'utf8')
  .includes('uses: ./.github/actions/setup-elixir'), 'pre-handoff action sets up Elixir');
assert.ok(!jobs.get('workflow-security').includes("Set up Elixir for PR evidence\n        if:"));
const affected = jobs.get('affected-tests');
const affectedTimeout = Number(affected.match(/^    timeout-minutes: (\d+)$/m)?.[1]);
assert.equal(affectedTimeout, 25, 'the job allows the bounded merge-queue time-bomb rerun');
assert.ok(affected.includes('run-ci-affected-tests.sh'), 'affected-tests delegates setup and base selection to its helper');
const affectedRunner = readFileSync(new URL('../scripts/run-ci-affected-tests.sh', import.meta.url), 'utf8');
assert.ok(affectedRunner.includes('bash ../scripts/install-ci-zsh.sh'), 'affected-tests uses the shared resilient zsh installer');
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
const { shards } = await import('../src/browser/scripts/run-browser-smoke-shard.mjs');
const browserSuites = await import('../src/browser/scripts/browser-suites.mjs');
const shardCommands = Object.values(browserSuites.shardCommands(shards)).flat().filter((name) => name.startsWith('test:'));
assert.ok(coreCommands.includes(browserSuites.SUITE_SCRIPT), 'test:core runs discovered home suites');
coreCommands.splice(coreCommands.indexOf(browserSuites.SUITE_SCRIPT), 1, ...browserSuites.discoverSuites().map(browserSuites.suiteCommand));
for (const command of coreCommands) {
  assert.equal(shardCommands.filter((name) => name === command).length, 1, `${command} appears in exactly one browser shard`);
}
assert.deepEqual([...new Set(shardCommands)].sort(), [...new Set(coreCommands)].sort(), 'shards match npm test:core commands');
const browserJob = jobs.get('browser');
assert.ok(browserJob.includes('./.github/actions/browser-smoke'), 'browser uses the shared browser action');
assert.ok(browserJob.includes('actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd'), 'browser checks out before the local action');
assert.ok(browserJob.includes('timeout-minutes: 23'), 'browser has 2-minute headroom beyond the 21-minute shard runner target');
assert.ok(browserJob.includes(`shard: [${Object.keys(shards).join(', ')}]`), 'browser matrix selects every shard in the shard map');
const browserAction = readFileSync(new URL('../.github/actions/browser-smoke/action.yml', import.meta.url), 'utf8');
assert.ok(browserAction.includes('using: composite'), 'shared browser setup is an allowed local composite action');
assert.ok(!browserAction.includes('report-ci-run-attempt.sh'), 'the workflow job, not the action, discloses reruns once');
assert.ok(browserAction.includes('run: node scripts/run-browser-smoke-shard.mjs ${{ inputs.shard }}'), 'shared action runs its selected shard');
assert.ok(browserAction.includes('Report slowest browser smoke suites'), 'shared action reports per-suite timings after success or timeout');
assert.ok(browserAction.includes('if: ${{ always() }}'), 'timing report runs after a shard timeout');
assert.ok(!source.includes('npm run test:core'), 'no single job runs the unsharded browser suite');
console.log('CI event selection and aggregate failure tests passed');
