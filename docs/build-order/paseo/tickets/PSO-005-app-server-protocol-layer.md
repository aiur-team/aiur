# PSO-005 — App-server JSON-RPC protocol layer

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — the sidecar half core talks to; conformance against frames core emits and parses today

**Risk:** high

**Phase hint:** 2

**Depends on:** PSO-004

**Serializes with:** none (PSO-009, PSO-010, PSO-011 implement the `SessionDriver` this ticket defines, in `src/session.ts`)

**External gates:** none

**Requirements:** R7, R8, R14

**Decisions:** DEC-003, DEC-004, DEC-008, DEC-009, DEC-010, DEC-012

**Design evidence:** 00-design.md sections 3, 5, 6, 9; aiur-claude 1.1.0 `src/server.ts`, `src/protocol.ts`, `src/types.ts`, `src/dynamic-tools.ts` (`PendingEngineCalls`)

**Researched at:** 8199f5373 (aiur main), paseo 726067b4, aiur-claude 1.1.0

**Suggested labels:** `complexity:4`, `model:claude`, `phase:2`, `build-lane:paseo-sidecar`; never `agent:todo`

## Outcome

`src/server.ts` implements every app-server method aiur core sends, in the exact shapes `Aiur.Claude.CodingAgent`, `Aiur.AppServer.Adapter`, `Interrupts`, `TurnLoop`, and `TurnState` emit and parse, over a `SessionDriver` interface with no Paseo dependency. A `FakeDriver` proves the protocol layer end to end in vitest. PSO-009 through PSO-011 plug the Paseo-backed driver in without touching this file's dispatch.

## Context and evidence

Core drives every app-server backend with the same handful of frames. The sidecar must be indistinguishable from `aiur-claude` on the wire, because `Aiur.AppServer.GenericBackend` (PSO-001) is the Claude adapter with the command made configurable, not a new protocol. The authoritative frames, copied for the conformance suite:

Core sends (from `src/lib/aiur/app_server/messages.ex`, `src/lib/aiur/claude/coding_agent.ex`, `src/lib/aiur/app_server/interrupts.ex`):

```jsonc
{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"capabilities":{"experimentalApi":true},"clientInfo":{"name":"aiur-orchestrator","title":"Aiur Orchestrator","version":"0.0.5"}}}
{"jsonrpc":"2.0","method":"initialized","params":{}}
{"jsonrpc":"2.0","method":"thread/start","id":2,"params":{"permissionMode":"bypassPermissions","cwd":"/abs/workspace","dynamicTools":[{"name":"emit_alert","description":"...","inputSchema":{...}}]}}
{"jsonrpc":"2.0","method":"turn/start","id":3,"params":{"threadId":"<id>","input":[{"type":"text","text":"<prompt>"}],"cwd":"/abs/workspace","title":"1234: Issue title","model":"opus"}}
{"jsonrpc":"2.0","method":"turn/start","id":48271,"params":{"threadId":"<id>","input":[{"type":"text","text":"<executor message>"}],"cwd":"/abs/workspace"}}
{"jsonrpc":"2.0","method":"turn/interrupt","id":48272,"params":{"threadId":"<id>","turnId":"<turn>"}}
{"jsonrpc":"2.0","id":"aiur-tool-7","result":{"success":true,"output":"...","contentItems":[{"type":"text","text":"..."}]}}
```

Core parses: `thread/start` result `{"thread":{"id":...}}` (`start_thread/2`), `turn/start` result `{"turn":{"id":...}}` (`start_turn/3`), `turn/completed` status from `params.turn.status` with fallback `"completed"` (`TurnState.turn_completion_status/1`), `turn/failed` params as the failure reason, `item/tool/call` as a request with string id answered on the same transport (`handle_method/5`), every other `method` as a notification (`item/created` feeds `Aiur.Claude.Transcript`). Integer-id responses are routed to pending Executor-message requests (`OperatorDelivery.handle_pending_operator_response/5`), so the second `turn/start` above must be answered with `{"turn":{"id"}}` too.

## Scope

- `src/server.ts` exporting `class AppServer` with `constructor(driver: SessionDriver, opts: {log?: (s: string) => void, toolCallTimeoutMs?: number})` and `handleMessage(msg: RpcMessage, conn: Connection): Promise<RpcResponse | null>`; wire it to `startStdio` in `src/cli.ts`.
- `src/driver.ts` exporting:

```ts
export interface ThreadStartParams { cwd: string; permissionMode: string; dynamicTools: DynamicToolSpec[]; model?: string }
export interface ThreadInfo { id: string; created_at: number; surface?: { kind: string; label: string; url: string } }
export interface TurnInput { text: string; title?: string; model?: string }
export interface SessionDriver {
  start(params: ThreadStartParams, emitter: Emitter): Promise<ThreadInfo>;
  resume(threadId: string, emitter: Emitter): Promise<ThreadInfo>;          // throws DriverError("thread_not_found")
  startTurn(threadId: string, turnId: string, input: TurnInput): Promise<void>; // resolves when the turn ends
  steer(threadId: string, input: TurnInput): Promise<void>;                 // message into an active turn
  interrupt(threadId: string, turnId: string): Promise<void>;
  close(threadId: string): Promise<void>;
}
export interface Emitter {
  itemCreated(turnId: string, item: Item): void;      // Item = text | thinking | tool_call | tool_result | user
  usage(turnId: string, usage: Usage): void;
  permissionRequested(turnId: string, request: unknown): void;
  toolCall(name: string, args: unknown, callId: string): Promise<ToolResult>; // server→client item/tool/call
}
```

- Thread and turn bookkeeping in `AppServer`: `threads: Map<threadId, {info, params, activeTurn?: {id, promise}}>`; turn ids `uuid()`; `created_at` epoch ms.
- Method behaviours:
  - `initialize`: sets `conn.initialized`, replies `{server:{name:"aiur-paseo",version}, capabilities:{threads:["start","resume"], turns:["start","interrupt"], dynamicTools:true}}`, then sends notification `initialized {server:"aiur-paseo"}` on the next tick. Any other method before it: `-32000 Not initialized`.
  - `initialized` (client notification): ignored.
  - `thread/start`: `cwd` required, absolute, existing directory (else `-32602`); `permissionMode` default `"bypassPermissions"`; `dynamicTools` through `parseDynamicTools` (port from aiur-claude; store on the thread; PSO-010 starts the bridge). Calls `driver.start`. Replies `{thread:{id, created_at, surface?}}`.
  - `thread/resume {threadId}`: `driver.resume`; `DriverError("thread_not_found")` maps to `-32001`; success replies `{thread:{id, created_at, surface?}}`.
  - `turn/start`: `threadId` must exist (`-32001`), `input[0].text` required (`-32602`). If no active turn: allocate `turnId`, reply `{turn:{id}}` immediately, then run `driver.startTurn` asynchronously; on resolve emit `turn/completed`, on reject emit `turn/failed {turn_id, thread_id, error}`. If a turn is active: reply `{turn:{id: activeTurn.id}}` and call `driver.steer` (Executor message; DEC-010). Never `-32003 TurnBusy`.
  - `turn/interrupt {threadId, turnId}`: `driver.interrupt`; reply `{}`; the running `startTurn` resolves and completion is emitted with `status:"interrupted"`. No active turn: `-32004`.
  - Unknown method: `-32601`.
  - Response frames (`id` present, `result` or `error`): routed to `PendingEngineCalls.handleResponse`; unmatched ids logged.
  - Stdin close: `driver.close` for every thread, then exit 0.
- Notification shapes (emit exactly):

```jsonc
{"method":"item/created","params":{"turn_id":"<t>","item":{"id":"<uuid>","created_at":1710000000000,"type":"text","text":"..."}}}
{"method":"item/created","params":{"turn_id":"<t>","item":{"id":"...","created_at":..., "type":"user","text":"...","source":"phone"}}}
{"method":"usage/update","params":{"turn_id":"<t>","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":0,"total_tokens":6}}}
{"method":"turn/completed","params":{"turn_id":"<t>","thread_id":"<th>","status":"completed","turn":{"id":"<t>","status":"completed"},"usage":{...},"cost_usd":0.01}}
{"method":"turn/failed","params":{"turn_id":"<t>","thread_id":"<th>","error":"paseo agent status=error"}}
{"method":"permission/requested","params":{"turn_id":"<t>","request":{...}}}
```

  `turn/completed` carries both the flat `status` (aiur-claude compatibility) and `turn.{id,status}` (what `TurnState.turn_completion_status/1` reads).
- Server-initiated requests: `{"jsonrpc":"2.0","id":"aiur-tool-N","method":"item/tool/call","params":{"name","arguments","callId"}}` through a ported `PendingEngineCalls` with `toolCallTimeoutMs` default 120000; timeout rejects the `Emitter.toolCall` promise.
- Output truncation: any `item.text`, `item.thinking`, or `tool_result.content` longer than 512 KiB is cut with a trailing `… [truncated N bytes]` so a frame never exceeds core's 1 MiB line cap.
- `src/cli.ts`: construct `AppServer` with a `NotImplementedDriver` that rejects `start` with `-32603 driver not wired` until PSO-009 lands, so the binary keeps running for transport-level tests.

## Non-goals

- Any Paseo call, timeline mapping, tool bridge socket, resume lookup, or surface computation: those are `SessionDriver` implementations (PSO-009, PSO-010, PSO-011).
- `thread/fork`, `turn/steer` as a distinct method, `approval/respond`, `model/list`, `skills/list`, `app/list`, `rate_limit/update`: core does not send or need them; reply `-32601`.
- WebSocket transport: aiur-claude's `start` mode is not needed.

## Existing owner and reuse target

Port from `aiur-claude/src/server.ts` (dispatch, `initialize`, thread map, turn lifecycle), `dynamic-tools.ts` (`parseDynamicTools`, `PendingEngineCalls`, `engineResultToMcp`), `protocol.ts`. Attribute in `NOTICE` (PSO-004). Keep aiur-claude's `E` codes: `NotInitialized -32000`, `ThreadNotFound -32001`, `TurnBusy -32003`, `NoActiveTurn -32004`.

## Contract and invariants

### Requirements

- PSO-005-R1. The conformance suite replays the frames in "Context and evidence" byte for byte and asserts every reply shape core parses.
- PSO-005-R2. `turn/start` replies before the turn runs; the reply id equals the request id, integer or string.
- PSO-005-R3. `turn/start` during an active turn is accepted, answered with the active turn id, and forwarded to `driver.steer`.
- PSO-005-R4. `turn/completed` is emitted exactly once per turn, after every `item/created` and `usage/update` for that turn, and never after `turn/failed` for the same turn.
- PSO-005-R5. `turn/interrupt` produces `turn/completed` with `status:"interrupted"` in both `status` and `turn.status`.
- PSO-005-R6. `item/tool/call` requests use ids `aiur-tool-N`, are answered by matching id, and time out into a rejected `toolCall` promise without crashing the server.
- PSO-005-R7. Emitted frames never exceed 1 MiB; oversized content is truncated with a marker.
- PSO-005-R8. Stdin close closes every thread through the driver and exits 0; a driver throw during close is logged, not raised.
- PSO-005-R9. No method other than `initialize` succeeds before `initialize`.

Invariants: the protocol layer imports nothing from `src/paseo/**`; `AppServer` is constructed with a driver, never creates one.

## Refreshable implementation notes

- Map `DriverError` codes to JSON-RPC: `thread_not_found → -32001`, `invalid_params → -32602`, anything else `-32603` with the message; never leak stack traces.
- Emit `initialized` with `setImmediate` after the `initialize` reply is written, as aiur-claude does; core ignores it but tolerates it.
- Executor messages arrive as `turn/start` with a fresh integer id from `:erlang.unique_integer/1`; treat any `turn/start` for a thread with `activeTurn` as steer. Core's `OperatorDelivery` waits for the `{turn:{id}}` reply to confirm delivery.
- Keep the `turn_id` on every emitted notification; core's `Aiur.Claude.Transcript.claude_turn_id/1` reads it for row grouping.
- `Item.created_at` is epoch milliseconds; `Aiur.Claude.Transcript.timestamp_for/1` reads the notification timestamp, so exactness is not load-bearing.

### Key technical decisions

- `SessionDriver` splits protocol from Paseo so this ticket and PSO-006 run in parallel and the conformance suite never needs a daemon.
- Steer is `turn/start` on an active thread rather than aiur-claude's `turn/steer`, because that is what core sends (`Aiur.Claude.CodingAgent.send_operator_message/2`).
- Both completion status encodings are emitted because `TurnState` reads `params.turn.status` while the Claude adapter's earlier consumers read the flat field.

## Acceptance and verification

### Agent gate

`test/server/conformance.test.ts` with `FakeDriver` (records calls, scripts emissions, resolves `startTurn` on command):

- initialize reply shape and `initialized` notification ordering.
- `thread/start` before `initialize` → `-32000`; with missing cwd → `-32602`; with a file path → `-32602`; happy path returns `{thread:{id,created_at}}`; `surface` passthrough when the driver returns one; `dynamicTools` parsed and stored (malformed → `-32602`).
- `thread/resume` happy path; `thread_not_found` → `-32001`.
- `turn/start`: reply precedes any emission; `item/created`, `usage/update`, then `turn/completed` with both status fields; failed turn → `turn/failed`, no `turn/completed`; unknown thread → `-32001`; empty input → `-32602`.
- steer: second `turn/start` during an active turn replies the active id and `driver.steer` receives the text.
- interrupt: `turn/interrupt` → `driver.interrupt` called, completion `status:"interrupted"`; no active turn → `-32004`.
- tool round trip: `Emitter.toolCall` sends `item/tool/call` with `aiur-tool-1`, a client reply resolves it with the result envelope; error reply rejects; timeout rejects; unmatched response id is logged and ignored.
- truncation: 600 KiB text item is emitted under 1 MiB with the marker.
- shutdown: closing input calls `driver.close` for each thread once.
- `test/server/replay.test.ts`: feed the literal frames from "Context and evidence" through `startStdio` with `PassThrough` streams and assert the literal reply lines.
- Coverage 100% on `src/server.ts`, `src/driver.ts`, `src/tools/pending-calls.ts`.

### At-merge gate

- CI job `aiur-paseo` green; `npm run build` produces a binary that answers `initialize` over stdio (`printf '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{}}\n' | node dist/cli.js --provider claude`).

### Human/manual evidence

- Run the stdio smoke above and paste the reply on the PR.

## Failure, security, migration, and accessibility cases

- A driver exception inside an asynchronous turn must become `turn/failed`, never an unhandled rejection; add a process-level `unhandledRejection` handler that logs to stderr and exits 1 so core sees a port exit rather than a hang.
- Tool-call arguments and outputs may contain secrets; never log their bodies at default verbosity.
- No migration.

## Surfaces

- Reads: NDJSON requests on stdin.
- Writes: NDJSON replies and notifications on stdout; logs on stderr.
- Contracts: `SessionDriver`, `Emitter`, `ThreadInfo`, notification shapes above (consumed by PSO-009, PSO-010, PSO-011, and core).

## Sibling boundaries and open gates

PSO-009 implements `startTurn`/`steer`/`interrupt` over Paseo; PSO-010 starts the MCP bridge in `driver.start` and feeds `Emitter.toolCall`; PSO-011 implements `resume`, re-attach, and `surface`. None of them change dispatch here.

## Plan context

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
