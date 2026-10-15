# Planning Contract

The planning pack records approved intent and evidence. It is not a second
ticket tracker: GitHub owns facts for promoted tickets and Aiur owns current
runtime facts.

Legacy pack JSON uses `scripts/publication/pack_format.py`: top-level keys and
array records each occupy one line; the publisher and CI share this formatter.

## Collection and evidence contract

A new feature outputs a collection into the repository's single continuous build.
Record its stable feature slug, display label, optional epics, logical members,
real prerequisites to new and existing tickets, proposed queue placement, and
`plan_version`. Do not create a standalone Build Order root or publish a new
legacy runtime pack. Existing packs remain readable history.

Preserve requirements, versioned design evidence, decisions, typed scheduling
graph, wave/critical-path analysis, `tickets/<ID>.md`, validation report, and
approved planning commit. Planning documents describe approved intent; they do
not supply current ticket state or progress.

## Executor-owned promotion

Promotion requires issue-creation authority. Encourage all researched members
ready to begin together; per-phase promotion is optional. Follow `SKILL.md`
§ Optional GitHub promotion and its continuous-build intake procedure.

Create each issue from its ticket document verbatim with feature and disposition
labels in the creation request. Record tracker-number mappings; freeze promoted
documents and edit the tickets thereafter. Join registry ownership with
`aiur feature add`, write native `blocked_by` links for real prerequisites,
and enqueue all executable members. A feature label alone does not schedule work.

Read back collection ownership, projected labels, native links, and queue order
in the continuous Build view or `aiur feature show` plus `aiur queue show`.
“Prioritize” requires priority labels and a queue position before the previous
next-up, naming the displaced work. Explicitly excluded work is parked with
`needs-triage`/`human:todo` and its reason. Partial promotion is incomplete.

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

Before handoff, validate unique IDs, safe document paths, tracker mappings,
resolved dependencies, and the planned phase/complexity metadata. Review the
graph for real prerequisites, one owner per public contract, bounded safety
conflicts, and explicit feature acceptance. Do not infer progress when live
membership or runtime evidence cannot establish it.

For promoted packs, completion requires collection and placement read-back.
Unpromoted packs record proposed membership and ordering without claiming live
verification; the Executor performs that rung during authorized promotion.

## Source-state rules

- A promoted ticket's tracker state and labels outrank the pack.
- A draft member remains proposed in its planning pack.
- Missing/stale Aiur progress is `unknown`, never `0%`.
- Provider failure preserves last-known-good data with visible health; unknown
  dependencies never become an empty or unblocked graph.
- Phases are computed antichains of the hard-dependency graph; lanes and epics
  carry thematic grouping, and summaries remain derived views.
