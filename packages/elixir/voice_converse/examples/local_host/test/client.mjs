import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { VoiceConverseClient } from '../../../priv/static/voice_converse_client.js';
import assert from 'node:assert/strict';
const [base] = process.argv.slice(2);
const response = await fetch(base);
assert.equal(response.status, 200);
const html = await response.text();
const token = html.match(/token=(vct1[^`]+)/)[1];
const source = await (await fetch(base + '/client.js')).text();
assert.equal(source, readFileSync(new URL('../../../priv/static/voice_converse_client.js', import.meta.url), 'utf8'));
const client = new VoiceConverseClient({
  url: base.replace('http:', 'ws:') + '/voice?token=' + token, target: 'local',
  onFrame(frame) {
    if (frame.type === 'state' && frame.state === 'listening') console.log('LISTENING');
    if (frame.type === 'agent_text') console.log('TEXT ' + frame.text);
    if (frame.type === 'draft') console.log('DRAFT ' + frame.draft_id);
    if (frame.type === 'delivery') console.log('DELIVERY ' + frame.status);
    if (frame.type === 'ended') { console.log('ENDED'); client.socket.close(); }
  }, onError(error) { throw error; }
});
// No DOM or microphone in this wire integration test. The page uses the same client.
client.renderDraft = () => {};
client.updateDraft = () => {};
await client.connect();
client.send({ type: 'start', target: 'local' });
const input = createInterface({ input: process.stdin });
input.on('line', line => {
  if (line.startsWith('confirm ')) client.send({ type: 'confirm_draft', draft_id: line.slice(8) });
  if (line === 'end') { client.end(); input.close(); }
});
