---
title: feat: Replace conversation pane with opencode chat surface
type: feat
status: completed
date: 2026-05-19
origin: src/docs/opencode-pane-brainstorm.md
revised: 2026-05-20
revision_history:
  - 2026-05-19 v1 — initial draft
  - 2026-05-19 v2 — Mechanism D plugin dropped; `Aiur.Opencode.Protocol` isolation per R12; bridge as dedicated Bandit listener; queued-pane via existing `resume_agent/1`; security review SEC-001..006 integrated
  - 2026-05-20 v3 — turn-end signal sourced from `:turn_completed` in CodingAgent (not opencode `session.idle`) per FEAS-01; `Aiur.AgentPubSub.broadcast_turn_completed/1` added (FEAS-03); Bandit option fix to `thousand_island_options: [num_connections: …]` (FEAS-02); TranscriptRelay subscribes before reading file with timestamp-based dedup (FEAS-04); `:user` filter explicit in U4 streaming (FEAS-06); `/models` lockdown via opencode permission rules (ADV-R2-10); queued-pane retry race resolved with single-flight gate (ADV-R2-07); Bandit bind failure stays-up policy (ADV-R2-08)
  - 2026-05-20 v4 — second-round review applied: `opencode_os_pid` rename + `Port.info(:os_pid)` wiring; ISO8601 parse in promoted decoder; per-workspace bearer tokens; turn-id scoping on `broadcast_turn_completed/2`; idle watchdog on SSE stream; `:turn_input_required` handling; orphan-reap PID identity validation + read-before-materialize reorder; BridgeSupervisor `restart: :temporary`; queued-pane synthetic system message; placeholder shell during cold-start; `chat_completion_chunk` moved out of Protocol; bind-failure operator alert; composite dedup key `{timestamp, sequence}`; Authorization-header log redaction; honest cost accounting in Overview; Dependency Posture subsection added
archived: f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61 (U8-P25-T01)
---

# feat: Replace conversation pane with opencode chat surface

> Historical record. Full text: https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md

## Overview

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#overview)

## Problem Frame

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#problem-frame)

## Requirements Trace

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#requirements-trace)

## Scope Boundaries

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#scope-boundaries)

### Deferred to Follow-Up Work

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#deferred-to-follow-up-work)

## Context & Research

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#context--research)

### Relevant Code and Patterns

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#relevant-code-and-patterns)

### Institutional Learnings

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#institutional-learnings)

### External References

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#external-references)

## Key Technical Decisions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#key-technical-decisions)

## Open Questions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#open-questions)

### Resolved During Planning

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#resolved-during-planning)

### Deferred to Implementation

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#deferred-to-implementation)

## High-Level Technical Design

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#high-level-technical-design)

## Output Structure

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#output-structure)

## Implementation Units

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#implementation-units)

## System-Wide Impact

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#system-wide-impact)

## Dependency Posture

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#dependency-posture)

## Risks & Dependencies

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#risks--dependencies)

## Accepted Tradeoffs

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#accepted-tradeoffs)

## Documentation / Operational Notes

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#documentation--operational-notes)

## Sources & References

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-19-001-feat-opencode-pane-chat-plan.md#sources--references)

