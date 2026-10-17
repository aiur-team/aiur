import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// Drafts and closed PRs must not hold runners that merge-group runs need (#4942).
const dir = new URL('../.github/workflows/', import.meta.url);
const guard = "github.event.pull_request.draft != true && github.event.action != 'closed'";

// ponytail: line-based parse of this repo's 2-space workflow style, like
// test-workflow-check-names.mjs. Switch to a YAML parser if that layout changes.
function jobs(file) {
  const source = readFileSync(new URL(file, dir), 'utf8');
  const types = source.match(/^  pull_request:\n(?:    #.*\n)*    types: \[(.+)\]$/m)?.[1].split(/,\s*/);
  assert.ok(types?.includes('ready_for_review'), `${file} must start CI when a draft is marked ready`);
  assert.ok(types?.includes('closed'), `${file} must cancel a closed PR's queued run`);
  const body = source.split(/^jobs:\n/m)[1];
  return new Map([...body.matchAll(/^  ([\w-]+):\n((?:(?:    .*)?\n)*)/gm)]
    .map(([, id, text]) => [id, text.match(/^    if: \$\{\{ (.+) \}\}$/m)?.[1] ?? '']));
}

const ci = jobs('ci.yml');
for (const id of ['changes', 'lint', 'ci-gate']) {
  assert.ok(ci.get(id)?.includes(guard), `ci.yml job ${id} must skip drafts and closed PRs`);
}
// A job skipped with `changes` stays skipped unless a status function overrides it,
// or its condition reads no `changes` result or output (empty when skipped).
for (const [id, condition] of ci) {
  if (/always\(\)|!cancelled\(\)/.test(condition) && !condition.includes('needs.changes.')
      && !/github\.event_name == '(schedule|push)'/.test(condition)) {
    assert.ok(condition.includes(guard), `ci.yml job ${id} runs on drafts; add the draft guard`);
  }
}
assert.ok(jobs('website.yml').get('guards')?.includes(guard), 'website.yml guards must skip drafts and closed PRs');
console.log('draft CI skip tests passed');
