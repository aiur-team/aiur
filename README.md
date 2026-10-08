# aiur-claude

A **JSON-RPC 2.0 Claude Code App Server** conforming to the **OpenAI Codex app-server** protocol spec.

No API key required. Authentication is handled by the `claude` CLI (`claude auth`).

Clients communicate over **stdio** (default) or **WebSocket**, using newline-delimited JSON (NDJSON).

---

## Install

### npm

```bash
npm install -g aiur-claude
```

### From source

```bash
pnpm install
pnpm run build
```

---

## Requirements

- Node.js >= 18
- [Claude Code CLI](https://claude.ai/code) installed and authenticated (`claude auth`)

---

## Quick start

```bash
# Start with WebSocket + QR code (recommended)
aiur-claude start

# Custom port
aiur-claude start --port 4000

# Plain WebSocket (no TLS)
aiur-claude start --no-tls

# stdio mode (for piped/programmatic use)
aiur-claude
```

On startup you'll see:

```
  aiur-claude  ·  WebSocket (TLS)
  ─────────────────────────────────
  Local:    wss://localhost:3284?key=AbC123
  Network:  wss://192.168.x.x:3284
  Pair Key: AbC123

  ▄▄▄ ... QR code ...
  Scan to connect
```

A random 6-character **pair key** is generated each time the server starts. The key is embedded in the QR code URL. Clients connecting without a valid key are rejected (close code 4401).

Scan the QR code from any device on the same Wi-Fi to connect.

---

## Transports

| Command | Transport | Notes |
|---------|-----------|-------|
| `aiur-claude start` | WebSocket :3284 | Shows QR code, binds to all interfaces |
| `aiur-claude start --port N` | WebSocket :N | Custom port |
| `aiur-claude start --no-tls` | WebSocket :3284 | Plain `ws://` (no TLS) |
| `aiur-claude --transport ws` | WebSocket :3284 | No QR code |
| `aiur-claude` | stdio | For piped/programmatic use |

### `--no-tls`

By default, WebSocket mode uses a self-signed TLS certificate (`wss://`). Pass `--no-tls` to disable TLS and use plain `ws://` instead. This is useful for local development or when TLS is handled by a reverse proxy.

---

## Protocol overview

Messages are newline-delimited JSON, following [JSON-RPC 2.0](https://www.jsonrpc.org/specification). Both `snake_case` and `camelCase` parameter names are accepted for Codex protocol compatibility.

### Handshake

```jsonc
// Client → Server
{ "jsonrpc": "2.0", "method": "initialize", "params": {
    "client": { "name": "my-app", "version": "1.0.0" },
    "cwd": "/path/to/project"
  }, "id": 1 }

// Server → Client (response)
{ "jsonrpc": "2.0", "result": {
    "server": { "name": "aiur-claude", "version": "1.2.0" },
    "capabilities": { ... }
  }, "id": 1 }

// Server → Client (notification, async)
{ "jsonrpc": "2.0", "method": "initialized", "params": { "server": "aiur-claude" } }
```

---

## Methods

### Thread management

| Method | Params | Returns |
|--------|--------|---------|
| `thread/start` | `{ cwd?, permissionMode?, dynamicTools? }` | `{ thread: { id, created_at } }` |
| `thread/resume` | `{ threadId }` | `{ thread: { id, turns[], cwd, … } }` |
| `thread/fork` | `{ threadId }` | `{ thread: { id, forked_from, created_at } }` |

### Turn management

| Method | Params | Returns |
|--------|--------|---------|
| `turn/start` | `{ threadId, content, model? }` or `{ threadId, input: [{ type, text }] }` | `{ turn: { id } }` |
| `turn/steer` | `{ threadId, content }` | `{ turn_id }` |
| `turn/interrupt` | `{ threadId }` | `{ turn_id, status }` |

`turn/start` returns immediately; the agent streams back **notifications** until `turn/completed`.

### Discovery

| Method | Returns |
|--------|---------|
| `model/list` | List of available Claude models |
| `skills/list` | List of available tools (Read, Bash, …) |
| `app/list` | (stub, always empty) |

### Approval

| Method | Params | Description |
|--------|--------|-------------|
| `approval/respond` | `{ threadId, approved, permissionMode? }` | Respond to a permission prompt |

---

## Server notifications

After `turn/start`, the server streams these notifications:

| Notification | When |
|-------------|------|
| `turn/started` | Turn began |
| `item/progress` | Streaming text delta — `{ turn_id, delta: { type, text } }` |
| `item/created` | Item finalized (text, tool_call, tool_result) |
| `usage/update` | Token usage update — `{ turn_id, usage: { input_tokens, output_tokens, total_tokens } }` |
| `rate_limit/update` | Sanitized rate-limit standing — `{ turn_id, thread_id, rate_limit: { status, used_percent?, resets_at?, account_type, source_version } }`. `used_percent` is percent of quota **used** (0–100), not remaining. Identifying data (org/account ids, emails, tokens, session ids, headers) is never forwarded. |
| `turn/completed` | Turn finished — `{ turn_id, status, items_count, usage?, cost_usd?, cost_usd_raw?, cost_source_version? }`. `cost_usd_raw` is the exact decimal as serialized by the CLI, captured before float conversion; `cost_usd` stays float for backward compatibility. |
| `turn/failed` | Turn failed — `{ turn_id, error, provider_error? }`. `provider_error` (`{ error, api_error_status?, message? }`) is present only when the claude CLI itself reported an API error (e.g. `rate_limit` / 429 for the session-limit banner); text items it synthesized carry `provider_error: <class>` too. |
| `turn/permission_denied` | Permission denied — `{ turn_id, denials }` |

---

## Dynamic tools

Orchestrators can declare client-side tools on `thread/start`; the server surfaces them to the claude subprocess and round-trips invocations back over the same transport:

```jsonc
// Client → Server
{ "jsonrpc": "2.0", "method": "thread/start", "params": {
    "cwd": "/path/to/project",
    "permissionMode": "bypassPermissions",
    "dynamicTools": [
      { "name": "emit_alert",
        "description": "Emit a milestone alert.",
        "inputSchema": { "type": "object", "required": ["name", "message"], "properties": { /* … */ } } }
    ]
  }, "id": 2 }
```

Each spec (`name`, `description`, JSON-schema `inputSchema`) is served to claude through an in-process MCP server: a unix-domain socket hosted by the app server, reached via a tiny stdio relay (`dist/mcp-shim.js`) wired with `--mcp-config`. Claude sees the tool as `mcp__aiur__<name>` and each name is allowlisted via `--allowedTools` so calls run headless under every permission mode.

When claude invokes a tool, the server sends a JSON-RPC **request** to the client and waits for the response (2-minute timeout):

```jsonc
// Server → Client (request)
{ "jsonrpc": "2.0", "id": "aiur-tool-1", "method": "item/tool/call",
  "params": { "name": "emit_alert", "arguments": { /* … */ }, "callId": "…" } }

// Client → Server (response)
{ "jsonrpc": "2.0", "id": "aiur-tool-1",
  "result": { "success": true, "output": "…", "contentItems": [{ "type": "inputText", "text": "…" }] } }
```

`output` (or `contentItems[0].text`) is returned to claude as the MCP tool result; `success: false`, error responses, and timeouts surface to claude as structured tool errors (`isError: true`). Threads started without `dynamicTools` behave exactly as before.

---

## Permission modes

| Mode | Behaviour |
|------|-----------|
| `default` | Prompts for bash and file writes |
| `acceptEdits` | Auto-approves file writes; prompts for bash |
| `bypassPermissions` | Approves all tools automatically |

---

## Example session (stdio)

```bash
aiur-claude
```

```jsonc
// Initialize
{"jsonrpc":"2.0","method":"initialize","params":{"client":{"name":"demo","version":"1.0"},"cwd":"/tmp/my-project"},"id":1}

// Start a thread
{"jsonrpc":"2.0","method":"thread/start","params":{"cwd":"/tmp/my-project","permissionMode":"acceptEdits"},"id":2}

// Start a turn
{"jsonrpc":"2.0","method":"turn/start","params":{"threadId":"<id>","content":"List the files in this project."},"id":3}
```

---

## Architecture

```
src/
  index.ts          CLI entry — parses subcommand / flags, shows QR code
  protocol.ts       JSON-RPC 2.0 types and helpers
  types.ts          Domain types: Thread → Turn → Item
  transport.ts      stdio and WebSocket transports
  tools.ts          Built-in skills catalog
  dynamic-tools.ts  MCP bridge for orchestrator-declared tools
  mcp-shim.ts       stdio↔unix-socket relay spawned by claude
  server.ts         ClaudeAppServer — method handlers + claude CLI runner
```

Each turn spawns:
```
claude --print --output-format stream-json --include-partial-messages
       --permission-mode <mode>
       --mcp-config <json> --allowedTools <names>   # threads with dynamicTools
       --session-id <id>    # first turn of a thread
       --resume <id>        # subsequent turns
```

---

## Models

Default model can be overridden per turn:

```json
{ "method": "turn/start", "params": { "threadId": "…", "content": "…", "model": "claude-haiku-4-5" } }
```

Available: `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5`

---

## Related

- [Symphony (fork)](https://github.com/sapsaldog/symphony) — Modified Symphony client for Claude Code integration
- [Symphony (original)](https://github.com/openai/symphony) — OpenAI's original Symphony
