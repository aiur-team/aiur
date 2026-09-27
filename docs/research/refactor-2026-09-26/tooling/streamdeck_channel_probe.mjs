// Node 24 source probes; no live socket, device, daemon, credentials or packages.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const snapshot = process.argv[2];
assert(snapshot, 'Usage: node streamdeck_channel_probe.mjs SNAPSHOT');
const root = path.join(snapshot, 'packages/streamdeck');
const temporary = await mkdtemp(path.join(tmpdir(), 'aiur-channel-research-'));
const hashes = {};
const sockets = [];
const channels = [];
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
  const {connectStreamDeckChannel} = await load('src/channel.js');
  const {createPhysicalController} = await load('src/controller.js');
  const {keyReport, dialButton, dialTurn} = await load('test/support/deckReports.js');
  const records = [];
  const names = ['snapshot','fleet','grid','usage','transcript','logs','control','voiceStarted','voice','voiceError','voiceClosed','voiceAvailability','commands','commandAnswered','commandsError','closed'];
  const events = Object.fromEntries(names.map(name => [name, (...args) => records.push({name, args})]));
  function socket() {
    const s = {binaryType: '', onopen: null, onmessage: null, onclose: null, onerror: null,
      sent: [], closed: 0, send(data) {this.sent.push(JSON.parse(data));}, close() {this.closed++;},
      reply(ref, status, response) {this.onmessage({data: JSON.stringify(['4',ref,'streamdeck:fleet','phx_reply',{status,response}])});},
    };
    sockets.push(s); return s;
  }
  async function connect(s) {
    const channel = await connectStreamDeckChannel({baseUrl: 'http://example.test', username:'example', password:'example',
      fetch: async () => ({ok:true,json:async()=>({token:'synthetic'})}), websocket:()=>s, events});
    channels.push(channel);
    return channel;
  }
  const s = socket();
  const channel = await connect(s);
  s.onopen(); s.reply('1','ok',{});
  for (const send of [() => channel.control('EX-1','implement'), () => channel.say('EX-1','synthetic message')]) {
    send(); s.reply(s.sent.at(-1)[1], 'error', {reason:'target_unavailable'});
  }
  assert.equal(records.length,0);
  channel.answerCommand('example-decision',1,'example-key',{option_id:'wait'});
  s.reply(s.sent.at(-1)[1],'error',{reason:'target_unavailable'});
  assert.equal(records.at(-1).name,'commandsError'); // control: reply parsing does work for tracked refs
  const ignored = {control_error_callbacks:0, say_error_callbacks:0, answer_error_callback:records.at(-1).name};
  channel.close();

  records.length = 0;
  const rejectedSocket = socket();
  const rejectedChannel = await connect(rejectedSocket);
  rejectedSocket.onopen(); rejectedSocket.reply('1','error',{reason:'unauthorized'});
  rejectedChannel.control('EX-1','implement');
  assert.equal(records.length,0);
  assert.equal(rejectedSocket.sent.length,1);
  const refusedJoin = {closed_callbacks:0, socket_closes:rejectedSocket.closed, sent_frames:rejectedSocket.sent.length};
  rejectedChannel.close();

  let text = 'synthetic operator instruction';
  let pageRequests = 0;
  let disconnected = true;
  const fakeChannel = {focus() {}, control() {}, say() {}, answerCommand() {}, commandsPage() {pageRequests++;}};
  const voice = {hold(){},release(){},message:()=>text,hasMessage:()=>text.length>0,
    clear(){text='';},dispose(){},microphones:()=>[],refresh(){},selectedDeviceId:()=>null,select(){}};
  const grid = {agents:[{identifier:'EX-1',bucket:'queued'}],total:1,windows:1,max_column_offset:0};
  const controller = createPhysicalController({grid:()=>grid,channel:()=>disconnected?null:fakeChannel,voice:()=>voice,stateChanged(){}});
  const press = key => {controller.handleReport(keyReport(key,true));controller.handleReport(keyReport(key,false));};
  press(0); controller.refreshVoice();
  assert.equal(controller.state().hasTranscript,true);
  press(5);
  assert.equal(text,''); assert.equal(controller.state().hasTranscript,false);
  press(7);
  assert.equal(controller.state().implementQueued,true);
  const offline = {message_before:'nonempty',message_after:text,has_transcript_after_send:controller.state().hasTranscript,implement_queued_without_channel:controller.state().implementQueued};

  disconnected = false;
  controller.setCommands({identifier:'EX-1',items:Array.from({length:8},(_,i)=>({decision_id:`example-${i}`,version:1,question:'Example',options:[],status:'resolved'})),has_next:true,next_cursor:'example-next',total:24});
  press(4);
  for(let i=0;i<4;i++) {
    controller.handleReport(dialTurn(3,20));
    controller.handleReport(dialButton(3,true));controller.handleReport(dialButton(3,false));
  }
  assert.equal(pageRequests,0); assert.equal(controller.state().historyOffset,0);
  console.log(JSON.stringify({node:process.version,source_sha256:hashes,ignored_replies:ignored,rejected_join:refusedJoin,
    offline_controller:offline,history:{loaded_items:8,total:24,has_next:true,page_requests:pageRequests,offset:controller.state().historyOffset},
    limits:'Source modules with types removed and only agentLess extracted from surface.ts; renderer/native image code not executed. Actual controller consumes encoded HID reports with injected channel/voice ports. Channel uses a synthetic socket and token fetch. No browser, physical hardware or live daemon tested. Missing join timeout is inspected, not timed here.'},null,2));
} finally {
  for (const channel of channels) channel.close();
  await rm(temporary,{recursive:true,force:true});
}
