import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import Ajv2020 from 'ajv/dist/2020.js';

const read = (path) => JSON.parse(readFileSync(new URL(`../${path}`, import.meta.url), 'utf8'));

const cases = [
  ['ticket lifecycle', 'ticket-lifecycle-event.v1'],
  ['ticket progress', 'ticket-progress-event.v1'],
  ['ticket usage', 'ticket-usage-event.v1'],
];

test('outbound event fixtures validate against their v1 schemas', () => {
  const ajv = new Ajv2020({ allErrors: true, formats: { 'date-time': true } });
  const envelope = read('schemas/outbound-event-envelope.v1.schema.json');
  ajv.addSchema(envelope);

  for (const [name, stem] of cases) {
    const schema = read(`schemas/${stem}.schema.json`);
    const fixture = read(`fixtures/${stem}.json`);
    const validate = ajv.compile(schema);
    assert.equal(validate(fixture), true, `${name}: ${JSON.stringify(validate.errors)}`);
  }
});

test('outbound events require ticket or job correlation', () => {
  const ajv = new Ajv2020({ allErrors: true, formats: { 'date-time': true } });
  ajv.addSchema(read('schemas/outbound-event-envelope.v1.schema.json'));
  const validate = ajv.compile(read('schemas/ticket-lifecycle-event.v1.schema.json'));
  const event = read('fixtures/ticket-lifecycle-event.v1.json');
  delete event.ticket_id;
  delete event.job_id;
  assert.equal(validate(event), false);
});

test('outbound schemas reject fixtures from a different event family', () => {
  const ajv = new Ajv2020({ allErrors: true, formats: { 'date-time': true } });
  ajv.addSchema(read('schemas/outbound-event-envelope.v1.schema.json'));
  const lifecycle = ajv.compile(read('schemas/ticket-lifecycle-event.v1.schema.json'));
  const progress = read('fixtures/ticket-progress-event.v1.json');
  assert.equal(lifecycle(progress), false);
});

test('the package is independently publishable', () => {
  const packageJson = read('package.json');
  assert.notEqual(packageJson.private, true);
  assert.equal(packageJson.exports['.'].types, './dist/index.d.ts');
  assert.ok(packageJson.files.includes('schemas'));
});
