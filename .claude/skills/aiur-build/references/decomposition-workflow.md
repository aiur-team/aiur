# Decomposition Workflow — the Aiur Layer

`build-order` owns the general decomposition method: its stages, their exit
criteria, ticket boundaries, sizing, the graph and its phases, validation, and
discovery policy. This document records only what the Aiur planning pack adds at
each stage — the records it writes, the validation that runs against them, and
the handoff it ends with. When this file and `build-order` disagree about a
general rule, `build-order` wins and this file is the defect.

## Contents

- Stage 0: identity, permissions, and pack location
- Stage 1: the evidence the pack keeps
- Stage 2: requirements and decisions the pack freezes
- Stage 5: the ticket document contract
- Stage 6: lanes, epics, and pack metadata
- Stage 7: Aiur validation of the pack
- Stage 8: Executor-owned GitHub promotion
- Stage 9: Executor handoff and stop

## Stage 0: identity, permissions, and pack location

Feature identity is stable before GitHub numbers exist. Choose a
repository-local slug for `aiur feature create`; map logical members to tracker
IDs only on promotion. Inspect the existing continuous build for real
cross-collection prerequisites before claiming a feature is independent.

Record in the pack:

- the feature slug, logical ticket prefix, and `plan_version`;
- the planning branch, and `questions-or-commands.md` for questions that cannot
  be answered synchronously;
- source precedence, commit/push permission, and GitHub ticket-promotion
  permission — separately, and never inferred;
- the researched repository SHA and the open PR/issue snapshot taken with it;
- the finite feature boundary and an empty deferred-findings ledger.

## Stage 1: the evidence the pack keeps

Keep evidence packets source-linked, and mark implementation notes refreshable
against `researched_at_commit`. For UI work, capture the external design into
the repository with original URL, import timestamp, file hash, viewport/theme
variants, and a delta/decision log: a mutable design URL is not durable
evidence. Record prototype/spec drift explicitly rather than resolving it
silently inside a ticket.

Research tracks, their number, and when to stop adding them are `build-order`'s.
The pack stores their output; it never stores live tracker or runtime state.

## Stage 2: requirements and decisions the pack freezes

Use `ce-brainstorm` after brownfield and design grounding. The pack freezes
requirement IDs, acceptance examples, invariants, resolved decisions with
rejected alternatives, and every open question whose answer changes the
architecture or a ticket boundary. An unanswered material question becomes an
owned gate in the pack, not a silent assumption.

Record the delta from the user's rough ticket estimate with per-boundary
justification: growing or shrinking the decomposition is expected, hiding the
change is not.

## Stage 5: the ticket document contract

Every executable member is a `tickets/<ID>.md` document following [the ticket
document template](planning-contract.md#ticket-document-template). Beyond that
template's headings, an executable ticket must carry:

- stable logical identity, kind, and provenance;
- implementation pointers — exact files to create or modify, module and
  function names, one worked fixture or data shape — verified against
  `researched_at_commit` and marked refreshable. A named reuse target that does
  not exist at the researched commit is a review-blocking defect;
- for each producer/consumer contract pair, one concrete interface sketch in the
  producer ticket (message JSON or struct typespec) that consumers quote
  verbatim;
- a plan-context navigation block linking the pack index, the graph/wave
  analysis, the decisions registry, and this ticket's implementation pointers,
  pinned to the approved planning commit;
- error, security, migration, and accessibility concerns where relevant;
- agent, at-merge, and human/manual evidence ownership;
- sibling boundaries and unresolved question gates.

Give every requirement and finding exactly one disposition: owned by one or more
tickets, deferred with reason, rejected with reason, or already satisfied with
evidence.

## Stage 6: lanes, epics, and pack metadata

General epics are the repository's cross-cutting areas (for example UI,
frontend, backend and docs), configured in `build_order.general_epics`. Features
are product slices, one per workstream. Give each workstream a distinct
Heroicons v2 outline `icon`, a one-line `summary` of at most 100 characters, and
an optional nonnegative integer or short-label `wave` in `build-order.json`.

General epic icons and feature icons must not overlap on any ticket: inspect the
target repository's configured general-epic label matchers and choose a
different feature icon for every matching ticket. The validator checks icon
names, uniqueness, and label-specific overlap. The legacy epic names `bug`,
`pen`, `server` and `docs` remain valid aliases.

Record the planned edges as Aiur facts, not as prose: a real start/merge
prerequisite becomes a native `blocked_by` link on promotion, a write-surface
conflict stays `serializes_with` in the pack, and advisory order becomes queue
position. The typed edges, phase leveling, wave profile and critical path are
`build-order`'s; the pack publishes them and the handoff names the fan-out
spine.

## Stage 7: Aiur validation of the pack

The bundled validator applies to legacy packs only; never invent a Build Order
root to satisfy it. Run it against a legacy pack and check the pack formats:

```bash
python3 .claude/skills/aiur-build/scripts/validate_build_order.py <pack>/build-order.json
python3 .claude/skills/aiur-build/scripts/publication/pack_format.py --check <packs…>
```

Commit a validation report with errors, warnings, reviewed SHA, artifact hashes,
and any accepted exceptions, then run the semantic review `build-order`
prescribes. Validate the collection records Aiur will publish: unique IDs, safe
document paths, a `product_features` partition that covers every published
ticket exactly once, resolved dependencies, and planned phase/complexity
metadata. A pack whose only defect is a stale live status table is reported as
stale, never corrected in prose.

The graph review that publication carries is rendered from `build-order.v1`, not
recomputed from the pack: run `scripts/render_build_order_review.py --build
<pack>/build-order.json --out <pack>/graph-review.md` (add `--from-daemon
[--root <n>]` to read live tracker and progress truth).

The pack stays the authored artifact; the document is what the review reads. The
renderer refuses a document that disagrees with the pack's typed edges, waves,
critical path or gates, and `publish_build_order.py --graph-review` refuses a
stale review.

## Stage 8: Executor-owned GitHub promotion

This stage requires issue-creation authority; reuse explicit authorization
already present in the run. Encourage promotion of every researched,
ready-to-begin member together; per-phase promotion remains optional. Follow
`SKILL.md` § Optional GitHub promotion and the linked continuous-build intake
procedure, including prioritized placement.

Create the feature collection and each selected issue from `tickets/<ID>.md`
verbatim with feature and disposition labels in the creation request. Record
tracker IDs, native prerequisites within and across collections, registry
ownership, and queue membership. Freeze promoted documents: subsequent edits go
to tickets. No new standalone Build Order root is created. Verify the
collection, labels, links, and effective queue order; record failures as
incomplete promotion.

## Stage 9: Executor handoff and stop

Write the durable handoff named in `SKILL.md` § Handoff and stop, and stop
there. Execution requires a separate `aiur-run` authorization.

Do not freeze PR verdicts, live agents, CPU values, current blockers, or
progress percentages into the handoff as durable truth. The runtime Executor
re-queries those at startup; a copied status table is a claim that goes stale
while it is read.
