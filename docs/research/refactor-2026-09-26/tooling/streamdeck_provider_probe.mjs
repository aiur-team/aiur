// Node 24 source probes; no live socket, device, daemon, credentials or packages.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const snapshot = process.argv[2];
assert(snapshot, 'Usage: node streamdeck_provider_probe.mjs SNAPSHOT');
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
    const js = relative.endsWith('.json') ? source : stripTypeScriptTypes(source, {mode: "transform"});
    const target = path.join(temporary, relative.replace(/\.ts$/, '.js'));
    await mkdir(path.dirname(target), {recursive: true});
    await writeFile(target, js);
    for (const match of js.matchAll(/(?:import|export)[^;]*?from\s+["'](\.[^"']+\.(?:js|json))["']/g)) {
      await copy(path.normalize(path.join(path.dirname(relative), match[1])).replace(/\.js$/, '.ts'));
    }
  }
  await copy('src/touchStrip/providerSegment.ts');
  const {providerSegmentModel}=await import(pathToFileURL(path.join(temporary,'src/touchStrip/providerSegment.js')));
  const serverPath='src/lib/aiur_web/streamdeck_projection.ex';
  const server=await readFile(path.join(snapshot,serverPath),'utf8');
  const block=server.match(/  defp normalize_window\([\s\S]*?\n  end/)[0];
  const keys=[...block.matchAll(/^      ([a-z_]+):/gm)].map(m=>m[1]);
  assert.deepEqual(keys,['used_percent','remaining','resets_at','observed_at','age_seconds','freshness']);
  assert(server.includes('[{"session", session}, {"weekly", weekly}]'));
  // Synthetic values in the producer's inspected wire shape; server not executed.
  const window=(percent)=>({used_percent:percent,observed_at:'2026-09-26T00:00:00Z',age_seconds:0,freshness:'fresh'});
  const cases={
    normalized_pair:{provider:'codex',freshness:'fresh',windows:{session:window(42),weekly:window(71)}},
    normalized_weekly_only:{provider:'codex',freshness:'fresh',windows:{weekly:window(71)}},
    legacy_pair:{provider:'codex',freshness:'fresh',windows:{session:{...window(42),duration_minutes:300},weekly:{...window(71),duration_minutes:10080}}},
    duration_missing_percentage:{provider:'codex',windows:{session:{duration_minutes:300}}},
  };
  const results=Object.fromEntries(Object.entries(cases).map(([key,input])=>[key,{input,output:providerSegmentModel(input)}]));
  assert.equal(results.normalized_pair.output.hasData,false);
  assert.equal(results.normalized_pair.output.session,null);assert.equal(results.normalized_pair.output.weekly,null);
  assert.equal(results.normalized_weekly_only.output.session.usedPercent,71);assert.equal(results.normalized_weekly_only.output.weekly,null);
  assert.equal(results.legacy_pair.output.session.usedPercent,42);assert.equal(results.legacy_pair.output.weekly.usedPercent,71);
  assert.equal(results.duration_missing_percentage.output.session.usedPercent,0);
  console.log(JSON.stringify({node:process.version,source_sha256:hashes,server_source:{path:serverPath,sha256:createHash('sha256').update(server).digest('hex'),normalized_window_keys:keys},cases:results,
    limits:'Actual client model executed; server normalize_window and semantic slot shape checked against frozen source, not executed. Fixture uses synthetic percentages in that wire shape. No live meter population, provider, rendered pixels or hardware; legacy missing-percentage case is not claimed reachable through the normalized producer.'},null,2));
} finally {await rm(temporary,{recursive:true,force:true});}
