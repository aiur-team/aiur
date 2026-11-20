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

const RECORDING = ['cancel', 'waveform', 'voice', 'stop', 'send'];
const IDLE = ['attach', 'input', 'mic', 'send'];

// The parts the user can see, in row order.
function visible(el) {
  return Array.from(el.shadowRoot.querySelector('[part="actions"]').children)
    .filter((node) => !node.hidden)
    .map((node) => node.getAttribute('part'));
}

const allAdapters = () => ({
  upload: async (file) => ({ name: file.name }),
  dictation: { start: async () => ({ stop: async () => '' }) },
  voice: { start: async () => ({ stop: async () => {} }) },
});

test('only the buttons the host can serve are shown, each with a label and no text', () => {
  const { el, part } = mount('placeholder="Message"');
  assert.equal(part('input').placeholder, 'Message');
  assert.deepEqual(visible(el), ['input', 'send']);

  el.adapters = allAdapters();

  for (const name of ['attach', 'mic', 'send', 'cancel', 'voice', 'stop']) {
    const button = part(name);
    assert.ok(button.getAttribute('aria-label'), name);
    assert.equal(button.textContent.trim(), '', `${name} has no visible text`);
  }
});

test('idle is one row of attach, input, mic and send; two-way voice waits for dictation', () => {
  const { el } = mount();
  el.adapters = allAdapters();
  assert.deepEqual(visible(el), IDLE);
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

// A recorder the test drives: it streams words and levels, and logs what the composer asks of it.
function recorder({ final = '', ready } = {}) {
  const calls = [];
  let callbacks;
  const adapter = {
    start: (options) => {
      calls.push('start');
      callbacks = options;
      const session = { stop: async () => (calls.push('stop'), final), cancel: () => calls.push('cancel') };
      return ready ? ready.promise.then(() => session) : Promise.resolve(session);
    },
  };
  return { adapter, calls, say: (text) => callbacks.onPartial(text), level: (value) => callbacks.onLevel(value) };
}

// A press and an immediate release; the release lands on the window because the mic hides.
function tap(button) {
  press(button, 'pointerdown');
  window.dispatchEvent(new MouseEvent('pointerup'));
}

async function settle() {
  for (let i = 0; i < 5; i++) await tick();
}

test('a tap on the mic keeps dictating and streams the words into the input as they are heard', async () => {
  const { el, part } = mount();
  const mic = recorder({ final: 'with a double jump.' });
  el.adapters = { ...allAdapters(), dictation: mic.adapter };
  const sent = [];
  el.addEventListener('aiur-send', (event) => sent.push(event.detail));
  type(el, 'Make the hero');

  tap(part('mic'));
  await settle();
  assert.deepEqual(mic.calls, ['start'], 'a tap must not stop dictation; only stop, send or cancel do');
  assert.deepEqual(visible(el), ['input', ...RECORDING], 'the input stays above the recording row');

  mic.say('with a');
  assert.equal(el.value, 'Make the hero with a');
  mic.say('with a double jump');
  assert.equal(el.value, 'Make the hero with a double jump', 'a partial replaces the previous one, not appends to it');

  part('stop').click();
  await settle();
  assert.deepEqual(mic.calls, ['start', 'stop']);
  assert.equal(el.value, 'Make the hero with a double jump.', 'the recognizer\'s final text wins');
  assert.deepEqual(visible(el), IDLE);
  assert.deepEqual(sent, [], 'stop leaves the words to edit; it never sends');
});

test('holding the mic and letting go stops dictation', async () => {
  const { el, part } = mount();
  const mic = recorder({ final: 'jump' });
  el.adapters = { dictation: mic.adapter };

  press(part('mic'), 'pointerdown');
  await new Promise((resolve) => setTimeout(resolve, 350));
  window.dispatchEvent(new MouseEvent('pointerup'));
  await settle();

  assert.deepEqual(mic.calls, ['start', 'stop']);
  assert.equal(el.value, 'jump');
  assert.equal(el.hasAttribute('data-recording'), false);
});

test('stop pressed before the recorder is ready still closes the microphone', async () => {
  const { el, part } = mount();
  const ready = deferred();
  const mic = recorder({ final: 'hi', ready });
  el.adapters = { dictation: mic.adapter };

  tap(part('mic'));
  part('stop').click();
  ready.resolve();
  await settle();

  assert.deepEqual(mic.calls, ['start', 'stop'], 'a quick tap then stop must not leave the microphone open');
  assert.equal(el.value, 'hi');
  assert.deepEqual(visible(el), ['input', 'mic', 'send']);
});

test('cancel discards the dictated words and keeps what was typed', async () => {
  const { el, part } = mount();
  const mic = recorder({ final: 'drop these words' });
  el.adapters = { dictation: mic.adapter };
  type(el, 'keep this');

  tap(part('mic'));
  await settle();
  mic.say('drop these words');
  part('cancel').click();
  await settle();

  assert.equal(el.value, 'keep this');
  assert.deepEqual(mic.calls, ['start', 'cancel'], 'cancel throws the recording away instead of transcribing it');

  tap(part('mic'));
  await settle();
  mic.say('and these');
  part('stop').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  await settle();
  assert.equal(el.value, 'keep this', 'Escape cancels too');
});

test('send in the recording row stops dictation and sends the final words once', async () => {
  const { el, part } = mount();
  const mic = recorder({ final: 'ship it' });
  el.adapters = { dictation: mic.adapter };
  const sent = [];
  el.onSend = async (text) => sent.push(text);

  tap(part('mic'));
  await settle();
  mic.say('ship');
  assert.equal(part('send').getAttribute('aria-label'), 'Stop and send');
  part('send').click();
  await settle();

  assert.deepEqual(mic.calls, ['start', 'stop']);
  assert.deepEqual(sent, ['ship it']);
  assert.equal(el.value, '');
});

test('two-way voice ends dictation and carries the words so far over as the first turn', async () => {
  const { el, part } = mount();
  const mic = recorder({ final: 'make the level longer' });
  const starts = [];
  let stops = 0;
  el.adapters = {
    upload: async (file) => ({ name: file.name }),
    dictation: mic.adapter,
    voice: {
      start: async (options) => {
        starts.push(options);
        return { stop: async () => stops++ };
      },
    },
  };

  tap(part('mic'));
  await settle();
  mic.say('make the level');
  part('voice').click();
  await settle();

  assert.deepEqual(mic.calls, ['start', 'stop'], 'the words are transcribed, not thrown away');
  assert.equal(starts[0].initialText, 'make the level longer');
  assert.equal(el.value, '', 'the words moved to the voice session, so they are not sent twice');
  assert.equal(part('voice').getAttribute('aria-pressed'), 'true');
  assert.equal(part('voice').getAttribute('aria-label'), 'End voice conversation');
  assert.deepEqual(visible(el), ['attach', 'input', 'voice', 'send']);

  part('voice').click();
  await settle();
  assert.equal(stops, 1);
  assert.deepEqual(visible(el), IDLE, 'two-way hides again once the conversation ends');

  tap(part('mic'));
  await settle();
  part('voice').click();
  await settle();
  starts[1].onEnd();
  assert.deepEqual(visible(el), IDLE, 'the agent hanging up resets the composer');
});

test('a voice session that fails to start gives the words back', async () => {
  const { el, part } = mount();
  const mic = recorder({ final: 'are you there' });
  const errors = [];
  el.addEventListener('aiur-composer-error', (event) => errors.push(event.detail.action));
  el.adapters = {
    dictation: mic.adapter,
    voice: {
      start: async () => {
        throw new Error('voice_unavailable');
      },
    },
  };

  tap(part('mic'));
  await settle();
  part('voice').click();
  await settle();

  assert.equal(el.value, 'are you there');
  assert.deepEqual(errors, ['voice']);
});

test('the waveform scrolls with the loudness the recorder reports', async () => {
  const { el, part } = mount();
  const mic = recorder();
  el.adapters = { dictation: mic.adapter };

  tap(part('mic'));
  await settle();
  mic.level(1);
  mic.level(0.5);

  const bars = Array.from(part('waveform').children).map((bar) => bar.style.transform);
  assert.equal(bars.at(-1), 'scaleY(0.50)');
  assert.equal(bars.at(-2), 'scaleY(1.00)');
  assert.equal(bars[0], 'scaleY(0.10)', 'silence still shows a sliver');
  assert.equal(el.hasAttribute('data-recording'), true);
});

test('the mic works from the keyboard and focus moves to stop', async () => {
  const { el, part } = mount();
  const mic = recorder({ final: 'spoken' });
  el.adapters = { dictation: mic.adapter };

  part('mic').click();
  await settle();
  assert.equal(el.shadowRoot.activeElement, part('stop'));

  part('stop').click();
  await settle();
  assert.equal(el.value, 'spoken');
  assert.equal(el.shadowRoot.activeElement, part('input'), 'focus is not lost on a hidden button');
});

test('removing the composer mid-dictation closes the microphone', async () => {
  const { el, part } = mount();
  const mic = recorder();
  el.adapters = { dictation: mic.adapter };

  tap(part('mic'));
  await settle();
  el.remove();
  assert.deepEqual(mic.calls, ['start', 'cancel']);
});

test('disabled blocks every action', () => {
  const { el, part } = mount('disabled');
  el.adapters = allAdapters();
  el.value = 'hello';

  for (const name of ['attach', 'mic', 'send']) assert.equal(part(name).disabled, true, name);
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
