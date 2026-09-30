// Node 24 source probes; no live socket, device, daemon, credentials or packages.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const snapshot = process.argv[2];
assert(snapshot, 'Usage: node streamdeck_audio_probe.mjs SNAPSHOT');
const root = path.join(snapshot, 'packages/streamdeck');
const temporary = await mkdtemp(path.join(tmpdir(), 'aiur-audio-research-'));
const hashes = {};
try {
  await writeFile(path.join(temporary, 'package.json'), '{"type":"module"}');
  async function copy(relative) {
    if (hashes[relative]) return;
    const source = await readFile(path.join(root, relative), 'utf8');
    hashes[relative] = createHash('sha256').update(source).digest('hex');
    const js = stripTypeScriptTypes(source);
    const target = path.join(temporary, relative.replace(/\.ts$/, '.js'));
    await mkdir(path.dirname(target), {recursive:true});
    await writeFile(target,js);
    for(const match of js.matchAll(/(?:import|export)[^;]*?from\s+["'](\.[^"']+\.js)["']/g)) {
      await copy(path.normalize(path.join(path.dirname(relative),match[1])).replace(/\.js$/,'.ts'));
    }
  }
  for(const file of ['src/voiceHost.ts','src/audio/relay.ts','src/audio/session.ts']) await copy(file);
  const load = relative => import(pathToFileURL(path.join(temporary,relative)));
  const {createVoiceLink} = await load('src/voiceHost.js');
  const {createRelayTranscriber} = await load('src/audio/relay.js');
  const {createVoiceSession} = await load('src/audio/session.js');
  function harness() {
    const events=[];
    const channel={voiceStart(){events.push(['start']);},voiceAudio(...a){events.push(['audio',...a]);},voiceStop(...a){events.push(['stop',...a]);}};
    let relay;
    const link=createVoiceLink({channel:()=>channel,relay:()=>relay});
    relay=createRelayTranscriber({port:link.port});
    const session=createVoiceSession({system:{},transcriber:relay.transcriber,deviceId:null,waveformWidth:10,
      onUpdate(){},onError(reason){events.push(['error',reason]);},capture:()=>({stop(){}})});
    return {events,link,relay,session};
  }
  const final=harness();
  final.session.hold(); final.link.started('example-session',null);
  final.link.transcript('example-session',{kind:'final',text:'already settled'});
  final.link.transcript('example-session',{kind:'partial',text:'last words'});
  const before=final.session.text();
  final.session.release();
  final.link.transcript('example-session',{kind:'final',text:'last words'});
  assert.equal(final.session.message(),'already settled');
  assert.deepEqual(final.events,[['start'],['stop','example-session']]);
  // Even retaining host identity alone is insufficient: relay close seals delivery.
  final.relay.deliver({kind:'final',text:'last words'});
  assert.equal(final.session.message(),'already settled');
  const race=harness();
  race.session.hold(); race.link.port.audio('hold-A'); race.session.release();
  race.session.hold(); race.link.port.audio('hold-B');
  race.link.started('session-A',null);
  race.link.transcript('session-A',{kind:'final',text:'old hold text'});
  const misrouted=[...race.events];
  assert.deepEqual(misrouted,[['start'],['start'],['audio','session-A','hold-B']]);
  assert.equal(race.session.message(),'old hold text');
  race.link.started('session-B',null); race.session.release();
  assert.deepEqual(race.events.at(-1),['stop','session-B']);
  console.log(JSON.stringify({node:process.version,source_sha256:hashes,
    release_final:{before_release:before,after_final:final.session.message(),events:final.events,relay_direct_delivery_also_dropped:true},
    overlapping_start:{before_second_reply:misrouted,old_session_text_accepted:race.session.message(),events:race.events},
    limits:'Actual frozen voice link, relay and session modules with TypeScript removed. Injected capture and channel ports; synthetic ordered replies. No microphone, provider, WebSocket, live daemon or manual UX test. The overlap demonstrates client misattribution; the server can discard mislabelled audio after replacing its active session.'},null,2));
} finally { await rm(temporary,{recursive:true,force:true}); }
