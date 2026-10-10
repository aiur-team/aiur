import assert from 'node:assert/strict';
import test from 'node:test';
import { KNOWN_CAPABILITY_IDS } from '../dist/index.js';
import { report, validateReport } from '../scripts/validate.mjs';

test('merge policy modes validate without changing existing v1 reports', () => {
  assert.equal(validateReport(report), true);
  const policy = structuredClone(report);
  policy.capabilities.merge_policy = { state: 'available', mode: 'ci=pending_ok local_tests=partial' };
  assert.equal(validateReport(policy), true, JSON.stringify(validateReport.errors));
  assert.ok(KNOWN_CAPABILITY_IDS.includes('merge_policy'));
  policy.capabilities.merge_policy.mode = 42;
  assert.equal(validateReport(policy), false);
});
