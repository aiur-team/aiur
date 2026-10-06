---
ticket_id: MP-E3-C4-T02
feature_id: MP-E3
chunk_id: MP-E3-C4
bucket: 2-platform
title: "Executor background-agent roster from subagent and task hooks; unsupported, never zero"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C1-T02, MP-E3-C3-T01]
prior_units: [U3]
prior_boundaries: [EXE]
prior_features: []
prior_findings: [plan acceptance 6; RQ-E3-4, RQ-E3-6]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C4-T02 — Executor background agents

## Identity and outcome

- Bucket 2 · MP-E3 · C4 · T02.
- **User value:** the operator sees the Executor's background agents (Claude
  subagents and tasks, Codex subagents) — running or finished, with their last
  message — or a plain "not available for this harness".
- **Deliverable:** `Aiur.Executor.BackgroundAgents` projection: rows
  `%{agent_id, agent_type, state: :running | :finished, started_at, stopped_at,
  last_message (≤ 500 chars)}` or `:unsupported` with reason.
- **Non-goals:** opening subagent transcripts (RQ-E3-4: shown only if a later
  ticket proves `agent_transcript_path` stable; not in this ticket).

## Dependencies and blockers

- DESIGN-E3 (panel copy). MP-E3-C1-T02 (events).
- MP-E3-C3-T01 provides the Codex `SubagentStart/Stop` field set (RQ-E3-6);
  until then Codex is `:unsupported` with reason `fields_unverified`.

## Verified starting point

- Claude hooks: `SubagentStart` (`agent_id`, `agent_type`), `SubagentStop`
  (adds `agent_transcript_path`, `last_assistant_message`), `TaskCreated`,
  `TaskCompleted` (https://code.claude.com/docs/en/hooks, read 2026-10-06; plan
  §2.3). Codex has `SubagentStart/Stop`, fields unverified (plan §2.3).
- Codex rollouts also carry `SubAgentActivity` items with `agent_path`,
  `agent_thread_id`, `kind` (census in MP-E3-C3-T01) — a second source C3-T02
  can feed here.

## Chosen design

- Reducer over `{:executor_hook, %{event: "SubagentStart" | "SubagentStop" |
  "TaskCreated" | "TaskCompleted"}}`; rows keyed by `agent_id` (task id for
  tasks). Finished rows kept for the binding generation, capped at 200 (oldest
  dropped, count kept).
- `supported?(harness, cli_version)`: Claude 2.1.x → true; Codex → true only
  after C3-T01 recorded fields; otherwise `{:unsupported, reason}`.
- Projection output is `{:unsupported, reason}` or `{:ok, rows}`; an empty list
  only when supported and no agent has started (distinct from unsupported).

## Implementation steps

1. Reducer + holder (or fold into the C4-T01 holder process).
2. Optional Codex feed from `SubAgentActivity` items via C3-T02's extractor
   callback.

## Non-happy paths

- `SubagentStop` without a prior start (missed hook) → row created as finished,
  `started_at: nil`.
- Restart → rows are lost (in memory); the projection says "since <restart
  time>" (`observed_since`), never implies completeness.

## Compatibility and rollout

- Projection only. Rollback: revert.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur/executor/background_agents_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "codex before C3-T01 is unsupported, not []" | `{:unsupported, :fields_unverified}` | support check (mutation: return `{:ok, []}` fails — plan acceptance 6) |
| "start then stop yields one finished row with last message" | row | reducer |
| "stop without start" | finished row, nil start | clause |
| "projection carries observed_since after restart" | field present | field |

## Completion and handoff

- Dependents: MP-E3-C4-T05, MP-E3-C6-T03.
