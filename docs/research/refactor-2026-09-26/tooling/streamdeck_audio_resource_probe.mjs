// Node 24 source probes; no live socket, device, daemon, credentials or packages.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const snapshot = process.argv[2];
assert(snapshot, 'Usage: node streamdeck_audio_resource_probe.mjs SNAPSHOT');
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
  for(const file of ['src/audio/session.ts','src/audio/node-system.ts','src/audio/node-playback.ts','src/audio/node-fetch.ts','src/audio/playback.ts']) await copy(file);
  const load = relative => import(pathToFileURL(path.join(temporary,relative)));
  const {createVoiceSession} = await load('src/audio/session.js');
  const {startCapture} = await load('src/audio/capture.js');
  const {createNodeSystem} = await load('src/audio/node-system.js');
  const {createPacatPlayback} = await load('src/audio/node-playback.js');
  const {playEncodedAudio} = await load('src/audio/playback.js');
  const {createNodeFetch} = await load('src/audio/node-fetch.js');
  let ready, ended;
  const readyPromise=new Promise(resolve=>ready=resolve);
  const endedPromise=new Promise(resolve=>ended=resolve);
  const raw=[],forwarded=[],errors=[];
  const nodeSystem=createNodeSystem();
  const system={run:nodeSystem.run,spawn(){
    const child=nodeSystem.spawn(process.execPath,['-e',
      'const t=setTimeout(()=>process.exit(8),5000);process.on("SIGINT",()=>{clearTimeout(t);process.stdout.write(Buffer.from([2,0]),()=>process.exit(0));});process.stdout.write(Buffer.from([1,0]));']);
    child.onExit(ended);
    return {kill:()=>child.kill(),onExit:handler=>child.onExit(handler),onData(handler){child.onData(chunk=>{raw.push(...chunk);handler(chunk);ready();});}};
  }};
  const session=createVoiceSession({system,deviceId:null,waveformWidth:2,onUpdate(){},onError:e=>errors.push(e),
    capture:(o,h)=>startCapture({...o,scheduler:()=>({cancel(){}})},h),
    transcriber:{available:true,unavailableReason:null,open(){return {push:bytes=>forwarded.push(...bytes),close(){}};}}});
  session.hold();await readyPromise;session.release();assert.equal(await endedPromise,0);
  assert.deepEqual(raw,[1,0,2,0]);assert.deepEqual(forwarded,[1,0]);assert.deepEqual(errors,[]);
  let exit,drain,error,endCalls=0,completed=false;
  const port=createPacatPlayback({spawn:()=>({stdin:{write:()=>false,end(){endCalls++;},once(_e,h){drain=h;},on(_e,h){error=h;}},onExit(h){exit=h;}})});
  const playing=playEncodedAudio(port,(async function*(){yield new Uint8Array([1]);})()).then(()=>{completed=true;});
  await new Promise(resolve=>setImmediate(resolve));
  error();exit(1);await new Promise(resolve=>setImmediate(resolve));
  assert.equal(completed,false);assert.equal(endCalls,0);
  const blocked={settled_after_error_and_exit:completed,close_calls_after_exit:endCalls};
  // Positive control and cleanup: only a synthetic drain unblocks the write.
  drain();await playing;assert.equal(endCalls,1);
  const failurePort=createPacatPlayback({spawn:()=>({stdin:{write:()=>true,end(){},once(){},on(){}},onExit(h){h(9);}})});
  await failurePort.close();
  let cancelled=0,bodyController;
  const originalFetch=globalThis.fetch;
  const body=new ReadableStream({start(c){bodyController=c;c.enqueue(new Uint8Array([7]));},cancel(){cancelled++;}});
  try {
    globalThis.fetch=async()=>new Response(body);
    const response=await createNodeFetch('https://example.test',{method:'POST',headers:{},body:'{}'});
    for await (const chunk of response.stream()) {assert.deepEqual([...chunk],[7]);break;}
    assert.equal(cancelled,0);assert.equal(body.locked,false);
    bodyController.enqueue(new Uint8Array([8]));
    const reader=body.getReader();assert.deepEqual([...(await reader.read()).value],[8]);reader.releaseLock();
    await body.cancel();
  } finally {globalThis.fetch=originalFetch;}
  console.log(JSON.stringify({node:process.version,source_sha256:hashes,
    recorder_tail:{raw_stdout:raw,forwarded_pcm:forwarded,errors,child_exit:0},
    playback:{...blocked,settled_after_synthetic_drain:completed,nonzero_exit_close_resolves:true},
    fetch_break:{cancel_calls_before_cleanup:0,body_unlocked:true,additional_bytes_readable:true},
    limits:'Capture uses the actual Node system adapter and a bounded synthetic child that flushes bytes on SIGINT, not parec or a microphone. Playback uses injected process events; fetch uses a local ReadableStream, not HTTP. Playback/TTS have no production callers in the frozen source search; these defects do not establish live device or quota impact.'},null,2));
} finally {await rm(temporary,{recursive:true,force:true});}
