# Planning Contract

The planning pack preserves approved intent and evidence. After materialization,
GitHub owns current ticket facts; during execution, Aiur owns current runtime
facts.

## Recommended artifact tree

```text
docs/build-orders/<slug>/
  README.md
  questions-or-commands.md
  00-brief-and-requirements.md
  01-research-index.md
  02-current-target-delta.md
  03-technical-decisions.md
  04-test-and-rollout.md
  evidence/
  build-order.json
  tickets/<ID>-<slug>.md
  validation-report.md
  EXECUTOR-HANDOFF.md
```

`README.md` is a generated/read-first index and authority map. It must not claim
that copied status is live.

## Canonical baseline record

`build-order.json` uses standard JSON so the bundled validator needs no external
parser. Minimum shape:

```json
{
  "schema_version": 1,
  "build_order_id": "owner/repo:feature-slug",
  "plan_version": 1,
  "repository": "owner/repo",
  "researched_at_commit": "40-character-git-sha",
  "requirements": [
    {
      "id": "REQ-001",
      "summary": "Operator can select one Build Order",
      "disposition": "ticket",
      "ticket_ids": ["BO-004"]
    }
  ],
  "tickets": [
    {
      "id": "BO-004",
      "kind": "executable",
      "provenance": "planned",
      "introduced_in_plan_version": 1,
      "title": "Render selectable Build Orders",
      "phase_hint": 2,
      "complexity_points": 3,
      "complexity_rationale": "New presenter and interactive selector",
      "risk": "medium",
      "capability_requirements": ["frontend"],
      "requirement_refs": ["REQ-001"],
      "depends_on": [],
      "serializes_with": [],
      "suggested_after": [],
      "read_surfaces": ["GitHub Build Order snapshot"],
      "write_surfaces": ["dashboard Build Order components"],
      "contract_surfaces": ["BuildOrderPresenter view model"],
      "github": null
    }
  ],
  "epic_acceptance": {
    "owner_ticket_id": "BO-010",
    "evidence": ["Merged-base end-to-end dashboard acceptance"]
  }
}
```

Allowed requirement dispositions are `ticket`, `covered`, `deferred`,
`rejected`, and `satisfied`. `ticket` and `covered` require at least one ticket
ID. Other dispositions require a non-empty `reason`.

Allowed ticket kinds are `executable`, `audit`, `gate`, `umbrella`, and
`capstone`. Every runnable kind needs complexity and acceptance metadata in its
ticket document. Umbrellas are not dispatchable work.

`github`, once materialized, should contain returned identity rather than an
expected number:

```json
{
  "repository": "owner/repo",
  "number": 1234,
  "node_id": "I_kw...",
  "url": "https://github.com/owner/repo/issues/1234"
}
```

## Ticket document template

```markdown
# BO-004 — Render selectable Build Orders

**Kind:** executable  
**Provenance:** planned in plan v1  
**Complexity:** 3 — New presenter and interactive selector  
**Risk:** medium  
**Phase hint:** 2  
**Depends on:** BO-002  
**Serializes with:** none  
**Requirements:** REQ-001, REQ-004  
**Researched at:** <commit>

## Outcome

One observable result, phrased for an operator.

## Context and evidence

Why this work exists and links to durable evidence/decisions.

## Scope

- Exact behavior and contract this ticket owns.

## Non-goals

- Sibling behavior this ticket must not absorb.

## Existing owner and reuse target

Name the current subsystem/store/provider/component to extend.

## Contract and invariants

Stable behavior, state precedence, error/freshness semantics, and public seams.

## Refreshable implementation notes

Likely files and mechanics tied to the researched commit. The worker refreshes
these at pickup without silently changing scope.

## Acceptance and verification

### Agent gate

Checks the worker can run in its issue workspace.

### At-merge gate

Checks requiring current base, integration environment, or central CI.

### Human/manual evidence

Named owner and exact user-visible evidence when required by repository policy.

## Failure, security, migration, and accessibility cases

Only relevant concerns; explicitly say when none apply.

## Surfaces

- Reads:
- Writes:
- Contracts:

## Sibling boundaries and open gates

What adjacent tickets own and any question that blocks pickup.
```

## Validation invariants

The pack fails validation when:

1. Build Order/version/repository/SHA or stable IDs are absent or duplicated.
2. Edge or requirement endpoints do not resolve, a self-edge exists, or the
   hard prerequisite graph has a cycle.
3. A dependent has an earlier/equal phase hint than its prerequisite without a
   documented exception.
4. Independently ready tickets overlap write/contract surfaces without hard
   ordering or `serializes_with`.
5. A requirement lacks exactly one valid disposition.
6. A runnable node lacks complexity/rationale, provenance/version, risk, or
   requirement traceability.
7. An umbrella is counted as runnable work or hides an internal phase program.
8. No capstone owns feature-level acceptance evidence.
9. Design hash/import metadata, researched SHA, or required approval commit is
   absent from the research/validation report.
10. Generated ticket counts, tables, diagrams, and the canonical record differ.
11. GitHub mappings or relationships do not requery successfully after
    materialization.
12. Planning prose claims live agent/progress state or contradicts the declared
    source precedence.

## Source-state rules

- A terminal GitHub issue state outranks stale `agent:*` labels.
- Conflicting workflow labels are data-quality warnings, not hidden choices.
- Missing/stale Aiur progress is `unknown`, never `0%`.
- Provider failure preserves last-known-good planning data with visible health
  and freshness; unknown dependencies never become an empty/unblocked graph.
- Phase is authored planning metadata; topological layer is a derived
  diagnostic, not a replacement.
- Reverse edges, ready sets, critical path, and status summaries are generated.
