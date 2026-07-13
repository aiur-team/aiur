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
  `16d6033d8824c8cb53ac09e2129f69af751be8c4`
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
  `765e72d3b501238a0f4fcbca593ef87693289bc9f5377eb580cac0b21efd1058`
- Companion baseline JSON SHA-256:
  `f74bb41b9e6f9ca78e2d8178bf3a6058a21df06bc6deffd711420642682d8e8a`
- Publication manifest SHA-256:
  `a07b3131604405624f2d320d796180b79f75e4f3520d803e78dd85c20de8d9d8`
- Requirements SHA-256:
  `80e2cb7f9f9c3c2721fd553cd98851bb0a91f8d468d755755df60973fb3203b2`
- Implementation plan SHA-256:
  `ad031004100d89450d6d3b1eb4b0686ef28e4edb17af04fedd168ddd6977aa81`
- Latest validator/skill authority: isolated draft PR #1065 at
  `fb89a300075abb235e5b5c0330c8aab9c0d35c4d`
- Approval commit: pending two clean passes

The design hashes match [the manifest](design-manifest.md). The prototype was
exercised in a real browser at desktop and mobile widths, in both themes, with
route, filter, detail, scrolling, and interaction behavior recorded in
[the capability audit](06-prototype-capability-audit.md).

## Current-state refresh

The 2026-07-13 refresh found no new ticket split, owner transfer, or hard graph
edge. It did require these contract updates:

- Current main's runner `:completed/:awaiting_dispatch` state is a nonterminal
  replacement boundary. DASH-002 and BO-006 now prove that it remains visible,
  queued/unfinished, zero-capacity, and never tracker-finished.
- Closed #1034 is accepted predecessor evidence, not an active DASH-001 native
  blocker. The shared predecessor-baseline gate still requires the configured
  implementation branch to contain it and all accepted OCC successors.
- The static website Playwright setup is reusable toolchain/CI precedent, but
  no committed runner yet exercises the authenticated Phoenix/LiveView
  dashboard. BO-008 remains the owner of that harness.
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
| Publication regression suite | 20 tests pass |
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

### Clean pass 1

Pending review of an immutable checkpoint.

### Clean pass 2

Pending a second review of the unchanged candidate after clean pass 1.

## Skill verification

At isolated skill commit `fb89a300075abb235e5b5c0330c8aab9c0d35c4d`:

- 54 adversarial `aiur-build` validator tests pass;
- the canonical example validates with zero errors and warnings; and
- `aiur-build`, `aiur-run`, and `aiur-monitor` pass structure validation.

The skill changes remain isolated in draft PR #1065. They are not merged in
this planning run and require conflict reconciliation against current main.

## Publication reconciliation

Pending explicit final execution of the already authorized publication plan.
Publication must create/reconcile only the root, BO-001..015, DASH-001..015,
and SKILL-DELIVERY-001; it must not mutate read-only #132 or #845. It then
records returned identities, full observed labels, exact native parenthood and
blockers, the pending root-comment URL, and both validator results before the
same comment is finalized as the last GitHub mutation.

No issue may receive any `agent:*` label during this planning run.
