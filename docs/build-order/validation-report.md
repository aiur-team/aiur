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
  `bc02b3a42431bf1953a6adcdeea9203fdfee6a3347ee338fe7f33346efa71ae2`
- Companion baseline JSON SHA-256:
  `c0d78ad9fd66c81d288f085e1c9b27aaa94aab8c548a0ae1bf2154b5d78fe7b9`
- Publication manifest SHA-256:
  `3e9224af9e8c93fb8d4ecf6a8fb298375f1e62c4e10936cf2937e5597e021efb`
- Requirements SHA-256:
  `5b01d66ea6cc7ef3e063e7be0e996840ea7ee976ee93a2a5812ee070be2b2a86`
- Implementation plan SHA-256:
  `78d2eda7aac863cec51ac7de6fda53b9fd05cfa7941727cb48869cf6b25f6237`
- Latest validator/skill authority: isolated draft PR #1065 at
  `0daf29726fbe8345a79588e14b6f4c556584a57c`
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
| Publication regression suite | 37 tests pass |
| Build Order tickets | 16, 61 complexity points |
| Standalone companions | 22, 75 complexity points |
| Planned GitHub materialization | 40 new issues: one root, 38 executable issues, one human issue |
| Logical IDs | Unique across BO, DASH, root, and skill delivery |
| Hard-edge graph | Acyclic across BO and DASH dependencies |
| Ticket documents | Paths, complexities, requirement refs, dependencies, and external gates match structured records |
| Requirements | Bidirectional BOREQ-001..015 plus exact unique DREQ-001..022 coverage |
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
5. BO-008's toolchain/fixture/artifact/performance scope was undersized; it was
   raised to complexity 4, producing the then-current 58-point graph. The final
   BO-016 split in corrective pass 4 produces the current 61-point graph.
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
   boundaries for the current twenty-two-ticket pack.
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

### Corrective pass 4 — executable ticket boundaries

This pass was not clean. A final prototype-to-main comparison and independent
complexity audit found several tickets that still bundled independently
reviewable backend programs. It corrected:

1. BO-001 had become a false prerequisite for event identity and the browser
   harness. BO-001, BO-004, and BO-008 are now independent initial nodes, each
   directly protected by GATE-001 and GATE-002.
2. Generic repository-qualified issue detail, bounded caching, deep-link base
   context, and accessibility lacked a reusable owner. BO-016 now owns that
   foundation; BO-011 is only the Build Order relationship-context adapter.
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
Publication must create/reconcile only the root, BO-001..016, DASH-001..022,
and SKILL-DELIVERY-001; it must not mutate read-only #132, #845, #1033, #1034,
or #1067. It then records returned identities, full observed labels, exact
native parenthood and blockers, all 40 re-read issue-body markers and hashes,
structured pending root-comment evidence, and both validator results before
the same comment is finalized as the last GitHub mutation.

No issue may receive any `agent:*` label during this planning run.
