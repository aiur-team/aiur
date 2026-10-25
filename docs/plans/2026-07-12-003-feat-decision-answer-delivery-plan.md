---
title: "feat: Add durable decision answer delivery"
type: feat
status: completed
date: 2026-07-12
origin: docs/operator-control-center/00-prd.md
deepened: 2026-07-12
archived: f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61 (U8-P25-T01)
---

# feat: Add durable decision answer delivery

> Historical record. Full text: https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md

## Summary

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#summary)

## Problem Frame

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#problem-frame)

## Assumptions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#assumptions)

## Requirements

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#requirements)

## Scope Boundaries

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#scope-boundaries)

### Deferred to Follow-Up Work

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#deferred-to-follow-up-work)

## Context & Research

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#context--research)

### Relevant Code and Patterns

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#relevant-code-and-patterns)

### Institutional Learnings

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#institutional-learnings)

### External References

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#external-references)

## Key Technical Decisions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#key-technical-decisions)

## Open Questions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#open-questions)

### Resolved During Planning

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#resolved-during-planning)

### Deferred to Implementation

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#deferred-to-implementation)

## High-Level Technical Design

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#high-level-technical-design)

## Implementation Units

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#implementation-units)

### U1. Extend the canonical audit and projection with lifecycle events

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#u1-extend-the-canonical-audit-and-projection-with-lifecycle-events)

### U3. Add correlated idempotency to the existing operator queue

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#u3-add-correlated-idempotency-to-the-existing-operator-queue)

### U2. Add persist-before-dispatch answer and recovery APIs

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#u2-add-persist-before-dispatch-answer-and-recovery-apis)

### U4. Correlate transport settlement and failure attentions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#u4-correlate-transport-settlement-and-failure-attentions)

### U5. Add explicit acknowledgement and resolution at agent ingress

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#u5-add-explicit-acknowledgement-and-resolution-at-agent-ingress)

### U6. Prove the end-to-end contract and document the handoff

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#u6-prove-the-end-to-end-contract-and-document-the-handoff)

## System-Wide Impact

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#system-wide-impact)

## Alternative Approaches Considered

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#alternative-approaches-considered)

## Risk Analysis & Mitigation

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#risk-analysis--mitigation)

## Documentation / Operational Notes

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#documentation--operational-notes)

## Sources & References

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-12-003-feat-decision-answer-delivery-plan.md#sources--references)

