---
title: Issue 40 Per-Issue Summary Logs
status: completed
created: 2026-05-18
origin: https://github.com/its-everdred/aiur/issues/40
---

# Issue 40 Per-Issue Summary Logs

## Problem And Scope

Aiur already writes raw per-issue logs, but operators need a condensed,
append-only progress view for each active agent. This change adds per-issue
summary logs that are produced by system-level orchestration code, not by a
worker agent slot.

In scope:

- Create `<logs-root>/<repo>.<issue>.summary.log` next to the existing raw
  per-issue log.
- Summarize structured agent PubSub events into dated one-line bullets.
- Deduplicate repeated bullets and cap active files by rotating old content.
- Attach summary writers automatically when an issue run starts.

Out of scope:

- A future `aiur status` renderer.
- LLM-generated natural-language summaries.
- New workflow alert namespaces for summary events.

## Decisions

- Reuse `Aiur.AgentPubSub` instead of tailing raw log files. Structured events
  preserve alert names, command lifecycle markers, running state, and timestamps
  without parsing human log text.
- Implement the summarizer as `Aiur.IssueSummaryLog`, a GenServer supervised
  beside `Aiur.IssueLog`. This makes it system-level runtime work and keeps it
  outside `max_concurrent_agents`.
- Use one writer per active issue. This matches the existing raw log writer,
  avoids shared file contention, and keeps deduplication state issue-local.
- Rotate at a small line cap rather than truncating in place so summary files
  stay glanceable while preserving the previous window at `.summary.log.1`.

## Implementation Units

### U1: Summary Writer

Files:

- `elixir/lib/aiur/issue_summary_log.ex`
- `elixir/test/aiur/issue_summary_log_test.exs`

Behavior:

- Subscribe to the issue agent topic, running topic, and status topic.
- Convert phase alerts, commands, concise assistant reports, notable system
  messages, operator messages, running changes, and pane status changes into
  single-line bullets.
- Skip noisy transcript events and deduplicate equivalent recent bullets.
- Rotate the active summary file once it reaches the configured line cap.

Test scenarios:

- Phase alerts and command completion produce dated one-line bullets.
- Repeated equivalent events write only one bullet.
- Running-state broadcasts do not repeat unchanged status.
- Existing files at the cap rotate to `.summary.log.1`.

### U2: Runtime Attachment

Files:

- `elixir/lib/aiur.ex`
- `elixir/lib/aiur/agent_runner.ex`
- `elixir/mix.exs`

Behavior:

- Supervise the issue summary registry and dynamic supervisor.
- Attach both raw and summary log writers at the start of an issue run.
- Exclude the summary writer from coverage gates consistently with the current
  raw writer exemption.

Test scenarios:

- Existing alert/log behavior remains stable.
- Full compile, lint, and test gates pass.

## Verification

- Run `mix test test/aiur/issue_summary_log_test.exs`.
- Run the full Elixir test suite.
- Run compile/build and lint/format gates from `elixir/`.
- Manually run the `aiur` CLI against a local workflow and confirm a summary
  file is created and updated end-to-end.
