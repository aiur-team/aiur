import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ThreadController } from '../src/thread-controller.mjs';

test('loads entries by cursor and sends attachments with a stable message id', async () => {
  const calls = [];
  const controller = new ThreadController({
    read: async (options) => { calls.push(['read', options]); return { entries: [{ id: 'entry-1' }], cursor: 'next' }; },
    send: async (message) => calls.push(['send', message]),
  });
  assert.equal(await controller.load(), true);
  assert.equal(controller.state.entries[0].id, 'entry-1');
  assert.equal(controller.state.cursor, 'next');
  assert.equal(await controller.send('look at this', [{ name: 'image.png' }]), true);
  assert.equal(calls[1][1].text, 'look at this');
  assert.equal(calls[1][1].attachments[0].name, 'image.png');
  assert.match(calls[1][1].message_id, /^[0-9a-f-]{36}$/);
  assert.deepEqual(calls[2], ['read', { after: 'next' }]);
});

test('keeps the loaded thread and reports a send failure', async () => {
  const controller = new ThreadController({ read: async () => ({ entries: [], cursor: null }), send: async () => { throw Object.assign(new Error('offline'), { code: 'offline' }); } });
  assert.equal(await controller.send('hello'), false);
  assert.equal(controller.state.error.action, 'send');
  assert.equal(controller.state.error.code, 'offline');
});
