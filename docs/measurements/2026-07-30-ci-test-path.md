# CI test-path measurements — #1378

This record keeps the test-path optimization loop reproducible. Durations are
the GitHub Actions `test` job wall-clock duration, including setup and the
tmux regression step, so they describe the merge-gate path users experience.

## Method

- Run the unchanged baseline three times in GitHub Actions; do not run the
  full suite locally.
- Change one lever at a time, then compare the same job path with the
  immediately preceding measurement.
- Keep the 85% aggregate coverage gate required for every pull request.
- Re-run the final configuration to check for flakes.

## Measurements

| Run | Ref | Lever | Test job wall-clock | Delta vs. baseline median | Result |
| --- | --- | --- | ---: | ---: | --- |
| Historical context | `1ca020f8` | Pre-change successful develop run | 12m 59s | — | passed |
| Baseline 1 | pending | Unchanged test path | pending | pending | pending |
| Baseline 2 | pending | Unchanged test path | pending | pending | pending |
| Baseline 3 | pending | Unchanged test path | pending | pending | pending |
| Sharding | pending | 4-way partitioned coverage + aggregation | pending | pending | pending |
| Final stability 1 | pending | Final configuration | pending | pending | pending |
| Final stability 2 | pending | Final configuration | pending | pending | pending |

Baseline median: pending.

## Interpretation notes

The historical row is context only, not a substitute for the three committed
baseline runs. A partition run is accepted only when all four partitions pass
and the aggregation job reports the single repository-wide coverage threshold.
