# PSO-014 — Permission bridge: Paseo permission requests as aiur Decisions (optional)

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — two small protocol additions in the sidecar and one Decision round trip in core, with a tie-break rule to test

**Risk:** medium

**Phase hint:** 5

**Depends on:** PSO-009, PSO-012

**Serializes with:** none

**External gates:** none

**Requirements:** R9

**Decisions:** DEC-011

**Design evidence:** 00-design.md sections 5, 6, 7; 01-spike-report.md section 5

**Researched at:** aiur `8199f5373`, paseo `726067b4`, aiur-claude 1.1.0

**Suggested labels:** `complexity:3`, `model:claude`, `phase:5`, `build-lane:paseo-integration`; never `agent:todo`

## Outcome

When an operator runs a Paseo-owned agent in a prompting mode (`default`, `acceptEdits`, `plan` for Claude; `auto`, `auto-review` for Codex), each permission request becomes an aiur Decision with `allow` and `deny` options. Answering the Decision in aiur answers Paseo; answering on the phone first moots the Decision. Under the default modes (`bypassPermissions`, `full-access`) nothing here runs.

## Context and evidence

Paseo surfaces a blocked tool call as `agent_stream {type: "permission_requested", request}` and later `permission_resolved {requestId, resolution}` (`packages/protocol/src/messages.ts` lines 800-810); the snapshot carries `pendingPermissions: AgentPermissionRequest[]` (line 871). `AgentPermissionRequestPayloadSchema` (line 520): `{id, provider, name, kind: tool|plan|question|mode|other, title?, description?, input?, detail?, suggestions?, actions?, metadata?}`. The spike (section 5) captured a real one: `Write` with `input.file_path`, `detail {type: "write", filePath, content}`, `suggestions [{type: "setMode", mode: "acceptEdits"}]`, and the answer `respond_to_permission {agentId, requestId, response: {behavior: "allow"}}` returning `{success: true}` in 245 ms; the agent stayed `running` with `activeTurn` set while blocked. The client exposes `agent.respondToPermission({requestId, response})` (`packages/client/src/index.ts` line 338; `daemon-client.ts:5019`).

Core's Decision API: `Aiur.DecisionStore.request(payload, opts)` (`src/lib/aiur/decision_store.ex` line 134) with `opts[:ticket]` required as `%{identifier:, title:, url:}` and payload validated by `Aiur.DecisionValidation.normalize/2` (`src/lib/aiur/decision_validation.ex` lines 73-110): required `question` (string) and `blocking` (boolean); optional `kind`, `authority`, `urgency`, `reversibility`, `context`, `options` (each `{id, label}`), `recommendation {option_id}`, `consequence_of_delay`. Answers arrive through `DecisionStore.answer/3` and are dispatched back to the agent by `Aiur.DecisionDispatchTasks`; `DecisionStore.moot/3` (line 231) retires a Decision the world answered another way. Codex's app-server approvals show how core already services an approval-shaped request inside a turn loop (`src/lib/aiur/codex/approvals.ex`).

## Scope

### Sidecar

- In `session.ts`, on `permission_requested` during an active turn: emit notification `permission/requested {turn_id, thread_id, request: {id, provider, name, kind, title, description, input, detail, suggestions}}` (drop `actions`, `metadata`). Keep the turn open. Track `pendingPermissions: Map<requestId, request>`.
- On `permission_resolved {requestId}` (the phone or desktop answered): emit `permission/resolved {turn_id, request_id, resolution}` and drop it from the map.
- Accept a client request `permission/respond {threadId, requestId, response: {behavior: "allow"|"deny", message?}}` → `agent.respondToPermission({requestId, response})` → reply `{}`; unknown `requestId` → JSON-RPC error `-32602`.
- Auto-deny: if a request is still pending when `turnTimeoutMs` (PSO-009) elapses, respond `{behavior: "deny", message: "aiur: turn timeout"}` before failing the turn.

### Core (`Aiur.AppServer.GenericBackend`)

- `handle_method/5` clause for `"permission/requested"`: build the Decision payload `%{question: "<name> wants to <verb> <target>", kind: "permission", blocking: true, urgency: "high", options: [%{id: "allow", label: "Allow"}, %{id: "deny", label: "Deny"}], recommendation: %{option_id: "allow"} when the request kind is "tool" and detail.type in ["read", "search"], context: %{provider, name, input (redacted paths only), detail_type}}` and call `DecisionStore.request(payload, ticket: ticket_from_issue(issue), source: %{kind: :paseo_permission, request_id})`. Store `request_id → decision_id` in the loop state (`loop_state_extras/1`). Emit `:permission_requested` through `on_message`. Continue the loop (the turn stays open; this is not a checkpoint).
- Subscribe the turn loop to the Decision's answer: on `{:decision_answered, decision_id, %{option_id: "allow"|"deny"}}` (use the existing `Aiur.DecisionPubSub` topic; cite the topic constructor in the PR), send `permission/respond {threadId, requestId, response: {behavior}}`. Deny carries `message: "denied by Executor"`.
- On `"permission/resolved"` for a request that still has an open Decision: `DecisionStore.moot(decision_id, %{reason: "answered_in_paseo", resolution: resolution})`.
- Question text: `Write` → "Write wants to write <basename>"; `Bash` → "Bash wants to run `<command truncated 80>`"; `Edit` → "Edit wants to edit <basename>"; other → "<name> wants permission (<kind>)".

## Non-goals

- Changing default modes or making prompting modes the default.
- Answering permissions from the TUI directly; the Decision surface (dashboard, CLI `aiur decisions`) is the Executor's answer path.
- `question` and `plan` kinds beyond rendering them as a Decision with the same two options; richer option mapping is a follow-up.

## Existing owner and reuse target

`Aiur.DecisionStore`, `Aiur.DecisionValidation`, and `Aiur.DecisionDispatchTasks` are reused unchanged. `Aiur.AppServer.GenericBackend` (PSO-001) gains two `handle_method/5` clauses and a loop-state map. `session.ts` (PSO-009) gains the two notifications and one request handler.

## Contract and invariants

- First answer wins: an aiur answer after Paseo resolved is a no-op reply from the sidecar (`-32602` swallowed and logged); a Paseo answer after aiur answered is idempotent on Paseo's side.
- Exactly one Decision per `request.id`; a re-emitted `permission_requested` with the same id does not create a second Decision.
- A turn never completes with a pending permission; timeout denies first.
- Under `bypassPermissions` and `full-access` no `permission/requested` frame is ever produced; a test asserts the absence.

### Requirements

- PSO-014-R1. The sidecar forwards `permission_requested` and `permission_resolved` and accepts `permission/respond`.
- PSO-014-R2. Core creates one blocking Decision per request with allow and deny options and ticket context.
- PSO-014-R3. A Decision answer sends `permission/respond` with the matching behaviour.
- PSO-014-R4. A Paseo-side resolution moots the open Decision.
- PSO-014-R5. Pending permissions are denied at turn timeout.
- PSO-014-R6. Default modes produce no permission traffic.

## Refreshable implementation notes

- Check `Aiur.DecisionPubSub` for the answered-event shape and whether the turn loop process can subscribe without owning a GenServer; if not, poll `DecisionStore.get/2` on each incoming frame plus a 2 s tick, which is acceptable at this rate.
- Ticket map: reuse whatever `Aiur.Codex.DynamicTool.EmitEvent` builds for `decision.requested` so the Decision links to the issue the same way agent-raised Decisions do.
- Redact `input.content` (file bodies) from `context`; keep `file_path`, `command` (truncated), `pattern`.

### Key technical decisions

- Decisions, not attentions: a permission is a bounded question with two answers, which is exactly the Decision shape, and it already has dashboard, CLI, and Stream Deck surfaces.
- The sidecar keeps the turn open rather than failing it: Paseo holds the tool call until answered, so the turn is genuinely still running.

## Acceptance and verification

### Agent gate

- Sidecar tests with the fake daemon: scripted `permission_requested` → `permission/requested` frame; `permission/respond allow` → `respondToPermission` recorded and turn continues to `turn/completed`; scripted `permission_resolved` → `permission/resolved` frame; timeout with a pending request → deny recorded then `turn/failed`; unknown request id → `-32602`.
- Core tests with fake sidecar frames (the FakeDriver pattern from PSO-005 mirrored in Elixir with a scripted port, as `test/aiur/claude/coding_agent_test.exs` does): `permission/requested` → `DecisionStore.request` called once with `blocking: true` and two options; answering the Decision `allow` → `permission/respond` frame on the port; `permission/resolved` before answer → `moot` called; duplicate request id → one Decision.
- `make all`, `mix specs.check`, `npm test`, `npm run lint`, `npm run typecheck`.

### At-merge gate

- CI green on the exact head. The PSO-012 integration test gains one prompting-mode case (Claude `default` with a `Write`) exercising the full round trip.

### Human/manual evidence

- Real daemon, `.aiur/config` `agent.claude.permission_mode: default`, `model:paseo-claude` issue: the first `Write` shows as a Decision on the dashboard; answer `Allow`; the file appears and the turn continues. Repeat and answer on the phone first; the Decision shows as mooted. Attach both to the PR.

## Failure, security, migration, and accessibility cases

- Decision context never includes file contents or full command output.
- If `DecisionStore.request` fails (store read-only), the sidecar's timeout deny still bounds the turn; log the store error at warning.
- Deny is the safe default on every failure path.

## Surfaces

- Reads: Paseo `permission_requested`, `permission_resolved`; Decision answers.
- Writes: `permission/requested`, `permission/resolved`, `permission/respond` frames; Decisions; `moot`.
- Contracts: `Aiur.DecisionValidation` payload; `AgentPermissionRequestPayloadSchema`.

## Sibling boundaries and open gates

PSO-009 owns the turn window this bridge keeps open. PSO-012's proof is the base; this ticket extends it with one prompting-mode case. Optional: the build order completes without it.

## Plan context

- [Design and decisions](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/00-design.md)
- [Spike report](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/01-spike-report.md)
- [Pack index](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/paseo/README.md)
- [Requirements plan](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/plans/2026-09-09-001-feat-paseo-integration-plan.md)
- Your issue's native parent is the Build Order root; native `blockedBy` edges are the dependency graph — the root issue renders the full picture.
