import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import Ajv2020 from 'ajv/dist/2020.js';

const read = (path) => JSON.parse(readFileSync(new URL(`../${path}`, import.meta.url), 'utf8'));
const schema = read('schemas/instance-summary.v1.schema.json');
const fixture = read('fixtures/instance-summary.v1.json');
const validate = new Ajv2020({ strict: true }).compile(schema);

test('instance summary golden skeleton validates within 4 KiB', () => {
  assert.equal(validate(fixture), true, JSON.stringify(validate.errors));
  assert.ok(Buffer.byteLength(JSON.stringify(fixture)) <= 4096);
});

test('summary facts reject degraded values and private nested fields', () => {
  const degraded = structuredClone(fixture);
  degraded.agents.active.value = 0;
  assert.equal(validate(degraded), false);
  const privateRoot = structuredClone(fixture);
  privateRoot.build_orders = {
    ...privateRoot.build_orders, status: 'available',
    value: { roots: [{ identity: 123, title: 'private title' }] },
  };
  assert.equal(validate(privateRoot), false);
  delete privateRoot.build_orders.value.roots[0].title;
  assert.equal(validate(privateRoot), true, JSON.stringify(validate.errors));
});


test('summary reasons accept only bounded lowercase codes', () => {
  for (const reason of ['/home/operator/private', 'offline/path', 'Offline', '', 'a'.repeat(65), 'offline\n']) {
    const invalid = structuredClone(fixture);
    invalid.agents.active.reason = reason;
    assert.equal(validate(invalid), false, JSON.stringify(reason));
  }
  for (const reason of [null, 'code_'.repeat(12) + 'code', 'not_running']) {
    const valid = structuredClone(fixture);
    valid.agents.active.reason = reason;
    assert.equal(validate(valid), true, JSON.stringify(validate.errors));
  }
});
