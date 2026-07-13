# GitHub Publication Plan and Receipt

## Status

Publication is the final planning action. Do not launch Aiur, add a dispatch
label, implement a ticket, or merge either planning branch.

## Materialization set

1. Requery open and closed issues for hidden logical-ID markers and overlapping
   work (#132, #845, #1033, #1034 and #1067). This is read-only; do not mutate
   the existing issues.
2. Create or reconcile one non-dispatchable root for
   `its-everdred/aiur:build-order-dashboard` from `root-issue.md`.
3. Create/reconcile BO-001 through BO-015 from the approved ticket documents.
4. Add the fifteen BO issues as direct native sub-issues without silently
   replacing an existing parent.
5. Publish every BO `depends_on` relationship as native `blockedBy`.
6. Create/reconcile DASH-001 through DASH-015 as standalone issues from
   `dashboard-companions.json` and their documents.
7. Publish companion hard prerequisites as native blockers, including
   cross-scope BO prerequisites, while leaving companions outside the root.
8. Create/reconcile the separate human-blocked skill-delivery issue from
   `skill-delivery.md` and `publication.json`; it references draft PR #1065 and
   is not feature work.
9. Publish the skill-delivery issue as a native external blocker of BO-001 so
   the exact Executor contract must land before feature dispatch; it remains
   outside root membership and the feature denominator.
10. Requery full label sets, returned identities, parenthood and every native
    blocker. Prove the root, skill-delivery issue, and every companion are
    parentless while all BO tickets have the intended direct root. Populate all
    three structured receipts with RFC3339 UTC check times and run the
    canonical plus publication validators.

All 32 created bodies link to the immutable approved planning commit and carry
one canonical `aiur-planning-issue` marker with schema 2, logical ID, plan
version, and that same commit. Requery each body, parse the marker and link, and
record its SHA-256; do not trust the submitted body. The approval SHA must
resolve to a real commit in this repository before the first issue mutation.

Once the root exists, create one uniquely marked
`aiur-build-order-reconciliation` comment whose visible and marker state is
`pending`. Requery it and record a structured receipt containing its URL,
marker, pending state, and body SHA-256. After all relationships requery
successfully, commit and push that receipt, then edit the same comment to link
the immutable receipt and declare `successful`. Requery the final live comment;
the final comment edit is the last publication mutation. This two-commit
authority preserves reviewed scope while giving the immutable handoff a live
route to the eventual receipt. A conflicting marker, parent, receipt comment,
or existing identity stops publication for reconciliation; never use a
replacement-parent mutation as a shortcut.

Generated BO and DASH bodies use the approved ticket document verbatim beneath
this preamble and marker:

```markdown
> Approved planning authority: [`<APPROVED_SHA>`](https://github.com/its-everdred/aiur/commit/<APPROVED_SHA>)

<!-- aiur-planning-issue
{"schema":2,"logical_id":"<LOGICAL_ID>","plan_version":1,"approved_planning_commit":"<APPROVED_SHA>"}
-->
```

## Label contract

Root:

- `build-order` only from the planning/routing family;
- no `model:*`, `complexity:*`, `phase:*`, `build-lane:*` or `agent:*`.

BO-001 through BO-015:

- exactly one `complexity:N`;
- `model:codex`;
- exactly one `phase:N`;
- exactly one `build-lane:documentation|frontend|backend|infrastructure`;
- no active `agent:*` state.

DASH-001 through DASH-015:

- exactly one `complexity:N` and `model:codex`;
- no Build Order parent, `phase:N`, `build-lane:*` or active `agent:*` state.

Skill delivery:

- `human:todo` because timing is blocked on the currently running dashboard
  Executor;
- no `agent:*` label and no Build Order membership.

Create missing `build-order`, four `build-lane:*`, and required phase labels
with Build Order-neutral descriptions. Reuse current complexity/model labels.
The version-2 core receipt records both the deterministic projected labels and
the full observed label set so the validator can prove required routing labels
and wildcard routing-family exclusions, not merely a self-authored manifest.

For all new root/BO/DASH/skill issues, reject every observed `agent:*` label,
including terminal, error, watch, and paused variants. Planning publication
does not inherit workflow state from a template.

## Relationship contract

- Native direct parenthood is Build Order membership.
- Native `blockedBy` is the only hard prerequisite truth.
- The human skill-delivery issue is an external native blocker of BO-001; it is
  neither root membership nor Build Order work.
- Companion dependencies are real hard prerequisites and are published even
  though the issues are standalone.
- Named external gates stay in issue contracts and are not converted into
  fabricated blocker issues or edges. Every DASH issue remains non-pickable
  until `GATE-OCC-PREDECESSOR-BASELINE` resolves.
- `serializes_with`, phase and `suggested_after` remain scheduling metadata and
  are not invented blocker edges.
- GitHub is live truth after publication. `build-order.json` and
  `dashboard-companions.json` remain approved baselines and receipts.

## Reconciliation receipt

- Approved planning commit: pending final clean reviews
- Reconciliation commit: pending post-publication write
- GitHub root: pending
- BO logical-ID mappings: pending in `build-order.json`
- Companion mappings: pending in `dashboard-companions.json`
- Membership requery: pending
- BO dependency requery: pending
- Companion dependency requery: pending
- Full-label requery: pending
- Root/skill/companion standalone-parenthood requery: pending
- Skill-delivery issue: pending
- Root reconciliation comment URL/final state: pending
- Approval commit existence and 32 observed body markers/hashes: pending
- Canonical validator: pending
- Companion/publication validator: pending

The post-publication commit updates this section with returned URLs/counts, the
pending root-comment URL, and exact validation output. It does not change
approved ticket scope. The final edit of that same root comment links the
immutable commit and is the durable start gate the later Executor re-queries.
