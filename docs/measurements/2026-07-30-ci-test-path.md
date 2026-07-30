# CI test-path measurements — #1378

This record keeps the test-path optimization loop reproducible. Durations are
the full GitHub Actions test-path critical path: from the first test runner
starting until the aggregate `test` job completes tmux regression. Before
sharding this is the `test` job duration; after sharding it includes the longest
partition plus regression. The unchanged full-suite `coverage` job remains a
separate required PR gate and reports the repository-wide 85% threshold.

## Method

- Run the unchanged baseline three times in GitHub Actions; do not run the
  full suite locally.
- Change one lever at a time, then compare the same job path with the
  immediately preceding measurement.
- Keep the 85% coverage gate required for every pull request.
- Re-run the final configuration to check for flakes.

## Measurements

| Run | Ref | Lever | Test-path wall-clock | Delta vs. baseline median | Result |
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
baseline runs. A partition run is accepted only when all four partitions and
the aggregate regression job pass; the separate coverage job must also report
the single repository-wide coverage threshold.
