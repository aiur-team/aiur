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
  assert.deepEqual(calls[2], ['read', { after: 'next', limit: 100 }]);
});

test('keeps the loaded thread and reports a send failure', async () => {
  const controller = new ThreadController({ read: async () => ({ entries: [], cursor: null }), send: async () => { throw Object.assign(new Error('offline'), { code: 'offline' }); } });
  assert.equal(await controller.send('hello'), false);
  assert.equal(controller.state.error.action, 'send');
  assert.equal(controller.state.error.code, 'send_failed');
});

test('overlapping pages do not duplicate a thread entry', async () => {
  let page = 0;
  const controller = new ThreadController({
    read: async () => ({ entries: [{ pos: 8, role: 'agent', text: page++ === 0 ? 'first copy' : 'overlap' }], next_after: 8 }),
    send: async () => ({}),
  });
  await controller.load();
  await controller.load();
  assert.deepEqual(controller.state.entries.map(({ pos, text }) => ({ pos, text })), [{ pos: 8, text: 'first copy' }]);
});

test('exposes and refreshes the send receipt for a host delivery status view', async () => {
  const polled = [];
  const controller = new ThreadController({
    read: async () => ({ entries: [], next_after: 0 }),
    send: async () => ({ request_id: 41, status: 'queued' }),
    receipt: async (requestId) => { polled.push(requestId); return { id: Number(requestId), status: polled.length === 1 ? 'delivered' : 'consumed', mode: 'steer' }; },
  });
  await controller.send('hello');
  assert.deepEqual(controller.state.receipt, { request_id: 41, status: 'queued' });
  assert.deepEqual(await controller.refreshReceipt(), { id: 41, status: 'delivered', mode: 'steer', request_id: '41' });
  assert.deepEqual(await controller.refreshReceipt(), { id: 41, status: 'consumed', mode: 'steer', request_id: '41' });
  assert.deepEqual(polled, ['41', '41']);
});

test('an adapter replacement ignores a late result from the previous ticket', async () => {
  let finish;
  const old = new ThreadController({ read: () => new Promise((resolve) => { finish = resolve; }) });
  const pending = old.load();
  old.adapters = { read: async () => ({ entries: [{ pos: 2 }], next_after: 2 }) };
  finish({ entries: [{ pos: 1 }], next_after: 1 });
  await pending;
  assert.deepEqual(old.state.entries, []);
});
