import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';

const script = readFileSync(new URL('../../priv/static/executor-voice-controller.js', import.meta.url), 'utf8');
function node(tag = 'div') {
  return {tag, textContent: '', children: [], attributes: {}, listeners: {},
    append(...items) { this.children.push(...items); }, replaceChildren() { this.children = []; },
    setAttribute(key, value) { this.attributes[key] = value; },
    addEventListener(key, fn) { this.listeners[key] = fn; }};
}
function fixture() {
  const fields = new Map();
  const button = {addEventListener() {}, removeEventListener() {}};
  const el = {dataset: {}, querySelector(selector) {
    if (selector.endsWith('-toggle]')) return button;
    if (!fields.has(selector)) fields.set(selector, node());
    return fields.get(selector);
  }};
  const window = {atob: value => Buffer.from(value, 'base64').toString('binary'),
    AiurVoiceTransport: {open: () => ({joined: Promise.resolve(), push() {}, close() {}})}};
  vm.runInNewContext(script, {window, Uint8Array, DataView, document: {createElement: node}});
  const controller = new window.AiurExecutorVoiceController({querySelector: () => el});
  controller.bindElements();
  return {controller, el, fields, window, button};
}

test('Executor playback uses supplied PCM rate and barge-in clears scheduled audio', () => {
  const {controller} = fixture();
  let actualRate, stopped = 0, startedAt;
  controller.playback = {
    currentTime: 2, destination: {},
    createBuffer(_channels, length, rate) { actualRate = rate; return {duration: length / rate, getChannelData: () => new Float32Array(length)}; },
    createBufferSource() { return {connect() {}, start(at) { startedAt = at; }, stop() { stopped++; }}; }
  };
  controller.status('live', 'Live');
  controller.playAudio({format: 'pcm_16000', data: Buffer.from([0, 64, 0, 192]).toString('base64')});
  assert.equal(actualRate, 16000);
  assert.equal(startedAt, 2);
  assert.equal(controller.sources.size, 1);
  controller.interrupt();
  assert.equal(stopped, 1);
  assert.equal(controller.sources.size, 0);
  assert.equal(controller.nextAudioAt, 0);
});

test('session end preserves queued receipt and never claims Executor has read it', () => {
  const {controller, fields, el} = fixture();
  controller.receipt({id: 42, at: '2026-10-27T10:00:00Z'});
  controller.ended();
  assert.equal(el.dataset.state, 'ended');
  const text = fields.get('[data-executor-voice-receipt]').textContent;
  assert.match(text, /SENT — receipt/);
  assert.match(text, /receipt 42 at 2026-10-27T10:00:00Z/);
  assert.match(text, /SENT NOT RECEIVED/);
  assert.equal(controller.receipts.get(42).ack_status, 'waiting');
});

test('ending retains the transport until the handoff receipt arrives', () => {
  const {controller} = fixture();
  const sent = [];
  let closed = false;
  controller.transport = {push: event => sent.push(event), close: () => { closed = true; }};
  controller.stop();
  assert.deepEqual(sent, ['stop']);
  assert.equal(closed, false);
  assert.equal(controller.state, 'ending');
  controller.receipt({id: 7, at: 'now'});
  controller.ended();
  assert.equal(closed, true);
});

test('provider failure retains transport for the final handoff receipt', () => {
  const {controller, fields} = fixture();
  let closed = false;
  controller.transport = {close: () => { closed = true; }};
  controller.providerError('Provider unavailable');
  assert.equal(controller.state, 'failed');
  assert.equal(closed, false);
  controller.receipt({id: 8, at: 'now'});
  controller.ended();
  assert.equal(closed, true);
  assert.equal(controller.state, 'failed');
  assert.match(fields.get('[data-executor-voice-receipt]').textContent, /receipt 8/);
});

test('natural end drains scheduled reply audio while closing capture and transport', () => {
  const {controller} = fixture();
  let stopped = 0, captureStopped = false, closed = false;
  controller.sources.add({stop() { stopped++; }});
  controller.nextAudioAt = 20;
  controller.capture = {stop() { captureStopped = true; }};
  controller.transport = {close() { closed = true; }};
  controller.status('live', 'Live');
  controller.ended();
  assert.equal(captureStopped, true);
  assert.equal(closed, true);
  assert.equal(stopped, 0);
  assert.equal(controller.sources.size, 1);
  controller.destroy();
  assert.equal(stopped, 1);
});

test('retry waits for the failed session handoff instead of abandoning its receipt', () => {
  const {controller, button} = fixture();
  controller.transport = {close() {}};
  let starts = 0;
  controller.start = () => { starts++; };
  controller.providerError('Provider unavailable');
  assert.equal(button.disabled, true);
  controller.onToggle();
  assert.equal(starts, 0);
  controller.receipt({id: 12, at: 'now'});
  controller.ended();
  assert.equal(button.disabled, false);
  controller.onToggle();
  assert.equal(starts, 1);
});

function prepareStart(f, onOpen = () => {}) {
  let options, captureStarted = false;
  f.window.AudioContext = class { async resume() {} };
  f.window.AiurVoiceCapture = {
    recalledDevice: () => '', requestMicrophone: async () => ({getTracks: () => []}),
    Capture: class { async start() { captureStarted = true; } stop() {} }
  };
  f.window.AiurVoiceTransport = {open(opts) {
    options = opts;
    onOpen(opts);
    return {joined: Promise.resolve(), close() {}, push() {}};
  }};
  return {get options() { return options; }, get captureStarted() { return captureStarted; }};
}

test('new session retains previous receipt items and clears only the transcript', async () => {
  const f = fixture();
  prepareStart(f);
  f.controller.receipt({id: 13, at: 'previous'});
  f.el.querySelector('[data-executor-voice-transcript]').textContent = 'previous transcript';
  await f.controller.start();
  assert.match(f.fields.get('[data-executor-voice-receipt]').textContent, /receipt 13/);
  assert.equal(f.fields.get('[data-executor-voice-transcript]').textContent, '');
});

test('channel join keeps connecting until provider listening and reconnecting resets readiness', async () => {
  const f = fixture();
  const started = prepareStart(f);
  await f.controller.start();
  assert.equal(started.captureStarted, true);
  assert.equal(f.controller.state, 'connecting');
  started.options.handlers.state({state: 'listening'});
  assert.equal(f.controller.state, 'live');
  started.options.handlers.state({state: 'reconnecting'});
  assert.equal(f.controller.state, 'connecting');
  started.options.handlers.state({state: 'speaking'});
  assert.equal(f.controller.state, 'live');
});

test('provider readiness arriving before channel join does not skip microphone startup', async () => {
  const f = fixture();
  const started = prepareStart(f, options => options.handlers.state({state: 'listening'}));
  await f.controller.start();
  assert.equal(f.controller.state, 'live');
  assert.equal(started.captureStarted, true);
});

test('ending during microphone startup preserves the pending handoff receipt', async () => {
  const f = fixture();
  let rejectCapture, active, options, closed = false;
  let captureReady;
  const ready = new Promise(resolve => { captureReady = resolve; });
  f.window.AudioContext = class { async resume() {} };
  f.window.AiurVoiceCapture = {
    recalledDevice: () => '', requestMicrophone: async () => ({getTracks: () => []}),
    Capture: class {
      start(isActive) { active = isActive; captureReady(); return new Promise((_, reject) => { rejectCapture = reject; }); }
      stop() {}
    }
  };
  const transport = {joined: Promise.resolve(), close() { closed = true; }, push() {}};
  f.window.AiurVoiceTransport = {open(opts) { if (opts.topic === "voice:executor") options = opts; return transport; }};
  const starting = f.controller.start();
  await ready;
  f.controller.stop();
  rejectCapture(new Error('Capture context closed'));
  await starting;
  assert.equal(f.controller.state, 'ending');
  assert.equal(active(), false);
  assert.equal(closed, false);
  options.handlers.receipt({id: 99, at: 'now'});
  options.handlers.ended();
  assert.match(f.fields.get('[data-executor-voice-receipt]').textContent, /receipt 99/);
  assert.equal(closed, true);
});


test('Executor acknowledgment updates its own persisted item after session end and later sessions', async () => {
  const f = fixture();
  let receiptOptions, receiptClosed = false;
  f.window.AiurVoiceTransport = {open(options) {
    receiptOptions = options;
    return {joined: Promise.resolve(), push() {}, close() { receiptClosed = true; }};
  }};
  f.controller.receipt({id: 101, at: 'sent-at', summary_status: 'unstructured'});
  f.controller.ended();
  assert.equal(receiptClosed, false);
  assert.match(f.fields.get('[data-executor-voice-receipt]').textContent, /SENT NOT RECEIVED/);
  assert.match(f.fields.get('[data-executor-voice-receipt]').textContent, /unstructured/);
  f.controller.receipt({id: 102, at: 'second-sent'});
  receiptOptions.handlers.receipt_status({id: 101, wake_id: 8, ack_status: 'received', observed_at: 'ack-at'});
  f.controller.receipt({id: 101, at: 'sent-at', summary_status: 'unstructured'});
  assert.equal(f.controller.receipts.get(101).wake_id, 8);
  const text = f.fields.get('[data-executor-voice-receipt]').textContent;
  assert.match(text, /receipt 101 at sent-at/);
  assert.match(text, /RECEIVED — wake 8; ack observed at ack-at/);
  assert.match(text, /receipt 102 at second-sent/);
  assert.equal(f.controller.receipts.get(102).ack_status, 'waiting');
  f.controller.bindElements();
  assert.match(f.fields.get('[data-executor-voice-receipt]').textContent, /ack observed at ack-at/);
  f.controller.destroy();
  assert.equal(receiptClosed, true);
});

test('missing acknowledgments and disconnected receipt transport remain explicit', () => {
  const f = fixture();
  let options;
  f.window.AiurVoiceTransport = {open(value) { options = value; return {joined: Promise.resolve(), push() {}, close() {}}; }};
  f.controller.receipt({id: 103, at: 'sent'});
  options.handlers.receipt_status({id: 103, ack_status: 'missing'});
  assert.match(f.fields.get('[data-executor-voice-receipt]').textContent, /handoff wake missing; no acknowledgement/);
  options.onError();
  assert.match(f.fields.get('[data-executor-voice-receipt]').textContent, /acknowledgement unavailable/);
  assert.equal(f.controller.receipts.get(103).ack_status, 'unavailable');
});


test('session join carries the selected provider and model and unlocks them after ending', async () => {
  const f = fixture();
  const started = prepareStart(f);
  const provider = f.el.querySelector('[data-executor-voice-provider]');
  const model = f.el.querySelector('[data-executor-voice-model]');
  provider.value = 'openai_realtime';
  model.value = 'chosen-openai-model';
  await f.controller.start();
  assert.equal(started.options.joinPayload().provider, 'openai_realtime');
  assert.equal(started.options.joinPayload().model, 'chosen-openai-model');
  assert.equal(provider.disabled, true);
  f.controller.ended();
  assert.equal(provider.disabled, false);
  provider.value = 'elevenlabs_agents';
  model.value = 'chosen-eleven-model';
  await f.controller.start();
  assert.equal(started.options.joinPayload().provider, 'elevenlabs_agents');
  assert.equal(started.options.joinPayload().model, 'chosen-eleven-model');
});

test('comparison transport renders both meters, unknown first audio and saves ratings without sending audio', async () => {
  const f = fixture();
  let options;
  const sent = [];
  f.window.AiurVoiceTransport = {open(opts) {
    options = opts;
    return {joined: Promise.resolve(), close() {}, push(event, payload) { sent.push({event, payload}); }};
  }};
  f.el.dataset.configured = 'true';
  f.controller.bindElements();
  await Promise.resolve();
  assert.equal(options.topic, 'voice:executor_receipts');
  assert.ok(sent.some(item => item.event === 'comparison_list'));
  const row = {id: 'comparison-1', at: 'session-time', provider: 'openai_realtime', model: 'chosen', status: 'ended',
    first_audio_ms: null, minutes: 2, estimated_cost_usd: 0.36, rating: null, note: ''};
  options.handlers.comparison({rows: [row], meters: [
    {provider: 'openai_realtime', used_seconds: 120, cap_seconds: 2700},
    {provider: 'elevenlabs_agents', used_seconds: 60, cap_seconds: 2700}]});
  assert.match(f.fields.get('[data-executor-voice-meter]').textContent, /OpenAI: 2.00 \/ 45 min/);
  assert.match(f.fields.get('[data-executor-voice-meter]').textContent, /ElevenLabs: 1.00 \/ 45 min/);
  const [empty, cell] = f.fields.get('[data-executor-voice-comparisons]').children[0].children;
  assert.equal(empty.textContent, 'No session');
  const [metrics, rating, note, save] = cell.children;
  assert.match(metrics.textContent, /First audio: unavailable/);
  assert.match(metrics.textContent, /chosen/);
  assert.match(metrics.textContent, /2.00 min/);
  assert.match(metrics.textContent, /USD 0.36 estimate/);
  rating.value = '4';
  note.value = 'Easy to interrupt';
  save.listeners.click();
  const last = sent.at(-1);
  assert.equal(last.event, 'comparison_rate');
  assert.equal(last.payload.id, row.id);
  assert.equal(last.payload.rating, 4);
  assert.equal(last.payload.note, 'Easy to interrupt');
  assert.equal('audio' in last.payload, false);
});
