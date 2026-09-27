// Node 24 source probes; no live socket, device, daemon, credentials or packages.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const snapshot = process.argv[2];
assert(snapshot, 'Usage: node streamdeck_log_refresh_probe.mjs SNAPSHOT');
const root = path.join(snapshot, 'packages/streamdeck');
const temporary = await mkdtemp(path.join(tmpdir(), 'aiur-channel-research-'));
const hashes = {};
try {
  await writeFile(path.join(temporary, 'package.json'), '{"type":"module"}');
  async function copy(relative) {
    if (hashes[relative]) return;
    const text = await readFile(path.join(root, relative), 'utf8');
    hashes[relative] = createHash('sha256').update(text).digest('hex');
    let source = text;
    if (relative === 'src/surface.ts') {
      // Controller imports only this pure predicate. Extract it unchanged;
      // do not load native image writers or pretend to test the device surface.
      source = text.match(/export const agentLess = [\s\S]*?;/)?.[0];
      assert(source);
    }
    const js = relative.endsWith('.json') ? source : stripTypeScriptTypes(source);
    const target = path.join(temporary, relative.replace(/\.ts$/, '.js'));
    await mkdir(path.dirname(target), {recursive: true});
    await writeFile(target, js);
    for (const match of js.matchAll(/(?:import|export)[^;]*?from\s+["'](\.[^"']+\.(?:js|json))["']/g)) {
      await copy(path.normalize(path.join(path.dirname(relative), match[1])).replace(/\.js$/, '.ts'));
    }
  }
  await copy('src/controller.ts');
  await copy('test/support/deckReports.ts');
  const load = relative => import(pathToFileURL(path.join(temporary, relative)));
  const {createPhysicalController} = await load('src/controller.js');
  const {keyReport, dialButton, dialTurn} = await load('test/support/deckReports.js');
  const grid = {agents:[{identifier:'EX-1',bucket:'running'}],total:1,windows:1,max_column_offset:0};
  const controller = createPhysicalController({grid:()=>grid,channel:()=>null,stateChanged(){}});
  const press = key => {controller.handleReport(keyReport(key,true));controller.handleReport(keyReport(key,false));};
  const rows = [
    {kind:'event_header',label:'origin',body:'origin'},
    {kind:'message',role:'system',body:'expired early row'},
    {kind:'message',role:'system',body:'retained early row'},
    {kind:'event_header',label:'selected event',body:'selected event'},
    {kind:'message',role:'system',body:'reading target'},
    {kind:'message',role:'system',body:'next row'},
    {kind:'event_header',label:'newest event',body:'newest event'},
    {kind:'message',role:'system',body:'tail one'},
    {kind:'message',role:'system',body:'tail two'},
    {kind:'message',role:'system',body:'tail three'},
  ];
  const keys = [
    {kind:'event',id:'origin',text:'origin',start:0},
    {kind:'event',id:'selected',text:'selected event',start:3},
    {kind:'event',id:'newest',text:'newest event',start:6},
    {kind:'live',id:'live',label:'LIVE',start:9},
  ];
  controller.setLogs({event_keys:keys,transcript:rows});
  press(0); press(1); press(1);
  controller.handleReport(dialTurn(0,1));
  assert.equal(controller.state().chatOffset,4);
  assert.equal(controller.state().selectedEvent,1);
  const before = {offset:controller.state().chatOffset,first_row:controller.state().transcriptRows[0].body};
  assert.equal(before.first_row,'reading target');
  // Positive control: unchanged header positions preserve the same reading.
  controller.setLogs({event_keys:keys,transcript:rows});
  assert.equal(controller.state().transcriptRows[0].body,'reading target');
  // A bounded tail drops an older transcript row. Event identities/order stay
  // fixed, so this isolates capture of the old header offsets, not ID matching.
  const shiftedRows=rows.filter((_,i)=>i!==1);
  const shiftedKeys=keys.map(k=>({...k,start:Math.max(0,k.start-1)}));
  controller.setLogs({event_keys:shiftedKeys,transcript:shiftedRows});
  const after={offset:controller.state().chatOffset,first_row:controller.state().transcriptRows[0].body};
  assert.equal(after.offset,4);assert.equal(after.first_row,'next row');
  assert.equal(shiftedRows[3].body,'reading target');
  console.log(JSON.stringify({node:process.version,source_sha256:hashes,
    refresh:{before,unchanged_refresh_preserved:true,after,expected_offset:3,expected_first_row:'reading target',event_identity_order_unchanged:true},
    limits:'Actual frozen controller consumes encoded HID reports; channel is null and only agentLess is extracted from surface. Synthetic sliding transcript with fixed event identities; no server execution, incident prevalence, canvas, USB or live daemon. Server source separately documents bounded tail reads and identity-based rebasing.'},null,2));
} finally {await rm(temporary,{recursive:true,force:true});}
