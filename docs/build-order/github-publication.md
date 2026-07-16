# GitHub Publication Plan and Receipt

> **Consolidation note (2026-07-13):** the operator consolidated the program
> into a single Build Order (DEC-014). All 54 tickets — BO-001..020 and
> DASH-001..034 — are direct native sub-issues of the one root defined in
> `build-order.json`; `dashboard-companions.json` was retired and
> `scripts/validate_publication.py` now validates the single manifest. The
> instructions below are written for that consolidated topology: DASH issues
> are members, not standalone issues, and the graph totals are 56 issues / 107
> blocker edges.

## Status

Publication is the final planning action. Do not launch Aiur, add a dispatch
label, implement a ticket, or merge either planning branch.

## Publication operator

Use the skill-owned `.claude/skills/aiur-build/scripts/publish_build_order.py`;
the pack-local `scripts/publication_operator.py` is compatibility-only. Do not reproduce the 56-issue and
107-edge ceremony with ad hoc `gh` commands. Its default mode is a bounded,
read-only rehearsal. Both authority arguments are assertions: the approval is
the exact commit reviewed as immutable planning scope, and the green authority
is the exact current tip of the frozen trusted branch.

The approval SHA changes whenever this planning branch changes, including a
change to the operator itself. After the final planning commit, obtain fresh
approval of that exact SHA; never reuse an approval for an earlier candidate.
Then run:

```bash
APPROVED_SHA=<exact-newly-reviewed-40-character-commit>
GREEN_SHA=<exact-current-green-tip-of-build-order-research>

# Default is --dry-run and performs no mutation.
python3 .claude/skills/aiur-build/scripts/publish_build_order.py \
  --build docs/build-order/build-order.json \
  --approved-sha "$APPROVED_SHA" \
  --green-authority-sha "$GREEN_SHA"

# Explicit publication stage. This stops with a pending comment and local
# receipt files; it never commits, pushes, or marks publication successful.
python3 .claude/skills/aiur-build/scripts/publish_build_order.py --apply \
  --build docs/build-order/build-order.json \
  --approved-sha "$APPROVED_SHA" \
  --green-authority-sha "$GREEN_SHA"
```

`--apply` is resumable. If it is interrupted, rerun the identical command.
The operator rescans mixed open/closed issue and PR entries, resolves only the
one exact canonical marker for each logical ID, fresh-GETs created identities,
adds missing labels and native relationships without removal/replacement, and
reuses the one exact pending reconciliation comment. A conflicting marker,
parent, child, blocker, routing label, or comment stops the run. The only label
definitions it is allowed to create are `build-order`, the five approved
`build-lane:*` labels, and `phase:7`/`phase:8`; all other required definitions
must already exist.

Every feature issue title and the root title is rendered from its approved H1
and starts with the literal `BO:` prefix (`BO: BO-001 — …`,
`BO: DASH-001 — …`). The separate skill-delivery prerequisite remains
unprefixed.

The trusted branch is rechecked immediately before the first mutation and at
bounded mutation checkpoints. Restore the same frozen authority and rerun if a
checkpoint detects drift. Any issue or PR containing multiple planning markers,
or any two logical IDs resolving to one issue number or node, fails before
publication mutation.

After `--apply`, review both receipt manifests and the two substituted
templates, then commit and push those receipt-only changes through the normal
review path. Finalization is deliberately separate:

```bash
RECEIPT_SHA=<exact-pushed-receipt-commit>
RECEIPT_URL="https://github.com/its-everdred/aiur/commit/$RECEIPT_SHA"

python3 .claude/skills/aiur-build/scripts/publish_build_order.py --finalize \
  --build docs/build-order/build-order.json \
  --approved-sha "$APPROVED_SHA" \
  --green-authority-sha "$RECEIPT_SHA" \
  --receipt-commit "$RECEIPT_SHA" \
  --receipt-url "$RECEIPT_URL"
```

Finalization runs the existing receipt-bound pending verifier (two complete
fresh snapshots plus branch/commit authority), preserves that pending comment
as immutable authorization, appends one distinct canonical successful receipt,
then runs the successful verifier.
The immutable receipt commit exclusively selects the comment identity; mutable
checkout receipt fields cannot redirect it. Finalization is idempotent: after a
crash or transient failure following creation, rerunning reuses and verifies
the already canonical successful comment without creating another. It rejects
malformed, conflicting, or duplicate reconciliation evidence. It does not create
issues, labels, membership, or dependencies.

## Materialization set

1. Requery open and closed issues for hidden logical-ID markers and overlapping
   work (#132, #845, #1033, #1034 and #1067). This is read-only; do not mutate
   the existing issues. Parse marker bodies on pull-request-shaped list entries
   too: a PR collision must not disappear when the mixed issues endpoint is
   filtered. Any open, closed, or PR-shaped marker collision stops publication.
   Never reopen a closed match or create a replacement identity.
2. Create or reconcile one non-dispatchable root for
   `its-everdred/aiur:build-order-dashboard` from `root-issue.md`.
3. Create/reconcile BO-001 through BO-020 and DASH-001 through DASH-034 from
   every `tickets[].document` path in the approved `build-order.json`.
4. Add all 54 member issues as direct native sub-issues without silently
   replacing an existing parent.
5. Publish all 105 manifest `depends_on` relationships as native `blockedBy`,
   including cross-prefix BO/DASH prerequisites.
6. Create/reconcile the separate human-blocked skill-delivery issue from
   `skill-delivery.md` and `publication.json`; it records reviewed PR #1065
   source head `6447f9c193d2322d63f54a58b9c54e0a72d3e98f` and squash merge
   `ed1846c4bc76d4657095da57951a0dbf3e914c3d` and is not feature work.
7. Publish the skill-delivery issue as a native external blocker of BO-004 and
   BO-008 so each independent initial branch requires the exact
   Executor contract before feature dispatch; it remains outside root
   membership and the feature denominator.
8. Requery full label sets, returned identities, parenthood and every native
   blocker. Prove the root and skill-delivery issue are parentless while all 54
   members have the intended direct root. Populate the core and auxiliary
   structured receipts with RFC3339 UTC check times and run the canonical plus
   publication validators.

The materialized receipt schemas are core v3 in `build-order.json` and
auxiliary v2 in `publication.json`. The core receipt owns the root and all 54
members; the auxiliary receipt owns skill-delivery evidence and repeats the
root mapping only to bind the standalone issue and reconciliation comment to
the same root. Their `observed_issue_states` evidence covers all 56 issue
identities and contains only the exact value `OPEN`.

All 56 created bodies link to the immutable approved planning commit and carry
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
owning receipt: root plus all 54 members in the core receipt, and skill delivery
in the auxiliary receipt. Together the maps must cover all 56 issue identities
exactly and every observed title must equal its approved H1; a
body-correct issue with a renamed or truncated title fails reconciliation.

Expected bodies are not receipt-authored hashes. Load `build-order.json`,
`publication.json`, and every referenced document with
`git show <APPROVED_SHA>:<path>`. Render BO and
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
relationships requery successfully, commit and push that receipt, then append
one distinct canonical `successful` comment with the exact immutable receipt
commit and link. Run the read-only `scripts/publication_comment.py`
verifier once against the pending-only evidence immediately before creation and
again against the pending-plus-successful evidence immediately afterward; the
successful comment creation is the only finalization mutation. The verifier does not trust a caller-authored
query file or observation object. It derives the complete expected graph and
exact pending-comment URL from the immutable receipt, queries GitHub itself,
and performs two complete bounded reads. The two snapshots must be identical
and must exactly match all 56 mappings, titles, independently rendered body
hashes, full label sets, `OPEN` states, unlocked state, all-state marker result
sets, native parents, subissues, all 107 `blockedBy` edges, the exact immutable
pending comment, and one distinct exact successful comment. The root has exactly 54 BO/DASH children and no parent; each member has
that root as parent; the skill issue is parentless; every non-root has no
subissues. Closed and PR-shaped marker matches remain visible to the collision
check. Every GitHub read, including branch/compare authority, pins `github.com`,
API version `2026-03-10`, finite page/item bounds where applicable, and a
per-call timeout. It treats its CLI identity arguments as
assertions, not authority: it derives repository, root identity and URL, plan
version, and approval from the exact receipt commit, requires both materialized
reconciliation receipts, and runs the trusted current validator
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
closed rather than racing successful receipt creation.

Verify the receipt-bound live comment directly:

```bash
# Immediately before the only finalization mutation (pending only):
python3 docs/build-order/scripts/publication_comment.py --state pending \
  its-everdred/aiur:build-order-dashboard 1 \
  <APPROVED_SHA> <RECEIPT_SHA> <RECEIPT_URL> \
  https://github.com/its-everdred/aiur/issues/<ROOT_NUMBER> \
  its-everdred/aiur

# Immediately after the successful receipt is appended (pending + successful):
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

All 54 members — BO-001 through BO-020 and DASH-001 through DASH-034:

- exactly one `complexity:N`;
- `model:codex-gpt-5.6-terra`;
- exactly one `phase:N`;
- exactly one `build-lane:plan-graph|runtime|dashboard-ui|accounting|platform`;
- no active `agent:*` state.

Skill delivery:

- `human:todo` because timing is blocked on the currently running dashboard
  Executor;
- no `agent:*` label and no Build Order membership.

Create missing `build-order`, five `build-lane:*`, required phase labels, and
the exact `model:codex-gpt-5.6-terra` label with Build Order-neutral
descriptions. Reuse current complexity labels. Never substitute generic
`model:codex`, a Sol, Luna, or Claude model label, or a different Codex variant.
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
- All BO/DASH dependencies are real hard prerequisites within the one
  consolidated member graph.
- Named external gates stay in issue contracts and are not converted into
  fabricated blocker issues or edges. Every DASH issue remains non-pickable
  until `GATE-OCC-PREDECESSOR-BASELINE` resolves.
- `serializes_with`, phase and `suggested_after` remain scheduling metadata and
  are not invented blocker edges.
- GitHub is live truth after publication. `build-order.json` is the approved
  member baseline/core receipt and `publication.json` is the auxiliary receipt.

## Reconciliation receipt

- Approved planning commit: pending final clean reviews
- Reconciliation commit: pending post-publication write
- GitHub root: pending
- Root/member logical-ID mappings and exact marker-query matches: pending in `build-order.json`
- Membership requery: pending
- All 105 member dependency requeries: pending
- Full-label requery: pending
- Root/skill standalone-parenthood requery: pending
- Skill-delivery issue: pending
- Root reconciliation comment unique query match/final state: pending
- Approval/receipt trusted-branch reachability: pending
- 56 independently rendered body markers/links/hashes and exact title pairs: pending
- Exact `OPEN` state and unlocked-state requery for all 56 issues: pending
- Two identical full live-graph snapshots (54 root members, 107 total blockers): pending
- Canonical validator: pending
- Publication validator: pending

The post-publication commit updates this section with returned URLs/counts, the
pending root-comment URL, and exact validation output. It does not change
approved ticket scope. The final edit of that same root comment links the
immutable commit and is the durable start gate the later Executor re-queries.
