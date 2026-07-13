# Build Order Planning Validation

## Candidate status

The canonical Build Order, standalone dashboard companions, and publication
manifest are mechanically valid. Multiple adversarial passes changed material
boundaries, ownership, gates, and receipt proof, so none counts toward the
two-clean-pass stop condition. Two successive clean semantic reviews, an
immutable approval commit, and GitHub publication reconciliation remain
pending.

## Evidence baseline

- Repository: `its-everdred/aiur`
- Researched and refreshed `origin/main`:
  `9849f32963c2a65367bce565b3f5ede3777c218f`
- Initial completed OCC integration baseline:
  `b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5`
- Configured `v2` snapshot:
  `3bbc064a67a3b920d25c55824306d411a78ff809`, which does not contain the
  refreshed main baseline. This remains an explicit pre-dispatch gate rather
  than an assumed implementation base.
- Prototype HTML SHA-256:
  `23b527eade8c2fad7d37957c248be709091dfd112bbc6e13c6d76cd092d663a3`
- Prototype constraints SHA-256:
  `49e068d4999d62197dbd1d5c0438db21a25cd1b5873fb959a58a7e0388c7829a`
- Canonical Build Order JSON SHA-256:
  `c7b00fb8c6321af9528a3261643c38ab5e1a95b4aa11fb805a88d5fff4cb8bdf`
- Companion baseline JSON SHA-256:
  `aa4d13b43af8c19cfeba158a34009d32c595c4996ea8982991108de3d4343294`
- Publication manifest SHA-256:
  `0e0b836d69bb6aec9b432cb3ba3d2e61a2a305eccf86fcca5dfccdf6f6819b9f`
- Requirements SHA-256:
  `0f0ede7470bdf47fd61059acf639a22834af517c58a58b7da4de59ebc88343fc`
- Implementation plan SHA-256:
  `3c871032a4e1f0000173779464a2509d316b29df560c4f39e708b863b9056e45`
- Latest validator/skill authority: isolated draft PR #1065 at
  `f92aa045f6766358d7561dadc1133c4d9180d1f3`
- Approval commit: pending two clean passes

The design hashes match [the manifest](design-manifest.md). The prototype was
exercised in a real browser at desktop and mobile widths, in both themes, with
route, filter, detail, scrolling, and interaction behavior recorded in
[the capability audit](06-prototype-capability-audit.md).

## Current-state refresh

The 2026-07-13 current-main and final prototype refresh required both contract
updates and a final ticket-boundary correction:

- Current main's runner `:completed/:awaiting_dispatch` state is a nonterminal
  replacement boundary. DASH-002 and BO-006 now prove that it remains visible,
  queued/unfinished, zero-capacity, and never tracker-finished.
- Closed #1034 is accepted predecessor evidence, not an active DASH-001 native
  blocker. The shared predecessor-baseline gate still requires the configured
  implementation branch to contain it and all accepted OCC successors.
- Current main includes a documentation-capture Playwright runner over a
  synthetic Phoenix/LiveView fixture. BO-008 generalizes that executable
  precedent into the shared authenticated interaction, accessibility,
  responsive-artifact, reconnect, trace and performance harness; DASH-001 now
  depends on it rather than inventing a second runner.
- Usage and provider meters require one privacy-safe opaque account generation
  rather than independent namespaces. DASH-018 owns that lifecycle,
  DASH-008 and DASH-012 consume it, and DASH-009 preserves occurrence-price
  date, currency, generation, and every grouping dimension through compaction.
  DASH-015 alone performs exact-generation tier composition.
- Main now uses the Executor role vocabulary, while compatibility module and
  event identifiers remain unchanged. Role-facing planning copy was refreshed
  without renaming durable implementation seams.
- Main's #1076 isolates warmed-slot OpenCode provider configuration from parent
  overrides. It changes neither provider-meter authority nor attributed usage
  ingestion, so the provider/accounting ticket graph remains unchanged.
- Draft PR #1065 now conflicts with current main in the retired-loop,
  `aiur-run`, `aiur-monitor`, skill-discovery, test, and documentation seams.
  GATE-002 therefore remains unresolved and the human delivery issue requires
  a reviewed reconciliation rather than a blind merge.

## Mechanical validation

| Gate | Current result |
|---|---|
| Canonical validator | 0 errors, 0 warnings |
| Companion/publication validator | 0 errors, 0 warnings |
| Publication regression suite | 102 tests pass |
| Build Order tickets | 19, 71 complexity points |
| Standalone companions | 25, 87 complexity points |
| Planned GitHub materialization | 46 new issues: one root, 44 executable issues, one human issue |
| Logical IDs | Unique across BO, DASH, root, and skill delivery |
| Hard-edge graph | Acyclic across BO and DASH dependencies |
| Ticket documents | Paths, complexities, requirement refs, dependencies, and external gates match structured records |
| Requirements | Bidirectional BOREQ-001..015 plus exact unique DREQ-001..025 coverage |
| Capstone | BO-015 transitively covers all 18 prerequisite BO tickets |
| Pre-publication policy | No dispatch labels; exact root/skill label denylist; standalone companions |
| Structured data | JSON parse and Python compile pass |
| Whitespace | `git diff --check` clean |

The validation commands are:

```bash
python3 <loaded-aiur-build-skill>/scripts/validate_build_order.py \
  docs/build-order/build-order.json
python3 docs/build-order/scripts/validate_publication.py
python3 -m unittest discover -s docs/build-order/scripts/tests -p 'test_*.py'
```

The canonical validator owns the BO receipt, membership, label, and dependency
proof. The local publication validator owns the all-or-nothing cross-pack
contract: companion mappings and blockers, exact observed labels, parentless
root/skill/companions, approval/version consistency, RFC3339 requery times,
independently rendered approved bodies and titles, exact logical-marker query
matches, and the unique root reconciliation comment. The read-only
final-comment verifier fetches the receipt-recorded comment ID itself and
requires its successful live body to name the exact receipt commit/link while
both authority commits remain reachable from the frozen repository branch.
Both validators are mandatory after materialization.

## Semantic review log

### Corrective pass 1 — feature composition

This pass was not clean. It found and corrected:

1. Build Order context had leaked pause/resume mutations across the standalone
   DASH-004/005 boundary. BO-011 is navigation and on-demand read context only.
2. Fit/pan/zoom had three owners. BO-013 owns interaction policy and controls,
   BO-010 applies geometry/transforms, and BO-014 owns responsive preservation
   and measured hardening.
3. Selected-detail fetching/caching lacked an owner. BO-002 owns the adapter,
   BO-003 owns bounded cache/LKG, BO-007 owns pure presentation, and BO-011 owns
   demand plus UI.
4. BO-009 and BO-011 consumed BO-008 infrastructure without hard prerequisites.
5. BO-008's toolchain/fixture/artifact/performance scope was undersized; it was
   raised to complexity 4, producing the then-current 58-point graph. The
   BO-016 split in corrective pass 4 produced a 61-point graph; later ownership
   splits produced the current 71-point graph.
6. BO-008..014 omitted material reviewer and at-merge proof from the canonical
   records; those gates are now retained.
7. Acceptance hard-coded `main`; it now resolves and records the configured
   integration target.

### Corrective pass 2 — ownership, security, and publication

This pass was not clean. It found and corrected:

1. Configured `v2` did not contain the researched OCC baseline, and the exact
   bounded skill revision was not guaranteed. GATE-001/GATE-002 now gate every
   core ticket transitively; all companions have a predecessor-baseline gate.
2. Event activity duplicated StatusReport lifecycle ownership. BO-005 now owns
   only progress, active stage, and latest safe event evidence; BO-006 migrates
   only that fold; BO-007 performs a pure three-source join.
3. Cross-source identity was infeasible with the existing display ID. BO-004
   now owns typed GitHub tracker identity through Issue, StatusReport, and event
   envelopes without changing legacy dispatch identity semantics.
4. The GitHub adapter description overstated current dependency support and
   ignored failure/cycle/partial-data boundaries; BO-002 now owns the bounded
   read contract explicitly.
5. Prototype delta was too large for one catch-up issue. This checkpoint split
   it into fifteen standalone Units, control, Commands, usage, meter, and
   summary contracts; corrective pass 4 separated seven more executable
   boundaries, and corrective pass 6 produced the current twenty-five-ticket
   pack.
6. Usage delta ownership was ambiguous. This checkpoint separated raw
   measurement, durable ledger, Remote Control, price projection, provider
   meters, and summary concerns; corrective pass 4 completed the transport,
   generation, adapter, authorization, and presentation boundaries.
7. Claude ingestion lacked a safe local authority boundary and account meters
   lacked protocol authority. Auth-before-decode, bounded transport, redaction,
   replay controls, and two named human gates are now required.
8. Financial facts could leak in unauthenticated mode. DASH-015 now locks all
   usage/account-meter facts, events, caches, assigns, and APIs unless
   authentication is enforced.
9. Publication lacked an authoritative manifest, mutation boundary, complete
   denylist, all-or-nothing receipts, standalone-parent proof, observed-label
   proof, stable requery timestamps, and immutable comment-to-receipt routing.
   The publication manifest and adversarial validator now own those checks.

### Corrective pass 3 — current-main delta and publication proof

This pass was not clean. It found and corrected:

1. The newly landed OCC screenshot runner made the old “no Phoenix browser
   runner” premise false. BO-008 now generalizes that precedent and DASH-001
   consumes it through a hard dependency.
2. Provider usage and meters could mint incompatible account generations,
   while compaction could erase the occurrence-price date, currency or
   generation needed for correct historical estimates. This pass established
   one shared generation and complete ledger partitions; corrective pass 4
   assigned generation lifecycle to DASH-018, with DASH-008 and DASH-012 as
   consumers and DASH-015 as the sole exact-generation tier join.
3. Publication policy could self-authorize routing-label drift, accept an
   unresolved approval SHA, omit issue-body evidence, accept an arbitrary root
   comment, skip three collision references, or follow a document symlink out
   of the pack. The pinned and local validators now fail closed on each case,
   with adversarial regression coverage.
4. A syntactically valid body SHA could still be arbitrary, marker and comment
   searches did not prove uniqueness, and `human:*` routing drift was ignored.
   The corrected receipt derives canonical bodies with `git show` from the
   approved commit, compares complete schema-2 marker/link/hash evidence,
   records exact query result sets, and read-only verifies the final successful
   root comment against its immutable receipt SHA and link.

### Corrective pass 4 — executable ticket boundaries

This pass was not clean. A final prototype-to-main comparison and independent
complexity audit found several tickets that still bundled independently
reviewable backend programs. It corrected:

1. BO-001 had become a false prerequisite for event identity and the browser
   harness. This pass initially made BO-001, BO-004, and BO-008 independent;
   corrective pass 5 later restored the semantic BO-004 to BO-001 prerequisite
   while leaving BO-008 independent.
2. Generic repository-qualified issue detail, bounded caching, deep-link base
   context, and accessibility lacked reusable ownership. This pass created
   BO-016; corrective pass 5 then separated detail, history, and base-context
   outcomes across BO-016, BO-019, and BO-018.
3. Current-run recovery and row eligibility were coupled. DASH-002 now owns
   membership journaling and recovery, while DASH-016 owns Units row
   projection, lifecycle predicates, counts, and stable ticket URLs.
4. Commands data retrieval and trust semantics were coupled. DASH-006 now owns
   lookup, pagination, search, and counts; DASH-017 owns provenance,
   confidence, migration, and trust presentation contracts.
5. Provider generation, meter protocol, and provider-specific adapters were
   coupled. DASH-018 owns generation lifecycle, DASH-012 the provider-neutral
   contract, and DASH-020/DASH-013 the Codex/Claude adapters.
6. Claude transport authority and accepted-event normalization were coupled.
   DASH-019 now owns authenticated bounded local transport and trusted session
   correlation; DASH-010 translates accepted events to UsageEnvelope.
7. Financial authorization, nonfinancial run summary, and provider usage UI
   were one oversized presentation ticket. DASH-021 owns the enforced
   financial boundary, DASH-022 the accessible current-run summary, and
   DASH-015 the authenticated usage/provider presentation.

### Corrective pass 5 — core identity and context boundaries

This pass was not clean. It found and corrected:

1. BO-004 still combined the durable tracker identity contract with propagation
   through every producer. BO-004 now owns identity definition and migration;
   BO-017 owns event-envelope and producer propagation.
2. BO-001 consumes tracker identity and therefore cannot start independently of
   BO-004. The final graph has exactly two initial nodes, BO-004 and BO-008, and
   the skill-delivery issue blocks exactly those two entry points.
3. Ticket detail, sanitized recent activity, and accessible base context had
   different providers, failure modes, and acceptance boundaries. BO-016,
   BO-019, and BO-018 now own those outcomes respectively; BO-011 owns only
   Build Order relationship context and truthful destinations.
4. Repository catalogs and selected graphs lacked explicit exhaustion bounds
   and freshness semantics. The final contracts cap catalog and selected
   membership at 100 tickets, use plus-one overflow detection, define provider
   call/page ceilings, and make refresh/reconnect behavior observable.
5. Prototype icon metadata had no GitHub source of truth. Icons are now derived
   from lane/status with a generic fallback instead of inventing tracker data.

### Corrective pass 6 — accounting storage and integration boundaries

This pass was not clean. It found and corrected:

1. DASH-009 combined append durability, aggregate/query projection, and
   retention/compaction. DASH-009 now owns occurrence ingestion and recovery,
   DASH-024 owns crash-safe aggregates and queries, and DASH-025 owns retention
   and compaction without destroying required accounting dimensions.
2. The prototype's selected Build Order totals lacked a bounded integration
   owner. DASH-023 joins GitHub membership with authorized Aiur accounting and
   owns per-ticket, provider/model, agent-type, token, estimated-cost, and total
   build projections for the selected Build Order.
3. Decision confidence was at risk of becoming a new scoring program.
   DASH-017 preserves the existing supervisor-supplied integer contract and
   owns provenance and presentation only.
4. Aiur planning cannot mutate the sibling `aiur-claude` repository. Provider
   tickets now require either Aiur-only evidence or an already-landed pinned
   compatible sibling revision; otherwise a separately authorized human issue
   and PR is required.
5. Cross-pack safety and write-surface conflicts were not mechanically checked.
   The publication validator now validates combined BO/DASH conflicts and
   rejects unapproved parallel safety overlap.
6. Approval protected rendered bodies but not all planning fields. Publication
   now derives every body from the exact approval commit and rejects any later
   title, scope, graph, label, or document drift; only returned GitHub mappings
   and reconciliation receipts may change after approval.

### Corrective pass 7 — shared execution seams

This pass was not clean. Independent core and dashboard reviewers found no new
product scope, but did find missing scheduling truth:

1. DASH-004 and DASH-019 consumed repository-qualified ticket identity while
   appearing initially ready. Both now depend on BO-004, the sole canonical
   configured-repository identity owner.
2. BO-003/005 were serialized on application supervision, but BO-016/019 also
   introduce supervised providers/caches through the same bootstrap surface.
   Every independently ready pair among BO-003/005/016/019 now serializes;
   BO-005 to BO-019 remains hard-ordered.
3. Prose required shell and selected-build route/CSS coordination without
   typed edges. Companion-declared cross-pack serialization now orders
   DASH-001 with BO-012 and DASH-023 with BO-013/014. BO-014 is explicitly
   limited to Build Order route-scoped styles rather than shared Units,
   Commands, or shell CSS.
4. DASH-018 and DASH-019 independently touched the Claude auth/process launch
   lifecycle. They now share an explicit lifecycle-adapter surface and
   serialize while preserving account-generation versus telemetry ownership.

### Corrective pass 8 — supervision and publication safety

This pass was not clean. Independent dashboard and publication reviewers found
no new product capability, but did find execution and fail-closed gaps:

1. DASH-002/009/012/018/019/024/025 also introduce long-lived children through
   the central application supervision tree. Their manifest now declares every
   independently ready cross-pack pair against BO-003/005/016/019 and every
   symmetric same-pack pair; existing hard dependencies order the remainder.
2. Human scheduling tables omitted the accepted BO-004 prerequisites for
   DASH-004 and DASH-019. Both generated views now agree with the canonical
   graph and ticket headers.
3. DASH-007 incorrectly assigned additive Decision migration to DASH-006.
   DASH-017 remains the sole provenance schema/replay/legacy-migration owner;
   DASH-007 owns presentation only.
4. Approval froze structured planning fields but not the current worker
   documents. Materialized validation now requires BO/DASH documents to equal
   their approved sources byte-for-byte and root/skill documents to equal the
   deterministic approved-template substitution.
5. Protected read-only issues could be reused as returned mappings. Every
   materialized root, BO, DASH, and skill identity is now checked against the
   exact read-only reference set before a receipt can validate.
6. The successful reconciliation comment accepted a shaped but nonexistent
   receipt SHA and foreign URL. Final verification now requires an exact
   repository commit link whose SHA resolves locally before the comment can be
   the durable start gate.

### Corrective pass 9 — receipt authority and skill pin

This pass was not clean. Independent publication and integrated reviewers
found two remaining authorization gaps:

1. The final comment verifier accepted caller-consistent repository, root,
   approval and URL values while proving only that the named receipt SHA was a
   local commit. A foreign repository identity and the current unmaterialized
   planning commit could therefore masquerade as the durable start gate. The
   verifier now loads raw regular blobs from the exact receipt commit into a
   no-checkout temporary clone, requires all three reconciliation receipts,
   runs the trusted current publication validator, derives all authority from
   that validated snapshot, and treats CLI values only as equality assertions.
2. The requirements still permitted an obsolete PR #1065 revision that
   predated approved-document freezing and protected receipt handling. Every
   gate and handoff at that checkpoint pinned the then-current isolated skill
   revision, whose reusable contract
   also requires a fully validated materialized receipt commit rather than
   mere commit existence.

### Corrective pass 10 — immutable object and origin authority

This pass was not clean. Two independent adversarial reviews found that the
receipt still trusted Git object and repository identity too early:

1. Git replace refs could substitute the fully materialized receipt tree for
   an unmaterialized SHA while `rev-parse`, `ls-tree`, and `show` continued to
   report the old SHA. All approval, receipt, and pinned-skill object reads now
   force `GIT_NO_REPLACE_OBJECTS=1`; a regression proves an unmaterialized
   commit cannot be promoted through replacement-object substitution. The
   distinct legacy graft mechanism was found and closed in corrective pass 15.
2. A self-consistent foreign approval and receipt history imported into the
   local Aiur object database could define its own repository, root, URLs, and
   matching caller values. Receipt authority now comes from the configured
   GitHub `origin`, requires the validated repository/root URL namespace to
   match it, and read-only verifies both approval and receipt commits exist in
   that remote repository. A fully materialized foreign-receipt fixture now
   fails even when its comment and caller values agree.
3. At that checkpoint the reusable skill authority was superseded by a
   no-substitution revision carrying the
   same no-substitution and trusted-origin/remote rules plus its own approved
   source regression. A malicious authorized same-repository publisher remains
   outside this receipt threat model; preventing that actor from fabricating
   observations would require independent API attestation or protected
   signatures.

### Corrective pass 11 — exact publication identity and revocation

This pass was not clean. Independent publication review found four remaining
fail-closed gaps without changing any issue boundary:

1. Receipts proved canonical bodies but not exact GitHub titles. Every expected
   title is now derived from its approved document H1, including BO/DASH logical
   prefixes, and each receipt records separately frozen expected and freshly
   observed title maps. Combined coverage must equal all 46 issues exactly.
2. Final verification accepted a caller-provided query array and any comment
   URL on the mapped root. The immutable receipt now supplies the one exact
   pending-comment URL, and the production verifier fetches that comment ID
   directly from GitHub before validating its canonical successful body.
3. GitHub's commit endpoint can expose fork/pull or otherwise unreferenced
   objects. The approved manifest now freezes the generic
   `trusted_repository_ref` to `refs/heads/build-order-research`; verification
   resolves and re-reads that exact branch tip, proves both commits are
   ancestors through strict compare invariants, and proves receipt descends
   from approval locally with replacement objects disabled. Branch deletion or
   a force-push that removes either commit intentionally revokes the start gate.
4. The reusable core receipt accepted the root-only `build-order` label on BO
   member issues because it rejected only dynamic routing-family drift. The
   successor pinned skill contract rejects that label on every BO member and
   carries an adversarial regression while preserving `build-order` on the root.
   The planning pack and gates now pin successor `f92aa045`.

### Corrective pass 12 — mixed-provider API-equivalent totals

This pass was not clean. Final dashboard review found that the accounting
contracts preserved provider and account-generation buckets but exposed no
API-equivalent run/build total across a mixed Codex/Claude workload, leaving the
headline build cost incomplete. DASH-011 now owns one exact same-currency
`api_equivalent_estimate` roll-up across provider/generation contributors while
preserving those contributors, coverage, pricing partitions, and exact tier
join boundaries. DASH-015 renders and explains that total without mixing
provider-reported bases, currencies, or synthesizing a cross-provider tier;
DASH-023 consumes the same selected-member contract. Requirements, decisions,
usage accounting, prototype audit, companion manifests, and implementation
plan now name and test this API-equivalent behavior consistently.

### Corrective pass 13 — live publication graph and state authority

This pass was not clean. Independent publication review confirmed two blockers
and exposed adjacent race/transport gaps:

1. A receipt could prove mappings and content without proving that every
   materialized issue was still open. Core receipt schema v3 and companion/
   auxiliary schema v2 now carry exact, logical-ID-keyed
   `observed_issue_states` partitions whose union is all 46 issues and whose
   only accepted value is `OPEN`; the bundle is v2.
2. Finalization previously verified only the reconciliation comment. The
   committed production verifier now derives the expected graph from the
   validated immutable receipt, queries GitHub itself twice, rejects any drift,
   and exactly rechecks mappings, titles, body hashes, full labels, open and
   unlocked state, all-state marker matches, nineteen root members, parent and
   non-root subissue state, 73 blockers, and the exact comment.
3. PR-shaped marker collisions and closed matches can no longer disappear from
   the mixed all-state issue scan. Malformed entries fail rather than being
   filtered, mapped PRs fail, reads pin `github.com` and API `2026-03-10`, and
   page/item/time bounds prevent an unbounded verification.
4. Receipt/branch authority is checked again after both live snapshots. The
   finalizer runs the full pending check before its only mutation and the full
   successful check after it, closing force-push and mid-query drift races.
5. The handoff now distinguishes the immutable publication-finalization OPEN
   snapshot from legitimate later execution state. The Executor must reverify
   before its first mutation, resolve both gates while skill delivery remains
   open, and only then close that issue and add dispatch labels.

### Corrective pass 14 — provider/source token relationships

This pass was not clean. Product accounting review against Anthropic's primary
pricing contract found that the prior global cache-subset assumption would
undercount Claude requests and misprice their cache dimensions. It corrected
the contracts without changing the twenty-five-ticket companion count or graph:

1. DASH-008 now owns an immutable, versioned provider/source/source-version
   relationship contract. It distinguishes additive, subset, mutually
   exclusive, and unknown dimensions; declares provider-total authority
   separately; pins the revision on each envelope; and fails closed instead of
   guessing when relationships are absent or contradictory.
2. DASH-010 maps the currently evidenced Claude base-input, cache-creation, and
   cache-read attributes as three additive request dimensions. The provider
   semantic is backed by Anthropic pricing evidence, while exact Claude Code
   OTel names remain versioned adapter evidence that is refreshed at pickup.
3. DASH-011 prices and reconciles Claude's three input dimensions separately,
   while a Codex cached-input subset is removed from the parent-priced slice
   and not counted twice. Mutually exclusive, provider-total, discrepancy, and
   unknown cases now have explicit exact-arithmetic/fail-closed tests.
4. DASH-009 preserves the pinned revision in canonical records and replayed
   deltas, DASH-024 partitions aggregates by it, and DASH-025 never merges it
   during compaction. Replay, projection, crash recovery, and destructive
   retention fixtures now vary known and unknown revisions explicitly.
5. Requirements, usage policy, DEC-009, the implementation/companion plans,
   canonical companion metadata, and all six affected ticket contracts preserve
   exact-money, provider-total, source-version, contributor, and coverage
   semantics consistently.

### Corrective pass 15 — graft-free ordered receipt authority

This pass was not clean. Publication review found that the prior authority
guard disabled replace objects but still honored legacy graft files, and that
its remote proof established only that approval and receipt independently
reached the branch tip:

1. Final verification now rejects any `info/grafts` entry in both the worktree
   Git directory and common Git directory, including symlink and non-regular
   entries. It audits before and after authority validation and runs the local
   approval-to-receipt check in a clean shared no-checkout clone, so a graft
   raced into the source repository cannot define accepted ancestry.
2. The configured-repository proof now uses a separate strict GitHub compare
   to prove approval is an ancestor of receipt, then proves both commits are
   ancestors of one unchanged trusted-branch tip. An unrelated orphan receipt
   merged beside the approval can no longer become the durable start gate.
3. Every authority-bearing GitHub request now explicitly pins `github.com`, API
   version `2026-03-10`, and a finite subprocess timeout. `GH_HOST` cannot
   redirect the branch proof to a same-named foreign server, and a stalled
   authority read fails closed.
4. Regressions cover an orphan materialized receipt promoted by a legacy graft,
   worktree/common-dir symlink and non-regular graft entries, a graft introduced
   during remote proof, two unordered commits that independently reach the same
   tip, `GH_HOST` redirection, and timeout behavior. The issue and relationship
   counts remain 46, nineteen, and 73.

### Clean pass 1

Pending review of an immutable checkpoint.

### Clean pass 2

Pending a second review of the unchanged candidate after clean pass 1.

## Skill verification

At isolated skill commit `f92aa045f6766358d7561dadc1133c4d9180d1f3`:

- 115 Python `aiur-build` validator tests pass;
- 41 repository skill/discovery tests pass;
- the canonical example validates with zero errors and warnings; and
- `aiur-build`, `aiur-run`, and `aiur-monitor` pass structure validation.

The skill changes remain isolated in draft PR #1065. They are not merged in
this planning run and require conflict reconciliation against current main.

## Publication reconciliation

Pending explicit final execution of the already authorized publication plan.
Publication must create/reconcile only the root, BO-001..019, DASH-001..025,
and SKILL-DELIVERY-001; it must not mutate read-only #132, #845, #1033, #1034,
or #1067. It then records returned identities, full observed labels, exact
native parenthood and blockers, every re-read issue-body marker/link/hash
against independently rendered approved sources, exact logical-marker query
matches, one canonical pending root-comment match, and both validator results
before the same comment is finalized. A full two-snapshot verification runs
immediately before and after that pending-to-successful edit; the edit is the
only finalization mutation.

No issue may receive any `agent:*` label during this planning run.
