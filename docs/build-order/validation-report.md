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
  `1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d`
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
  `2f561c915edae56e947335393285b9c4f62a59c4ed37bf48d7b56c300d3c7a4d`
- Companion baseline JSON SHA-256:
  `3fe30941a87b8929fccbef3c83ce3f107ab3c1700bb86c8b857a896fc5afad17`
- Publication manifest SHA-256:
  `31084d00f40826689c95ad00d67377f0f651207763161cacffa52cb1d690acd7`
- Requirements SHA-256:
  `05fd80e2f98593ff51511d0ddfff2f5ae08e07d00bd7b0ea6484d01e79c1080f`
- Implementation plan SHA-256:
  `9a238f919c44f6f872d7d8e8568119cf88801d8834174f32f4cf6e9f52405de4`
- Latest validator/skill authority: isolated draft PR #1065 at
  `0daf29726fbe8345a79588e14b6f4c556584a57c`
- Approval commit: pending two clean passes

The design hashes match [the manifest](design-manifest.md). The prototype was
exercised in a real browser at desktop and mobile widths, in both themes, with
route, filter, detail, scrolling, and interaction behavior recorded in
[the capability audit](06-prototype-capability-audit.md).

## Current-state refresh

The 2026-07-13 refresh found no new ticket split or owner transfer. It did add
two hard graph edges and require these contract updates:

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
  rather than independent namespaces. DASH-008 owns that contract and
  DASH-012 now depends on it. DASH-009 preserves occurrence-price date,
  currency, generation and every grouping dimension through compaction;
  DASH-015 alone performs exact-generation tier composition.
- Main now uses the Executor role vocabulary, while compatibility module and
  event identifiers remain unchanged. Role-facing planning copy was refreshed
  without renaming durable implementation seams.
- Draft PR #1065 now conflicts with current main in the retired-loop,
  `aiur-run`, `aiur-monitor`, skill-discovery, test, and documentation seams.
  GATE-002 therefore remains unresolved and the human delivery issue requires
  a reviewed reconciliation rather than a blind merge.

## Mechanical validation

| Gate | Current result |
|---|---|
| Canonical validator | 0 errors, 0 warnings |
| Companion/publication validator | 0 errors, 0 warnings |
| Publication regression suite | 37 tests pass |
| Build Order tickets | 15, 58 complexity points |
| Standalone companions | 15, 56 complexity points |
| Planned GitHub materialization | 32 new issues: one root, 30 executable issues, one human issue |
| Logical IDs | Unique across BO, DASH, root, and skill delivery |
| Hard-edge graph | Acyclic across BO and DASH dependencies |
| Ticket documents | Paths, complexities, requirement refs, dependencies, and external gates match structured records |
| Requirements | Bidirectional BOREQ-001..015 plus exact unique DREQ-001..015 coverage |
| Capstone | BO-015 transitively covers every BO ticket |
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
root/skill/companions, approval/version consistency, RFC3339 requery times, and
the root reconciliation comment. Both validators are mandatory after
materialization.

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
5. BO-008's toolchain/fixture/artifact/performance scope was undersized; it is
   complexity 4 and the feature total is 58 points.
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
5. Prototype delta was too large for one catch-up issue. It is decomposed into
   fifteen standalone Units, control, Commands, usage, meter, and summary
   contracts with explicit ownership and gates.
6. Usage delta ownership was ambiguous. DASH-008 emits raw measurements only;
   DASH-009 solely owns durable counters/deltas/replay; DASH-010 owns secure
   Remote Control ingestion; DASH-011 owns pricing/grouping; DASH-012/013 own
   provider meters; DASH-014/015 own summary projection/presentation.
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
   generation needed for correct historical estimates. DASH-008 owns one
   privacy-safe shared generation, DASH-012 consumes it, DASH-009 retains all
   required partitions, and DASH-015 alone joins tier facts exactly.
3. Publication policy could self-authorize routing-label drift, accept an
   unresolved approval SHA, omit issue-body evidence, accept an arbitrary root
   comment, skip three collision references, or follow a document symlink out
   of the pack. The pinned and local validators now fail closed on each case,
   with adversarial regression coverage.

### Clean pass 1

Pending review of an immutable checkpoint.

### Clean pass 2

Pending a second review of the unchanged candidate after clean pass 1.

## Skill verification

At isolated skill commit `0daf29726fbe8345a79588e14b6f4c556584a57c`:

- 56 adversarial `aiur-build` validator tests pass;
- the canonical example validates with zero errors and warnings; and
- `aiur-build`, `aiur-run`, and `aiur-monitor` pass structure validation.

The skill changes remain isolated in draft PR #1065. They are not merged in
this planning run and require conflict reconciliation against current main.

## Publication reconciliation

Pending explicit final execution of the already authorized publication plan.
Publication must create/reconcile only the root, BO-001..015, DASH-001..015,
and SKILL-DELIVERY-001; it must not mutate read-only #132, #845, #1033, #1034,
or #1067. It then records returned identities, full observed labels, exact
native parenthood and blockers, all 32 re-read issue-body markers and hashes,
structured pending root-comment evidence, and both validator results before
the same comment is finalized as the last GitHub mutation.

No issue may receive any `agent:*` label during this planning run.
