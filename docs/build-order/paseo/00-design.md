# aiur-paseo: design and decisions

Date: 2026-09-09. Researched code: aiur `main@8199f5373`, Paseo `getpaseo/paseo@726067b4` (daemon 0.7.2), `aiur-claude` 1.1.0.
Origin: [`docs/plans/2026-09-09-001-feat-paseo-integration-plan.md`](../../plans/2026-09-09-001-feat-paseo-integration-plan.md) (Option 2a) plus the operator's packaging constraint below.
Evidence: [`01-spike-report.md`](01-spike-report.md) is the hands-on spike against a real Paseo daemon on this machine. Every Paseo JSON shape in this document was captured there.

This document is the planning authority for the PSO tickets. A ticket doc restates only what it owns; anything shared lives here.

## 1. Goal

An Executor chats with any aiur agent from the Paseo mobile or desktop app while aiur keeps driving the agent's turn loop, and the TUI and dashboard keep working. One conversation, three views, selectable per agent.

Paseo cannot attach to a process it did not spawn, and a `claude` session accepts one input source. So for an opted-in issue **Paseo owns the provider process** and aiur drives it through Paseo. The phone talks to the same Paseo agent. There is no handoff.

## 2. The packaging constraint, and what the decomposition research says

The operator's constraint: Paseo support must not bloat the core package. It exists as a separate package that is installed and enabled opt-in.

The `planning/decompose-packages` research (2026-08-08, `docs/planning/decompose-packages/` on that branch) established the facts this design honors:

- aiur is one flat Mix app, no umbrella, no per-subsystem supervisors, so there is no startable Elixir boundary to put a feature behind today.
- The backend registry is consulted at compile time and its `provider_families()` is baked into four usage modules. New *families* cost a recompile; new *backends inside an existing family* do not.
- The verdict on backends was "extract the behaviour, not the implementations": `AppServer.Adapter` is the real runtime contract, and the claude/codex alias cycle blocks shipping an Elixir backend as its own package.
- The gate on that branch (parity and stability first) still stands, so this build order must not depend on any decomposition landing.

aiur already has an opt-in feature packaged outside core: `aiur-claude` is a separate npm package (`its-everdred/claude-app-server`) that aiur launches as a stdio sidecar and drives over the app-server JSON-RPC protocol. `packages/streamdeck` is the in-repo precedent for a TypeScript package with its own CI job and release asset. This design copies both precedents.

## 3. Decision: `aiur-paseo` is an app-server sidecar, not an Elixir backend

`aiur-paseo` is a TypeScript package under `packages/aiur-paseo/`, published to npm as `aiur-paseo`, that speaks the same stdio JSON-RPC protocol `aiur-claude` speaks and backs each thread with a Paseo agent through the official `@getpaseo/client` WebSocket SDK.

Core aiur sees one more app-server backend. The core delta is registry data plus three small generalizations that the decomposition research already asked for. Everything Paseo-specific, including its tests, its dependency on `@getpaseo/client`, and its release cadence, lives in the package.

```mermaid
flowchart TB
  subgraph core[aiur core, Elixir]
    ORCH[Orchestrator / AgentRunner turn loop]
    ADAPTER[Aiur.AppServer.GenericBackend<br/>command + family from the registry entry]
    REG[registry entries<br/>paseo-claude, paseo-codex: data only]
    SURF[TUI + dashboard<br/>generic surface indicator]
  end
  subgraph sidecar[aiur-paseo sidecar, TypeScript, stdio]
    RPC[app-server JSON-RPC server<br/>initialize, thread/start, turn/start, turn/interrupt]
    MAP[thread to Paseo agent mapping<br/>timeline to item/created]
    TOOLS[dynamic-tool bridge<br/>MCP over unix socket + stdio shim]
    PC[@getpaseo/client WebSocket]
  end
  subgraph paseo[Paseo daemon 127.0.0.1:6767]
    WS[/ws/]
    PROC[claude or codex process<br/>cwd = aiur workspace]
  end
  PHONE[Paseo app via relay or Tailscale]
  ORCH --> ADAPTER --> RPC
  REG -. selects command aiur-paseo .-> ADAPTER
  RPC --> MAP --> PC --> WS --> PROC
  PROC -. mcp__aiur__* .-> TOOLS --> RPC
  PHONE --> paseo
  SURF --> ORCH
```

## 4. Why this beats the in-core Elixir adapter drafted first

An earlier draft of this document put `Aiur.Paseo.*` modules in core with an HTTP client to Paseo's MCP endpoint. It was withdrawn because:

- It adds roughly ten modules and a `paseo:` config schema to core for a feature most installs never enable. That is the bloat the constraint forbids.
- Paseo's MCP tool `create_agent` has no `cwd`, `env`, or `mcpServers` field (spike section 7). The WebSocket SDK has all three. A TypeScript sidecar uses the official SDK; core Elixir would have to reimplement the WebSocket protocol against an unversioned zod schema.
- The dynamic-tool bridge that gives Paseo-owned agents `emit_alert`, `aiur_declare_blocker`, and the rest already exists in `aiur-claude` (`dynamic-tools.ts`, `mcp-shim.ts`, MIT) and ports to the sidecar verbatim. In core it would have needed a new aiur MCP server.
- Rich transcript mirroring falls out of the protocol: the sidecar converts Paseo timeline events into the `item/created` notifications `Aiur.Claude.Transcript` already renders. No native-file tailer, no activity-text parsing.

## 5. Decisions

- **DEC-001 Package boundary.** All Paseo code lives in `packages/aiur-paseo/` (TypeScript, Node 22+, `@getpaseo/client` pinned to a tested range). Published to npm as `aiur-paseo` with bin `aiur-paseo`. Core never imports Paseo types, never depends on the Paseo daemon, and compiles and tests identically with the package absent. `aiur init` offers the backend only when the `aiur-paseo` binary is on PATH, using the existing `install_hint` and `check_agent_auth` path (`src/lib/aiur/init/agent_cli.ex`).
- **DEC-002 Core registry entries are data.** `paseo-claude` and `paseo-codex` are added to `Aiur.CodingAgent.backends/0` with `family: "claude"` and `family: "codex"` so usage, pricing, and provider meters need no change. `adapter: Aiur.AppServer.GenericBackend`, `default_command: "aiur-paseo --provider claude"` (and `codex`), `install_hint: "npm install -g aiur-paseo"`, `dispatch_enabled_by_default: false`, `configurable: true`, `remote_control: false`, `remote_worker: false`, `resumable: true`, `immediate_delivery: true`, `safe_checkpoints: []`, `can_interrupt: true`, `fallback_backend: "claude"` (and `"codex"`), `model_aliases: :native`, `models` copied from the family entry, `efforts: []`. Enabling is `agent.backend_configs.paseo-claude.enabled: true` plus listing it in `agent.priority` or `agent.routing`, the mechanism that already exists for `deepseek`.
- **DEC-003 One generic app-server backend module in core.** `Aiur.Claude.CodingAgent` reads its command, permission mode, and model from `Aiur.Claude.Config`. `Aiur.AppServer.GenericBackend` is the same adapter with those three reads taken from the resolved registry entry and `agent.backend_configs.<backend>` instead. `claude` keeps its module and behaviour unchanged. This is the smallest form of the research's "extract the behaviour" verdict and is reusable by any future app-server sidecar.
- **DEC-004 Resume passthrough.** `GenericBackend.start_session/2` sends `thread/resume {threadId}` when `opts[:resume_thread_id]` is present, exactly as `Aiur.Codex.Handshake.start_or_resume_thread/5` does, and degrades to `thread/start` on error. The sidecar's thread id **is** the Paseo `agentId`, so `Aiur.SessionHandle` stores it unchanged and an aiur restart re-attaches to the same Paseo agent.
- **DEC-005 One Paseo agent per aiur workspace, enforced by the sidecar.** Paseo accepts many agents in one cwd (spike section 9). On `thread/start` the sidecar lists agents with `labels.aiur_issue == identifier` and `cwd == workspace` and re-attaches to a live one before creating. Labels written on every agent: `aiur_issue`, `aiur_repo`, `aiur_instance`. Title `"aiur <identifier>: <title>"` truncated to 60.
- **DEC-006 Environment travels in `create_agent_request.env`.** aiur launches the sidecar with `AgentEnvironment.workspace_env/2` in its environment; the sidecar forwards the `AIUR_*` variables plus `PATH` into the Paseo agent's `env`. The GitHub guard shims, build gate, and budget broker keep working for Paseo-owned agents. Lifecycle hooks are not needed because turn completion is a WebSocket event.
- **DEC-007 Dynamic tools through the MCP bridge.** The sidecar ports `dynamic-tools.ts` and `mcp-shim.ts` from `aiur-claude` and passes `config.mcpServers.aiur = {type: "stdio", command: "node", args: [shim, socketPath]}` on `create_agent_request`. Tool calls round-trip as `item/tool/call` requests to aiur, which already answers them (`Aiur.Claude.CodingAgent.handle_method/5` for `item/tool/call`). Paseo-owned agents get every aiur coordination tool on day one.
- **DEC-008 Transcript is the protocol.** The sidecar subscribes to the Paseo agent timeline and emits `item/created` notifications with the item types `Aiur.Claude.Transcript` renders (`text`, `thinking`, `tool_call`, `tool_result`) and one new type, `user`, for messages that did not come from aiur (phone or desktop). `usage/update` and `turn/completed {usage}` carry `snapshot.lastUsage` mapped to the aiur-claude usage shape.
- **DEC-009 Turn completion is a Paseo event, not a poll.** `turn/start` maps to `agent.send()` (or the initial prompt on create). Paseo's `agent_stream` carries explicit `turn_started`, `turn_completed`, `turn_failed`, and `turn_canceled` events with `turnId` and `usage`; the sidecar uses those as the turn boundary, emits `turn/completed` or `turn/failed`, and keeps the status snapshot (`idle` after the send, `error` or `closed`) as the fallback when a stream event is missed. A permission request while running is surfaced as a `permission/requested` notification (DEC-011) and does not end the turn.
- **DEC-010 Executor messages and interrupts.** `turn/start` while a turn is active (how core delivers an Executor message on app-server backends) maps to `agent.send()`; Paseo queues or steers it into the live session. `turn/interrupt` maps to the daemon's cancel. PSO-009 records the observed queue-versus-steer behaviour for Claude and Codex.
- **DEC-011 Permissions in v1 are configuration, not a bridge.** `paseo-claude` sends `permissionMode` from `agent.claude.permission_mode` (default `bypassPermissions`); `paseo-codex` sends `full-access`. Under those modes Paseo raises no permission requests. If an operator configures a prompting mode, the sidecar forwards each request as a `permission/requested` notification and auto-denies after `turn_timeout`; a Decision bridge is a follow-up (PSO-014, optional).
- **DEC-012 Generic surface indicator.** The sidecar answers `thread/start` with `thread.surface = {kind: "paseo", url: "paseo://h/<serverId>/agent/<agentId>", label: "Paseo"}`. `GenericBackend` copies it to `session.session_url` and `session.surface`, `runtime_report: :headless_wrapper` gains the field, and the status report exposes `surface:` beside `remote_control:`. The TUI border and dashboard row render 📱 with the label for any backend that reports a surface. Remote Control keeps its own field untouched.
- **DEC-013 Version and reachability guard in the sidecar.** On `initialize` the sidecar connects to the daemon, checks `/api/status` `version` against its own supported range, and fails `initialize` with a structured error (`paseo_unreachable`, `paseo_unsupported_version`, `paseo_unauthorized`). Core's existing spawn-failure path then applies `fallback_backend` once and raises an Executor attention naming the reason.
- **DEC-014 Daemon connection config lives with the sidecar.** `aiur-paseo` reads `PASEO_HOST` (default `127.0.0.1:6767`), `PASEO_PASSWORD`, and its own `--provider`, `--mode`, `--supported-versions` flags. Core passes nothing Paseo-specific; an operator sets `agent.backend_configs.paseo-claude.command` to change flags. Core has no `paseo:` config section.
- **DEC-015 Mid-run move.** A later ticket adds a `p` key that swaps an issue's `model:<backend>` label to the `paseo-*` twin and re-dispatches with the workspace kept, reusing `Aiur.Orchestrator.RemoteControlMode.teardown_for_redispatch/3`. Because there is no handoff, all three surfaces work after the move.

## 6. The app-server protocol the sidecar must implement

Authority: `aiur-claude` 1.1.0 (`src/server.ts`, `src/types.ts`, `README.md`) and core's consumers `src/lib/aiur/claude/coding_agent.ex`, `src/lib/aiur/app_server/adapter.ex`, `messages.ex`, `interrupts.ex`, `turn_loop.ex`, `turn_state.ex`, `src/lib/aiur/claude/transcript.ex`. NDJSON over stdio, JSON-RPC 2.0, camelCase and snake_case both accepted by aiur-claude; the sidecar emits camelCase where aiur-claude does.

Requests from aiur:

| method | params | result |
|---|---|---|
| `initialize` (id 1) | `{capabilities: {experimentalApi: true}, clientInfo: {name: "aiur-orchestrator", title, version}}` | `{server: {name, version}, capabilities}`; then the sidecar sends notification `initialized` |
| `initialized` | `{}` | notification, no reply |
| `thread/start` (id 2) | `{permissionMode, cwd, dynamicTools: [{name, description, inputSchema}]}` | `{thread: {id, created_at, surface?}}` |
| `thread/resume` | `{threadId}` | `{thread: {id, ...}}` or JSON-RPC error |
| `turn/start` (id 3, or a unique id for Executor messages) | `{threadId, input: [{type: "text", text}], cwd, title?, model?}` | `{turn: {id}}` |
| `turn/interrupt` | `{threadId, turnId}` | `{}` |

Requests from the sidecar to aiur:

| method | params | aiur replies |
|---|---|---|
| `item/tool/call` (id `aiur-tool-N`) | `{name, arguments, callId}` | `{id, result: {success, output, contentItems}}` |

Notifications from the sidecar:

| method | params |
|---|---|
| `item/created` | `{turn_id, item: {id, created_at, type, ...}}` with `type` in `text {text}`, `thinking {thinking}`, `tool_call {tool_use_id, name, input}`, `tool_result {tool_use_id, content, is_error?}`, `user {text, source: "phone"}` |
| `item/progress` | streaming deltas; aiur skips them, the sidecar may omit them |
| `usage/update` | `{turn_id, usage: {input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, total_tokens}}` |
| `turn/completed` | `{turn_id, thread_id, status: "completed" \| "interrupted", usage?, cost_usd?}` |
| `turn/failed` | `{turn_id, error}` |
| `rate_limit/update` | optional; omit in v1 |
| `permission/requested` | `{turn_id, request}` (DEC-011) |

Core-side gotchas the sidecar tests must cover: aiur reads `turn/completed` status through `TurnState.turn_completion_status/1`; an `item/tool/call` must be answered on the same transport with the same string id; the port line limit is 1 MiB, so long tool outputs are truncated by the sidecar before emission; `turn/start` may arrive while a turn is active (Executor message) and must not fail.

## 7. Paseo facts the sidecar relies on

From the spike and the Paseo source. The sidecar uses `@getpaseo/client` (`packages/client/src/index.ts`), not the MCP endpoint.

- Connect: `createPaseoClient({url: "ws://<host>/ws", password})`, `connect()`. Bearer travels as subprotocol `paseo.bearer.<token>`. Hello carries `protocolVersion: 1`; mismatch closes with "Incompatible protocol version".
- Create: `client.agents.create({config: {provider: "claude" | "codex", cwd, modeId, model, mcpServers, systemPrompt?}, env, labels, prompt?, idempotencyKey})`. `cwd` is honored directly; a local workspace is auto-provisioned per cwd. `mcpServers.<name> = {type: "stdio", command, args, env?}`.
- Drive: `agent.send(text)`, `agent.subscribe(update => ...)` (status `initializing | idle | running | error | closed`, `pendingPermissions`, `lastUsage`, `runtimeInfo.sessionId`), `agent.timeline.subscribe(event => ...)`, `agent.respondToPermission({requestId, response})`, `agent.archive()`. Cancel and kill are on the daemon client (`cancel_agent`, `kill_agent` tool equivalents); the SDK handle lacks them, so the sidecar uses the low-level daemon client or the MCP endpoint for those two calls.
- Re-attach: `client.agents.list()` filtered by `labels` and `cwd`; `client.agents.ref(id)`.
- Status: `GET /api/status` with bearer returns `{serverId, version, listen}`; `serverId` also in `PASEO_HOME/server-id`.
- Deep link: `paseo://h/<serverId>/agent/<agentId>`; web `/h/<serverId>/agent/<agentId>`.
- Modes: Claude `plan, default, acceptEdits, auto, bypassPermissions`; Codex `auto, auto-review, full-access`.
- Provider process env: whatever `env` was passed on create, merged by the daemon. Workspace-local `.claude/settings.local.json` is also loaded (`settingSources: user, project, local`), which is the fallback if `env` proves insufficient.
- Timings on this machine: create plus first turn 2.7 to 4.8 s (haiku), follow-up 1.3 s, codex 6.5 s.

## 8. aiur seams (with paths)

- Backend behaviour and registry: `src/lib/aiur/coding_agent/backend.ex`, `src/lib/aiur/coding_agent.ex` (`backends/0`, `dispatchable_backends/1`, `configurable_backends/0`, `@model_override_label`).
- App-server adapter to generalize: `src/lib/aiur/claude/coding_agent.ex` (three `Aiur.Claude.Config` reads: `command/0`, `permission_mode/0`, `model/0`), shared skeleton `src/lib/aiur/app_server/adapter.ex`, frames `messages.ex`, interrupt `interrupts.ex`, codex resume pattern `src/lib/aiur/codex/handshake.ex`.
- Backend config: `Aiur.Config.backend_config/1` and `agent_backend_configs/0` in `src/lib/aiur/config.ex`; schema field `backend_configs` in `src/lib/aiur/config/schema/agent.ex`; docs check `scripts/check-config-docs.py` (`KNOWN_MAP_SUBKEYS` for `backend_configs`).
- Session options and resume: `src/lib/aiur/agent_runner/session_lifecycle.ex` (`resolve_session_options/3`, `session_runtime_info/1`), `src/lib/aiur/agent_runner/session_resume.ex`, `src/lib/aiur/session_handle.ex`.
- Transcript: `src/lib/aiur/claude/transcript.ex` (`event_from_item/4` clauses for `text`, `thinking`, `tool_call`, `tool_result`; add `user`).
- Surface indicator precedent: `src/lib/aiur/orchestrator/remote_control_mode.ex` (`remote_control_summary/1`), `src/lib/aiur/orchestrator/status_report.ex` (`remote_control:` field), `src/lib/aiur/agent_list/rc_pane_borders.ex`, dashboard row in `src/lib/aiur_web/live/dashboard_live.ex`.
- Init: `src/lib/aiur/init/agent_cli.ex` (`check_agent_auth/1`, `install_hint/2`, `agent_executable/1`), `src/lib/aiur/init/questions.ex`.
- Fallback on spawn failure: `session_lifecycle.ex` around the `fallback_backend` retry (`remote_session_backend/2` and the RC degrade path at 904-943).
- Package precedents: `packages/streamdeck/` (tsconfig, vitest with 100% thresholds, eslint), `.github/workflows/streamdeck-package.yml`, `ci.yml` job `streamdeck`, `.github/workflows/release-npm.yml` for npm publish shape.
- Validation: `make all` in `src/`; `mix specs.check`; `python3 scripts/check-config-docs.py`; package: `npm test`, `npm run lint`, `npm run typecheck`; manual proof `scripts/aiurdev --test --force --allow-remote`.

## 9. Session map contract for `GenericBackend`

Same as `Aiur.Claude.CodingAgent.session/0` plus:

```elixir
%{
  port: port(), metadata: map(), thread_id: String.t(), workspace: Path.t(),
  model: String.t() | nil, backend: String.t(), resumed: boolean(),
  session_url: String.t() | nil,                 # surface.url from thread/start
  surface: %{kind: String.t(), label: String.t(), url: String.t()} | nil,
  account_generation_binding: reference()        # unchanged
}
```

## 10. Waves and parallelism

| Wave | Tickets | Parallel because |
|---|---|---|
| 1 | PSO-001 generic backend, PSO-002 registry entries and docs keys, PSO-003 surface indicator, PSO-004 package scaffold | four disjoint file sets |
| 2 | PSO-005 protocol server, PSO-006 Paseo client layer, PSO-007 resume passthrough, PSO-008 docs | 005 and 006 are separate modules in the package; 007 edits the module 001 created; 008 needs 002's key names |
| 3 | PSO-009 turn mapping, PSO-010 tool bridge, PSO-011 resume and surface in the sidecar | three package modules over 005 and 006 |
| 4 | PSO-012 integration proof and fallback, PSO-013 init wizard | 012 needs the whole path; 013 needs 002 and a working binary |
| 5 | PSO-014 permission bridge (optional), PSO-015 mid-run move (optional) | both over the proven path |

Critical path: PSO-004 to PSO-005/006 to PSO-009 to PSO-012, four ticket-lengths. Peak parallelism four in wave 1 and four in wave 2.

## 11. Serialization notes

- PSO-001 and PSO-007 both edit `src/lib/aiur/app_server/generic_backend.ex`; 007 is blocked by 001.
- PSO-005, PSO-006 land separate modules; PSO-009, PSO-010, PSO-011 each edit `session.ts` in the package and rebase in wave order 009, 010, 011.
- PSO-003 and PSO-015 both touch the orchestrator status report; 015 is blocked by 003 and 012.

## 12. Manual proof (owned by PSO-012, referenced by every ticket's at-merge gate)

1. `paseo daemon start` on this machine with a password; export `PASEO_PASSWORD` for aiur; `npm install -g aiur-paseo` from the package tarball.
2. `.aiur/config`: `agent.backend_configs.paseo-claude.enabled: true`; label a `--test` issue `model:paseo-claude`.
3. `scripts/aiurdev --test --force --allow-remote`; the agent row shows 📱 Paseo; the Paseo app shows the agent; a message typed in Paseo appears in the opencode pane as a user row; `aiur message <id> "..."` appears in Paseo; the agent calls `emit_alert` and the alert lands in aiur; the issue reaches a PR.
4. `pgrep -af "claude|codex"` shows exactly one provider process for that workspace, parented by the Paseo daemon.
5. Restart aiur mid-run; the agent row returns with the same Paseo `agentId` (`aiur status --json`).
6. Stop the Paseo daemon and dispatch another `model:paseo-claude` issue; the run falls back to `claude` once with an attention naming `paseo_unreachable`.
