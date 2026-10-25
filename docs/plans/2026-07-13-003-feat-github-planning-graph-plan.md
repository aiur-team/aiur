---
title: "feat: Fetch complete GitHub planning graph"
type: feat
date: 2026-07-13
status: active
origin: docs/brainstorms/2026-07-12-build-order-requirements.md
deepened: 2026-07-13
archived: f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61 (U8-P25-T01)
---

# feat: Fetch complete GitHub planning graph

> Historical record. Full text: https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md

## Summary

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#summary)

## Problem Frame

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#problem-frame)

## Requirements

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#requirements)

### Exact-head rework acceptance amendment

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#exact-head-rework-acceptance-amendment)

## Scope Boundaries

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#scope-boundaries)

### In scope

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#in-scope)

### Deferred for later

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#deferred-for-later)

### Outside this product's identity

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#outside-this-products-identity)

### Deferred to Follow-Up Work

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#deferred-to-follow-up-work)

## Assumptions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#assumptions)

## Key Technical Decisions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#key-technical-decisions)

## High-Level Technical Design

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#high-level-technical-design)

## System-Wide Impact

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#system-wide-impact)

## Implementation Units

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#implementation-units)

### U1. Define bounded planning-read configuration and result evidence

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#u1-define-bounded-planning-read-configuration-and-result-evidence)

### U2. Build fail-closed GraphQL pagination primitives

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#u2-build-fail-closed-graphql-pagination-primitives)

### U3. Normalize the independently valid root catalog

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#u3-normalize-the-independently-valid-root-catalog)

### U4. Fetch and validate a complete selected direct-member graph

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#u4-fetch-and-validate-a-complete-selected-direct-member-graph)

### U5. Expose the adapter without coupling it to tracker polling

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#u5-expose-the-adapter-without-coupling-it-to-tracker-polling)

### U6. Harden selected-root and connection provenance

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#u6-harden-selected-root-and-connection-provenance)

### U7. Preserve classified provider failure evidence

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#u7-preserve-classified-provider-failure-evidence)

## Risks and Mitigations

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#risks-and-mitigations)

## Dependencies and Sequencing

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#dependencies-and-sequencing)

## Validation Strategy

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/plans/2026-07-13-003-feat-github-planning-graph-plan.md#validation-strategy)

