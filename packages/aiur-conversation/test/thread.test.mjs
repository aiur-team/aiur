import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

test('thread element renders entries, exposes controls slot and refreshes on live changes', async () => {
  const dom = new JSDOM('<body><aiur-thread><button slot="controls">Refresh</button></aiur-thread></body>', { url: 'http://localhost' });
  const { window } = dom;
  globalThis.HTMLElement = window.HTMLElement;
  globalThis.EventTarget = window.EventTarget;
  globalThis.Event = window.Event;
  globalThis.customElements = window.customElements;
  globalThis.CustomEvent = window.CustomEvent;
  const { AiurThread, defineThread } = await import('../src/thread.mjs');
  const registry = window.customElements;
  registry.define('aiur-thread', AiurThread);
  const element = window.document.querySelector('aiur-thread');
  let changed;
  let reads = 0;
  let verdict;
  element.adapters = {
    read: async () => { reads += 1; return { entries: [{ pos: reads * 2 - 1, role: 'agent', kind: 'message', text: `Reply ${reads}`, media: [{ url: '/media/generated.png', name: 'generated.png', mime_type: 'image/png' }] }, { pos: reads * 2, kind: 'command', decision_id: 'decision-7' }], next_after: reads * 2 }; },
    send: async () => ({}), subscribe: (callback) => { changed = callback; return () => {}; },
    answer: async (payload) => { verdict = payload; return {}; },
  };
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(element.shadowRoot.querySelector('[part="entry-body"]').textContent, 'Reply 1');
  assert.equal(element.shadowRoot.querySelector('[part="media"]').alt, 'generated.png');
  const form = element.shadowRoot.querySelector('[part="verdict"]');
  form.querySelector('textarea').value = 'Proceed with the fix';
  form.dispatchEvent(new window.Event('submit', { bubbles: true, cancelable: true }));
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(verdict, { command_id: 'decision-7', answer: 'Proceed with the fix' });
  assert.ok(element.shadowRoot.querySelector('slot[name="controls"]'));
  changed();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(element.state.entries.length, 4);
  assert.equal(typeof defineThread('other-thread', registry), 'function');
  dom.window.close();
});
