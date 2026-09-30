// Source-level runtime probes. Node 24; no hardware, network, npm or Aiur launch.
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';

const snapshot = process.argv[2];
assert(snapshot, 'Usage: node streamdeck_lifecycle_probe.mjs SNAPSHOT');
const temporary = await mkdtemp(path.join(tmpdir(), 'aiur-deck-research-'));
const hashes = {};
const flush = () => new Promise(resolve => setImmediate(resolve));
try {
  await writeFile(path.join(temporary, 'package.json'), '{"type":"module"}');
  for (const name of ['runtime', 'lifecycle', 'lock', 'line-source', 'sleep-source', 'udev-source', 'report', 'read']) {
    const relative = `packages/streamdeck/src/${name}.ts`;
    const source = await readFile(path.join(snapshot, relative), 'utf8');
    hashes[relative] = createHash('sha256').update(source).digest('hex');
    await writeFile(path.join(temporary, name + '.js'), stripTypeScriptTypes(source));
  }
  const {startRuntime} = await import(pathToFileURL(path.join(temporary, 'runtime.js')));
  const {spawnLineSource} = await import(pathToFileURL(path.join(temporary, 'line-source.js')));
  const {parseUdevBlock} = await import(pathToFileURL(path.join(temporary, 'udev-source.js')));

  // Verify the triggering event sequence with a real Node spawn of an absent
  // executable inside our fresh temp directory, not just an invented double.
  const actualEndEvents = [];
  await new Promise(resolve => {
    spawnLineSource((command, args) => {
      const child = spawn(command, args);
      child.on('close', () => setImmediate(resolve));
      return child;
    }, path.join(temporary, 'deliberately-absent-monitor'), [], {
      onLine() {}, onEnd: cause => actualEndEvents.push(
        typeof cause === 'object' && cause !== null ? cause.code : cause),
    });
  });
  assert.deepEqual(actualEndEvents, ['ENOENT', -2]);

  function harness(present = false) {
    const children = [];
    const timers = new Map();
    let nextTimer = 0;
    let closes = 0;
    let opens = 0;
    let released = 0;
    const backend = {
      async write() {}, async sendFeatureReport() {}, async getFeatureReport() {return new Uint8Array();},
      async read() {return {kind: 'timeout'};}, async close() {closes++;},
    };
    const env = {
      spawn(command) {
        const child = new EventEmitter();
        child.command = command;
        child.stdout = new EventEmitter();
        child.stdout.setEncoding = () => {};
        child.killed = false;
        child.kill = () => {child.killed = true;};
        children.push(child);
        return child;
      },
      net: {createServer() {
        const server = new EventEmitter();
        server.listen = () => server.emit('listening');
        server.close = () => {released++;};
        return server;
      }},
      brightness: 80, devicePresentAtStart: present,
      async openBackend() {opens++; return backend;},
      registerSignals() {}, exit() {}, log() {}, onBackendClosed() {}, async repaint() {},
      setTimer(fn, delay) {const id = ++nextTimer; timers.set(id, {fn, delay}); return id;},
      clearTimer(id) {timers.delete(id);},
    };
    return {env, children, timers, counts: () => ({opens, closes, released}),
      fireFirst() {
        const [id, timer] = timers.entries().next().value;
        timers.delete(id); timer.fn();
      },
      feedUdev(vendor, product) {
        children.find(child => child.command === 'udevadm').stdout.emit('data',
          `ACTION=remove\nDEVTYPE=usb_device\nID_VENDOR_ID=${vendor}\nID_MODEL_ID=${product}\n\n`);
      },
    };
  }

  const duplicate = harness();
  const firstRuntime = await startRuntime(duplicate.env);
  duplicate.children[0].emit('error', Object.assign(new Error('absent'), {code: 'ENOENT'}));
  duplicate.children[0].emit('close', -2);
  const scheduled = [...duplicate.timers.values()].map(timer => timer.delay);
  assert.deepEqual(scheduled, [500, 1000]);
  duplicate.fireFirst();
  duplicate.fireFirst();
  const sleepChildren = duplicate.children.filter(child => child.command === 'gdbus');
  assert.equal(sleepChildren.length, 3); // original failed child plus two replacements
  firstRuntime.stop();
  const orphanedReplacements = sleepChildren.slice(1).filter(child => !child.killed).length;
  assert.equal(orphanedReplacements, 1);

  const stopped = harness();
  const secondRuntime = await startRuntime(stopped.env);
  stopped.children[0].emit('error', new Error('absent'));
  stopped.children[0].emit('close', -2);
  secondRuntime.stop();
  assert.equal(stopped.timers.size, 1);
  const spawnsBefore = stopped.children.length;
  stopped.fireFirst();
  assert.equal(stopped.children.length, spawnsBefore + 1);

  const removal = harness(true);
  const thirdRuntime = await startRuntime(removal.env);
  await flush();
  assert.equal(removal.counts().opens, 1);
  removal.feedUdev('1234', 'ffff');
  await flush();
  const afterOtherVendor = removal.counts().closes;
  assert.equal(afterOtherVendor, 0);
  removal.feedUdev('0fd9', 'ffff'); // deliberately different product, not a real hardware claim
  await flush();
  const afterOtherProduct = removal.counts().closes;
  assert.equal(afterOtherProduct, 1);
  assert.equal(removal.timers.size, 0);
  thirdRuntime.stop();
  const ownProduct = parseUdevBlock(['ACTION=remove', 'DEVTYPE=usb_device', 'ID_VENDOR_ID=0fd9', 'ID_MODEL_ID=0084']);
  assert.equal(ownProduct, 'device-removed');

  console.log(JSON.stringify({
    node: process.version, source_sha256: hashes,
    monitor: {actual_missing_executable_on_end_events: actualEndEvents,
      restart_delays_ms_for_one_error_then_close: scheduled,
      replacement_children_after_both_timers: sleepChildren.length - 1,
      replacement_children_not_killed_on_stop: orphanedReplacements,
      pending_restart_after_stop: 1, spawns_after_stop_when_pending_timer_fires: 1},
    removal: {backend_opens: 1, closes_after_other_vendor: afterOtherVendor,
      closes_after_same_vendor_different_product: afterOtherProduct,
      pending_poll_or_reopen_timers_after_wrong_removal: 0, own_product_parse: ownProduct},
    limits: 'Actual source modules with stripped types; fake timers, USB backend, net lock and monitor streams. A real Node spawn of a deliberately absent executable confirms error+close delivery. No hardware or live daemon exercised; no population/frequency claim. Product ffff is synthetic. No production changes.',
  }, null, 2));
} finally {
  await rm(temporary, {recursive: true, force: true});
}
