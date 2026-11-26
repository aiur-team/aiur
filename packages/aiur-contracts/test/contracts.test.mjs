import assert from 'node:assert/strict';
import test from 'node:test';
import { CAPABILITY_REASONS, KNOWN_CAPABILITY_IDS, KNOWN_CAPABILITY_ID_PATTERNS } from '../dist/index.js';
import { reportSchema, report, error, validateReport, validateError } from '../scripts/validate.mjs';

test('golden report and refusal validate against v1 schemas', () => {
  assert.equal(validateReport(report), true);
  assert.equal(validateError(error), true);
});

for (const key of ['contract', 'contract_version', 'boot_id', 'revision', 'observed_at', 'age_ms', 'freshness', 'min_client_versions', 'machine', 'instance', 'repository', 'executor', 'capabilities']) {
  test(`missing report ${key} is invalid`, () => {
    const missing = structuredClone(report);
    delete missing[key];
    assert.equal(validateReport(missing), false);
  });
}
for (const key of ['error', 'capability', 'state', 'reason', 'revision', 'boot_id']) {
  test(`missing refusal ${key} is invalid`, () => {
    const missing = structuredClone(error);
    delete missing[key];
    assert.equal(validateError(missing), false);
  });
}

test('unknown IDs and additive fields remain valid', () => {
  const additive = structuredClone(report);
  additive.future_field = true;
  additive.capabilities['future.feature'] = { state: 'available', future_field: 42 };
  assert.equal(validateReport(additive), true);
});

test('unavailable entries require a known non-null reason', () => {
  for (const reason of [undefined, null, 'invented']) {
    const invalid = structuredClone(report);
    invalid.capabilities.identity = { state: 'unavailable', reason };
    assert.equal(validateReport(invalid), false);
  }
});

test('nullable identity and provider sections preserve unknown state', () => {
  const absent = structuredClone(report);
  for (const key of ['machine', 'instance', 'repository', 'executor']) absent[key] = null;
  assert.equal(validateReport(absent), true);
  absent.instance = { ...report.instance, instance_id: null };
  assert.equal(validateReport(absent), true);
});

test('documented harness pattern matches exactly one valid segment', () => {
  const matches = (id) => KNOWN_CAPABILITY_ID_PATTERNS.some((pattern) => pattern.test(id));
  assert.equal(matches('harness.codex.native_question'), true);
  for (const id of ['harness.native_question', 'harness.foo.bar.native_question', 'harness.Foo.native_question']) {
    assert.equal(matches(id), false);
  }
  for (const id of ['identity', 'api.http', 'orchestration', 'listener_modes', 'build_queue', 'build_queue.build_order_source', 'events.export']) {
    assert.ok(KNOWN_CAPABILITY_IDS.includes(id));
  }
});

test('exported reasons match schema and contain every golden reason', () => {
  assert.deepEqual([...CAPABILITY_REASONS], reportSchema.$defs.reason.enum);
  for (const entry of Object.values(report.capabilities)) {
    if (entry.reason != null) assert.ok(CAPABILITY_REASONS.includes(entry.reason));
  }
  assert.ok(CAPABILITY_REASONS.includes(error.reason));
});

test('dependency refusals and report entries require dependency IDs', () => {
  for (const depends_on of [undefined, null, []]) {
    const invalid = structuredClone(report);
    invalid.capabilities['commands.answer'].depends_on = depends_on;
    assert.equal(validateReport(invalid), false);
    assert.equal(validateError({ ...error, depends_on }), false);
  }
});

test('absent and unknown executors may omit reserved identity fields', () => {
  for (const executor of [{ state: 'absent', consumer_id: null }, { state: 'unknown' }]) {
    assert.equal(validateReport({ ...report, executor }), true);
  }
});
