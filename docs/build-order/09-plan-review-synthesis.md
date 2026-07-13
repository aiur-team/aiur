# Plan review synthesis (independent second review)

Nine-lens parallel review of the Build Order planning pack: four
codebase-grounding passes against `origin/main@9849f329` (35 tickets deep-read,
56 factual claims verified), plus coherence, worker-readiness, scope/product,
reference-comparison (OCC #971, refactor #732, optimism/actions#513), and
skill/validator lenses. Companion artifacts: `07-graph-parallelism-review.md`
(graph analysis) and `08-implementation-pointers.md` (the concrete per-ticket
anchors this review found missing).

## Overall verdict

The decomposition itself is high quality: the 34-ticket companion graph plus
the 19-ticket BO graph is mechanically clean (no cycles, no dangling refs, the
point totals and blocker-edge estimates reproduce exactly), boundaries are
deliberate and mostly load-bearing, the Analytics exclusion is respected
everywhere, and the claims it makes about the current codebase are almost all
true (49 of 56 verified TRUE/PARTIAL; the PARTIALs are documented in
`08-implementation-pointers.md`).

The pack has three real problems, in descending order:

1. **Worker readiness.** The tickets are review-proof constraint contracts but
   poor work orders for the cheap codex models that will implement them —
   across eight sampled tickets there is not one file path, function
   signature, or example data shape, and several named reuse targets are
   phantoms (no JS asset pipeline exists for BO-009; no `Aiur.EventBus`; no
   CSP; no dialog focus helpers; `DecisionHistory`/`DecisionPresenter` are not
   the as-built module names). Readiness ratings ranged 2–4 of 5.
   **Remediation shipped:** `08-implementation-pointers.md` provides the
   missing layer for 35 tickets; the remaining 18 need the same treatment
   before dispatch, and each ticket body should grow an `## Implementation
   pointers` section (or an explicit link to its section in 08) when the
   manifests are regenerated.
2. **Split-brain propagation.** The canonical JSON manifest, companion index,
   README, validation report, Executor handoff, publication validator
   constants (46/73), four ticket titles, the OCC-gate lines in 18+16 ticket
   files, and eight skill-SHA pins all still describe the retired
   25-ticket/46-issue world. The 34-ticket ticket set cites nine requirement
   IDs (DREQ-026..034) that exist nowhere. The vendored skill copy on this
   branch is the skill's *first* commit (b8f11ea7), which fails the pack's own
   `build-order.json` with 43 unknown-key errors. All mechanical; worklist
   below.
3. **Two scope/process programs that need an explicit product decision** —
   see Questions. The 17-ticket usage/cost-accounting family (~58 points,
   whose user-visible payoff is transitively blocked on two human-owned Claude
   protocol gates) and the publication receipt/verifier ceremony (~19 scripts
   sized for a hostile supply chain) both exceed the feature the user
   described. Neither should be silently deleted — both were discussed during
   planning — but neither should silently consume half the program either.

## What the graph analysis found (see 07)

- 53 tickets schedule into 10 waves; waves 1–4 are healthy and wide.
- The BO backbone is a fully serial 10-ticket chain — the wall-clock floor.
- Wave 7 is false parallelism: seven UI tickets pairwise serialized on shared
  `DashboardLive` composition. Recommendation: per-page LiveView modules
  (`UnitsLive`, `CommandsLive`, `BuildOrderLive`) mounted by the DASH-001
  shell, dissolving the clique structurally.
- DASH-003 (fan-out 8, the companion spine) is gated behind the BO track via
  BO-018; downgrade to a contract dependency with the existing log modal as
  the documented temporary path.
- DASH-001 (shell) hard-depends on BO-008 (browser harness) — the same
  pattern; the Units/Commands catch-up (the user's fastest visible win)
  cannot start until BO infrastructure lands. Downgrade to serialize-with and
  verify the shell with the existing screenshot runner until BO-008 lands.

## What the reference comparison found

Compared against the three packages that real agent fleets executed
successfully (OCC #971, refactor #732, optimism/actions#513): this pack is
structurally richer than all three (typed deps, non-goals, gates — worth
keeping), but the executed packages won on concreteness: OCC tickets named
real modules/files and quoted design sections; the refactor package carried a
1,062-entry feature inventory as its anti-regression contract. The missing
element here is exactly the implementation-pointer layer, now added.

## Reconciliation worklist (mechanical, no product decision needed)

1. Regenerate `dashboard-companions.json` from the 34 ticket headers (deps,
   serialization, complexity, H1 titles — fixes the four title mismatches and
   the DASH-008/011/015/023 drift).
2. Repin `afd9828c` → `f92aa045` in all eight locations (EXECUTOR-HANDOFF.md,
   skill-delivery.md, validation-report.md ×3, build-order.json GATE-002,
   scripts/publication_core_receipt.py, root-issue.md, 05-technical-decisions.md)
   and refresh the 115/41 test-count evidence.
3. Re-vendor the skill at `f92aa045` under `.claude/skills/aiur-build/`.
4. Normalize the OCC predecessor gate to the resolved-baseline convention
   (`**Predecessor baseline:** resolved — origin/main@9849f329`) across all 34
   companion tickets, drop `GATE-OCC-PREDECESSOR-BASELINE` from active
   `external_gate_ids`, and update both handoffs + `dashboard-companions.md`.
5. Write DREQ-026..034 and re-scope DREQ-003/005/008/011/015/023 in the
   requirements doc.
6. Fix DASH-031 serialization (DASH-032 → DASH-034); add the reverse edges
   for the one-sided DASH-026/027/028/034 serializations (or drop forward).
7. Reword DASH-031's sibling prose so it cannot be read as depending on
   DASH-023.
8. Update counts/prose in README.md, dashboard-companions.md (34 rows / 111
   points), EXECUTOR-HANDOFF.md (55 issues / 102 blockers if the set stands),
   and banner validation-report.md as stale pending re-run.
9. Derive `EXPECTED_ISSUES`/`EXPECTED_BLOCKED_BY_EDGES` in
   `scripts/publication_live_graph.py` from the manifests instead of literals.
10. Propagate the DASH-026..034 evidence into `02-dashboard-design-delta.md`
    (the Fleet-row modal motivation is recorded only in PLANNING-HANDOFF) and
    `04-usage-accounting.md`/`06-prototype-capability-audit.md` ownership
    tables.

## Skill (/aiur-build, PR #1065) verdict

Genuinely generic — nothing instance-fitted; validators are unusually well
built (stdlib-only, hermetic, 115/115 at f92aa045, adversarial coverage).
Defects: (a) schema evolved breakingly twice without a `schema_version` bump —
version mismatches surface as dozens of unknown-key errors instead of one
version error; (b) the flagship instance already outgrew it (the companion
baseline fails the skill validator with ~1,072 errors, so the pack grew a
bespoke 19-module publication suite the skill never mentions); (c) it needs a
worked end-to-end mini example, and invariants 9–12 have no mechanical check;
(d) amendments landing on the skill branch from this review: a sizing-
calibration question in the brainstorm stage, implementation-pointers as
required ticket content, and design-for-parallelism rules in the graph stage
(wave-profile audit, serialization-clique dissolution, contract-vs-
implementation dependencies, spine staffing).

## Questions for Kevin (decision ledger)

1. **Usage/cost accounting family (17 tickets, ~58 pts).** The design's own
   constraints doc never mentions usage/meters; the delta doc classifies token
   totals as "not a requirement"; and the family's payoff (DASH-031) is
   transitively blocked on two *human* Claude-protocol gates, so cheap codex
   agents cannot deliver its value unaided. Options: (a) keep as-is; (b) cut
   this wave to a design-parity slice (~3–4 tickets: current-run meters over
   the existing TokenAccounting + Codex rate-limit snapshot, auth boundary,
   honest Claude unknowns) and move the durable ledger/pricing/OTEL program to
   #845 as a separately authorized wave — **recommended**; (c) drop entirely.
2. **Publication ceremony.** Keep the full immutable-receipt/graft-rejection/
   two-clean-reviews machinery, or collapse to the minimal safe subset (one
   idempotent render+publish script, one requery-and-diff verification, one
   human review of rendered bodies before creation) — **recommended**. The
   requery-diff is worth keeping regardless (documented OCC-era drift).
3. **Merge candidates** (each pair currently mutually serialized, so merging
   costs no parallelism and removes rebase cascades): BO-009+010, BO-013+014,
   BO-005+006, DASH-006+017, DASH-012+020, DASH-028→005, DASH-032+034,
   DASH-026+027, DASH-014+022, and (if accounting survives) DASH-011+030,
   DASH-015+031. Accepting most lands the program near 30–35 issues.
   Grounding note: the accounting storage chain (009/024/025) and
   contract-vs-adapter splits are load-bearing — keep those.
4. **Structural parallelism changes** (per 07): per-page LiveViews via
   DASH-001; BO-012 decoupled from BO-011; DASH-003/BO-018 and DASH-001/BO-008
   downgraded to contract dependencies. Ratify?
5. **/aiur-build automation ownership.** Add one executable ticket (or extend
   skill-delivery acceptance) proving the skill regenerates a planning pack
   from a requirements doc (or a second-feature dry run), and decouple skill
   review from the dashboard-run-completion gate — otherwise "automate the
   creation of planning packages" ships nothing verifiable this wave.

## Facts corrected during this review

- `Aiur.GitHub.Transport` exists as named (BO-002's extension seam is real).
- PR #1012 is open, not merged, and the pack characterizes it fairly.
- `Slots` read/adjust/set APIs exist; DASH-028 is correctly UI-only.
- `Boot.started_at/0` already exists (DASH-014's contingency is unnecessary).
- Pause/resume acks already round-trip `request_id` on pause (DASH-004's real
  gap is only the resume ack + correlation).
- `ecto` is already a dependency (repo-less), so `Decimal` is available for
  exact-money work — no new dependency decision needed.
