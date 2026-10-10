---
ticket_id: MP-E6-C5-T01
feature_id: MP-E6
chunk_id: MP-E6-C5
bucket: 2-platform
title: Read-only assistant tools — get_status, read_recent_conversation, list_open_commands, end_conversation
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: backend, read-only tools)", MP-E6-C4-T03]
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

## Amendment 2026-10-08 — fast voice over a slow agent

Source: [../realtime-convo-research.md](../realtime-convo-research.md) (Kevin's request of
2026-10-08: voice with high-effort agents is "extremely slow and broken up"). Context-handoff
requirement: the voice assistant must be able to answer from a current briefing in about one
second, without stopping or waiting for the coding agent.

- `get_status` answers from the status card (MP-E6-C10-T02), with field ages.
- Add `get_details(section)` with sections `conversation` (replaces
  `read_recent_conversation`; same `n` param), `pr` (title, diff stat, review state),
  `ci` (failing job names and the last 40 redacted log lines), `plan` (the workpad excerpt).
  All local reads; target ≤ 300 ms per call so the assistant answers without filler.

## Amendment 2026-10-09 — independent package

Source: [../plan.md](../plan.md) §17. Kevin, 2026-10-09: build the voice assistant as "its own
independent package that can be used separately from [aiur]". The core is the Mix project
`packages/elixir/voice_converse/` (OTP app `:voice_converse`, namespace `VoiceConverse.*`).
It has no `Aiur.*` reference, and aiur is one host behind ports (§17.4). Module moves:
plan §17.9. Core tests run with `env -C packages/elixir/voice_converse mise exec -- mix test`
and do not boot aiur.

- Home: `VoiceConverse.Tools`. The `get_details(section)` schema is built from
  `BriefingSource.sections/1`, so a host decides which sections exist. aiur offers
  `conversation`, `pr`, `ci` and `plan`; the example host offers `notes`.
  `list_open_commands` is offered only when `CommandSource` is configured. Without it, the
  "Command data unavailable" gap is stated (test unchanged in intent).

## Amendment 2026-10-10 — /talk and native providers

Source: [../plan.md](../plan.md) §19 (/talk skill) and §20 (native providers and preferences). Kevin, 2026-10-10 (verbatim): "earlier i asked about making convo mode usable by executors, i even want to usable by any agent via a skill separate from aiur" and "just to flag, i originally said i only wanted air convo to support eleven, this means full support for native model convo wrappers to use model APIs in aiur too and .config settings to choose preferences".

- **Dependency re-cut:** the read tools are core and run against fake ports and the fake provider; they no longer wait for C4-T02 (aiur port) or C2-T03 (ElevenLabs mapping, spike).
