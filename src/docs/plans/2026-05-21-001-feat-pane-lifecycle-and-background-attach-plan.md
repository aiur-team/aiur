---
title: feat: Pane lifecycle, background attach, autonomous loop, and shutdown hardening
type: feat
status: active
date: 2026-05-21
deepened: 2026-05-21
origin: elixir/docs/brainstorms/2026-05-21-aiur-pane-lifecycle-and-background-attach-requirements.md
archived: f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61 (U8-P25-T01)
---

# feat: Pane lifecycle, background attach, autonomous loop, and shutdown hardening

> Historical record. Full text: https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md

## Overview

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#overview)

## Problem Frame

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#problem-frame)

## Requirements Trace

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#requirements-trace)

## Scope Boundaries

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#scope-boundaries)

### Deferred to Follow-Up Work

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#deferred-to-follow-up-work)

## Context & Research

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#context--research)

### Relevant Code and Patterns

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#relevant-code-and-patterns)

### Institutional Learnings

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#institutional-learnings)

### External References

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#external-references)

## Key Technical Decisions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#key-technical-decisions)

## Open Questions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#open-questions)

### Resolved During Planning

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#resolved-during-planning)

### Deferred to Implementation

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#deferred-to-implementation)

## High-Level Technical Design

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#high-level-technical-design)

### State machine for a single agent's pane

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#state-machine-for-a-single-agents-pane)

### Priority preemption in AttachQueue

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#priority-preemption-in-attachqueue)

### Shutdown defense layers

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#shutdown-defense-layers)

## Implementation Units

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#implementation-units)

## System-Wide Impact

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#system-wide-impact)

## Risks & Dependencies

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#risks--dependencies)

## Documentation / Operational Notes

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#documentation--operational-notes)

## Sources & References

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/src/docs/plans/2026-05-21-001-feat-pane-lifecycle-and-background-attach-plan.md#sources--references)

