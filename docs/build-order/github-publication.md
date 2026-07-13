# GitHub Publication Plan and Receipt

## Status

Publication is the final planning action. Do not launch Aiur, add a dispatch
label, implement a ticket, or merge either planning branch.

## Materialization set

1. Requery open and closed issues for hidden logical-ID markers and overlapping
   work (#132, #845, #1033, #1034 and #1067).
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
   `skill-delivery.md`; it references draft PR #1065 and is not feature work.
9. Add a short supersession/link comment to #132 and lineage comment to #845;
   do not close or rewrite those broader issues silently.
10. Requery full label sets, returned identities, parenthood and every native
    blocker. Populate both structured receipts and run validation.

All created bodies link to the immutable approved planning commit and carry a
bounded hidden marker. A conflicting marker, parent or existing identity stops
publication for reconciliation; never use a replacement-parent mutation as a
shortcut.

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
- no `agent:todo` and no Build Order membership.

Create missing `build-order`, four `build-lane:*`, and required phase labels
with Build Order-neutral descriptions. Reuse current complexity/model labels.
The receipt records the full observed label set so the validator can prove
required routing labels and forbidden dispatch labels, not merely the expected
projection.

## Relationship contract

- Native direct parenthood is Build Order membership.
- Native `blockedBy` is the only hard prerequisite truth.
- Companion dependencies are real hard prerequisites and are published even
  though the issues are standalone.
- `serializes_with`, phase and `suggested_after` remain scheduling metadata and
  are not invented blocker edges.
- GitHub is live truth after publication. `build-order.json` and
  `dashboard-companions.json` remain approved baselines and receipts.

## Reconciliation receipt

- Approved planning commit: pending final clean reviews
- GitHub root: pending
- BO logical-ID mappings: pending in `build-order.json`
- Companion mappings: pending in `dashboard-companions.json`
- Membership requery: pending
- BO dependency requery: pending
- Companion dependency requery: pending
- Full-label requery: pending
- #132/#845 comments: pending
- Skill-delivery issue: pending
- Canonical validator: pending

The post-publication commit updates this section with returned URLs/counts and
the exact validation output. It does not change approved ticket scope.
