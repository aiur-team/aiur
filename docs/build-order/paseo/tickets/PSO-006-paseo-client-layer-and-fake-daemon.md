# PSO-006 — Paseo client layer and fake daemon

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — the only module that touches the Paseo wire; the fake daemon is what every later sidecar test runs against

**Risk:** high

**Phase hint:** 2

**Depends on:** PSO-004

**Serializes with:** none

**External gates:** none

**Requirements:** R6, R10, R11, R14

**Decisions:** DEC-001, DEC-005, DEC-006, DEC-007, DEC-013, DEC-014

**Design evidence:** 00-design.md sections 5, 7; 01-spike-report.md sections 1, 2, 7, 9, 10, 11; Paseo `packages/client/src/index.ts`, `packages/client/src/daemon-client.ts`, `packages/protocol/src/messages.ts`, `packages/server/src/server/auth.ts`

**Researched at:** 8199f5373 (aiur main), paseo 726067b4, aiur-claude 1.1.0

**Suggested labels:** `complexity:4`, `model:claude`, `phase:2`, `build-lane:paseo-sidecar`; never `agent:todo`

## Outcome

`src/paseo/client.ts` is the sidecar's only doorway to a Paseo daemon: it checks reachability, auth, and version, connects the official `@getpaseo/client`, and exposes the eight operations the driver needs. `src/paseo/fake-daemon.ts` is an in-process WebSocket daemon that speaks enough of the real protocol for the whole sidecar to be tested without Paseo installed. `aiur-paseo --check` reports the daemon in one JSON line and a stable exit code.

## Context and evidence

The design chose the WebSocket SDK over the MCP endpoint because only the SDK carries `cwd`, `env`, `mcpServers`, and a structured timeline (00-design.md section 4; spike section 7). Facts from the SDK and protocol source the implementation depends on:

- `createPaseoClient({url, password, connectTimeoutMs, reconnect, logger})` returns `PaseoClient` with `connect()`, `close()`, `agents`, `workspaces`, `providers` (`packages/client/src/index.ts:78-101`, `:468`). The bearer travels as WebSocket subprotocol `paseo.bearer.<password>` (`packages/server/src/server/auth.ts:63` `extractWsBearerProtocol`); the SDK does this from `password`.
- `client.agents.create(options: PaseoAgentCreateOptions)` with `config: {provider: "claude/<model>", modeId, mcpServers, systemPrompt, toolPolicy}`, `cwd`, `env`, `labels`, `prompt`, `title`, `requestId` (`index.ts:211-240`). Returns `PaseoAgentHandle` with `current()`, `refresh()`, `send(text, {messageId})`, `respondToPermission({requestId, response})`, `run`, `waitForFinish`, `archive()`, `detach()`, `subscribe(update => ...)`, `timeline.subscribe(event => ...)` (`index.ts:313-353`).
- `client.agents.list(options)` wraps `fetch_agents_request` whose `filter` is `AgentDirectoryFilterSchema = {labels?, projectKeys?, statuses?, includeArchived?, requiresAttention?}` (`messages.ts:947-954`). There is no `cwd` filter on the wire; filter by `cwd` client-side on the returned snapshots.
- The SDK handle lacks cancel and kill. The low-level `DaemonClient` (exported as `@getpaseo/client/internal/daemon-client`, `packages/client/package.json` exports) has `cancelAgent(agentId)` (`daemon-client.ts:3262`, wire `cancel_agent_request`), `deleteAgent(agentId)` (`:2611`, `delete_agent_request`), `archiveAgent` (`:2634`, `archive_agent_request`), `sendAgentMessage` (`:3189`, `send_agent_message_request` with `activeTurnBehavior: "interrupt" | "steer"`, `messages.ts:1240,1395`), `fetchAgents` (`:2085`), `resumeAgent(handle, overrides)` (`:2822`, `resume_agent_request`), `respondToPermission` (`:5019`, `agent_permission_response`), `subscribeAgentTimeline` (`:3061`).
- Server pushes: `agent_update` (snapshot: `status` in `initializing|idle|running|error|closed`, `pendingPermissions`, `lastUsage`, `runtimeInfo.sessionId`, `labels`, `cwd`), `agent_stream` with `event.type` in `thread_started {sessionId}`, `turn_started {turnId?}`, `turn_completed {turnId?, usage?}`, `turn_failed {turnId?, error, code?}`, `permission_requested`, `permission_resolved`, and timeline items (`messages.ts:762-805`, `:3952-3961`). Timeline item payloads: `user_message {text, messageId?}`, `assistant_message {text}`, `reasoning {text}`, `tool_call {callId, name, detail, status: running|completed|failed|canceled, error}`, `todo`, `error`, `notification`, `compaction` (`messages.ts:704-756`).
- Hello handshake: `{type:"hello", clientId, clientType: "cli", protocolVersion: 1, capabilities}` (`messages.ts:7136`); a mismatch closes with "Incompatible protocol version".
- `/api/status` (bearer) returns `{status:"server_info", serverId, hostname, version, listen}`; `/api/health` has no version (spike section 10).

## Scope

`src/paseo/client.ts`:

```ts
export type DaemonErrorCode = "paseo_unreachable" | "paseo_unauthorized" | "paseo_unsupported_version" | "paseo_protocol_error";
export class DaemonError extends Error { constructor(public code: DaemonErrorCode, message: string, public data?: unknown) }
export interface ConnectOptions { host: string; password?: string; supportedVersions: string; connectTimeoutMs?: number; fetchImpl?: typeof fetch; clientFactory?: typeof createPaseoClient }
export interface DaemonSession { client: PaseoClient; daemon: DaemonClient; serverId: string; version: string; close(): Promise<void> }
export function connectDaemon(opts: ConnectOptions): Promise<DaemonSession>;
export function checkDaemon(opts: ConnectOptions): Promise<{serverId: string; version: string}>;   // status only, no WebSocket
export interface AgentLookup { cwd: string; labels: Record<string, string> }
export function findAgent(s: DaemonSession, q: AgentLookup): Promise<PaseoAgent | null>;             // list({filter:{labels, includeArchived:false}}) then cwd match; newest wins
export interface CreateAgentInput { provider: "claude" | "codex"; model?: string; cwd: string; modeId: string; env: Record<string,string>; labels: Record<string,string>; mcpServers?: Record<string, McpServerConfig>; title: string; prompt?: string; idempotencyKey?: string }
export function createAgent(s: DaemonSession, input: CreateAgentInput): Promise<PaseoAgentHandle>;
export function agentRef(s: DaemonSession, agentId: string): PaseoAgentHandle;
export function sendPrompt(s: DaemonSession, agentId: string, text: string, behavior: "queue" | "steer" | "interrupt"): Promise<void>; // queue = handle.send; steer/interrupt = daemon.sendAgentMessage({activeTurnBehavior})
export function subscribeStatus(handle: PaseoAgentHandle, fn: (u: PaseoAgentUpdate) => void): () => void;
export function subscribeTimeline(handle: PaseoAgentHandle, fn: (e: PaseoAgentTimelineEvent) => void): () => void;
export function cancel(s: DaemonSession, agentId: string): Promise<void>;   // daemon.cancelAgent
export function archive(s: DaemonSession, agentId: string): Promise<void>;  // daemon.archiveAgent
export function kill(s: DaemonSession, agentId: string): Promise<void>;     // daemon.deleteAgent
export function deepLink(serverId: string, agentId: string): string;         // paseo://h/<serverId>/agent/<agentId>
```

- `connectDaemon` order: `GET http://<host>/api/status` with `Authorization: Bearer <password>` (2 s timeout). `ECONNREFUSED`, timeout, or non-JSON → `paseo_unreachable`; 401 → `paseo_unauthorized`; `version` outside `supportedVersions` (semver range; add `semver` dependency) → `paseo_unsupported_version` with `{version, supported}`; then `createPaseoClient({url: "ws://<host>/ws", password, reconnect: {enabled: false}})`, `connect()`, and the `DaemonClient` for the internal calls (construct it the way `createPaseoClient` does at `index.ts:468-477`, or obtain it through `createPaseoApi`; pick whichever the package exports permit and record it). The password is never included in `DaemonError` messages.
- `src/cli.ts --check`: `checkDaemon`, print `{"serverId":"...","version":"..."}` on stdout, exit 0. Exit 3 `paseo_unreachable`, 4 `paseo_unauthorized`, 5 `paseo_unsupported_version`, 6 `paseo_protocol_error`; one-line reason on stderr. Update the README exit-code table.
- `src/paseo/fake-daemon.ts` (test support, shipped in `src/` so PSO-009 through PSO-012 import it; excluded from the npm `files` list is not possible with `dist`, so keep it small and dependency-light):

```ts
export interface FakeDaemonOptions { password?: string; version?: string; serverId?: string; protocolVersion?: number }
export class FakeDaemon {
  static start(opts?: FakeDaemonOptions): Promise<FakeDaemon>;  // http server + ws on 127.0.0.1:0
  readonly host: string;                                        // "127.0.0.1:<port>"
  agents: Map<string, FakeAgent>;                               // snapshot + recorded create input (env, labels, mcpServers, cwd, modeId, prompt)
  createdRequests: CreateAgentRequestMessage[];
  sentMessages: Array<{agentId: string; text: string; activeTurnBehavior?: string}>;
  scriptTurn(agentId: string, steps: FakeStep[]): Promise<void>; // emits agent_stream/agent_update in order, e.g. [{type:"turn_started"}, {item:{type:"assistant_message",text}}, {item:{type:"tool_call",...}}, {type:"turn_completed",usage}, {status:"idle"}]
  requestPermission(agentId: string, request: unknown): Promise<void>; // agent_update with pendingPermissions + agent_stream permission_requested
  setStatus(agentId: string, status: AgentStatus): void;
  stop(): Promise<void>;
}
```

  Implements: `GET /api/status` (401 without the right bearer), `GET /api/health`; WebSocket at `/ws` requiring subprotocol `paseo.bearer.<password>` when a password is set; `hello` (reject `protocolVersion !== 1` with the real close code and reason); `create_agent_request` → `agent_created` status reply plus an `agent_update`; `fetch_agents_request` honoring `filter.labels` and `includeArchived`; `fetch_agent_request`; `send_agent_message_request` (recorded; if a turn is active and `activeTurnBehavior` is `steer`, append a `user_message` timeline item); `cancel_agent_request` (status `idle`, `turn_completed` with the last turn id); `archive_agent_request` (status `closed`, `archivedAt`); `delete_agent_request` (status `closed`); `agent_permission_response` (clears the pending permission, emits `permission_resolved`); timeline subscription messages the SDK sends (read `subscribeAgentTimeline` in `daemon-client.ts:3061` for the exact request and event type names and mirror them); `resume_agent_request` → `agent_resumed` for a known handle, `error` for unknown. Unknown message types → `error` reply with the type named, so a test fails loudly when the SDK sends something the fake does not model.

## Non-goals

- Reconnect after a daemon restart mid-session: out of scope; the sidecar treats a dropped WebSocket as a failed turn (PSO-009 handles the error path) and core's turn retry re-creates the sidecar.
- E2EE relay, hub, terminals, workspaces API, schedules.
- The `SessionDriver` itself (PSO-009, PSO-010, PSO-011).

## Existing owner and reuse target

New module. Reuses `@getpaseo/client` public and `internal/daemon-client` entry points; nothing is copied from the Paseo repo except message type names in the fake.

## Contract and invariants

### Requirements

- PSO-006-R1. `connectDaemon` classifies every failure into one `DaemonErrorCode`; the message never contains the password.
- PSO-006-R2. The version guard accepts `0.7.2` and `0.8.3` and rejects `0.6.9` and `0.9.0` under the default range `>=0.7.2 <0.9.0`; the range is operator-overridable through `--supported-versions`.
- PSO-006-R3. `findAgent` returns the newest non-archived agent whose labels include every queried label and whose `cwd` equals the query, else `null`.
- PSO-006-R4. `createAgent` forwards `cwd`, `env`, `labels`, `mcpServers`, `modeId`, `title`, and `prompt` unchanged; `provider` and `model` are joined as `"<provider>/<model>"`, or `"<provider>"` alone when no model is given (verify the SDK accepts a bare provider; if not, resolve the provider's default model through `client.providers` and record it).
- PSO-006-R5. `sendPrompt` with `queue` uses the SDK handle; `steer` and `interrupt` use `sendAgentMessage` with the matching `activeTurnBehavior`.
- PSO-006-R6. `cancel`, `archive`, and `kill` resolve on the daemon's acknowledgement and reject with `paseo_protocol_error` on an `error` reply.
- PSO-006-R7. `--check` exit codes are 0, 3, 4, 5, 6 as listed and print exactly one line on stdout.
- PSO-006-R8. `FakeDaemon` rejects a wrong or missing bearer with 401 on HTTP and a closed WebSocket, rejects `protocolVersion !== 1`, and fails any unmodelled message type loudly.

Invariants: `client.ts` is the only file importing `@getpaseo/client`; the fake daemon never imports it (it speaks the wire directly with `ws`).

## Refreshable implementation notes

- Read `createPaseoClient` (`index.ts:468-481`) to see how it builds `DaemonClient` and whether the SDK exposes it on the returned object; if not, construct one `DaemonClient` and build the API from it with `createPaseoApi(daemonClient)` so both layers share one socket.
- The SDK reconnects by default; disable it (`reconnect.enabled: false`) so a dropped daemon fails fast and deterministically.
- Timeline subscriptions may start with a history replay; the driver (PSO-009) needs to know which events are backfill. Expose the raw event including `seq` and `epoch` and let the driver decide.
- `ws` is the dependency for the fake daemon only; keep it in `dependencies` because `src/paseo/fake-daemon.ts` ships in `dist`, or move the fake to `test/support/` and import it from tests only. Prefer `test/support/fake-daemon.ts` with `ws` in `devDependencies` if vitest can share it across PSO tickets; state the choice in the PR.

### Key technical decisions

- Status check over HTTP before the WebSocket, because the WebSocket handshake failure modes (auth versus version versus refused) are not distinguishable from the SDK's error surface.
- `semver` for the range instead of hand parsing, matching how Paseo itself compares versions.
- Wire-level fake instead of mocking the SDK, so SDK upgrades that change message shapes fail these tests before they fail in production.

## Acceptance and verification

### Agent gate

`test/paseo/client.test.ts` against `FakeDaemon`:

- version guard matrix (four versions, default range; custom range accepts `0.9.1`).
- refused port → `paseo_unreachable`; wrong password → `paseo_unauthorized`; non-JSON status → `paseo_unreachable`.
- connect succeeds and `serverId` matches the fake's.
- create then list: the created agent is found by `findAgent` with the same labels and cwd; a different cwd is not found; an archived twin is skipped; two matches return the newest.
- env, labels, mcpServers, modeId, title, prompt are recorded verbatim on `createdRequests[0]`.
- `sendPrompt` queue/steer/interrupt land in `sentMessages` with the right behaviour.
- timeline subscription receives scripted items in order with `seq` increasing.
- `cancel`, `archive`, `kill` change the fake's status as specified; an `error` reply rejects with `paseo_protocol_error`.
- hello with `protocolVersion: 2` is closed (test the fake directly).
- `test/cli-check.test.ts`: spawn `node dist/cli.js --check --host <fake>` for each outcome and assert stdout, stderr, and exit code.
- Coverage 100% on `src/paseo/client.ts`; the fake daemon is test support and is excluded from thresholds with a comment.

### At-merge gate

- CI job `aiur-paseo` green; `npm run build` green.

### Human/manual evidence

- Against the real daemon from the spike (`PASEO_HOME=<spike>/paseo-home`, port 6768, password `spike-pass`): `aiur-paseo --check --host 127.0.0.1:6768` prints the server id `srv_xySFiO0r9AuK` and version `0.7.2`, exit 0; with a wrong password exit 4; with the daemon stopped exit 3. Paste the three runs on the PR.

## Failure, security, migration, and accessibility cases

- The bearer is a daemon-wide password; it must not appear in logs, errors, `--debug` output, or the `env` forwarded to agents.
- `env` forwarded to `createAgent` is the caller's responsibility (PSO-009 filters `AIUR_*` and `PATH`); this layer forwards what it is given.
- A daemon that answers `/api/status` but rejects the WebSocket is reported as `paseo_protocol_error` with the close reason.

## Surfaces

- Reads: `/api/status`, WebSocket `/ws`.
- Writes: `create_agent_request`, `send_agent_message_request`, `cancel_agent_request`, `archive_agent_request`, `delete_agent_request`, `agent_permission_response`, `fetch_agents_request`, `resume_agent_request`, timeline subscription.
- Contracts: the exported functions above (consumed by PSO-009, PSO-010, PSO-011, PSO-012) and `FakeDaemon` (consumed by every later sidecar test).

## Sibling boundaries and open gates

PSO-005 owns the app-server side and must not import this module; PSO-009 maps turns and timelines; PSO-011 owns re-attach and resume policy on top of `findAgent` and `resumeAgent`.

## Plan context

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
