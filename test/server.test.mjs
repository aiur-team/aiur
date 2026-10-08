import test from "node:test";
import assert from "node:assert/strict";

import { ClaudeAppServer } from "../dist/server.js";
import { fakeConn, waitFor, mcpClient, TOOLS } from "./helpers.mjs";

// TypeScript `private` is compile-time only; tests reach internals (threads,
// buildClaudeArgs) through the erased JS surface on purpose.

async function initializedServer() {
  const server = new ClaudeAppServer("claude", false);
  const conn = fakeConn();
  const resp = await server.handleMessage(
    {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { clientInfo: { name: "aiur-orchestrator", version: "0.0.0" } },
    },
    conn,
  );
  assert.ok(resp.result.server);
  return { server, conn };
}

async function startThread(server, conn, params) {
  const resp = await server.handleMessage(
    { jsonrpc: "2.0", id: 2, method: "thread/start", params },
    conn,
  );
  return resp;
}

test("thread/start without dynamicTools keeps the legacy claude invocation", async () => {
  const { server, conn } = await initializedServer();
  const resp = await startThread(server, conn, { cwd: "/tmp", permissionMode: "bypassPermissions" });

  assert.ok(resp.result.thread.id);
  const thread = server.getThread(resp.result.thread.id);
  assert.equal(thread.dynamicTools, undefined);
  assert.equal(thread.toolBridge, undefined);

  assert.deepEqual(server.buildClaudeArgs(thread), [
    "--print",
    "--output-format", "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--permission-mode", "bypassPermissions",
    "--session-id", thread.id,
  ]);
});

test("thread/resume restores an on-disk session in a fresh app-server process", async () => {
  const { server, conn } = await initializedServer();
  const sessionId = "resume-session-3040";
  const resumed = await server.handleMessage(
    { jsonrpc: "2.0", id: 7, method: "thread/resume", params: { threadId: sessionId, cwd: "/repo", permissionMode: "bypassPermissions" } },
    conn,
  );

  assert.equal(resumed.result.thread.id, sessionId);
  const thread = server.getThread(sessionId);
  assert.equal(thread.cliSessionId, sessionId);
  assert.equal(thread.cwd, "/repo");
  assert.deepEqual(server.buildClaudeArgs(thread), [
    "--print", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
    "--permission-mode", "bypassPermissions", "--resume", sessionId,
  ]);
});

test("thread/resume rejects a missing session id", async () => {
  const { server, conn } = await initializedServer();
  const resumed = await server.handleMessage(
    { jsonrpc: "2.0", id: 8, method: "thread/resume", params: { cwd: "/repo" } },
    conn,
  );
  assert.equal(resumed.error.code, -32602);
});

test("thread/start with dynamicTools wires the MCP bridge into claude args", async (t) => {
  const { server, conn } = await initializedServer();
  const resp = await startThread(server, conn, {
    cwd: "/tmp",
    permissionMode: "bypassPermissions",
    dynamicTools: TOOLS,
  });

  const thread = server.getThread(resp.result.thread.id);
  t.after(() => thread.toolBridge?.close());
  assert.equal(thread.dynamicTools.length, 2);
  assert.ok(thread.toolBridge);

  // Args gain MCP flags only once the bridge is started (runClaudeTurn does this)
  await thread.toolBridge.start();
  const args = server.buildClaudeArgs(thread);

  const mcpConfigIdx = args.indexOf("--mcp-config");
  assert.notEqual(mcpConfigIdx, -1);
  const config = JSON.parse(args[mcpConfigIdx + 1]);
  assert.ok(config.mcpServers.aiur);
  assert.equal(config.mcpServers.aiur.args[1], thread.toolBridge.socketPath);

  const allowedIdx = args.indexOf("--allowedTools");
  assert.notEqual(allowedIdx, -1);
  assert.equal(args[allowedIdx + 1], "mcp__aiur__aiur_declare_blocker,mcp__aiur__emit_alert");

  // Legacy flags all still present
  for (const flag of ["--print", "--verbose", "--include-partial-messages", "--session-id"]) {
    assert.ok(args.includes(flag), `missing ${flag}`);
  }
});

test("thread/start with malformed dynamicTools returns InvalidParams", async () => {
  const { server, conn } = await initializedServer();

  const notArray = await startThread(server, conn, { cwd: "/tmp", dynamicTools: "oops" });
  assert.equal(notArray.error.code, -32602);

  const badEntry = await startThread(server, conn, { cwd: "/tmp", dynamicTools: [{ description: "no name" }] });
  assert.equal(badEntry.error.code, -32602);
});

test("full round-trip over the app-server transport with a mock engine", async (t) => {
  const { server, conn } = await initializedServer();
  const resp = await startThread(server, conn, { cwd: "/tmp", dynamicTools: TOOLS });
  const thread = server.getThread(resp.result.thread.id);
  t.after(() => thread.toolBridge.close());

  // What runClaudeTurn does before spawning claude
  thread.toolBridge.bindConnection(conn);
  const socketPath = await thread.toolBridge.start();

  // "claude" invokes the tool through MCP
  const client = mcpClient(socketPath);
  t.after(() => client.close());
  const replyPromise = client.request(50, "tools/call", {
    name: "emit_alert",
    arguments: { name: "milestone.test", message: "hi", reason: "r", needs_attention: false },
  });

  // Engine sees an item/tool/call request frame on its transport…
  const request = await waitFor(() => conn.sent.find((m) => m.method === "item/tool/call"));
  assert.equal(request.params.name, "emit_alert");
  assert.equal(request.params.arguments.name, "milestone.test");

  // …and answers on the same transport; handleMessage routes it to the bridge.
  const routed = await server.handleMessage(
    { jsonrpc: "2.0", id: request.id, result: { success: true, output: "alert emitted" } },
    conn,
  );
  assert.equal(routed, null, "responses must not produce a reply frame");

  const reply = await replyPromise;
  assert.equal(reply.result.isError, false);
  assert.deepEqual(reply.result.content, [{ type: "text", text: "alert emitted" }]);
});

test("thread/fork inherits dynamicTools with its own bridge", async (t) => {
  const { server, conn } = await initializedServer();
  const resp = await startThread(server, conn, { cwd: "/tmp", dynamicTools: TOOLS });
  const src = server.getThread(resp.result.thread.id);
  src.cliSessionId = "sess-under-test"; // forking requires a completed turn

  const forkResp = await server.handleMessage(
    { jsonrpc: "2.0", id: 3, method: "thread/fork", params: { threadId: src.id } },
    conn,
  );
  const forked = server.getThread(forkResp.result.thread.id);
  t.after(() => { src.toolBridge?.close(); forked.toolBridge?.close(); });

  assert.deepEqual(forked.dynamicTools, src.dynamicTools);
  assert.ok(forked.toolBridge);
  assert.notEqual(forked.toolBridge, src.toolBridge);
});
