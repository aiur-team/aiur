# Research continuation

The user resumed the full research goal on 2026-09-26. The pause recorded in
`HANDOFF.md` is historical; no fleet operation or production implementation is
authorized by this research goal. The original handoff is preserved.

## Authoritative sources

- Research branch: `research/refactor-2026-09-26`.
- Working research directory: `~/.aiur/research/refactor-2026-09-26/`.
- Complete frozen code: path in local `scratch/complete-snapshot-path.txt`,
  commit `3339b887196d5e9aefb273117a14bf33391ee41f`.
- The original partial extraction is preserved. It matched 2,692 Git blobs but
  omitted 686 tracked paths. The complete extraction matches all 3,378 blobs;
  see `synthesis/snapshot-audit.json`. Missing areas include runtime guard
  scripts, browser files, configuration, examples and workflow files, so the
  final coverage review must account for them explicitly.
- The initial codebase boundary report measured `0972f0297`, not the later
  frozen review revision. Report both revisions wherever counts differ.

## Evidence repairs completed

`synthesis/verdicts/done.json` originally lost every `lens` label during export.
All 40 results matched local journal objects exactly. The restored metadata
records the label, workflow result key and journal hash. This is recovered
provenance, not 40 new verification passes. Reproduction tool:
`tooling/recover_claim_provenance.py <done.json> <local-journal.jsonl>`.

The initial recovered inventory was 36 of 60 claims with both lenses present,
two more with only a reproduction check, and 22 untouched. The inherited
"37 checked" count was wrong. `tooling/research_inventory.py <research-root>`
recomputes current artifact coverage and rejects ambiguous lens duplicates.
Its JSON output is saved at `synthesis/research-inventory.json`; artifact
presence does not prove a verdict is right.

New checks corrected `codebase-08` and `codebase-09`, with methods and limits in
`synthesis/verdicts/claims-codebase-control.json`. The source report was amended.
Two checks were performed sequentially by the continuing researcher; they are
not represented as independent agents. `synthesis/privacy-review.md` records the
privacy audit's completed corrections and still-open scope.

## Further architecture and privacy checkpoint

Six additional combined checks cover `codebase-02` through `codebase-06` and
`codebase-10`, bringing artifact coverage to 44 of 60 claims with both lenses.
See `synthesis/architecture-verification.md` for corrected conclusions,
revision-specific graph counts, reproduction commands and parser limitations.
The graph tool parses source without compiling or booting Aiur. Both saved
summaries reproduce exactly. Attention routing (`codebase-07`) remains open. The checkpoint now includes a
14-topic membership sample and confirmed alternate pause-attention path; the
complete emit-site census and condition-level coverage remain outstanding.

Privacy corrections preserve every numerical CSV measurement and public row;
76 private identifier/chronology cells were blanked. Three verdict fields were
redacted after provenance recovery, with explicit metadata. The title/body
comparison supplements rather than completes the contextual privacy audit.

## Gap measurement checkpoint

The independent arithmetic audit reproduced all 202 historical attendance
fractions and found 67 above one, caused by whole-minute numerators divided by
exact durations. `gaps.csv` retains every previous cell and adds a bounded
`duration_weighted_attended_frac`; the corrected aggregate barely changes and
the 86/108 majority-attended count is unchanged. See
`synthesis/gap-measurement-verification.md` for methods and limits.

Claim gaps-02 now has reproduction and interpretation checks, bringing artifact
coverage to 45/60. Its 78% bucket arithmetic reproduces, but it is not a causal
share proving human bottleneck ownership. Gaps-01 and the remaining causal
claims still require their full source checks. No category was silently
reassigned or prior numeric field overwritten.

## Wake-consumption checkpoint

Claim gaps-09 is checked, bringing both-lens coverage to 46/60. The cursors and
backlog counts reproduce, but a successful later tool result returned wake 419
while the observed cursor remains 352. Above-cursor records are not necessarily
unseen. The frozen implementation already has owner acknowledgements, observer
reads, bounded retention/overflow reporting and stalled-consumer status.
Metadata-only evidence and a reproduction tool are published. Action completion
and escalation must be evaluated separately; no consumer state was changed.

## Completion contract — all still required unless explicitly checked

- [ ] Complete privacy/provenance review of inherited and new public artifacts.
- [ ] Finish both checks on all 60 claims; retain corrections and disagreement.
- [ ] Correct all six source reports where verdicts contradict their headlines.
- [ ] Complete the 32 planned review units and coverage follow-ups, including
      the runtime areas omitted from the old extraction.
- [ ] Skeptic-check every P0/P1 finding; retain P2/P3 with honest verification
      status. Deduplicate without losing any source ID.
- [ ] Produce `review/code-review.md`, `review/findings.json`, and
      `review/by-boundary.md`, then audit source-ID coverage and counts.
- [ ] Challenge every cut/merge/externalize recommendation and account for
      features omitted from the five inventories.
- [ ] Produce `features/feature-inventory.md`, `features/usage-matrix.md`,
      `features/loc-reduction.md`, and `features/features.json`; measure physical
      LOC without double counting shared modules. Distinguish predicted savings
      from measured change and moving code from removing it.
- [ ] Produce `synthesis/verified-claims.md`, `problem-map.md`,
      `contradictions.md`, `rewrite-requirements.md`, and `open-questions.md`.
      Tie idle-gap explanations to measured evidence, not structural guesses.
- [ ] Audit all eight research questions in README against concrete evidence.
- [ ] Run CE brainstorm, plan, and deepen-plan; write requirements and a
      detailed evidence-linked plan under `docs/brainstorms` and `docs/plans`.
- [ ] Commit and push incremental research; verify remote head directly.
- [ ] Final requirement-by-requirement audit before completing the goal.

## Publishing

Keep the working research directory and selected branch artifacts synchronized.
The inherited `sync.sh` hides push failures with `|| true`; do not use its final
log line as proof of publication. Commit explicit research paths and check the
actual push result and remote branch SHA. Do not copy scratch directories.
Do not change the live main checkout or the shared release directory.
