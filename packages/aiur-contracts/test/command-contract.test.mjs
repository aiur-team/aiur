import assert from 'node:assert/strict';
import test from 'node:test';
import { command, validateCommand } from '../scripts/validate.mjs';

test('command schema requires public attribution and excludes native correlation', () => {
  assert.equal(validateCommand(command), true, JSON.stringify(validateCommand.errors));
  assert.equal(validateCommand({ ...command, short_label: 'e\u0301'.repeat(40) }), true);
  for (const field of ['requester', 'origin', 'native', 'questions', 'short_label']) {
    const missing = structuredClone(command);
    delete missing[field];
    assert.equal(validateCommand(missing), false, field);
  }
  for (const field of ['native_ref', 'call_id', 'turn_id']) {
    const leaked = { ...command, native: { harness: 'codex', hold: 'in_band', question_ids: [], [field]: 'private' } };
    assert.equal(validateCommand(leaked), false, field);
  }
  assert.equal(validateCommand({ ...command, payload_version: 1 }), false);
});
