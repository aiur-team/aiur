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

test('command media is typed on the prompt and on an option', () => {
  const media = {
    kind: 'video',
    mime_type: 'video/mp4',
    attachment_id: 'med_0123456789abcdef01234567',
    locator: { kind: 'attachment', attachment_id: 'med_0123456789abcdef01234567' },
    poster: { kind: 'url', value: 'https://raw.githubusercontent.com/aiur-team/aiur/main/p.png' },
    alt_text: null,
    caption: 'Walkthrough',
    byte_size: 1024,
    width: 1280,
    height: 720,
    duration_ms: 4000,
  };

  assert.equal(validateCommand({ ...command, media: [media] }), true, JSON.stringify(validateCommand.errors));
  assert.equal(
    validateCommand({ ...command, options: [{ id: 'a', label: 'Dense', media: [media] }] }),
    true,
    JSON.stringify(validateCommand.errors),
  );

  for (const broken of [
    { ...media, kind: 'hologram' },
    { ...media, locator: { kind: 'path', value: '/etc/passwd' } },
    { ...media, attachment_id: 'not-an-attachment' },
    { ...media, duration_ms: 0 },
  ]) {
    assert.equal(validateCommand({ ...command, media: [broken] }), false, JSON.stringify(broken));
  }
});
