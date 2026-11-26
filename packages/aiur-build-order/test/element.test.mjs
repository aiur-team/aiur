import assert from 'node:assert/strict';
import test from 'node:test';
import { ELEMENT_NAME, registerAiurBuildOrder } from '../src/index.js';
import { fixture, fixtureText } from './helpers.mjs';
import { mount, settle } from './fake-dom.mjs';

test('mounts the review and the graph from a json attribute', async () => {
  const { element, head } = mount({ json: fixtureText('build-order.v1.json'), view: 'both' });
  element.connectedCallback();
  await settle();

  assert.equal(element.error, null);
  assert.equal(element.document.contract, 'aiur.build_order');
  assert.match(element.innerHTML, /class="aiur-bo aiur-bo--review"/);
  assert.match(element.innerHTML, /class="aiur-bo-graph"/);
  assert.equal(element.dataset.status, 'known');
  // The stylesheet is injected once, not once per render.
  element.render();
  assert.equal(head.children.length, 1);
  assert.match(head.children[0].textContent, /--aiur-color-fg/);
});

test('view selects one renderer', async () => {
  const { element } = mount({ json: fixtureText('build-order.v1.json'), view: 'graph' });
  await element.load();
  assert.match(element.innerHTML, /class="aiur-bo-graph"/);
  assert.doesNotMatch(element.innerHTML, /aiur-bo--review/);

  element.setAttribute('view', 'review');
  element.render();
  assert.match(element.innerHTML, /aiur-bo--review/);
  assert.doesNotMatch(element.innerHTML, /class="aiur-bo-graph"/);
});

test('a fetch function resolves a src URL without the page global', async () => {
  const calls = [];
  const { element } = mount({ src: 'https://example.test/build-order.json' });
  element.fetch = async (url) => {
    calls.push(url);
    return { ok: true, text: async () => fixtureText('build-order.v1.json') };
  };
  await settle();

  assert.deepEqual(calls, ['https://example.test/build-order.json']);
  assert.equal(element.error, null);
  assert.match(element.innerHTML, /data-ticket="BO-001"/);
});

test('a failing fetch renders the structured error and announces it', async () => {
  const { element, events } = mount({ src: 'https://example.test/missing.json' });
  element.fetch = async () => ({ ok: false, status: 404, text: async () => '' });
  await settle();

  assert.equal(element.error.code, 'fetch_failed');
  assert.match(element.error.message, /404/);
  assert.match(element.innerHTML, /data-status="error"/);
  assert.equal(events.at(-1).type, 'aiur-build-order:error');
});

test('an invalid document is an error, not a blank box', async () => {
  const { element, events } = mount({ json: fixtureText('build-order-invalid.v1.json') });
  await element.load();

  assert.equal(element.error.code, 'invalid_edge');
  assert.deepEqual(element.error.path, ['edges', 0, 'to']);
  assert.equal(element.document, null);
  assert.match(element.innerHTML, /This build order could not be read/);
  assert.equal(events.at(-1).type, 'aiur-build-order:error');
});

test('a fetch that throws is reported, not swallowed', async () => {
  const { element } = mount({ src: 'https://example.test/boom.json' });
  element.fetch = async () => {
    throw new Error('network down');
  };
  await settle();
  assert.equal(element.error.code, 'fetch_failed');
  assert.match(element.error.message, /network down/);
});

test('a src with no fetch function is a named fetch error', async () => {
  const { element } = mount({ src: 'https://example.test/no-fetch.json' });
  await element.load();
  assert.equal(element.error.code, 'fetch_failed');
});

test('no source at all is a named error', async () => {
  const { element } = mount();
  await element.load();
  assert.equal(element.error.code, 'missing_source');
});

test('the element loads a document and announces it', async () => {
  const { element, events } = mount();
  element.json = fixture('build-order.v1.json');
  await settle();

  assert.equal(element.error, null);
  assert.equal(events.at(-1).type, 'aiur-build-order:load');
  assert.equal(events.at(-1).detail.document.tickets.length, 6);
});

test('registers the element once', () => {
  const defined = new Map();
  const registry = {
    define: (name, ctor) => defined.set(name, ctor),
    get: (name) => defined.get(name),
  };

  assert.equal(registerAiurBuildOrder(registry), true);
  assert.equal(registerAiurBuildOrder(registry), false);
  assert.deepEqual([...defined.keys()], [ELEMENT_NAME]);
});
