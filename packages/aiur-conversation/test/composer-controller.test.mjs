import assert from 'node:assert/strict';
import test from 'node:test';
import { ComposerController } from '@aiur/conversation';

test('headless host uploads and sends final dictation through the shared commands and events', async () => {
  assert.equal(globalThis.document, undefined);
  const composer = new ComposerController();
  const uploaded = { name: 'brief.txt', id: 'server-id' };
  let partial;
  const observed = [];
  const sent = [];
  composer.addEventListener('aiur-conversation-state', ({ detail }) => observed.push(detail));
  composer.addEventListener('aiur-send', ({ detail }) => sent.push(detail));
  composer.adapters = {
    upload: async () => uploaded,
    dictation: {
      start: async ({ onPartial }) => {
        partial = onPartial;
        return { stop: async () => 'please review' };
      },
    },
  };

  const upload = composer.attach(new File(['brief'], 'brief.txt'));
  assert.equal(composer.state.attachments[0].state, 'uploading');
  assert.equal(composer.state.controls.send.disabled, true);
  assert.equal(await upload, true);
  assert.equal(composer.state.attachments[0].state, 'ready');

  composer.value = 'Hello, team';
  await composer.startDictation(6, 6);
  assert.equal(composer.state.focusOrder.includes('mic'), false);
  partial('please');
  assert.equal(composer.value, 'Hello, please team');
  assert.equal(await composer.send(), true);
  assert.deepEqual(sent, [{ text: 'Hello, please review team', attachments: [uploaded] }]);
  assert.equal(composer.value, '');
  assert.deepEqual(composer.attachments, []);
  assert.deepEqual(
    [...new Set(observed.map((state) => state.dictation))],
    ['idle', 'recording', 'stopping'],
  );
});

test('headless errors distinguish permissions, upload, provider and send failures', async () => {
  const composer = new ComposerController();
  const errors = [];
  composer.addEventListener('aiur-conversation-error', ({ detail }) => errors.push(detail));
  const permission = new Error('internal microphone detail');
  permission.name = 'NotAllowedError';
  const upload = new Error('internal upload detail');
  const provider = new Error('internal service detail');
  const send = new Error('internal send detail');
  composer.adapters = {
    dictation: { start: async () => { throw permission; } },
    upload: async () => { throw upload; },
    voice: { start: async () => { throw provider; } },
  };
  composer.onSend = async () => { throw send; };

  await composer.startDictation();
  assert.equal(composer.state.announcement, 'Permission denied.');
  await composer.attach(new File(['data'], 'file.txt'));
  composer.value = 'Keep this draft';
  await composer.startVoice();
  assert.equal(await composer.send(), false);
  assert.equal(composer.value, 'Keep this draft');
  assert.deepEqual(errors.map(({ action, code, error }) => [action, code, error]), [
    ['dictation', 'permission_denied', permission],
    ['upload', 'upload_failed', upload],
    ['voice', 'provider_unavailable', provider],
    ['send', 'send_failed', send],
  ]);
});
