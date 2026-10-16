import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';

// GitHub's required-check gate matches by check name only, so a same-named job
// in another workflow can block (or satisfy) a required check (#4184). Every
// required check is published by ci.yml, so no other workflow may reuse a name
// ci.yml publishes.
const dir = new URL('../.github/workflows/', import.meta.url);

// ponytail: line-based parse of this repo's 2-space workflow style, and names
// compare as written (`${{ }}` templates are not expanded). Switch to a YAML
// parser if a workflow stops following that layout.
function checkNames(file) {
  const jobs = readFileSync(new URL(file, dir), 'utf8').split(/^jobs:\n/m)[1];
  assert.ok(jobs, `${file} must declare jobs`);
  return [...jobs.matchAll(/^  ([\w-]+):\n((?:(?:    .*)?\n)*)/gm)]
    .map(([, id, body]) => body.match(/^    name: (.+)$/m)?.[1].replace(/^(['"])(.*)\1$/, '$2') ?? id);
}

const required = checkNames('ci.yml');
for (const name of ['build', 'lint', 'test', 'streamdeck', 'workflow security', 'pre-handoff']) {
  assert.ok(required.includes(name), `ci.yml must publish required check '${name}'`);
}
const ciSource = readFileSync(new URL('ci.yml', dir), 'utf8');
assert.ok(ciSource.includes('node scripts/test-workflow-check-names.mjs'),
  'workflow security must execute this test');
const securityJob = ciSource.split(/^  workflow-security:\n/m)[1].split(/^  build:\n/m)[0];
assert.ok(securityJob.includes('timeout-minutes: 5'),
  'workflow security keeps its original bounded job budget');
assert.ok(!securityJob.includes('pull-requests:'),
  'workflow security does not receive PR access');
const preHandoffJob = ciSource.split(/^  pre-handoff:\n/m)[1].split(/^  workflow-security:\n/m)[0];
assert.ok(preHandoffJob.includes('timeout-minutes: 60'),
  'pre-handoff checks have their own bounded job budget');
assert.ok(!preHandoffJob.includes('pull-requests:'),
  'pre-handoff checks do not read the PR body');
const preHandoffAction = readFileSync(new URL('../.github/actions/pre-handoff/action.yml', import.meta.url), 'utf8');
assert.ok(preHandoffAction.includes('uses: ./.github/actions/setup-elixir'),
  'pre-handoff checks install mise and project dependencies');
assert.ok(preHandoffAction.includes('path: src/_build/dev/*.plt*'),
  'pre-handoff checks cache Dialyzer PLTs');
assert.ok(preHandoffAction.includes('run: scripts/run-pre-handoff-guards.sh'),
  'all event types use the shared guard runner');
assert.ok(!preHandoffAction.includes('PATCH'), 'pre-handoff checks never write PR bodies');

const others = readdirSync(dir).filter((file) => /\.ya?ml$/.test(file) && file !== 'ci.yml');
assert.ok(others.includes('streamdeck-package.yml'), 'workflow scan must see sibling workflows');
for (const file of others) {
  for (const name of checkNames(file)) {
    assert.ok(!required.includes(name),
      `${file} publishes check '${name}', which collides with a required ci.yml check`);
  }
}
console.log('workflow check-name tests passed');
