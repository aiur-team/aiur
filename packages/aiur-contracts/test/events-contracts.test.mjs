import assert from 'node:assert/strict';
import test from 'node:test';
import { events, eventsReset, eventsCatalog, validateEvents, validateEventsCatalog } from '../scripts/validate.mjs';

test('event feed fixtures cover sequenced events, gaps, and an unsequenced reset', () => {
  for (const fixture of [events, eventsReset]) {
    assert.equal(validateEvents(fixture), true, JSON.stringify(validateEvents.errors));
  }
  assert.equal(validateEventsCatalog(eventsCatalog), true, JSON.stringify(validateEventsCatalog.errors));
});

test('event and gap records require a positive feed sequence', () => {
  for (const record of events.records) {
    for (const seq of [undefined, 0, -1]) {
      const wrong = { ...record, seq };
      if (seq === undefined) delete wrong.seq;
      assert.equal(validateEvents({ ...events, records: [wrong] }), false);
    }
  }
});

test('reset is the only record in its response and has no sequence', () => {
  const reset = eventsReset.records[0];
  assert.equal(validateEvents({ ...eventsReset, records: [{ ...reset, seq: 1 }] }), false);
  assert.equal(validateEvents({ ...eventsReset, records: [reset, events.records[0]] }), false);
  const missingBounds = { ...reset };
  delete missingBounds.oldest_seq;
  assert.equal(validateEvents({ ...eventsReset, records: [missingBounds] }), false);
});

test('event feed requires envelope identity, version, bounds and bounded pages', () => {
  for (const key of ['instance', 'epoch', 'head_seq', 'oldest_seq', 'records']) {
    const missing = structuredClone(events);
    delete missing[key];
    assert.equal(validateEvents(missing), false);
  }
  for (const key of ['v', 'id', 'topic', 'class', 'refs', 'attrs', 'payload_version', 'anchor']) {
    const missing = structuredClone(events.records[1]);
    delete missing[key];
    assert.equal(validateEvents({ ...events, records: [missing] }), false);
  }
  assert.equal(validateEvents({ ...events, records: Array(501).fill(events.records[0]) }), false);
  assert.equal(validateEvents({ ...events, records: [{ ...events.records[1], v: 2 }] }), false);
});

test('catalog requires its version and exported pattern metadata', () => {
  assert.equal(validateEventsCatalog({ ...eventsCatalog, v: 2 }), false);
  for (const key of ['pattern', 'class', 'payload_version']) {
    const missing = structuredClone(eventsCatalog.topics[0]);
    delete missing[key];
    assert.equal(validateEventsCatalog({ ...eventsCatalog, topics: [missing] }), false);
  }
  assert.equal(validateEventsCatalog({ ...eventsCatalog, topics: [{ ...eventsCatalog.topics[0], payload_version: 0 }] }), false);
});

test('feed and catalog permit additive fields within v1', () => {
  assert.equal(validateEvents({ ...events, future_field: true }), true);
  assert.equal(validateEventsCatalog({ ...eventsCatalog, future_field: true }), true);
});
