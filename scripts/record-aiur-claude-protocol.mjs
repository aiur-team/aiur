// Real sibling implementation + its fake CLI; no API credentials or live Claude.
import assert from 'node:assert/strict';
import {mkdtemp, readFile, writeFile, chmod, rm} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import net from 'node:net';
import readline from 'node:readline';
import {spawnSync} from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sibling = path.resolve(process.argv[2]);
const fixture = path.join(root, 'src/test/fixtures/aiur_claude/protocol-1.1.0.ndjson');
const {ClaudeAppServer} = await import(pathToFileURL(path.join(sibling, 'dist/server.js')));
const scratch = await mkdtemp(path.join(process.env.TMPDIR ?? '/tmp', 'claude-protocol-'));
const recorded = [];
const writeMode = process.argv[3] === '--write';
assert.ok(!process.argv[3] || writeMode, 'Only --write is accepted');
const reference = writeMode ? [] : (await readFile(fixture, 'utf8')).trim().split('\n').map(JSON.parse);
const pause = () => new Promise(resolve => setTimeout(resolve, 5));
const waitFor = async check => {
  const deadline = Date.now() + 5000;
  while (!check()) {
    assert.ok(Date.now() < deadline, 'Timed out waiting for sibling protocol message');
    await pause();
  }
};
const tools = [{name: 'emit_alert', description: 'Emit a milestone alert.', inputSchema: {type: 'object'}}];
const wrapper = path.join(scratch, 'fake-claude.mjs');
await writeFile(wrapper, `#!/usr/bin/env node
import {existsSync} from 'node:fs';
if (!process.argv.includes('--version')) {
  while (!existsSync(process.env.PROTOCOL_GATE)) await new Promise(r => setTimeout(r, 5));
}
// The v1.1.0 fake predates FAKE_CLAUDE_EXIT; control failures identically.
const exit = process.exit.bind(process);
process.exit = code => exit(Number(process.env.FAKE_CLAUDE_EXIT ?? code));
await import(${JSON.stringify(pathToFileURL(path.join(sibling, 'test/fixtures/fake-claude.mjs')).href)});
`);
await chmod(wrapper, 0o755);

try {
  for (const scenario of ['completed_tool', 'operator', 'interrupt', 'failure_legacy', 'failure_provenance', 'busy']) {
    const ids = new Map();
    const outbound = reference.filter(row => row.scenario === scenario && row.dir === 'out');
    let outboundIndex = 0;
    function expand(value) {
      if (value === '<workspace>') return scratch;
      if (value === '<dynamic-tools>') return tools;
      for (const [actual, placeholder] of ids) if (value === placeholder) return actual;
      if (Array.isArray(value)) return value.map(expand);
      if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, expand(v)]));
      return value;
    }
    let turnNumber = 0;
    function normalize(value, key = '') {
      if (value === scratch) return '<workspace>';
      if (ids.has(value)) return ids.get(value);
      if (['created_at', 'completed_at'].includes(key)) return '<timestamp>';
      if (key === 'dynamicTools' && Array.isArray(value)) return '<dynamic-tools>';
      if (Array.isArray(value)) return value.map(v => normalize(v));
      if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, normalize(v, k)]));
      return value;
    }
    function record(dir, msg) {
      if (dir === 'in') {
        if (msg.id === 2 && msg.result?.thread?.id) ids.set(msg.result.thread.id, '<thread>');
        if (msg.result?.turn?.id) ids.set(msg.result.turn.id, ++turnNumber === 1 ? '<turn>' : '<turn-2>');
        if (msg.params?.item?.id) ids.set(msg.params.item.id, '<item>');
        if (msg.method === 'item/tool/call') {
          ids.set(msg.id, '<tool-request>');
          ids.set(msg.params.callId, '<tool-call>');
        }
      }
      recorded.push({scenario, dir, msg: normalize(msg)});
    }
    const server = new ClaudeAppServer(wrapper, false, async () => undefined);
    const messages = [];
    const conn = {initialized: false, send(msg) { messages.push(msg); record('in', msg); }};
    const send = async frame => {
      // Checks play the committed outbound frames; --write authors the scenarios below.
      const msg = writeMode ? {jsonrpc: '2.0', ...frame} : expand(outbound[outboundIndex++]?.msg);
      assert.ok(msg, `Missing outbound frame for ${scenario}`);
      assert.notEqual(msg.method, 'turn/steer', 'Aiur must not send the unsupported steer operation');
      record('out', msg);
      const result = await server.handleMessage(msg, conn);
      if (result) { messages.push(result); record('in', result); }
      return result;
    };
    const request = (id, method, params) => send({id, method, params});
    const gate = path.join(scratch, `${scenario}.gate`);
    process.env.PROTOCOL_GATE = gate;
    process.env.FAKE_CLAUDE_FIXTURE = path.join(scratch, `${scenario}.ndjson`);
    process.env.FAKE_CLAUDE_EXIT = scenario.startsWith('failure') ? '1' : '0';
    const text = scenario.startsWith('failure') ? 'You have hit your session limit' : 'Done.';
    const cli = [
      {type: 'system', subtype: 'init', session_id: 'fixture-session', apiKeySource: 'none'},
      ...(scenario === 'completed_tool' ? [{type: 'rate_limit_event', rate_limit_info: {status: 'allowed'}}] : []),
      {type: 'assistant', ...(scenario === 'failure_provenance' ? {error: 'rate_limit', is_api_error_message: true} : {}), message: {id: 'fixture-message', content: [{type: 'text', text}]}},
      {type: 'result', subtype: 'success', ...(scenario === 'failure_provenance' ? {is_error: true, api_error_status: 429, terminal_reason: 'api_error', result: text} : {}), usage: {input_tokens: 3, output_tokens: 4}, ...(scenario === 'completed_tool' ? {permission_denials: [{tool_name: 'Bash', tool_use_id: 'fixture-denial', tool_input: {command: 'denied'}}]} : {})}
    ];
    await writeFile(process.env.FAKE_CLAUDE_FIXTURE, cli.map(v => JSON.stringify(v)).join('\n') + '\n');
    await request(1, 'initialize', {capabilities: {experimentalApi: true}, clientInfo: {name: 'aiur-orchestrator', title: 'Aiur Orchestrator', version: '<client-version>'}});
    await waitFor(() => messages.some(m => m.method === 'initialized'));
    await send({method: 'initialized', params: {}});
    const started = await request(2, 'thread/start', {permissionMode: 'bypassPermissions', cwd: scratch, dynamicTools: tools});
    assert.ok(started.result?.thread?.id, 'thread/start must return thread.id');
    const threadId = started.result.thread.id;
    const thread = server.getThread(threadId);
    let socket;
    try {
      const first = await request(3, 'turn/start', {threadId, input: [{type: 'text', text: 'Protocol fixture prompt'}], cwd: scratch, title: 'fixture: Protocol fixture'});
      assert.ok(first.result?.turn?.id, 'turn/start must return turn.id');
      await waitFor(() => messages.some(m => m.method === 'turn/started'));
      if (scenario === 'completed_tool') {
        await waitFor(() => thread.toolBridge.socketPath && existsSync(thread.toolBridge.socketPath));
        socket = net.connect(thread.toolBridge.socketPath);
        const rl = readline.createInterface({input: socket});
        let toolResult;
        rl.on('line', line => { toolResult = JSON.parse(line); });
        socket.write(JSON.stringify({jsonrpc: '2.0', id: 50, method: 'tools/call', params: {name: 'emit_alert', arguments: {name: 'milestone.test', message: 'hi', reason: 'r', needs_attention: false}}}) + '\n');
        await waitFor(() => messages.some(m => m.method === 'item/tool/call'));
        const call = messages.find(m => m.method === 'item/tool/call');
        await send({id: call.id, result: {success: true, output: 'alert emitted'}});
        await waitFor(() => toolResult);
        assert.equal(toolResult.result.isError, false);
        rl.close();
      }
      if (scenario === 'busy') {
        const busy = await request(4, 'turn/start', {threadId, input: [{type: 'text', text: 'Operator follow-up'}], cwd: scratch});
        assert.equal(busy.error?.code, -32003);
      }
      if (['interrupt', 'busy'].includes(scenario)) {
        // Interrupt the gated CLI after spawn, independent of --version timing.
        await waitFor(() => thread.turns[0].process);
        const interrupted = await request(5, 'turn/interrupt', {threadId, turnId: first.result.turn.id});
        assert.equal(interrupted.result?.status, 'interrupted');
      }
      await writeFile(gate, 'release');
      await waitFor(() => messages.some(m => ['turn/completed', 'turn/failed'].includes(m.method)));
      if (scenario === 'operator') {
        await request(4, 'turn/start', {threadId, input: [{type: 'text', text: 'Operator follow-up'}], cwd: scratch});
        await waitFor(() => messages.filter(m => m.method === 'turn/completed').length === 2);
      }
      if (!writeMode) assert.equal(outboundIndex, outbound.length, 'Unconsumed outbound frames');
    } finally {
      socket?.destroy();
      thread.toolBridge?.close();
      for (const turn of thread.turns) turn.process?.kill('SIGTERM');
    }
  }
  const output = path.join(scratch, 'observed.ndjson');
  await writeFile(output, recorded.map(row => JSON.stringify(row)).join('\n') + '\n');
  if (writeMode) {
    await writeFile(fixture, await readFile(output));
    console.log(`Recorded ${recorded.length} frames in ${fixture}`);
  } else {
    const result = spawnSync('diff', ['-u', fixture, output], {stdio: 'inherit'});
    assert.equal(result.status, 0, 'Sibling protocol drift: inspect the diff; use --write only after reviewing compatibility');
    console.log(`Sibling protocol matches (${recorded.length} frames)`);
  }
} finally {
  await rm(scratch, {recursive: true, force: true});
}
