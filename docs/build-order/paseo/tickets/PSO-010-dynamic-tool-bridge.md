# PSO-010 — Dynamic tool bridge: aiur coordination tools for Paseo-owned agents

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — a port of a proven module plus one new wiring point, with process and socket lifecycle to get right

**Risk:** medium

**Phase hint:** 3

**Depends on:** PSO-005, PSO-006

**Serializes with:** PSO-009 — both edit `packages/aiur-paseo/src/session.ts`; rebase onto PSO-009

**External gates:** none

**Requirements:** R6, R14

**Decisions:** DEC-006, DEC-007

**Design evidence:** 00-design.md sections 4, 5, 6, 7; 01-spike-report.md sections 3, 7, 8

**Researched at:** aiur `8199f5373`, paseo `726067b4`, aiur-claude 1.1.0

**Suggested labels:** `complexity:3`, `model:claude`, `phase:3`, `build-lane:paseo-sidecar`; never `agent:todo`

## Outcome

A Paseo-owned Claude or Codex agent can call `emit_alert`, `emit_event`, `aiur_subscribe`, `aiur_declare_blocker`, the review-thread tools, and `linear_graphql` exactly as an `aiur-claude` agent can. The sidecar hosts the same MCP bridge `aiur-claude` hosts, and injects it into the Paseo agent through `config.mcpServers` on create. Tool calls round-trip to aiur as `item/tool/call` requests and aiur's existing handler answers them.

## Context and evidence

aiur advertises its tools on `thread/start` as `dynamicTools: [{name, description, inputSchema}]` (`src/lib/aiur/claude/coding_agent.ex` `start_thread/2`, specs from `Aiur.Codex.DynamicTool.tool_specs/0`). It answers `item/tool/call {name, arguments, callId}` requests with `{id, result: {success, output, contentItems}}` (`handle_method/5` clause for `"item/tool/call"`, which calls `Aiur.AgentRunner.ToolExecutor.execute/4` and `Messages.normalize_tool_result/2`). String ids of the form `aiur-tool-N` never collide with aiur's integer ids.

aiur-claude 1.1.0 already implements the agent side (MIT, `$(npm root -g)/aiur-claude/src/dynamic-tools.ts`, 14 KB): `parseDynamicTools` validates the specs, `DynamicToolBridge` serves an NDJSON MCP server (protocol `2025-06-18`, `tools/list`, `tools/call`) on a unix socket, `PendingEngineCalls` tracks `item/tool/call` requests awaiting the orchestrator with a 120 s timeout, `engineResultToMcp` maps the result envelope to `{content: [{type: "text", text}], isError}`. `src/mcp-shim.ts` (30 lines) is the stdio relay the provider spawns; it pipes stdin/stdout to the socket. aiur-claude passes it to `claude` via `--mcp-config` under server key `aiur`, so tools are namespaced `mcp__aiur__<name>` and the bare name round-trips. Its tests live in `$(npm root -g)/aiur-claude/test/dynamic-tools.test.mjs` (fake connection, fake MCP client over the socket, timeouts).

Paseo accepts MCP servers per agent: `create_agent_request.config.mcpServers` is `Record<string, McpServerConfig>` with `McpStdioServerConfigSchema = {type: "stdio", command, args?, env?, alwaysLoad?}` (`packages/protocol/src/messages.ts`, spike section 7). Both providers report `capabilities.supportsMcpServers: true` in `get_agent_status` (spike sections 3 and 8). Paseo itself injects one MCP server named `paseo` by default (`runtime-mcp-config.ts`), so the name `aiur` does not collide.

## Scope

- Copy `dynamic-tools.ts`, `mcp-shim.ts`, and `protocol.ts`'s `RpcException`/error codes into `packages/aiur-paseo/src/tools/` with a header comment attributing aiur-claude 1.1.0 (MIT) and keeping its license text in `packages/aiur-paseo/THIRD-PARTY-NOTICES.md`.
- Build output must include `dist/tools/mcp-shim.js` as a standalone runnable file; `shimPath` resolves relative to `import.meta.url` at runtime.
- Per thread, in `session.ts` `start`: `parseDynamicTools(params.dynamicTools)`; when non-empty, create `new DynamicToolBridge(tools, pendingEngineCalls, {timeoutMs: 120000, log})`, `bindConnection(conn)`, `await bridge.start(socketPath)`. Socket path: `path.join(process.env.XDG_RUNTIME_DIR ?? os.tmpdir(), "aiur-paseo", <threadId>.sock)`, directory `0700`, socket `0600`, path under 100 bytes (unix socket limit, use a short id).
- Pass `config.mcpServers = {aiur: {type: "stdio", command: process.execPath, args: [shimPath, socketPath], alwaysLoad: true}}` on `create_agent_request`. Drop `alwaysLoad` if the pinned client version rejects it.
- Route the sidecar's `item/tool/call` requests through `AppServer`'s `PendingEngineCalls` (PSO-005) so responses on stdin resolve them; `engineResultToMcp` maps the reply.
- `close(threadId)`: `bridge.close()` (closes the server, unlinks the socket). Also on `SIGTERM`, `SIGINT`, and `exit`: unlink every live socket path.
- Same wiring for `--provider codex`; nothing provider-specific.

## Non-goals

- Changing any tool spec or aiur's tool handler.
- Serving the tools over HTTP or inside Paseo's own `paseo` MCP server.
- Persisting bridge state across sidecar restarts; a re-attached thread (PSO-011) starts a fresh bridge, and the Paseo agent must be re-created if its `mcpServers` no longer point at a live socket (PSO-011 owns that check).

## Existing owner and reuse target

`aiur-claude` `src/dynamic-tools.ts` and `src/mcp-shim.ts` are ported, not rewritten. `src/server.ts` (PSO-005) already owns `PendingEngineCalls` for `item/tool/call`; this ticket connects the bridge to it. `src/session.ts` (PSO-009) gains the bridge lifecycle and the `mcpServers` entry.

## Contract and invariants

- Tool names reach aiur unchanged; namespacing is the provider's job.
- A tool call that aiur does not answer within 120 s returns an MCP error result to the agent; the turn continues.
- A tool call while the sidecar's stdin is closed returns an MCP error, never a hang.
- One bridge, one socket, per thread; closed with the thread; no socket files survive process exit.
- The bridge never logs tool arguments or results at info level.

### Requirements

- PSO-010-R1. `thread/start` with `dynamicTools` starts a bridge and the Paseo agent is created with `config.mcpServers.aiur` pointing at the shim and socket.
- PSO-010-R2. `tools/list` on the socket returns the parsed specs; `tools/call` produces an `item/tool/call` request on stdout with `{name, arguments, callId}` and a string id.
- PSO-010-R3. An aiur response with matching id resolves the call and maps through `engineResultToMcp`.
- PSO-010-R4. Timeout and transport failures become `isError: true` results.
- PSO-010-R5. Sockets are removed on thread close and on process signals.
- PSO-010-R6. `thread/start` without `dynamicTools` creates the agent with no `aiur` MCP entry.

## Refreshable implementation notes

- Keep the port byte-for-byte where possible so future aiur-claude fixes can be diffed in; only change imports and the `RpcException` source.
- `socketPath` length: unix sockets fail above ~104 bytes on macOS and 108 on Linux; derive a 12-char id from the thread id.
- Codex's MCP client may require the shim to respond to `initialize` before `tools/list`; the ported bridge already does.
- If Paseo's create fails with a schema error on `alwaysLoad`, retry once without it and log.

### Key technical decisions

- Port aiur-claude's bridge rather than write a new one: it is tested, it already speaks the exact aiur `item/tool/call` envelope, and the `mcp-shim` stdio relay is precisely what `McpStdioServerConfig` needs.
- Socket under `XDG_RUNTIME_DIR` first: it is per-user, tmpfs, and cleaned at logout.

## Acceptance and verification

### Agent gate

- Port `dynamic-tools.test.mjs` into vitest (`test/tools/dynamic-tools.test.ts`) and keep every existing case: spec parsing, result mapping, `tools/list`, `tools/call` round trip, orchestrator error response, timeout, unbound connection.
- New tests: the fake daemon records `create_agent_request.config.mcpServers.aiur` with `type: "stdio"`, `command === process.execPath`, `args[0]` ending in `mcp-shim.js`, `args[1]` an existing socket; a fake MCP client spawns the real shim against the bridge and completes a `tools/call`; `AppServer` with a `FakeDriver` answers an `item/tool/call` reply from stdin and the MCP client sees the text; `close` unlinks the socket; `thread/start` without tools yields no `mcpServers.aiur`.
- `npm test`, `npm run lint`, `npm run typecheck` green; coverage thresholds hold (the shim is excluded like `main.ts` is in streamdeck's config, with a comment).

### At-merge gate

- Package CI job green; PSO-011 rebases onto this `session.ts`.

### Human/manual evidence

- With a real daemon and the aiur prompt that loads the `aiur-agent` skill, ask the Paseo-owned agent to call `emit_alert`; the alert appears in `aiur alerts`. PSO-012 records this as part of the end-to-end proof; this ticket's PR attaches a stdout transcript showing the `item/tool/call` request and the reply.

## Failure, security, migration, and accessibility cases

- The socket is `0600` in a `0700` directory; another local user cannot call aiur tools.
- Arguments from the agent are untrusted; the bridge forwards them verbatim and aiur's `ToolExecutor` validates.
- If the socket directory is not writable, `thread/start` fails with a JSON-RPC error `paseo_bridge_unavailable` so aiur's fallback engages (DEC-013).
- Process exit paths (`exit`, `SIGTERM`, `SIGINT`, uncaught exception) all unlink sockets; test at least `close` and `SIGTERM`.

## Surfaces

- Reads: `thread/start.dynamicTools`; aiur replies to `item/tool/call`.
- Writes: unix socket server; `create_agent_request.config.mcpServers`; `item/tool/call` requests.
- Contracts: aiur tool result envelope `{success, output, contentItems}`; MCP `2025-06-18` tools list and call.

## Sibling boundaries and open gates

PSO-009 owns turn and timeline mapping. PSO-011 owns re-attach and must re-create rather than re-attach when the stored agent's `mcpServers` socket is gone. PSO-012 proves `emit_alert` end to end.

## Plan context

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
