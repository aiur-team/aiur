# U0 physical-line migration gate contract

Research contract only; no gate is implemented here. The frozen
`3339b887196d5e9aefb273117a14bf33391ee41f` census has 3,378 tracked
paths: 3,293 UTF-8 text, 47 binary, 38 symlinks, and 359 text paths above
500 lines ([baseline](file-size-analysis.md), lines 3–13). These numbers are
historical. U0 must regenerate a ledger from the **merged implementation-base
Git tree**, reconcile the [359 proposed owner rows](oversized-file-owner-map.csv)
with deletions/additions, and record the base commit and each path's owner,
blob identity, classification and physical-line count ([U0 plan](../../../../docs/plans/2026-09-29-001-refactor-production-readiness-plan.md), lines 138–140).

A read-only rerun of `tooling/file_size_census.py` against clean
`main@ec5a81c72616b1f99c8edfde647bc6e525e6c987` counted 3,437 tracked
paths: 3,349 UTF-8 text, 47 binary, 41 symlinks and 357 text paths above
500. This confirms the release-head debt count after the mainline plan merge;
U0 still regenerates from its own implementation head before installing a gate.

## Source and CI observations

- The existing [census script](../tooling/file_size_census.py) (lines 11–19,
  33–70) lists tracked paths at a revision, decodes UTF-8, classifies NUL or
  undecodable content as binary, lists symlinks separately, and counts LF bytes
  plus one nonempty unterminated final line. It reads a separate extraction,
  so a merge gate should read `git ls-tree` modes and `git cat-file` blobs from
  the commit being checked, avoiding workspace drift and symlink traversal.
- The [owner-map audit script](../tooling/audit_oversized_owner_map.py) (lines
  20–21, 31–34, 60–75) uses `str.splitlines()` against filesystem paths and
  pins candidate `7bce08f...`. It is historical reconciliation tooling, not
  the future gate: `splitlines()` can count separators that the LF-byte rule
  does not, and `Path.is_file()` can follow a symlink.
- [CONTRIBUTING.md](../../../../CONTRIBUTING.md) (lines 18–29) currently calls
  200 lines a review target and says CI does not fail on line count. U0 must
  update this statement when the hard gate is installed, preserving the
  200-line cohesion judgment.
- The required [CI workflow security job](../../../../.github/workflows/ci.yml)
  already checks out on every PR, merge-group and main push. By contrast, the
  required `lint` job skips its checkout and checks for website-only PRs;
  the path classifier keeps its required job name present while its steps
  short-circuit. Put the size check in `workflow security` so tracked
  `website/**` files are covered. A separate non-required job or a
  website-only-skipped step would not enforce the rule.

## Acceptance matrix

| Input at checked Git commit | Transitional gate | Final universal gate |
| --- | --- | --- |
| Tracked UTF-8 text, exactly 500 LF physical lines | Pass. | Pass. |
| Tracked UTF-8 text, 501 lines, new path or previously at most 500 | Fail with path, old/new count and owner/action. | Fail. |
| Frozen oversized path, unchanged blob/count | Pass only if present in the ledger derived from the pinned protected-main baseline Git blobs; report remaining debt. A PR cannot add itself to that grandfathered set. | Fail. |
| Frozen oversized path edited from 600 to 599, or 600 to 601 | Shrink passes with updated count; growth fails. An edited path is never silently exempt. | Both fail while above 500. |
| New path by rename/copy of oversized blob | Treat as new above-500 debt and fail; do not launder grandfathering through a path change. | Fail. |
| Exactly 200 versus 201 lines | Both pass the hard gate; at 201 emit a review prompt for a cohesion rationale. No automatic split or CI failure solely at 201. | Same. |
| 500 LF delimiters with no last newline versus 500 newline-terminated lines | First is 501 physical lines if nonempty bytes follow the 500th LF; second is 500. Empty file is zero. | Same. |
| Tracked symlink; binary blob (invalid UTF-8 or NUL) | Classify and report separately; do not dereference/count target twice or assign arbitrary binary lines. A formerly text path changing to binary, including by one NUL byte, fails unless an exact path and new-blob identity was separately reviewed and recorded on protected main before this change. | Same classification and reclassification rule; all UTF-8 text remains in scope. |
| Tracked generated, vendor, archive, test, docs, skill, CSS or lockfile text | Same size rule and owner ledger as product source, with no permanent path exclusion. | Fail at 501 regardless of directory or provenance. |

The first six rows implement the [baseline contract](file-size-analysis.md)
(lines 56–74) and [R11/U8](../../../../docs/plans/2026-09-29-001-refactor-production-readiness-plan.md)
(lines 52, 170–174). The migration rule must be made unambiguous: the baseline
contract says a "new or changed" path above 500 fails while also saying no
update may raise a grandfathered count. This note chooses **shrink-only for
already oversized paths** so component owners can retire debt in small PRs;
U0 should record that decision in the executable gate and documentation.

## Required proof before enabling

1. Generate a fresh per-path ledger from the merged-main Git tree, compare its
   oversized paths with owner-map rows and record every release deletion or
   newly oversized path. Pin the protected baseline commit and derive the
   grandfathered path/count/blob set from **that commit's Git objects**, not
   from a ledger edited in the PR under test. A tracked ledger may add owners
   and actions, but cannot create baseline eligibility. For a real text-to-binary
   migration, require a separately reviewed, previously merged protected-main
   record naming the exact path and binary blob; otherwise fail. The raw
   research branch contains additional large evidence files; keep that corpus
   on its pinned research ref, not in main
   ([promotion audit](research-promotion-and-500-line-gate.md), lines 3–23).
2. Unit-test all matrix rows against synthetic Git trees/blobs, including
   CRLF, an unterminated final line, symlink mode `120000`, an invalid UTF-8
   blob, a NUL-containing blob, and generated/vendor paths. Assert that a PR
   adding its own >500 path to the debt ledger still fails, and that an
   oversized text file changed only by appending NUL (or invalid UTF-8) fails.
   An exact, prior protected-main classification approval may pass only for
   its named path and new blob; a different blob must fail.
3. Run the check on a docs-only PR fixture and a merge-group/main fixture in
   the existing required CI context. Report debt count and offending paths in
   one bounded diagnostic; machine status fails on new/growing debt.
4. Switch to the universal gate only when a fresh census finds **zero** text
   paths above 500. Remove the transitional ledger then; no permanent
   exemptions. Keep the 200-line review prompt and publish actual before/after
   physical-line totals by source, tests, docs and generated assets.
