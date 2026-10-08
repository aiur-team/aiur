---
ticket_id: MP-E6-C5-T01
feature_id: MP-E6
chunk_id: MP-E6-C5
bucket: 2-platform
title: Read-only assistant tools — get_status, read_recent_conversation, list_open_commands, end_conversation
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend, read-only tools)", MP-E6-C4-T02, MP-E6-C2-T03]
prior_units: []
prior_boundaries: [VOX, DEC]
prior_features: []
prior_findings: []
size_owner: n/a (new file `tools.ex`)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C5-T01 — Tool router and read tools

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C5 tools and drafts.
- **User value:** the assistant can look things up mid-conversation ("what did the agent say
  last?", "which Commands are open?") instead of guessing.
- **Deliverable:** `Aiur.VoiceConversation.Tools` (PROPOSED): tool specs for the provider
  (names, descriptions, JSON schemas), a router `handle(session, %ToolCall{})` and the four
  read-only tools. Every call and result is recorded (`tool_call`, `tool_result{summary}`)
  before the result is sent (contract §9).
- **Non-goals:** draft tools (C5-T02..T05).

## Dependencies and blockers

- **Predecessors:** C4-T02 (ports), C2-T03 (tool round trip).

## Verified starting point

Ports and sources as in MP-E6-C4-T02. No tool exists today.

## Chosen design

| Tool | Params | Result to provider (summary, ≤ 1,500 chars) |
| --- | --- | --- |
| `get_status` | none | one paragraph from the status port, with `observed <age>` |
| `read_recent_conversation` | `n` 1..30 (default 10) | last n messages, role-prefixed, each ≤ 300 chars, redacted |
| `list_open_commands` | none | numbered list: id, question, option labels |
| `end_conversation` | none | "ending"; session ends `user_end` after the reply audio drains |

- Port unavailable → result text "Status data unavailable" (or the matching phrase) with
  `is_error: false` so the assistant can say it; never an empty list that reads as "nothing
  open".
- Unknown tool name → `is_error: true`, "Unknown tool".
- Full payloads stay local (transcript `tool_result` keeps the summary; detail is
  re-derivable).

## Implementation steps

1. Specs and router; 2. four handlers; 3. tests with FakeProvider.

## Non-happy paths

Port timeouts (2 s, C4-T02) answer within the provider tool timeout (spike RQ-E6-2).

## Compatibility and rollout

Internal. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| "list_open_commands with the Command port absent says unavailable" | result text contains "unavailable"; not "No open Commands" |
| "read_recent_conversation clamps n and redacts" | n=500 → 30; token redacted |
| "every tool call is recorded before its result is sent" | transcript has `tool_call` then `tool_result` before FakeProvider sees `tool_result` |
| "unknown tool returns is_error" | — |

```bash
env -C src mise exec -- mix test test/aiur/voice_conversation/tools_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check (AGENTS.md unknown path).** Replace the unavailable branch with an empty
list: the first test fails.

## Completion and handoff

- [ ] Router + read tools.
- **Dependents:** C5-T02..T05, C3-T02 (tool specs uploaded to the agent).
