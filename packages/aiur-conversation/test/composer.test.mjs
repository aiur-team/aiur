import assert from 'node:assert/strict';
import test from 'node:test';
import { JSDOM } from 'jsdom';

// The element extends the page's HTMLElement, so the DOM must exist before the import.
const dom = new JSDOM('<!doctype html><body></body>', { pretendToBeVisual: true });
for (const name of ['window', 'document', 'HTMLElement', 'CustomEvent', 'customElements', 'Event', 'KeyboardEvent', 'MouseEvent']) {
  globalThis[name] = name === 'window' ? dom.window : dom.window[name];
}

const { defineComposer } = await import('../src/index.mjs');
defineComposer();

function mount(attrs = '') {
  document.body.innerHTML = `<aiur-composer ${attrs}></aiur-composer>`;
  const el = document.querySelector('aiur-composer');
  const part = (name) => el.shadowRoot.querySelector(`[part="${name}"]`);
  return { el, part };
}

function type(el, text) {
  const input = el.shadowRoot.querySelector('textarea');
  input.value = text;
  input.dispatchEvent(new Event('input'));
}

function press(button, type) {
  button.dispatchEvent(new MouseEvent(type, { bubbles: true, button: 0 }));
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

test('only the buttons the host can serve are shown, each with a label and no text', () => {
  const { el, part } = mount('placeholder="Message"');
  assert.equal(part('input').placeholder, 'Message');
  assert.equal(part('attach').hidden, true);
  assert.equal(part('mic').hidden, true);
  assert.equal(part('voice').hidden, true);
  assert.equal(part('send').hidden, false);

  el.adapters = { upload: async (file) => ({ name: file.name }), dictation: { start: async () => ({ stop: async () => '' }) }, voice: { start: async () => ({ stop: async () => {} }) } };

  for (const name of ['attach', 'mic', 'voice', 'send']) {
    const button = part(name);
    assert.equal(button.hidden, false, name);
    assert.ok(button.getAttribute('aria-label'), name);
    assert.equal(button.textContent.trim(), '', `${name} has no visible text`);
  }
});

test('send hands the host the trimmed text and clears the draft only once the host accepts it', async () => {
  const { el, part } = mount();
  const reply = deferred();
  const sent = [];
  el.onSend = (text, attachments) => {
    sent.push({ text, attachments });
    return reply.promise;
  };

  assert.equal(part('send').disabled, true, 'nothing to send yet');
  type(el, '  make the jump higher  ');
  assert.equal(part('send').disabled, false);

  part('send').click();
  await tick();
  assert.deepEqual(sent, [{ text: 'make the jump higher', attachments: [] }]);
  assert.equal(part('send').disabled, true, 'no double send while the host is sending');
  assert.equal(el.value, '  make the jump higher  ', 'the draft stays until the host accepts it');

  reply.resolve();
  await tick();
  assert.equal(el.value, '');
});

test('a refused send keeps the draft so the creator does not lose it', async () => {
  const { el, part } = mount();
  const errors = [];
  el.addEventListener('aiur-composer-error', (event) => errors.push(event.detail.action));
  el.onSend = async () => {
    throw new Error('executor_unavailable');
  };

  type(el, 'are you there?');
  part('send').click();
  await tick();
  await tick();

  assert.equal(el.value, 'are you there?');
  assert.deepEqual(errors, ['send']);
  assert.equal(part('send').disabled, false);
});

test('Enter sends and Shift+Enter keeps writing', async () => {
  const { el, part } = mount();
  const sent = [];
  el.addEventListener('aiur-send', (event) => sent.push(event.detail.text));

  type(el, 'line one');
  part('input').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true, cancelable: true }));
  assert.deepEqual(sent, []);

  part('input').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', cancelable: true }));
  await tick();
  assert.deepEqual(sent, ['line one']);
  assert.equal(el.value, '');
});

test('files upload through the host adapter and travel with the next send; send waits for uploads', async () => {
  const { el, part } = mount();
  const upload = deferred();
  el.adapters = { upload: () => upload.promise };
  const sent = [];
  el.addEventListener('aiur-send', (event) => sent.push(event.detail));

  const file = new dom.window.File(['png'], 'level.png', { type: 'image/png' });
  const input = el.shadowRoot.querySelector('input[type="file"]');
  Object.defineProperty(input, 'files', { value: [file], configurable: true });
  input.dispatchEvent(new Event('change'));
  await tick();

  assert.equal(part('attachment').dataset.state, 'uploading');
  assert.equal(part('send').disabled, true, 'a half-uploaded file cannot be sent');

  upload.resolve({ name: 'level.png', id: 'med_1' });
  await tick();
  assert.equal(part('send').disabled, false, 'an attachment alone can be sent');

  part('send').click();
  await tick();
  assert.deepEqual(sent, [{ text: '', attachments: [{ name: 'level.png', id: 'med_1' }] }]);
  assert.equal(part('attachment'), null);
});

test('a removed attachment is not sent', async () => {
  const { el, part } = mount();
  el.adapters = { upload: async (file) => ({ name: file.name }) };
  const input = el.shadowRoot.querySelector('input[type="file"]');
  Object.defineProperty(input, 'files', { value: [new dom.window.File(['x'], 'a.png')], configurable: true });
  input.dispatchEvent(new Event('change'));
  await tick();

  part('attachment').querySelector('button').click();
  assert.deepEqual(el.attachments, []);
  assert.equal(part('send').disabled, true);
});

test('holding the mic dictates into the input at the cursor; releasing stops it', async () => {
  const { el, part } = mount();
  const calls = [];
  el.adapters = {
    dictation: {
      start: async () => {
        calls.push('start');
        return { stop: async () => (calls.push('stop'), 'with a double jump') };
      },
    },
  };
  type(el, 'Make the hero');

  press(part('mic'), 'pointerdown');
  await tick();
  assert.equal(part('mic').getAttribute('aria-pressed'), 'true');

  press(part('mic'), 'pointerup');
  await tick();
  await tick();

  assert.deepEqual(calls, ['start', 'stop']);
  assert.equal(part('mic').getAttribute('aria-pressed'), 'false');
  assert.equal(el.value, 'Make the hero with a double jump', 'dictation fills the input; it never sends by itself');
});

test('a release before the recorder is ready still stops it', async () => {
  const { el, part } = mount();
  const ready = deferred();
  let stopped = false;
  el.adapters = { dictation: { start: () => ready.promise } };

  press(part('mic'), 'pointerdown');
  press(part('mic'), 'pointerup');
  ready.resolve({ stop: async () => ((stopped = true), 'hi') });
  await tick();
  await tick();

  assert.equal(stopped, true, 'a quick tap must not leave the microphone open');
  assert.equal(el.value, 'hi');
});

test('the mic works from the keyboard: hold Space to dictate, Escape cancels', async () => {
  const { el, part } = mount();
  let cancelled = false;
  el.adapters = { dictation: { start: async () => ({ stop: async () => 'spoken', cancel: () => (cancelled = true) }) } };

  part('mic').dispatchEvent(new KeyboardEvent('keydown', { key: ' ', cancelable: true }));
  await tick();
  part('mic').dispatchEvent(new KeyboardEvent('keyup', { key: ' ' }));
  await tick();
  await tick();
  assert.equal(el.value, 'spoken');

  part('mic').dispatchEvent(new KeyboardEvent('keydown', { key: ' ', cancelable: true }));
  await tick();
  part('mic').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
  assert.equal(cancelled, true);
  assert.equal(el.value, 'spoken');
});

test('two-way voice toggles a live session and shows when it ends on its own', async () => {
  const { el, part } = mount();
  let onEnd;
  let stops = 0;
  el.adapters = {
    voice: {
      start: async (options) => {
        onEnd = options.onEnd;
        return { stop: async () => stops++ };
      },
    },
  };

  part('voice').click();
  await tick();
  assert.equal(part('voice').getAttribute('aria-pressed'), 'true');
  assert.equal(part('voice').getAttribute('aria-label'), 'End voice conversation');

  part('voice').click();
  await tick();
  assert.equal(stops, 1);
  assert.equal(part('voice').getAttribute('aria-pressed'), 'false');

  part('voice').click();
  await tick();
  onEnd();
  assert.equal(part('voice').getAttribute('aria-pressed'), 'false', 'the agent hanging up resets the button');
});

test('disabled blocks every action', () => {
  const { el, part } = mount('disabled');
  el.adapters = { upload: async () => ({ name: 'x' }), dictation: { start: async () => ({ stop: async () => '' }) }, voice: { start: async () => ({ stop: async () => {} }) } };
  el.value = 'hello';

  for (const name of ['attach', 'mic', 'voice', 'send']) assert.equal(part(name).disabled, true, name);
  assert.equal(part('input').disabled, true);
});

test('a pinned composer rises above the on-screen keyboard', () => {
  const listeners = {};
  const viewport = { height: 844, offsetTop: 0, addEventListener: (type, fn) => (listeners[type] = fn), removeEventListener: () => {} };
  globalThis.visualViewport = viewport;
  globalThis.innerHeight = 844;

  try {
    const { el } = mount('pinned');
    assert.equal(el.style.getPropertyValue('--aiur-composer-keyboard-inset'), '0px');

    viewport.height = 508;
    listeners.resize();
    assert.equal(el.style.getPropertyValue('--aiur-composer-keyboard-inset'), '336px');
  } finally {
    delete globalThis.visualViewport;
  }
});

test('defineComposer is safe to call twice and supports another tag', () => {
  assert.equal(defineComposer(), customElements.get('aiur-composer'));
  const Other = defineComposer('ogm-composer');
  assert.equal(customElements.get('ogm-composer'), Other);
});
