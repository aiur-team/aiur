import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';

const script = readFileSync(new URL('../../priv/static/executor-voice-controller.js', import.meta.url), 'utf8');
function fixture() {
  const fields = new Map();
  const button = {addEventListener() {}, removeEventListener() {}};
  const el = {dataset: {}, querySelector(selector) {
    if (selector.endsWith('-toggle]')) return button;
    if (!fields.has(selector)) fields.set(selector, {textContent: ''});
    return fields.get(selector);
  }};
  const window = {atob: value => Buffer.from(value, 'base64').toString('binary')};
  vm.runInNewContext(script, {window, Uint8Array, DataView});
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
  assert.match(text, /Queued for Executor/);
  assert.match(text, /receipt 42 at 2026-10-27T10:00:00Z/);
  assert.match(text, /does not confirm it has been read/);
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

test('new session clears the previous receipt and transcript', async () => {
  const f = fixture();
  prepareStart(f);
  f.controller.receipt({id: 13, at: 'previous'});
  f.el.querySelector('[data-executor-voice-transcript]').textContent = 'previous transcript';
  await f.controller.start();
  assert.equal(f.fields.get('[data-executor-voice-receipt]').textContent, '');
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
