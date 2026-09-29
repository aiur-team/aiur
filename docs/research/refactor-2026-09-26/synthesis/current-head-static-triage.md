# Complete current-head citation triage — 2026-09-28

The [machine-readable triage](current-head-static-triage.json) covers every
canonical finding and source ID in [review/findings.json](../review/findings.json).
It compares frozen source `3339b887196d5e9aefb273117a14bf33391ee41f`
with fetched `origin/main` at the **same** commit on 2026-09-28. The Git tree
is `592df59873dfa45be6c41a983d78afd30117bcba`. This is a static citation
check, not a new semantic review, a runtime reproduction, or an incidence
estimate. The [earlier eight-item semantic sample](current-head-validation-2026-09-28.md)
still provides the narrower direct source reading of those findings.

## Method and meaning

Run from the research checkout with the two pinned commits:

```sh
python3 docs/research/refactor-2026-09-26/tooling/current_head_static_triage.py \
  --findings docs/research/refactor-2026-09-26/review/findings.json \
  --base 3339b887196d5e9aefb273117a14bf33391ee41f \
  --head 3339b887196d5e9aefb273117a14bf33391ee41f \
  --output docs/research/refactor-2026-09-26/synthesis/current-head-static-triage.json
```

The tool reads Git blobs at each pinned revision. A **current** source anchor
has a tracked regular file, a parseable cited line range within the frozen
file, and identical cited bytes at the same line positions on `main`. **Stale**
means the path or cited range no longer exists at the head. **Unknown** means
the frozen citation itself is out of bounds or freeform, or changed lines
require re-anchoring and semantic inspection. One non-current location makes
its source ID and canonical finding non-current. Each record also carries
`runtime_incidence: unverified` regardless of source status.

| Population | Current anchors | Stale anchors | Unknown anchors |
| --- | ---: | ---: | ---: |
| Canonical findings | 960 | 0 | 26 |
| Raw source IDs | 1,007 | 0 | 26 |
| Cited locations | 4,929 | 0 | 32 |

The 32 unknown locations are 25 frozen line ranges outside their cited files
and seven freeform references. All 1,295 distinct cited paths exist in the
unchanged public tree. No result says a finding is true, reachable, severe on
current traffic, or ready to implement. In particular, zero stale anchors is
an expected consequence of `main` still equaling the frozen revision; rerun
against the first merged release head before assigning work.

## Severity and disposition readiness

| Reviewed severity | Canonical count | Current source | Unknown source | Next review |
| --- | ---: | ---: | ---: | --- |
| P0 | 3 | 3 | 0 | Reproduce reachable paths and constrain blast radius; the [earlier sample](current-head-validation-2026-09-28.md) reads all three mechanisms. |
| P1 | 94 | 92 | 2 | Repair `build-order-02` and `web-rest-08` citations; then check exposure and behavior before ticketing. |
| P2 | 674 | 658 | 16 | Triage all 674 for current use, duplicates, owner and action/defer reason. Fix the 16 anchors first. |
| P3 | 215 | 207 | 8 | Triage all 215 for current use, duplicates, owner and action/defer reason. Fix the eight anchors first. |

The P2/P3 population is **889 canonical findings**, with 865 current source
anchors and 24 unknown anchors. It is not 889 confirmed current defects.
The original review's 851 provisional P2/P3 *raw source IDs* is a different
denominator; merged canonical severities and raw-review provenance must not be
conflated. No current-head semantic disposition has been completed for these
889, so the implementation-ready count from this triage is **zero**.

The two high-priority unknowns are `build-order-02` (one cited range exceeds
its file) and `web-rest-08` (four cited ranges exceed their files). The JSON
names every lower-priority unknown ID, path and line reference without
repeating the 4,929 current citations. These are citation defects, not proof
that the underlying proposed issues are false.

## Next validation boundary

Fetch merged `main`, rerun the pinned comparison with its full commit SHA, and
manually inspect every changed or invalid anchor against the code around it.
Then assign each of the 986 canonical findings a current-head semantic
disposition, reachable population, owner and action or defer reason. Runtime
tests are still needed for the behavioral P0/P1 claims; source equality cannot
substitute for the foreground CLI/TUI acceptance required by the [CE plan](../../../plans/2026-09-29-001-refactor-production-readiness-plan.md).
