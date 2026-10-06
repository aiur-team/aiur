---
ticket_id: MP-E7-C5-T01
feature_id: MP-E7
chunk_id: MP-E7-C5
bucket: 2-platform
title: "Async pull tool aiur_read_messages with a per-agent read cursor"
status: blocked
blocked_by: [DESIGN-E7, MP-E7-C3-T01, MP-E7-C3-T02, MP-E7-C3-T04, MP-R7-C3-T01]
repo: aiur-team/aiur
wave: 4
prior_units: [U3, U4]
prior_boundaries: [MSG (16), CA (20)]
prior_features: [MP-R7]
prior_findings: [MP-E7 plan E7-F1, E7-F3 (khala_read is paging, not a cursor)]
size_owner: AGENT_CORE (agent tool surface)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C5-T01 — `aiur_read_messages`: the async pull tool

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C5 async pull.
- **User value:** an agent in `async` mode is never interrupted or woken, yet
  can read the operator's messages when it chooses; read messages show as
  `read`, so the operator knows they were seen.
- **Deliverable:** one agent coordination tool, `aiur_read_messages`, exposed
  through the shared tool catalog to every harness that has a tool path
  (Codex dynamic tools, headless Claude via the `aiur-claude` MCP bridge,
  OpenAI-compatible tool loop, Muse session MCP — `muse/session.ex:75`), plus the per-agent cursor
  that acknowledges reads.
- **Non-goals:** unread count projection (C5-T02), mode-transition backlog
  handling (C5-T03), prompt guidance (C5-T04), any UI.
- **Name:** contract §7 says `read_messages`; every aiur tool is prefixed
  `aiur_` (`aiur_set_ticket_state`, `codex/dynamic_tool/ticket_state.ex:60`),
  so the tool is `aiur_read_messages`. Contract text to be aligned by the
  parent.

## Dependencies and blockers

- **DESIGN-E7** (feature gate; also E7-D3 if the Executor may read a worker's
  inbox — not in this ticket).
- **MP-R7-C3-T01** moves `Aiur.Codex.DynamicTool.*` to the agent tool
  surface; this ticket adds its handler at the new location. If R7-C3-T01 has
  not merged, the handler goes under `src/lib/aiur/codex/dynamic_tool/` and
  moves with it.
- **MP-E7-C3-T01/T02** define how an `async` arrival is held (the
  held-async marker on the queue item; never claimed by checkpoint/boundary
  drains). **MP-E7-C3-T04** defines the `read` receipt mapping.
- **May run concurrently with** C4-*, C6-*. C5-T02 and C5-T03 follow it.

## Verified starting point (at `45a290e3`)

- Tool catalog: `Aiur.AgentTools.Catalog.specs/0` = `DynamicTool.tool_specs/0`
  (`agent_tools/catalog.ex:7`); handlers implement
  `tools/0`, `specs/0`, `execute/3` (`codex/dynamic_tool/handler.ex:6-8`) and
  are listed in `@handlers` (`codex/dynamic_tool.ex:15`).
- Exposure: Codex `thread/start` `dynamicTools` (`codex/frames.ex:52`);
  headless Claude `thread/start` `dynamicTools` (`claude/coding_agent.ex:234`)
  which `aiur-claude` bridges over MCP (`claude-app-server src/server.ts`
  `--mcp-config`/`--allowedTools mcp__aiur__<name>`, :701-706 at `b1ea979c`);
  OpenAI-compat (`open_ai_compat/tool_spec.ex:109`); Muse session MCP
  (`muse/turn_loop.ex:4`, `Aiur.AgentTools.MCP`). `claude-repl` has none
  (`claude/repl/command.ex:27-36`, no `--mcp-config`).
- Per-call context is injected as callbacks in
  `AgentRunner.ToolExecutor` (`agent_runner/tool_executor.ex:103-140`).
- Queue items carry an increasing `sequence` and `id`
  (`agent_queue_item.ex:10-30`); statuses `pending | delivered | consumed |
  failed | superseded` (`:6`).
- Tests to extend: `src/test/aiur/codex/dynamic_tool_test.exs`,
  `src/test/aiur/codex/dynamic_tool/handler_test.exs`.

## Chosen design

- **Spec** (JSON schema, `additionalProperties: false`):
  `{ "max": integer 1..50 (default 50) }`. No client-supplied cursor: the
  daemon owns the cursor, so an agent cannot skip or replay by accident.
  Khala's `khala_read` pages history (`src/mcp/tools.ts:78-85` at
  `99e72a43`); aiur's tool is a consuming read, matching the contract's
  "acks by advancing a per-agent cursor".
- **Result:** `{ "messages": [{ "id", "text", "from": "operator"|"executor",
  "accepted_at" }], "remaining": n }`, oldest first, at most 50 messages and
  64 KiB of text (same limits as the hook frame, contract §8), UTF-8-safe
  truncation of the last message with a `truncated: true` flag.
- **Ack semantics:** the handler calls a new orchestrator API
  `Aiur.Orchestrator.read_held_messages(identifier, max)` (PROPOSED), which in
  one GenServer call selects the ticket's held-async items in `sequence`
  order, marks them `:consumed` with `read_at` (receipt `read`), records
  `last_read_sequence` on the ticket's listener record (C2 ModeStore,
  PROPOSED field), persists through `AgentQueueStore`, and returns them. The
  GenServer serialises reads, which gives the CAS property the contract asks
  for without a client cursor.
- **Mode check:** the tool works in any mode (an agent may drain held items
  after leaving `async`); in `sync`/`steer` it returns only held-async
  leftovers, never normal pending items (those belong to the scheduler).
- **Callback wiring:** `ToolExecutor` passes `message_reader: fn max ->
  Orchestrator.read_held_messages(issue.identifier, max) end`.

## Implementation steps

1. Handler module (PROPOSED `Aiur.AgentTools.ReadMessages`,
   `src/lib/aiur/agent_tools/read_messages.ex`, the namespace MP-R7-C3-T01
   moves `Codex.DynamicTool` into; `codex/dynamic_tool/read_messages.ex` if it
   lands before R7-C3-T01) with
   `tools/0`, `specs/0`, `execute/3`; add to `@handlers`.
2. Orchestrator API + `OperatorMessages.read_held_messages/3` (new function in
   a new module `orchestrator/operator_messages/held_reads.ex`, < 150 lines,
   because `operator_messages.ex` is already > 1,000 lines).
3. `ToolExecutor`: `message_reader` callback.
4. Broadcast a transcript event per read batch via
   `AgentPubSub.broadcast_transcript/2` (pattern
   `operator_messages.ex:1018-1028`) with `status: :read`.
5. Tests.

## Non-happy paths

- **No held messages:** `{messages: [], remaining: 0}`; not an error.
- **Orchestrator unavailable / timeout:** tool returns a failure response
  (`Response.failure/1`) with `retryable: true`; nothing is marked read.
- **Restart between select and persist:** the mark and persist happen inside
  one GenServer call before reply; a crash before reply leaves items unread
  (at-least-once to the agent is impossible — the reply never arrived).
- **Paused agent:** cannot call tools; nothing changes.
- **Harness without a tool path** (`claude-repl`): `pull_tool: false`, so the
  effective mode is never `async` there (contract §4); the tool is absent.
- **Gemini/ACP (RC-22, draft PR #2870, unmerged):** if merged, its adapter
  binds aiur MCP tools per turn (`gemini/turn.ex:17` at head `c1fc6f84`), so
  this tool reaches it through the shared catalog with no extra code;
  `(gemini, async)` becomes possible once this ticket lands.
- **Privacy:** the tool returns only this ticket's messages; the issue
  identifier comes from the executor context, never from tool arguments.

## Compatibility and rollout

Adds one tool to every agent's tool list (a visible change to agents, not
operators). Present regardless of routing flag; with `:legacy` routing there
are no held-async items, so it returns empty. Rollback: remove from
`@handlers`.

## Verification

- `read_messages_test.exs` (new, next to the handler):
  `"returns held messages oldest first and marks them read"` — two held items
  → both returned, both `:consumed` with `read_at`; second call returns `[]`.
  **Mutation:** skip the mark step → the second call returns them again → fails.
  `"never returns normal pending sync items"` — a pending non-held item is not
  returned. Mutation: drop the held-async filter → fails.
  `"caps at 50 messages and 64 KiB"`; `"rejects unknown arguments"`.
- `dynamic_tool_test.exs`: `"catalog includes aiur_read_messages"`.
- Command: `env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec --
  mix test test/aiur/codex/dynamic_tool_test.exs test/aiur/agent_tools
  test/aiur/orchestrator`.
- Manual (wrapper-tmux, `:listener` routing, Codex agent in `async`): send two
  messages; the chat pane shows no new turn; ask the agent (via a later sync
  message) to call the tool, or let it call on its own after C5-T04; the
  pane shows the `aiur_read_messages` tool call and both texts.

## Completion and handoff

- [ ] Tests and mutation checks in PR.
- [ ] Parent aligns contract §7 tool name (`aiur_read_messages`) and
  harness-adapter §3 `pull_tool` (codex/claude/openai-compat/muse: yes).
- Docs: C7-T05 adds the `aiur-agent` skill note.
- Dependents: C5-T02, C5-T03, C5-T04.
