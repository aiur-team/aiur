# Paseo daemon spike: driving Claude Code and Codex agents from an external orchestrator

Date: 2026-09-09. Paseo source clone HEAD `726067b43759c5c489ab865eee0fe05e8334ea77`.
Scratch dir: `<spike>` = `<spike>`.
Raw request/response captures are in `<spike>/*.json`; daemon log in `<spike>/daemon.log` and `<spike>/paseo-home/daemon.log`.

## Summary for the aiur orchestrator (what matters)

1. **Transport**: `POST http://127.0.0.1:6768/mcp/agents` with `Authorization: Bearer <daemon password>`, `Content-Type: application/json`, `Accept: application/json, text/event-stream`. The server is **stateless** (`sessionIdGenerator: undefined` in `bootstrap.ts`): every POST builds a fresh MCP server + transport; there is no `mcp-session-id`; `initialize` is optional; GET/DELETE return 405. Responses come back as a single SSE frame (`event: message\ndata: {...}`) with `content-type: text/event-stream` and a `content-length`, so a plain HTTP client that strips `data: ` works. `tools/call` results carry both `content[0].text` and a `structuredContent` object; parse `structuredContent`.
2. **Directory binding**: the MCP `create_agent` tool has **no `cwd` and no `mcpServers` field**. The cwd comes from a `workspaceId`; make one with `create_workspace {isolation:"local", path:<repo>}` (returns `workspaceId`, `projectId`, `cwd`). Top-level `create_agent` without `workspaceId` creates a new local workspace (path unspecified: the daemon's cwd). The WebSocket `create_agent_request` (`packages/protocol/src/messages.ts`) does carry `config.cwd`, `config.mcpServers`, `config.systemPrompt`, `config.toolPolicy`, `env`, `idempotencyKey`. See section 7 for the delta.
3. **Permission mode** field: `settings.modeId` on `create_agent`; `sessionMode` on `send_agent_prompt`; `modeId` on `set_agent_mode`. Claude ids: `plan`, `default`, `acceptEdits`, `auto`, `bypassPermissions`. Codex ids: `auto`, `auto-review`, `full-access`.
4. **Status vocabulary** (`list_agents.statuses` enum): `initializing | idle | running | error | closed`. Completion is signaled by `status: "idle"` plus `snapshot.requiresAttention: true, attentionReason: "finished"`. There is no `finished` status. A blocked permission shows `status: "running"` with `snapshot.pendingPermissions[]` non-empty and `activeTurn` set.
5. **Blocking vs background**: `create_agent`/`send_agent_prompt` with `background:false` (the top-level default) block until the turn finishes or a permission request appears, then return `{status, lastMessage, permission}`. With `background:true` they return in ~250 ms with `status:"idle", lastMessage:null` (note: it says `idle`, not `running`, at that instant) and you poll `get_agent_status`.
6. **Timings (haiku-4-5, load ~8)**: create + first turn 4.7 s (agent 1) and 2.7 s (agent 3); follow-up turn 1.3 s; codex `gpt-5.6-luna` create + turn 6.5 s; `respond_to_permission` 245 ms; `paseo import` 1.4 s.
7. **Same session across prompts**: `agentId` stays the same, `runtimeInfo.sessionId` stays the same (`6a776524-…`), and the Claude transcript is the native one at `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`. Paseo keeps **no transcript under PASEO_HOME**: `agent-timelines/` is explicitly deleted at boot as obsolete (`bootstrap.ts:575`), and the timeline store is `InMemoryAgentTimelineStore`. PASEO_HOME holds only `agents/<cwd-slug>/<agentId>.json` metadata records.
8. **Hooks**: workspace-local `.claude/settings.local.json` hooks fire. `CLAUDE_SETTING_SOURCES = ["user","project","local"]` (`providers/claude/agent.ts:145`) and Paseo appends its own hooks rather than replacing (`providers/claude/hooks.ts`).
9. **Two owners**: a second Claude agent in the same workspace/cwd while the first is idle is accepted; no refusal.
10. **Versions**: CLI/daemon 0.7.2; `/api/status` (auth required) returns `version: "0.7.2"`; `/api/health` has no version; WebSocket `WS_PROTOCOL_VERSION = 1` (`websocket-server.ts:500`); MCP server reports `serverInfo {name:"agent-mcp", version:"2.0.0"}` and `protocolVersion "2025-03-26"`; relay protocol `"2"`.
11. **Deep link**: `/h/<serverId>/agent/<agentId>` (web route) or `paseo://h/<serverId>/agent/<agentId>` (desktop). `serverId` = contents of `PASEO_HOME/server-id` (`srv_xySFiO0r9AuK` here) or `/api/status.serverId`. `daemon-keypair.json` holds only `{v, publicKeyB64, secretKeyB64}`, not the server id.
12. **Import**: `paseo import <claude-session-id> --provider claude --cwd <repo> [--label k=v] --host 127.0.0.1:6768` with `PASEO_PASSWORD=<pw>` in env. Refuses sessions that Paseo already owns (`AGENT_IMPORT_FAILED`).

Gotchas found: `paseo daemon set-password` is an interactive clack prompt that does not accept piped stdin (I wrote a bcrypt hash into `config.json` directly instead); the daemon auto-downloads ~2 local speech models into `PASEO_HOME/models/local-speech` on first boot; the daemon also probes an OpenCode server and logs warnings if the installed `opencode` is old; `paseo daemon status` reports `daemonVersion: null` and `connectedDaemon: "auth_required"` when a password is set and `PASEO_PASSWORD` is unset; CLI subcommands take `--host` and read `PASEO_PASSWORD`, `daemon` subcommands take `--home` only.

---

## Step 1. Install and start

```
npm install -g @getpaseo/cli        # installed 0.7.2 (npm warned: esbuild / node-pty postinstall scripts blocked by allow-scripts; daemon still ran)
paseo --version                     # 0.7.2
node --version                      # v24.18.0 (mise lts)
```

Environment for every command:
```
export PASEO_HOME=<spike>/paseo-home
export PASEO_LISTEN=127.0.0.1:6768
```

`paseo daemon set-password --home $PASEO_HOME` **failed** for non-interactive use: it renders a clack prompt and `printf 'spike-pass\nspike-pass\n' |` gives:
```
Warning: Detected unsettled top-level await at .../@getpaseo/cli/dist/index.js:2
const exitCode = await runCli(process.argv.slice(2), {
```
and writes nothing. Workaround (equivalent to what the command writes; `persisted-config.ts` `DaemonAuthSchema` requires a bcrypt hash matching `/^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$/`, cost 12 per `auth.ts DAEMON_PASSWORD_BCRYPT_COST`):
```
HASH=$(NODE_PATH=$(npm root -g)/@getpaseo/cli/node_modules node -e 'console.log(require("bcryptjs").hashSync("spike-pass",12))')
cat > $PASEO_HOME/config.json <<JSON
{ "daemon": { "listen": "127.0.0.1:6768", "auth": { "password": "$HASH" }, "relay": { "enabled": false } } }
JSON
```
Start (foreground, backgrounded with a log):
```
nohup paseo daemon start --foreground --no-relay --home $PASEO_HOME --listen 127.0.0.1:6768 > <spike>/daemon.log 2>&1 &
curl -s http://127.0.0.1:6768/api/health
{"status":"ok","timestamp":"2026-09-09T21:19:02.069Z"}
```
Daemon log confirms: `Server listening on http://127.0.0.1:6768`, `authRequired: true`, `Daemon password authentication enabled`, `Agent MCP route mounted {route:"/mcp/agents", enabled:true}`, `WebSocket server initialized on /ws`. It also started `Starting model download` for `parakeet-tdt-0.6b-v2-int8` and `kokoro-en-v0_19` (unrequested; ~30 s of downloads into `PASEO_HOME/models/local-speech`).

`paseo daemon status --home $PASEO_HOME --json` (while running):
```json
{
  "serverId": "srv_xySFiO0r9AuK",
  "localDaemon": "running",
  "connectedDaemon": "auth_required",
  "home": "<spike>/paseo-home",
  "listen": "127.0.0.1:6768",
  "relay": "disabled",
  "hostname": "orangekid",
  "pid": 3455448,
  "startedAt": "2026-09-09T21:18:55.031Z",
  "owner": "1000@orangekid",
  "logPath": "<spike>/paseo-home/daemon.log",
  "cliVersion": "0.7.2",
  "daemonVersion": null,
  "desktopManaged": false,
  "providers": [
    {"label": "Claude", "path": "~/.local/bin/claude", "version": "2.1.267 (Claude Code)"},
    {"label": "Codex", "path": ".../mise/installs/node/lts/bin/codex", "version": "codex-cli 0.153.4"},
    {"label": "OpenCode", ...}
  ]
}
```

## Step 2. MCP endpoint and tool schemas

Source: `packages/server/src/server/bootstrap.ts:1439-1520` (route `/mcp/agents`), `packages/server/src/server/agent/tools/paseo-tools.ts` (tool definitions), `packages/server/src/server/agent/mcp-server.ts`.

Key verbatim facts from `bootstrap.ts`:
```ts
// Stateless mode: each HTTP request builds a fresh server + transport that is
// torn down when the response closes, so no per-session state is retained between
// requests. ...
const transport = new StreamableHTTPServerTransport({
  sessionIdGenerator: undefined,
  enableDnsRebindingProtection: false,
});
...
// This route is exempt from the global daemon-password middleware, so it
// authenticates here using the injected capability token (or a valid
// daemon password).
if (!(await isAgentMcpRequestAuthorized({ password: config.auth?.password, capabilityToken: agentMcpAuthToken, authorizationHeader: req.header("authorization") }))) {
  res.status(401).json({ error: "Unauthorized" }); return;
}
// Stateless: GET (standalone SSE) and DELETE (session termination) have no
// meaning without sessions. ... if (req.method !== "POST") { res.status(405)... }
const callerAgentIdRaw = req.query.callerAgentId;   // ?callerAgentId=<id> scopes the call to an agent (subagent semantics)
```
Note `?callerAgentId=` changes defaults: agent-scoped callers default `background:true` and create subagents in the caller's workspace. **Omit it** for an external orchestrator. Also `agentMcpAuthToken = randomUUID()` per daemon run is injected into each agent as an MCP server named `paseo` (`runtime-mcp-config.ts`: `{type:"http", url: "<base>/mcp/agents?callerAgentId=<agentId>", headers:{Authorization:"Bearer <token>"}}`) unless `--no-inject-mcp`.

Without auth:
```
curl -s -X POST http://127.0.0.1:6768/mcp/agents -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
{"error":"Unauthorized"}
```

### initialize
```
curl -s -i -X POST http://127.0.0.1:6768/mcp/agents \
  -H 'Authorization: Bearer spike-pass' -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"aiur-spike","version":"0.0.1"}}}'

HTTP/1.1 200 OK
cache-control: no-cache
content-type: text/event-stream
content-length: 187

event: message
data: {"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"agent-mcp","version":"2.0.0"}},"jsonrpc":"2.0","id":1}
```
No `mcp-session-id` header is returned.

### tools/list
```
curl -s -X POST http://127.0.0.1:6768/mcp/agents -H 'Authorization: Bearer spike-pass' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```
39 tools: `create_workspace, list_workspaces, archive_workspace, create_agent, send_agent_prompt, get_agent_status, list_agents, cancel_agent, archive_agent, kill_agent, update_agent, rename_workspace, list_workspace_scripts, start_workspace_script, stop_workspace_script, list_terminals, create_terminal, kill_terminal, capture_terminal, send_terminal_keys, create_schedule, create_heartbeat, delete_heartbeat, list_schedules, inspect_schedule, pause_schedule, resume_schedule, delete_schedule, update_schedule, schedule_logs, run_schedule_once, list_providers, list_models, list_profiles, inspect_provider, get_agent_activity, set_agent_mode, list_pending_permissions, respond_to_permission`. Full response saved at `<spike>/tools-list.json`; the 12 relevant ones at `<spike>/tools-subset.json`.

#### create_agent
Description: "Create an agent. Agent-scoped creation defaults to your workspace and creates your subagent. Top-level creation without workspaceId creates a new local workspace. Requires provider/model (for example codex/gpt-5.4) and an initial prompt. Do not guess; call list_providers and list_models first if uncertain."
```json
{
  "type": "object",
  "properties": {
    "title": {"type": "string", "minLength": 1, "maxLength": 60, "description": "Short descriptive title (<= 60 chars) summarizing the agent's focus."},
    "provider": {"type": "string", "description": "Required provider/model pair, for example codex/gpt-5.4."},
    "labels": {"description": "Labels to set on the agent", "type": "object", "propertyNames": {"type": "string"}, "additionalProperties": {"type": "string"}},
    "settings": {
      "description": "Initial runtime settings for the new agent.",
      "type": "object",
      "properties": {
        "modeId": {"description": "Session mode to configure before the first run.", "type": "string"},
        "thinkingOptionId": {"description": "Thinking option ID.", "type": "string"},
        "features": {"description": "Provider-specific feature values, for example { fast_mode: true } for Codex.", "type": "object", "propertyNames": {"type": "string"}, "additionalProperties": {}}
      },
      "additionalProperties": false
    },
    "initialPrompt": {"type": "string", "minLength": 1, "description": "Required first task to run immediately after creation."},
    "workspaceId": {"description": "Existing workspace id. Agent-scoped calls default to the caller workspace; top-level calls create a new local workspace when omitted.", "type": "string", "minLength": 1},
    "background": {"default": false, "description": "Run agent in background. If false (default), waits for completion or permission request. If true, returns immediately.", "type": "boolean"},
    "notifyOnFinish": {"default": false, "description": "Agent-scoped only: get notified when the created agent finishes, errors, or needs permission.", "type": "boolean"}
  },
  "required": ["title", "provider", "initialPrompt"],
  "additionalProperties": {}
}
```
**No `cwd`, no `mcpServers`, no `model` (model rides in `provider` as `claude/claude-haiku-4-5`), no `systemPrompt`, no `env`.**

#### send_agent_prompt
Description: "Send a task to a running agent. Agent-scoped callers run in background by default; top-level callers wait by default."
```json
{"type":"object","properties":{
  "agentId":{"type":"string"},
  "prompt":{"type":"string"},
  "sessionMode":{"description":"Optional mode to set before running the prompt.","type":"string"},
  "background":{"default":false,"description":"Run agent in background. If false (default), waits for completion or permission request. If true, returns immediately.","type":"boolean"},
  "notifyOnFinish":{"default":false,"description":"Agent-scoped only: ...","type":"boolean"}},
 "required":["agentId","prompt"]}
```

#### get_agent_status
"Return the latest snapshot for an agent, including lifecycle state, capabilities, and pending permissions."
```json
{"type":"object","properties":{"agentId":{"type":"string"}},"required":["agentId"]}
```

#### get_agent_activity
"Return recent agent timeline entries as a curated summary."
```json
{"type":"object","properties":{"agentId":{"type":"string"},"limit":{"description":"Optional limit for number of activities to include (most recent first).","type":"number"}},"required":["agentId"]}
```

#### list_agents
"List recent agents as compact metadata."
```json
{"type":"object","properties":{
  "includeArchived":{"default":false,"type":"boolean"},
  "cwd":{"type":"string"},
  "sinceHours":{"default":48,"type":"integer","exclusiveMinimum":0,"maximum":720},
  "statuses":{"type":"array","items":{"type":"string","enum":["initializing","idle","running","error","closed"]}},
  "limit":{"default":50,"type":"integer","exclusiveMinimum":0,"maximum":200}}}
```

#### list_pending_permissions
"Return all pending permission requests across all agents with the normalized payloads."
```json
{"type":"object","properties":{}}
```

#### respond_to_permission
"Approve or deny a pending permission request with an AgentManager-compatible response payload."
```json
{"type":"object","properties":{
  "agentId":{"type":"string"},
  "requestId":{"type":"string"},
  "response":{"oneOf":[
    {"type":"object","properties":{"behavior":{"type":"string","const":"allow"},"selectedActionId":{"type":"string"},"updatedInput":{"type":"object","propertyNames":{"type":"string"},"additionalProperties":{}},"updatedPermissions":{"type":"array","items":{"type":"object","propertyNames":{"type":"string"},"additionalProperties":{}}}},"required":["behavior"]},
    {"type":"object","properties":{"behavior":{"type":"string","const":"deny"},"selectedActionId":{"type":"string"},"message":{"type":"string"},"interrupt":{"type":"boolean"}},"required":["behavior"]}]}},
 "required":["agentId","requestId","response"]}
```

#### set_agent_mode
"Switch the agent's session mode (plan, bypassPermissions, read-only, auto, etc.)."
```json
{"type":"object","properties":{"agentId":{"type":"string"},"modeId":{"type":"string"}},"required":["agentId","modeId"]}
```

#### kill_agent — "Terminate an agent session permanently."
#### archive_agent — "Archive an agent (soft-delete). The agent is interrupted if running and removed from the active list."
#### cancel_agent — "Abort the agent's current run but keep the agent alive for future tasks."
All three:
```json
{"type":"object","properties":{"agentId":{"type":"string"}},"required":["agentId"]}
```

#### create_workspace (needed to bind a cwd)
"Create a workspace using an existing local checkout or a new Paseo-managed worktree."
```json
{"type":"object","properties":{
  "isolation":{"type":"string","enum":["local","worktree"]},
  "path":{"description":"Local directory or source checkout. Defaults to your current workspace.","type":"string"},
  "projectId":{"description":"Existing project id to own the workspace.","type":"string"},
  "title":{"type":"string","minLength":1},
  "mode":{"description":"Worktree creation mode. Defaults to branch-off.","type":"string","enum":["branch-off","checkout-branch","checkout-pr"]},
  "worktreeSlug":{"type":"string","minLength":1},
  "branchName":{"description":"New branch name for branch-off mode.","type":"string","minLength":1},
  "baseBranch":{"description":"Base ref for branch-off mode.","type":"string","minLength":1},
  "branch":{"description":"Existing branch for checkout-branch mode.","type":"string","minLength":1},
  "prNumber":{"description":"Pull request or change request number for checkout-pr mode.","type":"integer","exclusiveMinimum":0,"maximum":9007199254740991},
  "forge":{"description":"Forge for checkout-pr mode. Defaults to the source checkout.","type":"string","minLength":1}},
 "required":["isolation"]}
```

#### update_agent (labels/settings after creation)
```json
{"type":"object","properties":{"agentId":{"type":"string"},"name":{"type":"string"},"labels":{...same as create...},
 "settings":{"type":"object","properties":{"modeId":{"type":"string"},"model":{"type":["string","null"]},"thinkingOptionId":{"type":["string","null"]},"features":{"type":"object",...}},"additionalProperties":false}},
 "required":["agentId"]}
```

### list_providers / list_models
```
curl ... -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_providers","arguments":{}}}'
```
`structuredContent.providers[]`: `claude` (status `available`, modes `plan`, `default` "Always Ask", `acceptEdits`, `auto` "Uses a model classifier", `bypassPermissions`), `codex` (`available`, modes `auto` "Default Permissions", `auto-review`, `full-access`), `copilot`, `opencode`, `pi` (available), `omp` (unavailable).

```
curl ... -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_models","arguments":{"provider":"claude"}}}'
```
`models_ids=claude-opus-5,claude-fable-5-1,claude-fable-5,claude-opus-4-8[1m],claude-opus-4-8,claude-sonnet-5,claude-sonnet-5[1m],claude-opus-4-7[1m],claude-opus-4-7,claude-opus-4-6[1m],claude-opus-4-6,claude-sonnet-4-6[1m],claude-sonnet-4-6,claude-haiku-4-5,claude-fable-5-1[1m]`. Each model entry: `{provider,id,label,description,isDefault?,contextWindowMaxTokens,thinkingOptions:[{id,label,isDefault?}],defaultThinkingOptionId}`. Cheapest used: `claude-haiku-4-5` (no thinkingOptions).

CLI equivalent (needs `PASEO_PASSWORD`; `--password` is not an option):
```
PASEO_PASSWORD=spike-pass paseo provider models claude --host 127.0.0.1:6768 --json
PASEO_PASSWORD=spike-pass paseo provider models codex  --host 127.0.0.1:6768 --json
```
Codex models: `gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna` ("Fast and affordable agentic coding model."), `gpt-5.5`, ... Cheapest used: `gpt-5.6-luna`.

## Step 3. Create a Claude agent, poll, verify

Scratch repo: `git -C <spike>/repo init; README.md; commit a9658a5 "init"` (branch `master`).

### create_workspace
```
curl ... -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"create_workspace","arguments":{"isolation":"local","path":"<spike>/repo","title":"spike-repo"}}}'
```
```json
{"result":{"content":[{"type":"text","text":"{...}"}],"structuredContent":{
  "workspaceId":"wks_a16090c9430e4113","projectId":"prj_75a5636bdd9f6a19",
  "cwd":"<spike>/repo","isolation":"local","kind":"local_checkout","title":"spike-repo"}},"jsonrpc":"2.0","id":5}
```
Persisted to `PASEO_HOME/projects/workspaces.json` and `projects.json` (`projectKey: "host:srv_xySFiO0r9AuK:<path>"`).

### create_agent (blocking)
```
curl ... -d '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"create_agent","arguments":{
  "title":"spike hello","provider":"claude/claude-haiku-4-5","workspaceId":"wks_a16090c9430e4113",
  "labels":{"ticket":"123"},"settings":{"modeId":"bypassPermissions"},
  "initialPrompt":"Create a file hello.txt containing 'hi' and reply DONE","background":false}}}'
```
Response `structuredContent`:
```json
{
  "agentId": "6fd700c6-e4b1-47c7-ba64-e6dad7ba12c9",
  "type": "claude",
  "status": "idle",
  "cwd": "<spike>/repo",
  "workspaceId": "wks_a16090c9430e4113",
  "currentModeId": "bypassPermissions",
  "availableModes": [
    {"id":"plan","label":"Plan Mode","description":"Analyze the codebase without executing tools or edits"},
    {"id":"default","label":"Always Ask","description":"Prompts for permission the first time a tool is used"},
    {"id":"acceptEdits","label":"Accept File Edits","description":"Automatically approves edit-focused tools without prompting"},
    {"id":"auto","label":"Auto mode","description":"Uses a model classifier to review permission prompts automatically"},
    {"id":"bypassPermissions","label":"Bypass","description":"Skip all permission prompts (use with caution)"}
  ],
  "lastMessage": "DONE",
  "permission": null
}
```
The `content[0].text` also carries a preamble line `availableModes_count=5\navailableModes_ids=plan,default,acceptEdits,auto,bypassPermissions` before the JSON; always use `structuredContent`.

Verification: `<spike>/repo/hello.txt` exists, contents `hi`.
Timing: `createdAt 2026-09-09T21:20:36.114Z` → `updatedAt 21:20:40.863Z` = **4.75 s** create+turn (the daemon spawns the Claude Agent SDK process, runs the turn).

### get_agent_status
```
curl ... -d '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_agent_status","arguments":{"agentId":"6fd700c6-e4b1-47c7-ba64-e6dad7ba12c9"}}}'
```
```json
{
 "status": "idle",
 "snapshot": {
  "id": "6fd700c6-e4b1-47c7-ba64-e6dad7ba12c9",
  "provider": "claude",
  "cwd": "<spike>/repo",
  "workspaceId": "wks_a16090c9430e4113",
  "model": "claude-haiku-4-5",
  "thinkingOptionId": null,
  "effectiveThinkingOptionId": null,
  "runtimeInfo": {"provider":"claude","sessionId":"6a776524-24a6-4c85-9255-7327d17935de","model":"claude-haiku-4-5","modeId":"bypassPermissions","extra":{"runtimeModel":"claude-haiku-4-5"}},
  "createdAt": "2026-09-09T21:20:36.114Z",
  "updatedAt": "2026-09-09T21:20:40.863Z",
  "lastUserMessageAt": "2026-09-09T21:20:36.199Z",
  "status": "idle",
  "activeTurn": null,
  "capabilities": {"supportsStreaming":true,"supportsSessionPersistence":true,"supportsSessionListing":true,"supportsDynamicModes":true,"supportsMcpServers":true,"supportsReasoningStream":true,"supportsToolInvocations":true,"supportsRewindConversation":true,"supportsRewindFiles":true,"supportsRewindBoth":true},
  "currentModeId": "bypassPermissions",
  "availableModes": [ ...5 modes as above... ],
  "features": [],
  "pendingPermissions": [],
  "persistence": {"provider":"claude","sessionId":"6a776524-24a6-4c85-9255-7327d17935de","nativeHandle":"6a776524-24a6-4c85-9255-7327d17935de","metadata":{"provider":"claude","cwd":"<spike>/repo","modeId":"bypassPermissions","model":"claude-haiku-4-5","title":"spike hello"}},
  "title": "spike hello",
  "labels": {"ticket": "123"},
  "lastUsage": {"inputTokens":18,"cachedInputTokens":37122,"outputTokens":207,"totalCostUsd":0.0220992,"contextWindowMaxTokens":200000,"contextWindowUsedTokens":22843},
  "requiresAttention": true,
  "attentionReason": "finished",
  "attentionTimestamp": "2026-09-09T21:20:40.862Z"
 }
}
```

### get_agent_activity
```
curl ... -d '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_agent_activity","arguments":{"agentId":"6fd700c6-...","limit":10}}}'
```
```json
{"structuredContent":{
  "agentId":"6fd700c6-e4b1-47c7-ba64-e6dad7ba12c9",
  "updateCount":6,
  "currentModeId":"bypassPermissions",
  "content":"Showing all 3 activities\n\n[User] Create a file hello.txt containing 'hi' and reply DONE\n[Write] <spike>/repo/hello.txt\nDONE"}}
```
Activity is a **curated text summary**, not a structured timeline (lines like `[User] …`, `[Write] path`, `[Shell] cmd`, `[Edit] file`, and assistant text). Full timeline events are only on the WebSocket stream.

### list_agents
```
curl ... -d '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"list_agents","arguments":{}}}'
```
```json
{"structuredContent":{"agents":[{
  "id":"6fd700c6-e4b1-47c7-ba64-e6dad7ba12c9","shortId":"6fd700c","title":"spike hello","provider":"claude","model":"claude-haiku-4-5",
  "thinkingOptionId":null,"effectiveThinkingOptionId":null,"status":"idle","cwd":"<spike>/repo",
  "createdAt":"2026-09-09T21:20:36.114Z","updatedAt":"2026-09-09T21:20:40.863Z","lastUserMessageAt":"2026-09-09T21:20:36.199Z",
  "archivedAt":null,"requiresAttention":true,"attentionReason":"finished","attentionTimestamp":"2026-09-09T21:20:40.862Z",
  "labels":{"ticket":"123"}}]}}
```
`list_agents` has a `cwd` filter but **no label filter**; filter client-side on `labels`.

## Step 4. Follow-up prompts, same session, transcript location

### background:false
```
curl ... -d '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"send_agent_prompt","arguments":{"agentId":"6fd700c6-...","prompt":"What file did you create? Answer in one line.","background":false}}}'
```
```json
{"structuredContent":{"success":true,"status":"idle","lastMessage":"I created hello.txt containing 'hi'.","permission":null}}
```
elapsed **1342 ms** (wall, including the model turn). Same-session continuation confirmed (it remembered hello.txt).

### background:true
```
curl ... -d '{... "name":"send_agent_prompt","arguments":{"agentId":"6fd700c6-...","prompt":"Now reply with just the word PONG.","background":true}}}'
```
```json
{"structuredContent":{"success":true,"status":"idle","lastMessage":null,"permission":null}}
```
returned in **248 ms**; first `get_agent_status` poll 1 s later was already `idle`, `activeTurn: null`, `attentionReason: "finished"`, `updatedAt 21:21:31.007Z`. Activity afterwards:
```
Showing all 7 activities
[User] Create a file hello.txt containing 'hi' and reply DONE
[Write] <spike>/repo/hello.txt
DONE
[User] What file did you create? Answer in one line.
I created hello.txt containing 'hi'.
[User] Now reply with just the word PONG.
PONG
```
Agent id unchanged (`6fd700c6-…`); `runtimeInfo.sessionId` unchanged (`6a776524-24a6-4c85-9255-7327d17935de`).

### Storage under PASEO_HOME
```
PASEO_HOME/agents/<cwd-slug>/6fd700c6-e4b1-47c7-ba64-e6dad7ba12c9.json   # metadata record only (1.5 KB)
PASEO_HOME/projects/projects.json, workspaces.json
PASEO_HOME/config.json, daemon-keypair.json, server-id, paseo.pid, daemon.log, cli-client-id
PASEO_HOME/models/local-speech/..., opencode-home/, runtime/, schedules/
```
`<cwd-slug>` = `tmp-claude-1000--home-everdred-...-scratchpad-spike-repo`. The agent record:
```json
{"id":"6fd700c6-...","provider":"claude","cwd":"<spike>/repo","workspaceId":"wks_a16090c9430e4113",
 "createdAt":"...","updatedAt":"...","lastActivityAt":"...","lastUserMessageAt":"...","title":"spike hello",
 "labels":{"ticket":"123"},"lastStatus":"idle","lastModeId":"bypassPermissions",
 "config":{"modeId":"bypassPermissions","model":"claude-haiku-4-5"},
 "runtimeInfo":{...},"features":[],"persistence":{...sessionId/nativeHandle...},
 "requiresAttention":true,"attentionReason":"finished","attentionTimestamp":"...","internal":false}
```
**There is no `agent-timelines/` directory.** `bootstrap.ts:575`: `const obsoleteTimelineDirectory = path.join(config.paseoHome, "agent-timelines"); await rm(obsoleteTimelineDirectory, { recursive: true, force: true })`. Timelines live in `InMemoryAgentTimelineStore` (`agent-timeline-store.ts:138`) and are rebuilt from the provider's native session on resume. The durable transcript is Claude's own:
`~/.claude/projects/-tmp-claude-1000--home-everdred-...-scratchpad-spike-repo/6a776524-24a6-4c85-9255-7327d17935de.jsonl` (43 lines; first user line shows `"permissionMode"` recorded).

## Step 5. Permission flow (mode `default`)

```
curl ... -d '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"create_agent","arguments":{"title":"spike perms","provider":"claude/claude-haiku-4-5","workspaceId":"wks_a16090c9430e4113","labels":{"ticket":"124"},"settings":{"modeId":"default"},"initialPrompt":"Run the shell command `ls -la` using the Bash tool and then reply with the number of entries.","background":true}}}'
```
```json
{"agentId":"db2b1ca0-be8d-458a-a6a8-85f3526cc7ad","type":"claude","status":"running","cwd":"<spike>/repo","workspaceId":"wks_a16090c9430e4113","currentModeId":"default","availableModes":[...],"lastMessage":null,"permission":null}
```
**Observation**: `ls -la` did **not** raise a permission request in `default` mode (Claude Code auto-allows it as a read-only command; `~/.claude/settings.json` here has no `permissions.allow` rules). The agent finished idle in <20 s with `[Shell] ls -la` in its activity. Empty pending list shape:
```json
{"result":{"content":[{"type":"text","text":"permissions_count=0\n\n{\n  \"permissions\": []\n}"}],"structuredContent":{"permissions":[]}},"jsonrpc":"2.0","id":30}
```
A `Write` does prompt:
```
curl ... -d '{... "name":"send_agent_prompt","arguments":{"agentId":"db2b1ca0-...","prompt":"Use the Write tool to create a new file perm.txt containing the word granted. Then reply WROTE.","background":true}}}'
```
Pending appeared on poll 3 (~3 s).
```
curl ... -d '{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{"name":"list_pending_permissions","arguments":{}}}'
```
```json
{"structuredContent":{"permissions":[{
  "agentId":"db2b1ca0-be8d-458a-a6a8-85f3526cc7ad",
  "status":"running",
  "request":{
    "id":"permission-888d2f2e-afdf-4397-975b-c9c5bb124a85",
    "provider":"claude",
    "name":"Write",
    "kind":"tool",
    "input":{"file_path":"<spike>/repo/perm.txt","content":"granted"},
    "detail":{"type":"write","filePath":"<spike>/repo/perm.txt","content":"granted"},
    "suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],
    "metadata":{"toolUseId":"toolu_012AFmtEQenrLkE2Fac2Q5ct"}}}]}}
```
`get_agent_status` while blocked: `status: "running"`, `snapshot.activeTurn: {"turnId":"foreground-turn-2","startedAt":"2026-09-09T21:23:02.684Z"}`, `snapshot.pendingPermissions: [ {same request object, plus "actions": null} ]`, `requiresAttention: true` (attentionReason still `finished` from the previous turn, so key off `pendingPermissions`, not `attentionReason`).

Permission request schema (`messages.ts AgentPermissionRequestPayloadSchema`): `{id, provider, name, kind: "tool"|"plan"|"question"|"mode"|"other", title?, description?, input?, detail?, suggestions?, actions?: [{id,label,behavior:"allow"|"deny",variant?,intent?}], metadata?}`.

```
curl ... -d '{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"respond_to_permission","arguments":{"agentId":"db2b1ca0-be8d-458a-a6a8-85f3526cc7ad","requestId":"permission-888d2f2e-afdf-4397-975b-c9c5bb124a85","response":{"behavior":"allow"}}}}'
{"result":{"content":[{"type":"text","text":"{\n  \"success\": true\n}"}],"structuredContent":{"success":true}},"jsonrpc":"2.0","id":40}
```
245 ms; 1 s later status `idle`, `pendingPermissions` empty; `<spike>/repo/perm.txt` = `granted`; activity ends `[Write] .../perm.txt` / `WROTE`.

Lifecycle tool shapes (same agents):
```
cancel_agent  (idle agent)  -> {"structuredContent":{"success":false}}          # nothing to cancel
set_agent_mode acceptEdits  -> {"structuredContent":{"success":true,"newMode":"acceptEdits"}}
archive_agent               -> {"structuredContent":{"success":true}}           # list_agents: status "closed", archivedAt "2026-09-09T21:29:21.238Z"
kill_agent                  -> {"structuredContent":{"success":true}}           # get_agent_status: "status":"closed", snapshot retained, archivedAt null
```
Daemon log on kill/archive: `Claude query operation did not settle cleanly ... "ProcessTransport is not ready for writing"` (level 40) for both agents; harmless but noisy.

## Step 6. Hooks (workspace-local settings)

`<spike>/repo/.claude/settings.local.json`:
```json
{
  "hooks": {
    "Stop": [{"hooks":[{"type":"command","command":"curl -s -m 2 -X POST http://127.0.0.1:9/hook -o /dev/null; echo \"stop $(date -Is)\" >> <spike>/hook.log; exit 0"}]}],
    "UserPromptSubmit": [{"hooks":[{"type":"command","command":"echo \"prompt $(date -Is)\" >> <spike>/hook.log; exit 0"}]}]
  }
}
```
```
curl ... -d '{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"create_agent","arguments":{"title":"spike hooks","provider":"claude/claude-haiku-4-5","workspaceId":"wks_a16090c9430e4113","labels":{"ticket":"125"},"settings":{"modeId":"bypassPermissions"},"initialPrompt":"Reply with just the word HOOKED.","background":false}}}'
-> {"agentId":"9cf172b9-34d2-4594-ad4f-b92f88d02a70","status":"idle","lastMessage":"HOOKED.","currentModeId":"bypassPermissions"}   elapsed 2679 ms
```
`<spike>/hook.log` after (was empty before):
```
prompt 2026-09-09T14:30:16-07:00
stop 2026-09-09T14:30:18-07:00
```
Both hooks fired, the dead-port curl did not block the turn. Source confirmation: `providers/claude/agent.ts:145`:
```ts
const CLAUDE_SETTING_SOURCES: NonNullable<ClaudeOptions["settingSources"]> = ["user", "project", "local"];
```
passed at `agent.ts:3296 settingSources: CLAUDE_SETTING_SOURCES`; and `providers/claude/hooks.ts mergeClaudeHooks(own, extra)` appends user hooks per event to Paseo's own observation hooks ("Neither side wins").

(Aside for the orchestrator's own shell: my first attempt at this step hung for >5 min because a mid-script `cd /tmp` in a backgrounded zsh never returned; the request never reached the daemon. Not a Paseo issue.)

## Step 7. MCP server injection: MCP tool vs WebSocket delta

The MCP `create_agent` tool has **no `mcpServers` field** (schema above). `paseo agent run` CLI also has no MCP flag (it has `--cwd`, `--env`, `--label`, `--mode`, `--model`, `--thinking`, `--workspace`, `--new-workspace`, `--output-schema`, `--wait-timeout`). So the stdio-MCP experiment could not be run through the MCP tool; **not tested**.

WebSocket `create_agent_request` (`packages/protocol/src/messages.ts` ~L1682):
```ts
export const CreateAgentRequestMessageSchema = z.object({
  type: z.literal("create_agent_request"),
  idempotencyKey: z.string().min(1).max(512).optional(),
  config: AgentSessionConfigSchema,
  env: z.record(z.string(), z.string()).optional(),
  workspaceId: z.string().optional(),
  callerAgentId: z.string().optional(),
  worktreeName: z.string().optional(),
  initialPrompt: z.string().optional(),
  clientMessageId: z.string().optional(),
  outputSchema: z.record(z.string(), z.unknown()).optional(),
  images: z.array(ImageAttachmentSchema).optional(),
  attachments: AgentAttachmentsSchema,
  git: GitSetupOptionsSchema.optional(),
  worktree: CreateAgentWorktreeTargetSchema.optional(),
  autoArchive: z.boolean().optional(),
  labels: z.record(z.string(), z.string()).default({}),
  requestId: z.string(),
});
const AgentSessionConfigSchema = z.object({
  provider: AgentProviderSchema,
  cwd: z.string(),
  modeId: z.string().optional(),
  model: z.string().optional(),
  thinkingOptionId: z.string().optional(),
  featureValues: z.record(z.string(), z.unknown()).optional(),
  title: z.string().trim().min(1).max(MAX_EXPLICIT_AGENT_TITLE_CHARS).optional().nullable(),
  providerOptions: ProviderOptionsSchema.optional(),      // z.record(z.string(), z.json())
  toolPolicy: ToolPolicySchema.optional(),                // { preapproved: [{kind:"mcp", server, tool}] }
  systemPrompt: z.string().optional(),
  mcpServers: z.record(z.string(), McpServerConfigSchema).optional(),
});
const McpStdioServerConfigSchema = z.object({ type: z.literal("stdio"), command: z.string(), args: z.array(z.string()).optional(), env: z.record(z.string(), z.string()).optional(), alwaysLoad: z.boolean().optional() });
const McpHttpServerConfigSchema  = z.object({ type: z.literal("http"), url: z.string(), headers: z.record(z.string(), z.string()).optional(), alwaysLoad: z.boolean().optional() });
const McpSseServerConfigSchema   = z.object({ type: z.literal("sse"),  url: z.string(), headers: ..., alwaysLoad: ... });
```
**Delta (WS has, MCP tool lacks)**: `config.cwd` (MCP: only via `workspaceId`), `config.model` as a separate field (MCP: `provider` string `"claude/<model>"`), `config.mcpServers`, `config.systemPrompt`, `config.toolPolicy` (pre-approved MCP tools), `config.providerOptions`, `env`, `idempotencyKey`, `outputSchema`, `images`/`attachments`, `git`/`worktree` setup, `autoArchive`, `worktreeName`. **MCP tool has, WS lacks**: `background`/`notifyOnFinish` (WS is streaming so these are moot). The WS path needs a `hello` handshake with `protocolVersion: 1`, `clientType: "cli"|"mcp"|"browser"|"mobile"|"hub"`, bearer via `Sec-WebSocket-Protocol: paseo.bearer.<token>` (`auth.ts extractWsBearerProtocol`).

The daemon **does** inject one MCP server into every agent by default: `paseo` → `{type:"http", url:"http://127.0.0.1:6768/mcp/agents?callerAgentId=<agentId>", headers:{Authorization:"Bearer <per-run random token>"}}` (`runtime-mcp-config.ts withRuntimePaseoMcpServer`), disable with `--no-inject-mcp` or `config.json daemon.mcp.injectIntoAgents=false`. Codex/Claude snapshots both report `capabilities.supportsMcpServers: true`.

## Step 8. Codex

`which codex` → `~/.local/share/mise/installs/node/lts/bin/codex`, `codex-cli 0.153.4`, `codex login status` → `Logged in using ChatGPT`.
```
curl ... -d '{"jsonrpc":"2.0","id":80,"method":"tools/call","params":{"name":"create_agent","arguments":{"title":"spike codex","provider":"codex/gpt-5.6-luna","workspaceId":"wks_a16090c9430e4113","labels":{"ticket":"126"},"settings":{"modeId":"full-access"},"initialPrompt":"Create a file hello-codex.txt containing hi and reply DONE","background":false}}}'
```
```json
{"agentId":"6dc91a16-785b-4254-a5a4-f9f0e9f74cdd","type":"codex","status":"idle","cwd":"<spike>/repo","workspaceId":"wks_a16090c9430e4113","currentModeId":"full-access",
 "availableModes":[{"id":"auto","label":"Default Permissions","description":"Edit files and run commands with Codex's default approval flow."},{"id":"auto-review","label":"Auto-review","description":"Same workspace-write permissions as Default, but eligible `on-request` approvals are routed through the auto-reviewer subagent."},{"id":"full-access","label":"Full Access","description":"Edit files, run commands, and access the network without additional prompts."}],
 "lastMessage":"\n\n---\n\nDONE","permission":null}
```
elapsed **6486 ms**; `<spike>/repo/hello-codex.txt` = `hi`. Note `lastMessage` keeps Codex's markdown separator.

`get_agent_status` (codex), differing parts:
```json
{"status":"idle","snapshot":{
  "runtimeInfo":{"provider":"codex","sessionId":"01a08814-a4cd-7053-8bb6-51a242e5c81d","model":"gpt-5.6-luna","thinkingOptionId":"high","modeId":"full-access","extra":{"collaborationMode":"Default"}},
  "persistence":{"provider":"codex","sessionId":"01a08814-...","nativeHandle":"01a08814-...","metadata":{"provider":"codex","cwd":"<spike>/repo","title":"spike codex","threadId":"01a08814-...","modeId":"full-access","model":"gpt-5.6-luna","thinkingOptionId":"high"}},
  "features":[{"type":"toggle","id":"fast_mode","label":"Fast","description":"Priority inference at 2x usage","tooltip":"Toggle fast mode","icon":"zap","value":false},{"type":"toggle","id":"plan_mode","label":"Plan","description":"Switch Codex into planning-only collaboration mode","tooltip":"Toggle plan mode","icon":"list-todo","value":false}],
  "lastUsage":{"inputTokens":13805,"cachedInputTokens":13056,"outputTokens":5,"contextWindowMaxTokens":258400,"contextWindowUsedTokens":13810},
  "capabilities":{"supportsStreaming":true,"supportsSessionPersistence":true,"supportsSessionListing":true,"supportsDynamicModes":false,"supportsMcpServers":true,"supportsReasoningStream":true,"supportsToolInvocations":true,"supportsRewindConversation":true,"supportsRewindFiles":false,"supportsRewindBoth":false}}}
```
Same status vocabulary as Claude. No `totalCostUsd` in `lastUsage` for codex. Activity: `[User] …` / `I'll create hello-codex.txt…` / `[Edit] hello-codex.txt` / `---` / `DONE`. Native transcript: `~/.codex/sessions/2026/09/09/rollout-2026-09-09T14-30-49-01a08814-a4cd-7053-8bb6-51a242e5c81d.jsonl`.

## Step 9. Two owners in one cwd

Agent 2 (`db2b1ca0`) was created in workspace `wks_a16090c9430e4113` / same cwd while agent 1 (`6fd700c6`) was idle: **accepted, no refusal, no warning**. Later agents 3 (claude), codex, and the import also shared the cwd; five agent records sit in the same `agents/<cwd-slug>/` directory. Paseo does not serialize agents per workspace; the orchestrator must.

## Step 10. Versions

| Surface | Value |
|---|---|
| `paseo --version` / `daemon status .cliVersion` | `0.7.2` |
| `/api/health` | `{"status":"ok","timestamp":...}` — **no version field** |
| `/api/status` (needs bearer; `{"error":"Unauthorized"}` without) | `{"status":"server_info","serverId":"srv_xySFiO0r9AuK","hostname":"orangekid","version":"0.7.2","listen":"127.0.0.1:6768"}` |
| daemon log field | `"daemonVersion":"0.7.2"` on every line |
| MCP `initialize` | `protocolVersion "2025-03-26"`, `serverInfo {name:"agent-mcp", version:"2.0.0"}` |
| WebSocket | `WS_PROTOCOL_VERSION = 1` (`packages/server/src/server/websocket-server.ts:500`); hello with another value is closed with `WS_CLOSE_INCOMPATIBLE_PROTOCOL` "Incompatible protocol version". `WSHelloMessageSchema.protocolVersion: z.number().int()` (`messages.ts:7139`). |
| Relay | `CURRENT_RELAY_PROTOCOL_VERSION = "2"` (`packages/protocol/src/daemon-endpoints.ts:18`) — not used (relay disabled). |

## Step 11. Deep links and import

`packages/protocol/src/agent-deep-link.ts`:
```ts
export function buildAgentDeepLinkRoute(target): `/h/${string}/agent/${string}` {
  return `/h/${encodeURIComponent(serverId)}/agent/${encodeURIComponent(agentId)}`;
}
export function buildAgentDeepLink(target): string { return `paseo:/${buildAgentDeepLinkRoute(target)}`; }   // => paseo://h/<serverId>/agent/<agentId>
```
`packages/app/src/utils/host-routes.ts:375 buildHostAgentDetailRoute(serverId, agentId, workspaceId?)`: with a workspaceId it returns `/h/<serverId>/workspace/<workspaceId>?open=agent:<agentId>`; otherwise the agent deep-link route above. Parser at `host-routes.ts:271`: `/^\/h\/([^/]+)\/agent\/([^/]+)(?:\/|$)/`.

`serverId` comes from `getOrCreateServerId(config.paseoHome)` (`bootstrap.ts:614`) = file `PASEO_HOME/server-id` (`srv_xySFiO0r9AuK`), also in `/api/status.serverId` and `paseo daemon status --json .serverId`. `daemon-keypair.json` is `{v:2, publicKeyB64, secretKeyB64}` (pairing/relay), not the server id.

Concrete links for the codex agent: web `/h/srv_xySFiO0r9AuK/agent/6dc91a16-785b-4254-a5a4-f9f0e9f74cdd` (served by the daemon only when started with `--web-ui`, which was off: log `Daemon web UI disabled or missing dist directory {enabled:false, hasDistDir:true}`), desktop `paseo://h/srv_xySFiO0r9AuK/agent/6dc91a16-785b-4254-a5a4-f9f0e9f74cdd`, CLI `paseo agent open <agent-id> [--server <server-id>]`.

Import (an external `claude -p` session, `session_id 1b16e2e3-0e9e-40d0-a56d-dc1d3fee4625`, run in the repo):
```
PASEO_HOME=<spike>/paseo-home PASEO_PASSWORD=spike-pass paseo import 1b16e2e3-0e9e-40d0-a56d-dc1d3fee4625 --provider claude --cwd <spike>/repo --label ticket=999 --host 127.0.0.1:6768 --json
{
  "agentId": "a412f7b4-4f0a-46fd-8bb1-e17e01934f5e",
  "status": "created",
  "provider": "claude",
  "cwd": "<spike>/repo",
  "title": "Reply with the word EXTERNAL."
}
```
1394 ms; the agent then lists as `idle` with `labels {ticket: "999"}`. Importing a session Paseo already owns fails:
```
{"error":{"code":"AGENT_IMPORT_FAILED","message":"Failed to import agent: Provider session is already imported: 6a776524-24a6-4c85-9255-7327d17935de"}}
```
Options: `--provider <id>`, `--cwd <path>` ("for providers that require it"), `--label k=v` (repeatable), `--json`, `--host`.

## Step 12. Stop

```
PASEO_HOME=<spike>/paseo-home paseo daemon stop --home <spike>/paseo-home
STATUS   HOME                      PID      MESSAGE
stopped  <spike>/paseo-home        3455448  daemon websocket at 127.0.0.1:6768 is not reachable, falling back to owner PID signal
```
(The "not reachable" message is because the CLI could not authenticate its WebSocket without `PASEO_PASSWORD`; it then signalled the PID.) `curl /api/health` afterwards: connection refused. PASEO_HOME left in place. Final agent inventory (`list_agents includeArchived:true` before stop):
```
6dc91a16-785b-4254-a5a4-f9f0e9f74cdd | spike codex | codex  | idle   | {ticket:126}
9cf172b9-34d2-4594-ad4f-b92f88d02a70 | spike hooks | claude | idle   | {ticket:125}
6fd700c6-e4b1-47c7-ba64-e6dad7ba12c9 | spike hello | claude | closed | {ticket:123}   (killed)
a412f7b4-4f0a-46fd-8bb1-e17e01934f5e | Reply with the word EXTERNAL. | claude | idle | {ticket:999}   (imported)
db2b1ca0-be8d-458a-a6a8-85f3526cc7ad | spike perms | claude | closed | {ticket:124}   (archived)
```

## Recommended aiur driver loop (derived from the above)

1. Boot: `GET /api/status` with bearer → check `version`, capture `serverId`.
2. Per repo: `create_workspace {isolation:"local", path}` once; cache `workspaceId` by path (or `list_workspaces`).
3. Per ticket: `create_agent {title, provider:"claude/<model>"|"codex/<model>", workspaceId, labels:{ticket}, settings:{modeId}, initialPrompt, background:true}` → `agentId`.
4. Poll `get_agent_status` (1–2 s): `status=="running"` and `pendingPermissions.length>0` → decide → `respond_to_permission {agentId, requestId: pendingPermissions[i].id, response:{behavior:"allow"|"deny", message?, interrupt?}}`; `status=="idle"` and `attentionReason=="finished"` and `updatedAt > lastUserMessageAt` → turn done, read `get_agent_activity`; `status in ("error","closed")` → failure.
   Alternatively call with `background:false` and rely on the blocking return `{status,lastMessage,permission}` (the HTTP request stays open for the whole turn; set a long client timeout).
5. Follow-ups: `send_agent_prompt {agentId, prompt, sessionMode?, background}`.
6. Teardown: `archive_agent` (soft) or `kill_agent` (hard). Deep link for humans: `/h/<serverId>/agent/<agentId>`.
7. If you need `cwd` without a workspace, `env`, `systemPrompt`, `mcpServers`, `toolPolicy` or idempotent creates, use the WebSocket `create_agent_request` (protocolVersion 1) instead of the MCP tool.
