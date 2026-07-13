# GitHub Publication Plan and Receipt

## Status

Pending operator review. Do not create or update the Build Order issues from
this draft until Kevin approves the ticket contracts.

## Planned materialization

1. Requery GitHub for duplicates and current labels.
2. Create or identify one non-dispatchable root issue for
   `its-everdred/aiur:build-order-dashboard`.
3. Create/update BO-001 through BO-011 from their reviewed documents.
4. Add each BO issue as a direct native sub-issue of the root without replacing
   any existing parent silently.
5. Publish native `blockedBy` relationships for hard `depends_on` only.
6. Create/update DASH-001 through DASH-008 as standalone companion issues.
7. Requery identities, parenthood, labels, and every hard relationship; write
   returned node IDs/numbers/URLs into `build-order.json` and this receipt.
8. Run the canonical validator with GitHub reconciliation enabled.

## Labels

Root:

- `build-order`
- no `model:*`, `complexity:*`, `phase:*`, `build-lane:*`, or `agent:*`

BO-001 through BO-011:

- exactly one `complexity:N`
- `model:codex`
- exactly one `phase:N`
- exactly one `build-lane:backend|frontend|infrastructure`
- no `agent:todo` or other active agent state

DASH-001 through DASH-008:

- exactly one `complexity:N`
- `model:codex`
- no Build Order parent, `phase:N`, `build-lane:*`, or `agent:todo`

Create missing `build-order`, `build-lane:*`, and `phase:7` labels before issue
publication. Reuse existing complexity/model labels. Reconcile existing
`phase:1..6` descriptions rather than assuming their old refactor wording is a
new semantic source.

## Relationship rules

- Native direct sub-issue parenthood is membership.
- Native `blockedBy` is the only hard edge.
- `serializes_with`, phase, suggested order, and companion dependencies are not
  published as fake blocker relationships.
- Do not assume issue-number adjacency.
- Root and ticket hidden markers preserve stable logical identity/version only.
- A conflicting existing parent, logical ID, or duplicate issue stops
  materialization for reconciliation; never pass `replaceParent` silently.

## Reconciliation receipt

To be populated after review and publication:

- Approved planning commit: pending
- GitHub root identity: pending
- BO logical-ID mappings: pending
- Companion logical-ID mappings: pending
- Membership requery: pending
- Dependency requery: pending
- Label requery: pending
- Validator output: pending
