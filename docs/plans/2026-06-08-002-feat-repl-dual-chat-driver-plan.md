---
title: "feat: Persistent interactive-REPL driver for simultaneous dual-chat (opencode + Claude app RC)"
type: feat
status: active
date: 2026-06-08
origin: docs/brainstorms/2026-06-08-rc-dual-surface-handoff-requirements.md
archived: f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61 (U8-P25-T01)
---

# feat: Persistent interactive-REPL driver for simultaneous dual-chat

> Historical record. Full text: https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md

## Overview

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#overview)

## Problem Frame

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#problem-frame)

## Requirements Trace

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#requirements-trace)

## Scope Boundaries

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#scope-boundaries)

### Deferred to Follow-Up Work

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#deferred-to-follow-up-work)

## Context & Research

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#context--research)

### Relevant Code and Patterns

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#relevant-code-and-patterns)

### Institutional Learnings

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#institutional-learnings)

### External References

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#external-references)

## Key Technical Decisions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#key-technical-decisions)

## Open Questions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#open-questions)

### Resolved During Planning

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#resolved-during-planning)

### Resolved by U0 spike (2026-06-08, scratch REPL, claude 2.1.149, workspace `/tmp/aiur-spike-u0`)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#resolved-by-u0-spike-2026-06-08-scratch-repl-claude-21149-workspace-tmpaiur-spike-u0)

### Deferred to Implementation

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#deferred-to-implementation)

## High-Level Technical Design

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#high-level-technical-design)

## Implementation Units

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#implementation-units)

## System-Wide Impact

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#system-wide-impact)

## Risks & Dependencies

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#risks--dependencies)

## Documentation / Operational Notes

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#documentation--operational-notes)

## Phased Delivery

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#phased-delivery)

### Phase 1 — De-risk & foundation

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#phase-1--de-risk--foundation)

### Phase 2 — Turn lifecycle & instant delivery

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#phase-2--turn-lifecycle--instant-delivery)

### Phase 3 — Integration, opt-in config, hardening

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#phase-3--integration-opt-in-config-hardening)

### Phase 4 — Operator-facing controls (redesign 2026-06-08)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#phase-4--operator-facing-controls-redesign-2026-06-08)

## Sources & References

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-06-08-002-feat-repl-dual-chat-driver-plan.md#sources--references)

