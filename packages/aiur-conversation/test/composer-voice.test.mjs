import assert from 'node:assert/strict';
import test from 'node:test';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<!doctype html><body></body>', { pretendToBeVisual: true });
for (const name of ['window', 'document', 'HTMLElement', 'CustomEvent', 'customElements', 'Event', 'EventTarget', 'MouseEvent']) {
  globalThis[name] = name === 'window' ? dom.window : dom.window[name];
}
const { defineComposer } = await import('../src/index.mjs');
defineComposer();

function mount() {
  document.body.innerHTML = '<aiur-composer></aiur-composer>';
  const el = document.querySelector('aiur-composer');
  const part = (name) => el.shadowRoot.querySelector(`[part="${name}"]`);
  return { el, part };
}

function recorder() {
  const calls = [];
  let callbacks;
  return {
    calls,
    adapter: { start: (options) => {
      calls.push('start');
      callbacks = options;
      return Promise.resolve({ stop: async () => (calls.push('stop'), 'make the level longer'), setMuted: () => {} });
    } },
    say: (text) => callbacks.onPartial(text),
  };
}

function visible(el) {
  return [...el.shadowRoot.querySelector('[part="actions"]').children]
    .filter((node) => !node.hidden)
    .map((node) => node.getAttribute('part') ?? node.name);
}

function tap(button) {
  button.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true, button: 0 }));
  window.dispatchEvent(new MouseEvent('pointerup'));
}

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

const IDLE = ['attach', 'input', 'mic', 'send'];

test('two-way upgrades dictation and keeps mute, waveform, transcript, and right-side controls', async () => {
  const { el, part } = mount();
  const mic = recorder();
  const starts = [];
  let stops = 0;
  el.adapters = {
    upload: async (file) => ({ name: file.name }),
    dictation: mic.adapter,
    voice: { start: async (options) => {
      starts.push(options);
      return { stop: async () => stops++, setMuted: () => {} };
    } },
  };

  tap(part('mic'));
  await settle();
  mic.say('make the level');
  part('voice').click();
  await settle();

  assert.deepEqual(mic.calls, ['start', 'stop']);
  assert.equal(starts[0].initialText, 'make the level longer');
  assert.equal(el.value, '');
  assert.deepEqual(visible(el), ['attach', 'input', 'waveform', 'voice', 'mic', 'send']);
  starts[0].onLevel(0.8);
  assert.ok(part('waveform').lastElementChild.style.transform.includes('0.80'));
  starts[0].onPartial('user', 'hello there');
  starts[0].onPartial('agent', 'Hi!');
  starts[0].onPartial('user', 'hello there again');
  assert.deepEqual([...el.shadowRoot.querySelectorAll('[part="transcript"] p')].map((p) => p.textContent), [
    'You: hello there again', 'Agent: Hi!',
  ]);
  part('mic').click();
  assert.equal(part('mic').getAttribute('aria-label'), 'Unmute microphone');
  assert.equal(part('mic').getAttribute('aria-pressed'), 'false');

  part('voice').click();
  await settle();
  assert.equal(stops, 1);
  assert.deepEqual(visible(el), IDLE);
});
