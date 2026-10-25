---
title: "feat: Add canonical usage ledger"
type: feat
status: completed
date: 2026-07-15
origin: docs/brainstorms/2026-07-12-build-order-requirements.md
archived: f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61 (U8-P25-T01)
---

# feat: Add canonical usage ledger

> Historical record. Full text: https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md

## Summary

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#summary)

## Problem Frame

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#problem-frame)

## Assumptions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#assumptions)

## Requirements

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#requirements)

## Scope Boundaries

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#scope-boundaries)

### Deferred to Follow-Up Work

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#deferred-to-follow-up-work)

## Context & Research

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#context--research)

### Relevant Code and Patterns

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#relevant-code-and-patterns)

### Institutional Learnings

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#institutional-learnings)

### External References

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#external-references)

## Key Technical Decisions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#key-technical-decisions)

## Open Questions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#open-questions)

### Resolved During Planning

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#resolved-during-planning)

### Deferred to Implementation

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#deferred-to-implementation)

## Output Structure

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#output-structure)

## High-Level Technical Design

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#high-level-technical-design)

## Implementation Units

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#implementation-units)

### U1. Define the ledger seam and pure counter policy

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#u1-define-the-ledger-seam-and-pure-counter-policy)

### U2. Add contained record, checkpoint, and recovery storage

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#u2-add-contained-record-checkpoint-and-recovery-storage)

### U3. Implement the supervised single writer and acknowledgement boundary

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#u3-implement-the-supervised-single-writer-and-acknowledgement-boundary)

### U4. Register the daemon child without changing transient compatibility ownership

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#u4-register-the-daemon-child-without-changing-transient-compatibility-ownership)

### U5. Prove recovery, permission, and replay invariants end to end

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#u5-prove-recovery-permission-and-replay-invariants-end-to-end)

## System-Wide Impact

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#system-wide-impact)

## Risks & Dependencies

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#risks--dependencies)

## Documentation / Operational Notes

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#documentation--operational-notes)

## Sources & References

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-15-002-feat-canonical-usage-ledger-plan.md#sources--references)

