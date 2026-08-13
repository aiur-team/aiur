# Planning Contract

The planning pack records approved intent and evidence. It is not a second
ticket tracker: GitHub owns facts for promoted tickets and Aiur owns current
runtime facts.

## Runtime artifact tree

```text
~/.aiur/repo/<owner>/<repo>/builds/<slug>/
  build-order.json
  status.json                 # daemon-owned runtime projection
  tickets/<ID>.md             # draft issue body until promoted
```

The state node is host-local canonical runtime storage. Aiur also reads the
materialized repository discovery mirror that successful publication writes to
`.aiur/build_orders/<slug>.json`; a copied plan under `docs/` remains inert.

## Canonical pack

Each `build-order.json` member has the following fields:

```json
{
  "id": "AS-101",
  "title": "Wire the stream",
  "lane": "runtime",
  "phase": 1,
  "complexity": 2,
  "depends_on": [],
  "ticket": null,
  "doc": "tickets/AS-101.md",
  "icon": "bolt"
}
```

`ticket` is either `null` or a positive tracker issue number. `doc` must be a
safe relative path under `tickets/`. While `ticket` is `null`, the document is
the draft body and the pack supplies the planned state. Once a ticket exists,
its tracker state and labels are authoritative; `status.json` supplies only
known runtime state where the tracker projection lacks it.

An optional top-level `icon` chooses the Build Order icon. Without one, Aiur
selects a deterministic generic icon that is distinct from the other Build
Orders in that repository list. There is no converter: existing packs are
hand-converted once by the Executor.

## Executor-owned promotion

Promotion happens only when the user asks to create tickets. The Executor
should encourage promotion of all researched tickets that are ready to begin;
per-phase promotion is an optional user choice, not an Aiur workflow rule.

For every promoted member, create the issue using `tickets/<ID>.md` verbatim,
write the returned issue number to `ticket`, and freeze the document. **After
promotion, edits go to the ticket, never the doc.** No publication manifest,
receipt, or automatic materialization machinery is part of this flow.

## Ticket document template

```markdown
# AS-101 — Wire the stream

**Complexity:** 2
**Phase hint:** 1
**Depends on:** none

## Outcome

One observable result, phrased for an operator.

## Context and evidence

Why this work exists and links to durable evidence and decisions.

## Scope

- Exact behavior and contract this ticket owns.

## Non-goals

- Sibling behavior this ticket must not absorb.

## Existing owner and reuse target

Name the current subsystem, store, provider, or component to extend.

## Contract and invariants

Stable behavior, state precedence, error/freshness semantics, and public seams.

## Refreshable implementation notes

Likely files and mechanics tied to the researched commit. The worker refreshes
these at pickup without silently changing scope.

## Acceptance and verification

Agent, CI, and named human/manual evidence as required by repository policy.
```

## Validation invariants

Before handoff, validate unique IDs, safe document paths, ticket values,
resolved dependencies, and the planned phase/complexity metadata. Review the
graph for real prerequisites, one owner per public contract, bounded safety
conflicts, and explicit feature acceptance. Do not infer progress when live
membership or `status.json` cannot establish it.

Planning is complete only after the daemon's Build Order page renders the pack
title and members. This is the required verification rung.

## Source-state rules

- A promoted ticket's tracker state and labels outrank the pack.
- A draft member renders planned from its pack and draft document.
- Missing/stale Aiur progress is `unknown`, never `0%`.
- Provider failure preserves last-known-good data with visible health; unknown
  dependencies never become an empty or unblocked graph.
- Phase is authored planning metadata; topological layers and summaries are
  derived views.
