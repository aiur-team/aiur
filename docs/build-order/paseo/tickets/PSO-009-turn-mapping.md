# PSO-009 — Turn mapping: turn/start to Paseo agent, timeline to item/created, completion and usage

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — the session driver is the sidecar's core: every frame aiur renders or acts on flows through this mapping, and turn boundaries must be exact

**Risk:** high

**Phase hint:** 3

**Depends on:** PSO-005, PSO-006

**Serializes with:** PSO-010, PSO-011 — all three edit `packages/aiur-paseo/src/session.ts`; land in order 009, 010, 011

**External gates:** none

**Requirements:** R6, R7, R8

**Decisions:** DEC-005, DEC-008, DEC-009, DEC-010

**Design evidence:** 00-design.md sections 5, 6, 7, 9; 01-spike-report.md sections 3, 4, 5, 8

**Researched at:** aiur `8199f5373`, paseo `726067b4`, aiur-claude 1.1.0

**Suggested labels:** `complexity:4`, `model:claude`, `phase:3`, `build-lane:paseo-sidecar`; never `agent:todo`

## Outcome

`packages/aiur-paseo/src/session.ts` implements the `SessionDriver` interface from PSO-005 over the Paseo client from PSO-006. A `thread/start` from aiur becomes one Paseo agent in aiur's workspace; each `turn/start` becomes one Paseo prompt; every Paseo timeline event becomes an `item/created` notification that `Aiur.Claude.Transcript` already renders; turn boundaries, usage, failure, and interrupt map to the exact `turn/completed` and `turn/failed` frames core expects. A message typed on the phone shows up in aiur as a `user` item with `source: "phone"`.

## Context and evidence

Core's consumer of this stream is `src/lib/aiur/claude/transcript.ex` (`event_from_item/4` clauses for `text`, `thinking`, `tool_call`, `tool_result`; a `user` clause is added by PSO-012) and `src/lib/aiur/app_server/turn_state.ex` (`turn_completion_status/1` reads `status` on `turn/completed`). aiur-claude 1.1.0 `src/server.ts` lines 640-830 are the reference emitter: `item/created {turn_id, item: {id, created_at, type, ...}}`, `usage/update {turn_id, usage}`, `turn/completed {turn_id, thread_id, status, usage, cost_usd}`.

Paseo's side, from `packages/protocol/src/messages.ts` (clone `726067b4`):

- `AgentStreamEventPayloadSchema` (line 762): `thread_started {sessionId, provider}`, `turn_started {turnId?}`, `turn_completed {turnId?, usage?}`, `turn_failed {turnId?, error, code?, diagnostic?}`, `turn_canceled {turnId?, reason}`, `timeline {item, turnId?}`, `permission_requested {request}`, `permission_resolved {requestId, resolution}`, `attention_required {reason: finished|error|permission}`.
- `AgentTimelineItemPayloadSchema` (line 708): `user_message {text, messageId?, clientMessageId?}`, `assistant_message {text, messageId?}`, `reasoning {text}`, `tool_call {callId, name, detail, status: running|completed|failed|canceled, error, metadata?}`, `todo {items}`, `error {message}`.
- `ToolCallDetailPayloadSchema` (lines 560-670): `shell {command, output?, exitCode?}`, `read {filePath, content?}`, `edit {filePath, ...}`, `write {filePath, content?}`, `search {toolName?, content?, filePaths?}`, `fetch`, `sub_agent`, `plain_text {text?}`, `plan {text}`, `unknown {output}`.
- Stream envelope: `agent_stream {agentId, event, timestamp, seq?, epoch?}` (line 3952).

Client API, `packages/client/src/index.ts`: `PaseoAgentCreateOptions {config, cwd, env?, prompt?, labels?, title?}` (line 224; `prompt` is optional, so an agent can be created idle), `PaseoAgentHandle.send(text, {messageId?})` (line 337), `subscribe(update => ...)` for `agent_update` snapshots (line 353), `timeline.subscribe(event => ...)` for `agent_stream` (line 310), `archive()` (line 351). Cancel is only on the low-level client: `daemon-client.ts:3262 cancelAgent(agentId)`.

Spike section 5 shows `snapshot.lastUsage = {inputTokens, cachedInputTokens, outputTokens, totalCostUsd?, contextWindowMaxTokens, contextWindowUsedTokens}` and status vocabulary `initializing | idle | running | error | closed`. Spike section 8 shows codex `lastUsage` has no `totalCostUsd`.

## Scope

- Implement `PaseoSessionDriver` in `src/session.ts` with `start`, `startTurn`, `steer`, `interrupt`, `close`. `resume` is PSO-011.
- `start(params)`: create the agent with no `prompt`, `config: {provider, model?, modeId, cwd: params.cwd, mcpServers: <from PSO-010, empty here>}`, `env: filteredEnv(process.env)` (every `AIUR_*` key plus `PATH`, `HOME`), `labels: {aiur_issue, aiur_repo, aiur_instance}`, `title: "aiur <identifier>: <title>"` cut to 60 chars. Re-attach lookup by labels is PSO-011; this ticket always creates.
- Subscribe to `agent.subscribe` and `agent.timeline.subscribe` immediately after create and keep both for the thread's life.
- `startTurn(threadId, prompt, model?)`: generate `turnId` (uuid), record `sentAt`, set `activeTurn`, call `agent.send(prompt, {messageId: turnId})`, and emit frames as events arrive. Resolve the turn on the first matching stream event: `turn_completed` → `turn/completed status "completed"`; `turn_failed` → `turn/failed {turn_id, error}`; `turn_canceled` → `turn/completed status "interrupted"`. Fallback predicate when no turn event arrives (older daemon, dropped frame): `agent_update` with `status === "idle"` and `updatedAt > sentAt` and at least one timeline item seen since `sentAt` → treat as completed. `status in {"error","closed"}` → `turn/failed`.
- `turnTimeoutMs` from `AIUR_PASEO_TURN_TIMEOUT_MS` (default 3600000): no stream event and no snapshot change for that long → `turn/failed {error: "turn_timeout"}` and `cancelAgent`.
- `steer(threadId, text)` for a `turn/start` that arrives while `activeTurn` is set: call `agent.send(text)`, return `{turn: {id: <new uuid>}}`, and do NOT open a second turn window; the reply belongs to the active turn. Record the observed daemon behaviour per provider in the ticket's PR (see Human evidence).
- Timeline mapping (one `item/created` per Paseo timeline item, `item.id = <agentId>:<seq>` or the Paseo `messageId`/`callId` when present, `created_at = Date.parse(timestamp)`):

| Paseo item | app-server item |
|---|---|
| `assistant_message {text}` | `{type: "text", text}` |
| `reasoning {text}` | `{type: "thinking", thinking: text}` |
| `tool_call status running` | `{type: "tool_call", tool_use_id: callId, name: mapName(detail, name), input: mapInput(detail)}` |
| `tool_call status completed\|failed\|canceled` | `{type: "tool_result", tool_use_id: callId, content: mapOutput(detail, error), is_error: status !== "completed"}` |
| `user_message {text}` not sent by this sidecar | `{type: "user", text, source: "phone"}` |
| `user_message` whose `messageId` or exact `text` matches a prompt this sidecar sent | dropped (aiur already has it) |
| `error {message}` | `{type: "text", text: "error: " + message}` and remembered for `turn/failed` |
| `todo`, `plan`, `worktree_setup`, unknown | dropped |

- `mapName`: `shell` → `"Bash"`, `read` → `"Read"`, `edit` → `"Edit"`, `write` → `"Write"`, `search` → `detail.toolName ?? "Grep"`, `fetch` → `"WebFetch"`, otherwise the Paseo `name`. `mapInput`: `shell` → `{command}`, `read`/`edit`/`write` → `{file_path: filePath, ...}`, `search` → `{pattern/query from detail}`, else `{}`. `mapOutput`: `shell` → `output ?? ""` plus `exit_code`, `write`/`read` → `content ?? ""`, `unknown` → `JSON.stringify(output)`, failed → `String(error)`.
- Each `tool_call` emits `tool_call` once (first `running` or first sight) and `tool_result` once (first terminal status); dedupe by `callId`.
- `usage/update {turn_id, usage}` on every `agent_update` whose `lastUsage` changed during a turn, and `turn/completed.usage` from the final one: `input_tokens = inputTokens`, `cache_read_input_tokens = cachedInputTokens`, `output_tokens = outputTokens`, `cache_creation_input_tokens = 0`, `total_tokens` = sum. `cost_usd = totalCostUsd` when present.
- `interrupt(threadId, turnId)`: `daemonClient.cancelAgent(agentId)`, then resolve the turn as `interrupted` on `turn_canceled` or after 5 s.
- `close(threadId)`: unsubscribe both subscriptions, `agent.archive()`. Never `kill`.
- Truncate any emitted string field above 256 KiB with a `… [truncated N bytes]` suffix; the aiur port line cap is 1 MiB (`Aiur.AppServer.Adapter.port_line_bytes/0`).

## Non-goals

- Re-attach by labels and `thread/resume` (PSO-011). Surface deep link (PSO-011).
- MCP server injection (PSO-010) beyond passing through a `mcpServers` map the driver receives in `start(params)`.
- Permission forwarding beyond emitting nothing: a `permission_requested` event is logged to stderr and the turn stays open (PSO-014 adds the bridge).
- `rate_limit/update`; Paseo exposes no rate-limit signal.

## Existing owner and reuse target

`src/server.ts` (PSO-005) owns the protocol and calls the driver; `src/paseo/client.ts` (PSO-006) owns the WebSocket connection and typed wrappers; `src/paseo/fake-daemon.ts` (PSO-006) is the test double. This ticket adds only `src/session.ts` and `src/timeline-map.ts` (pure mapping functions) plus tests.

## Contract and invariants

- Exactly one `turn/completed` or `turn/failed` per `turn/start` that opened a turn window. A steer never produces its own completion frame.
- `item/created` frames for a turn are emitted before that turn's `turn/completed`. Events that arrive after completion but before the next `turn/start` are emitted with the completed turn's id.
- No frame is emitted twice for the same Paseo `seq`.
- The sidecar's own prompts never come back as `user` items.
- All `item.text`, `thinking`, `content` fields are strings, never null.

### Requirements

- PSO-009-R1. `start` creates one Paseo agent in `params.cwd` with the labels, title, env, mode, model, and provider from the `thread/start` params and the CLI flags.
- PSO-009-R2. `startTurn` sends the prompt and resolves on the Paseo `turn_completed`, `turn_failed`, or `turn_canceled` stream event for that agent, with the idle-snapshot fallback and the timeout.
- PSO-009-R3. Every Paseo timeline item maps to the table above, deduplicated by `seq` and `callId`.
- PSO-009-R4. Phone-originated user messages become `user` items with `source: "phone"`; sidecar-sent prompts are not echoed.
- PSO-009-R5. Usage maps to aiur-claude keys on `usage/update` and `turn/completed`.
- PSO-009-R6. A `turn/start` during an active turn is a steer: one `send`, no new turn window.
- PSO-009-R7. `interrupt` cancels the Paseo run and completes the turn as `interrupted`.
- PSO-009-R8. Emitted strings are capped at 256 KiB.

## Refreshable implementation notes

- Keep the mapping pure in `src/timeline-map.ts` (`mapTimelineItem(event, ctx) => AppServerItem[]`, `mapUsage(lastUsage)`) so it is unit-testable without a daemon.
- Keep a per-thread `sentPrompts: Map<messageId, text>` and a bounded set of the last 32 prompt texts for the exact-text fallback.
- The `agent_stream.seq` is monotonic per epoch; on a `replacement` event (epoch change, `index.ts:287`) reset the dedupe set and log.
- Node 22 `AbortController` for the timeout; clear it on any event.
- Log every dropped item kind once per thread at debug level.

### Key technical decisions

- Turn boundary from Paseo's `turn_*` stream events, with the idle-snapshot rule only as fallback: the stream events carry `turnId` and `usage` and arrive before the snapshot update.
- One turn window at a time per thread; steers join it. Matches how `Aiur.Claude.CodingAgent.send_operator_message/2` sends a second `turn/start` and how core treats `immediate_delivery: true` (DEC-010).
- `archive` not `kill` on close so the Paseo app keeps the conversation readable after the issue finishes.

## Acceptance and verification

### Agent gate

- `npm test` in `packages/aiur-paseo` with fake-daemon scenarios, each asserting the exact frame sequence on stdout:
  - happy path: `thread/start` → `create_agent_request` recorded with cwd, labels, env; `turn/start` → `send` recorded; scripted `timeline` items → `item/created` frames in order; `turn_completed` → `usage/update` then `turn/completed {status: "completed", usage, cost_usd}`.
  - mid-turn steer: second `turn/start` while active → one more `send`, reply `{turn: {id}}`, still one `turn/completed`.
  - phone message: scripted `user_message` with foreign `messageId` → `item/created {type: "user", source: "phone"}`; scripted echo of the sidecar's own prompt → no frame.
  - tool mapping: `shell` running then completed → `tool_call` then `tool_result` with `exit_code`; `write` → `Write` with `file_path`; failed tool → `is_error: true`.
  - usage mapping for claude (`totalCostUsd` present) and codex (absent).
  - `turn_failed` → `turn/failed {error}`; snapshot `status: "closed"` mid-turn → `turn/failed`.
  - `interrupt` → `cancelAgent` recorded → `turn/completed {status: "interrupted"}`.
  - timeout with `AIUR_PASEO_TURN_TIMEOUT_MS=200` → `turn/failed {error: "turn_timeout"}` and `cancelAgent`.
  - 300 KiB assistant text → truncated with suffix; frame under 1 MiB.
  - duplicate `seq` replay → no duplicate frame.
- `npm run lint`, `npm run typecheck`; coverage thresholds from PSO-004's vitest config.

### At-merge gate

- Package CI job green; core `make all` untouched (no Elixir changes in this ticket).
- PSO-010 and PSO-011 rebase onto this `session.ts`.

### Human/manual evidence

- Against a real daemon (`PASEO_HOST`, `PASEO_PASSWORD` set), run `node dist/cli.js --provider claude` by hand, paste the `initialize`, `thread/start`, `turn/start` frames from 00-design.md section 6, and attach the stdout transcript to the PR. Repeat with `--provider codex`. Record in the PR whether a steer during a running turn was queued (reply after the current answer) or injected (answer references it mid-turn) for each provider; this is the evidence DEC-010 asks for.

## Failure, security, migration, and accessibility cases

- Daemon disconnect mid-turn: `turn/failed {error: "paseo_disconnected"}`; the driver does not reconnect inside a turn.
- Never log `PASEO_PASSWORD`, the bearer subprotocol, or full env maps; log env key names only.
- `env` forwarded to Paseo is filtered to `AIUR_*`, `PATH`, `HOME`, `TMPDIR`, `XDG_RUNTIME_DIR`; provider credentials never pass through the sidecar (the daemon owns provider auth).
- Text truncation must cut on a UTF-8 boundary.

## Surfaces

- Reads: aiur `thread/start` and `turn/start` params; Paseo `agent_update` and `agent_stream`.
- Writes: Paseo `create_agent_request`, `send_agent_message_request`, `cancel`, `archive`; app-server notifications on stdout.
- Contracts: 00-design.md section 6 frame table; `Aiur.Claude.Transcript` item types.

## Sibling boundaries and open gates

PSO-010 adds the MCP bridge and the `mcpServers` map. PSO-011 adds re-attach, `thread/resume`, and `thread.surface`. PSO-012 proves the whole path in Elixir and adds the `user` transcript clause in core. PSO-014 turns `permission_requested` into Decisions.

## Plan context

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
