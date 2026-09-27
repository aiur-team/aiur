// Node 24 source probes; no live socket, device, daemon, credentials or packages.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const snapshot = process.argv[2];
assert(snapshot, 'Usage: node streamdeck_surface_probe.mjs SNAPSHOT');
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
    if (relative === 'src/rasterizer.ts') {
      source = `export const createRasterizer = () => ({key: () => new Uint8Array([1]), segment: (content) => {globalThis.__researchPanels.push(content); return new Uint8Array([2]);}});`;
    }
    const js = relative.endsWith('.json') ? source : stripTypeScriptTypes(source, {mode: "transform"});
    const target = path.join(temporary, relative.replace(/\.ts$/, '.js'));
    await mkdir(path.dirname(target), {recursive: true});
    await writeFile(target, js);
    for (const match of js.matchAll(/(?:import|export)[^;]*?from\s+["'](\.[^"']+\.(?:js|json))["']/g)) {
      await copy(path.normalize(path.join(path.dirname(relative), match[1])).replace(/\.js$/, '.ts'));
    }
  }
  await copy('src/surface.ts');
  const {createPhysicalSurface} = await import(pathToFileURL(path.join(temporary,'src/surface.js')));
  globalThis.__researchPanels=[];
  const surface=createPhysicalSurface();
  const backend={write:async()=>{},sendFeatureReport:async()=>{}};
  const devices=Array.from({length:8},(_,i)=>({id:`mic-${i}`,label:`Mic ${i}`}));
  const base={mode:'settings',focusedIdentifier:'EX-1',columnOffset:0,microphones:devices,selectedMicId:'mic-7'};
  const labels=[];
  for(const offset of [6,0,6]) {
    globalThis.__researchPanels.length=0;
    await surface.repaint(backend,{agents:[],total:0},{},undefined,{...base,micOffset:offset});
    labels.push(JSON.parse(JSON.stringify(globalThis.__researchPanels)));
  }
  const serialized=labels.map(p=>JSON.stringify(p));
  assert(serialized[0].includes('Mic 7'));assert(serialized[1].includes('Mic 0'));assert(serialized[2].includes('Mic 7'));
  console.log(JSON.stringify({node:process.version,source_sha256:hashes,selected_device:'mic-7',page_offsets:[6,0,6],composed_panels:labels,
    limits:'Actual physical compositor and strip layout with a recording rasterizer replacement and no-op device writes. No pixels, USB or microphone tested. Encoder records the panel model supplied for rendering; production capture selection was source-traced separately.'},null,2));
} finally {delete globalThis.__researchPanels;await rm(temporary,{recursive:true,force:true});}
