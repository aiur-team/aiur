---
title: refactor: Slot-bound opencode instances with lazy chain pre-warm
type: refactor
status: active
date: 2026-05-21
deepened: 2026-05-21
origin: elixir/docs/brainstorms/2026-05-21-slot-bound-opencode-instances-requirements.md
archived: f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61 (U8-P25-T01)
---

# refactor: Slot-bound opencode instances with lazy chain pre-warm

> Historical record. Full text: https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md

## Overview

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#overview)

## Problem Frame

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#problem-frame)

## Requirements Trace

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#requirements-trace)

## Scope Boundaries

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#scope-boundaries)

### Deferred to Follow-Up Work

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#deferred-to-follow-up-work)

## Context & Research

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#context--research)

### Relevant Code and Patterns

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#relevant-code-and-patterns)

### Institutional Learnings

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#institutional-learnings)

### Probed opencode 1.15.6 behavior (resolves origin Q1/Q2)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#probed-opencode-1156-behavior-resolves-origin-q1q2)

## Key Technical Decisions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#key-technical-decisions)

## Open Questions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#open-questions)

### Resolved During Planning

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#resolved-during-planning)

### Deferred to Implementation

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#deferred-to-implementation)

## High-Level Technical Design

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#high-level-technical-design)

### Supervisor tree (changed parts)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#supervisor-tree-changed-parts)

### Slot state machine

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#slot-state-machine)

### Per-slot lifecycle on user pane open

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#per-slot-lifecycle-on-user-pane-open)

## Implementation Units

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#implementation-units)

## System-Wide Impact

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#system-wide-impact)

## Risks & Dependencies

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#risks--dependencies)

## Documentation / Operational Notes

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#documentation--operational-notes)

## Sources & References

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-002-refactor-slot-bound-opencode-instances-plan.md#sources--references)

