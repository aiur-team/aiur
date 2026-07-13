# GitHub Publication Plan and Receipt

## Status

Publication is the final planning action. Do not launch Aiur, add a dispatch
label, implement a ticket, or merge either planning branch.

## Materialization set

1. Requery open and closed issues for hidden logical-ID markers and overlapping
   work (#132, #845, #1033, #1034 and #1067). This is read-only; do not mutate
   the existing issues. Parse marker bodies on pull-request-shaped list entries
   too: a PR collision must not disappear when the mixed issues endpoint is
   filtered. Any open, closed, or PR-shaped marker collision stops publication.
   Never reopen a closed match or create a replacement identity.
2. Create or reconcile one non-dispatchable root for
   `its-everdred/aiur:build-order-dashboard` from `root-issue.md`.
3. Create/reconcile BO-001 through BO-019 from the approved ticket documents.
4. Add the nineteen BO issues as direct native sub-issues without silently
   replacing an existing parent.
5. Publish every BO `depends_on` relationship as native `blockedBy`.
6. Create/reconcile DASH-001 through DASH-025 as standalone issues from
   `dashboard-companions.json` and their documents.
7. Publish companion hard prerequisites as native blockers, including
   cross-scope BO prerequisites, while leaving companions outside the root.
8. Create/reconcile the separate human-blocked skill-delivery issue from
   `skill-delivery.md` and `publication.json`; it references draft PR #1065 and
   is not feature work.
9. Publish the skill-delivery issue as a native external blocker of BO-004 and
   BO-008 so each independent initial branch requires the exact
   Executor contract before feature dispatch; it remains outside root
   membership and the feature denominator.
10. Requery full label sets, returned identities, parenthood and every native
    blocker. Prove the root, skill-delivery issue, and every companion are
    parentless while all BO tickets have the intended direct root. Populate all
    three structured receipts with RFC3339 UTC check times and run the
    canonical plus publication validators.

The materialized receipt schemas are core v3, companion v2, auxiliary v2, and
bundle v2. Each owning receipt includes a freshly queried
`observed_issue_states` map keyed by logical ID. The three maps are disjoint,
cover exactly all 46 identities, and contain only the exact value `OPEN`.

All 46 created bodies link to the immutable approved planning commit and carry
one canonical `aiur-planning-issue` marker with schema 2, logical ID, plan
version, and that same commit. Requery each body, parse the marker and link, and
record its SHA-256; do not trust the submitted body. Record the complete result
set of each logical-marker query and require exactly one returned issue mapping
per logical ID. The approval SHA must resolve to a real commit in this
repository before the first issue mutation.

GitHub issue titles are equally authoritative publication content. Derive each
expected title from the exact H1 of its approved document (without the `# `),
including the logical-ID prefix and em dash on BO/DASH documents. Record both
the frozen expected-title map and the freshly queried observed-title map in the
owning receipt: root plus BO in the core receipt, DASH in the companion
receipt, and skill delivery in the auxiliary receipt. Both maps must cover all
46 issues exactly and every observed title must equal its approved H1; a
body-correct issue with a renamed or truncated title fails reconciliation.

Expected bodies are not receipt-authored hashes. Load the three manifests and
every referenced document with `git show <APPROVED_SHA>:<path>`. Render BO and
DASH bodies as the exact preamble below plus the approved ticket document
verbatim. Render root and skill bodies from their complete approved templates
by replacing `<APPROVED_SHA>`. Require exactly one schema-2 marker and exactly
one approved-commit link in every result, then compare the observed SHA-256 to
that independently rendered body. A missing approved pack/path or any
missing/wrong/duplicate marker, link, issue match, or hash fails closed.

Once the root exists, create one uniquely marked
`aiur-build-order-reconciliation` comment whose visible and marker state is
`pending`. Requery the marker search and require exactly one comment match;
record its URL, parsed pending marker, and canonical body SHA-256. After all
relationships requery successfully, commit and push that receipt, then edit the
same comment URL to the canonical `successful` body with the exact immutable
receipt commit and link. Run the read-only `scripts/publication_comment.py`
verifier once against the pending comment immediately before the edit and
again against the successful comment immediately afterward; the comment edit
is the only finalization mutation. The verifier does not trust a caller-authored
query file or observation object. It derives the complete expected graph and
exact pending-comment URL from the immutable receipt, queries GitHub itself,
and performs two complete bounded reads. The two snapshots must be identical
and must exactly match all 46 mappings, titles, independently rendered body
hashes, full label sets, `OPEN` states, unlocked state, all-state marker result
sets, native parents, subissues, 73 `blockedBy` edges, and the one exact comment.
The root has exactly nineteen BO children and no parent; each BO has that root
as parent; DASH and skill issues are parentless; every non-root has no
subissues. Closed and PR-shaped marker matches remain visible to the collision
check. Every GitHub read, including branch/compare authority, pins `github.com`,
API version `2026-03-10`, finite page/item bounds where applicable, and a
per-call timeout. It treats its CLI identity arguments as
assertions, not authority: it derives repository, root identity and URL, plan
version, and approval from the exact receipt commit, requires all three
materialized reconciliation receipts, and runs the trusted current validator
against raw regular blobs from that commit before accepting the comment.
Every authority-bearing Git read disables replacement objects. Because that
setting does not disable legacy grafts, the verifier rejects any `info/grafts`
entry (including symlink or non-regular entries) in both the worktree Git dir
and common Git dir before and after validation, and performs its local ancestry
check in a clean shared no-checkout clone. The repository is anchored to the
configured GitHub `origin`. The approved pack
freezes `trusted_repository_ref` as
`refs/heads/build-order-research`. GitHub must return that exact branch ref and
an unchanged commit tip around the compare reads. Strict GitHub comparisons
must prove approval is an ancestor of receipt and both are ancestors of that
tip; the clean local graph must independently agree. Imported foreign object
history and the mere
existence of a local or API-visible commit cannot authorize execution. Branch
fast-forwards are valid. Deleting the branch or force-pushing either authority
commit out of its history revokes the start gate and fails closed, even when a
commit URL or `refs/pull/*` still resolves; never fall back silently to `main`.
This two-commit
authority preserves reviewed scope while giving the immutable handoff a live
route to the eventual receipt. A conflicting marker, parent, receipt comment,
or existing identity stops publication for reconciliation; never use a
replacement-parent mutation as a shortcut.

Receipt/branch authority is checked before and after the two live snapshots.
Deletion, force-push, or authority drift during the query therefore fails
closed rather than racing the final comment edit.

Verify the receipt-bound live comment directly:

```bash
# Immediately before the only finalization mutation:
python3 docs/build-order/scripts/publication_comment.py --state pending \
  its-everdred/aiur:build-order-dashboard 1 \
  <APPROVED_SHA> <RECEIPT_SHA> <RECEIPT_URL> \
  https://github.com/its-everdred/aiur/issues/<ROOT_NUMBER> \
  its-everdred/aiur

# Immediately after the pending-to-successful edit:
python3 docs/build-order/scripts/publication_comment.py \
  its-everdred/aiur:build-order-dashboard 1 \
  <APPROVED_SHA> <RECEIPT_SHA> <RECEIPT_URL> \
  https://github.com/its-everdred/aiur/issues/<ROOT_NUMBER> \
  its-everdred/aiur
```

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

BO-001 through BO-019:

- exactly one `complexity:N`;
- `model:codex`;
- exactly one `phase:N`;
- exactly one `build-lane:documentation|frontend|backend|infrastructure`;
- no active `agent:*` state.

DASH-001 through DASH-025:

- exactly one `complexity:N` and `model:codex`;
- no Build Order parent, `phase:N`, `build-lane:*` or active `agent:*` state.

Skill delivery:

- `human:todo` because timing is blocked on the currently running dashboard
  Executor;
- no `agent:*` label and no Build Order membership.

Create missing `build-order`, four `build-lane:*`, and required phase labels
with Build Order-neutral descriptions. Reuse current complexity/model labels.
The version-3 core receipt records both the deterministic projected labels and
the full observed label set so the validator can prove required routing labels
and wildcard routing-family exclusions, not merely a self-authored manifest.

For all new root/BO/DASH/skill issues, reject every observed `agent:*` label,
including terminal, error, watch, and paused variants. Planning publication
does not inherit workflow state from a template. Treat `human:*` as an exact
routing family too: only the skill issue may carry `human:todo`, and no issue
may acquire any other `human:*` label.

These are exact planning/routing-family projections, not a repository-wide
denylist for unrelated metadata labels. A pre-existing non-routing label may
remain; publication neither invents nor removes it. The receipt records the
entire observed label set, and “exact full labels” at finalization means the two
live snapshots must equal that frozen full set with no later addition/removal.

## Relationship contract

- Native direct parenthood is Build Order membership.
- Native `blockedBy` is the only hard prerequisite truth.
- The human skill-delivery issue is an external native blocker of BO-004 and
  BO-008; it is neither root membership nor Build Order work.
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
- BO logical-ID mappings and exact marker-query matches: pending in `build-order.json`
- Companion mappings and exact marker-query matches: pending in `dashboard-companions.json`
- Membership requery: pending
- BO dependency requery: pending
- Companion dependency requery: pending
- Full-label requery: pending
- Root/skill/companion standalone-parenthood requery: pending
- Skill-delivery issue: pending
- Root reconciliation comment unique query match/final state: pending
- Approval/receipt trusted-branch reachability: pending
- 46 independently rendered body markers/links/hashes and exact title pairs: pending
- Exact `OPEN` state and unlocked-state requery for all 46 issues: pending
- Two identical full live-graph snapshots (19 members, 73 blockers): pending
- Canonical validator: pending
- Companion/publication validator: pending

The post-publication commit updates this section with returned URLs/counts, the
pending root-comment URL, and exact validation output. It does not change
approved ticket scope. The final edit of that same root comment links the
immutable commit and is the durable start gate the later Executor re-queries.
