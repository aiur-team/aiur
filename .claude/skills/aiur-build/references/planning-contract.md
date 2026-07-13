# Planning Contract

The planning pack preserves approved intent and evidence. After materialization,
GitHub owns current ticket facts; during execution, Aiur owns current runtime
facts.

## Contents

- Recommended artifact tree
- Canonical baseline record
- Ticket document template
- Validation invariants
- Source-state rules

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
  deferred-findings.md
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
parser. The complete canonical example is
[`build-order.example.json`](build-order.example.json); it is validated by the
skill's regression suite.

Top-level records are strict:

- schema, repository-scoped Build Order ID, ticket prefix, plan version,
  repository, and researched commit;
- controlled workstreams and deterministic GitHub label projection;
- optional returned GitHub root identity after materialization;
- finite feature boundary with acceptance, critical path, documentation,
  cleanup, end-to-end proof, and terminal condition;
- owned external gates;
- captured design evidence and explicit accepted/rejected decisions;
- requirements with exactly one disposition;
- complete ticket contracts; and
- capstone-owned epic acceptance evidence.

Each ticket record includes document path, observable outcome, scope, non-goals,
kind/provenance/version, workstream/phase/complexity/risk/capabilities,
requirement references, typed edges, external gates, read/write/contract/safety
surfaces, structured conflict exceptions, agent/at-merge/human acceptance, and
optional returned GitHub identity.

Allowed requirement dispositions are `ticket`, `deferred`, `rejected`, and
`satisfied`. `ticket` means one or more tickets own the requirement and requires
their IDs plus a null reason. Other dispositions require a non-empty reason and
no ticket IDs. Requirement-to-ticket traceability agrees in both directions.

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

Keep `github_reconciliation` null before publication. After publication it is a
bounded receipt from a fresh requery: timestamp, root node ID, exact direct
membership, exact native dependency edges, and the full observed label set for
the root and tickets. `label_projection.required_ticket_labels` defines static
routing labels; `forbidden_labels` defines labels that must be absent. The
validator requires projected labels, rejects projected-family drift and
forbidden dispatch states, and requires every GitHub mapping; it cannot prove
the remote query was honestly performed.

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

The graph validator fails when:

1. Build Order/version/repository/SHA or stable IDs are absent or duplicated.
2. Edge or requirement endpoints do not resolve, a self-edge exists, or the
   hard prerequisite graph has a cycle.
3. A dependent has an earlier phase hint than its prerequisite. Same-phase hard
   dependencies are valid because phase is a grouping hint, not readiness.
4. Independently ready tickets overlap declared safety surfaces without hard
   ordering, `serializes_with`, or a structured approved exception. Other
   surface overlap remains a warning that must be dispositioned.
5. A requirement lacks exactly one valid disposition.
6. A runnable node lacks complexity/rationale, provenance/version, risk, or
   requirement traceability.
7. An umbrella is counted as runnable work or hides an internal phase program.
8. No capstone owns feature-level acceptance evidence.
9. Captured design artifacts do not match their recorded hashes, decisions or
   design evidence are orphaned, or ticket references do not resolve.
10. Materialized mappings are partial or their reconciliation receipt drifts
    from membership, dependencies, or projected labels.

The command validates the canonical graph and referenced ticket/design files;
it is not a whole-pack verifier. The committed validation report must separately
record the approved planning commit, artifact hashes, generated-view/count
agreement, fresh GitHub requery evidence, and a prose/source-precedence review.

## Source-state rules

- A terminal GitHub issue state outranks stale `agent:*` labels.
- Conflicting workflow labels are data-quality warnings, not hidden choices.
- Missing/stale Aiur progress is `unknown`, never `0%`.
- Provider failure preserves last-known-good planning data with visible health
  and freshness; unknown dependencies never become an empty/unblocked graph.
- Phase is authored planning metadata; topological layer is a derived
  diagnostic, not a replacement.
- Reverse edges, ready sets, critical path, and status summaries are generated.
